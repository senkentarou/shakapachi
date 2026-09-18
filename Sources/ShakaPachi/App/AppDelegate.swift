import AppKit

// AppDelegate.swift
// The app's wiring diagram: it CREATES every part once at launch and CONNECTS
// them, then manages lifecycle. It holds no switch logic — it only composes.
//
// Wiring at a glance (AppDelegate builds these once and connects them):
//
//   HotkeyTap ──> SwitchCoordinator ──> WindowStore    (enumerate + MRU)
//   (CGEventTap)  (drives one cycle)├──> IconCache      (pre-scaled icons)
//                                   ├──> SwitcherPanel  (the floating row)
//                                   ├──> Activator      (raise the window)
//                                   ├──> StatsStore     (switch counts)
//                                   └──> PermissionManager (gate preview)
//
//   Lifecycle side (created and retained by AppDelegate):
//     StatusItemController ──> PermissionManager   (menu-bar icon + menu)
//     PermissionManager                            (AX + Screen Recording)
//
// See docs/ARCHITECTURE.md "Layered component map" for the full graph.

// NSApplicationDelegate callbacks are called on the main thread by the
// framework. We annotate each method with @MainActor explicitly so Swift 6
// strict concurrency can verify this without requiring the class-level
// annotation (which would make the init @MainActor and break top-level code).
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItemController: StatusItemController?
    private var permissionManager: PermissionManager?
    private var onboardingWindow: OnboardingWindow?
    private var hotkeyTap: HotkeyTap?

    // Orchestrates the switch cycle (trigger → panel → move → confirm/cancel).
    // Created and wired in startTapIfPossible(); see SwitchCoordinator.swift.
    private var switchCoordinator: SwitchCoordinator?

    // Panel created once at startup, retained forever.
    private var switcherPanel: SwitcherPanel?

    // Real window data source and pre-scaled icon cache.
    private var windowStore: WindowStore?
    private var iconCache: IconCache?

    // Activator created once at launch in applicationDidFinishLaunching and
    // retained for the lifetime of the app. Optional only to avoid calling the
    // @MainActor init from a non-isolated stored-property context (Swift 6).
    private var activator: Activator?

    // Settings window controller — retained here because NSWindow.delegate
    // is weak; a local would dealloc and leave activation policy stuck at .regular.
    private var settingsWindow: SettingsWindow?

    // Update window controller — same retention rationale as settingsWindow.
    private var updateWindow: UpdateWindow?

    // Settings change observer token (NotificationCenter).
    private var settingsObserver: (any NSObjectProtocol)?
    // Observer tokens for one-shot notification subscriptions registered in
    // applicationDidFinishLaunching. Retained here so they can be removed on
    // applicationWillTerminate and do not outlive the delegate.
    private var onboardingObserver: (any NSObjectProtocol)?
    private var relaunchObserver: (any NSObjectProtocol)?

    // Key for the first-run login-item flag: written once after the initial
    // SMAppService registration so a subsequent user toggle to OFF is not
    // overridden on relaunch.
    private static let didInitializeLoginItemKey = "didInitializeLoginItem"

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture the language that was active at launch so Settings can tell
        // whether a relaunch is needed to apply a language change.
        Settings.launchLanguage = Settings.shared.appLanguage

        // Run as a menu-bar accessory: no Dock icon, no activation on launch.
        NSApp.setActivationPolicy(.accessory)

        // Create Activator on main actor (must be done here, not at
        // stored-property init time, because of @MainActor isolation).
        self.activator = Activator()

        // Create the panel once here; never destroy it.
        let panel = SwitcherPanel()
        self.switcherPanel = panel

        // Apply the saved theme immediately at launch.
        applyTheme(Settings.shared.theme)

        // Real data source + icon cache, created once and retained.
        let settings = Settings.shared
        self.windowStore = WindowStore(excludedBundleIDs: Set(settings.excludedBundleIDs))
        self.iconCache = IconCache()

        #if DEBUG
            // N5 timing measurement: run enumerate() 10 times and log min/median/max.
            // This requires the app to be launched as a signed .app bundle so that
            // screen recording TCC permission is active and kCGWindowName is populated.
            measureWindowStoreN5()
        #endif

        let pm = PermissionManager()
        self.permissionManager = pm

        let sc = StatusItemController(permissionManager: pm)
        self.statusItemController = sc

        // Menu toggle drives the tap lifecycle (also the recovery path after
        // a deadman fire).
        sc.onToggleTap = { [weak self] enable in
            guard let tap = self?.hotkeyTap else { return }
            if enable {
                tap.enable()
            } else {
                tap.disable(reason: NSLocalizedString("メニューから無効化", comment: "Tap disabled from menu"))
            }
        }

        // Settings menu item: open the settings window with Cmd+,
        sc.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        // Close the Settings window from the menu when it is open (tray toggle).
        sc.onCloseSettings = { [weak self] in
            self?.settingsWindow?.close()
        }

        // "Check for Updates…" tapped: open the window and immediately kick off a check.
        sc.onCheckForUpdates = { [weak self] in
            self?.showUpdateWindow()
            UpdateManager.shared.checkForUpdates(userInitiated: true)
        }

        // Single status subscriber — always called on the main thread.
        UpdateManager.shared.onStatusChange = { [weak self] status in
            switch status {
            case .available(let r):
                self?.statusItemController?.setUpdateAvailable(r.version.description)
            case .upToDate, .idle:
                self?.statusItemController?.setUpdateAvailable(nil)
            default:
                break  // keep badge visible during download / verify / install / failed
            }
            self?.updateWindow?.apply(status)
        }

        // Live settings: observe all settings changes and apply immediately.
        // The observer closure is @Sendable, so it captures a Sendable weak box
        // rather than `self` (a non-Sendable @MainActor NSObject) directly. The
        // .main queue guarantees the body runs on the main thread.
        let selfBox = WeakDelegateBox(self)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                selfBox.value?.applySettingsChanges()
            }
        }

        // Observer for the onboarding window trigger from the permissions tab.
        onboardingObserver = NotificationCenter.default.addObserver(
            forName: .showOnboardingWindow, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                selfBox.value?.showOnboarding()
            }
        }

        // Observer for the relaunch request (e.g. after a language change).
        relaunchObserver = NotificationCenter.default.addObserver(
            forName: .relaunchApp, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                selfBox.value?.relaunchApp()
            }
        }

        // Check permissions and show onboarding if any are missing.
        if !pm.allPermissionsGranted() {
            showOnboarding()
            NSLog(
                "[ShakaPachi] Permissions missing — showing onboarding. " + "Accessibility: %@  ScreenRecording: %@",
                pm.accessibilityStatus() == .granted ? "granted" : "denied",
                pm.screenRecordingStatus() == .granted ? "granted" : "denied")
        } else {
            NSLog("[ShakaPachi] All permissions granted — normal startup.")
            startTapIfPossible()
        }

        // Schedule background update checks (initial: 10 s after launch, then every 24 h).
        UpdateManager.shared.startAutoCheck()

        // First-run login-at-launch registration: register with SMAppService once
        // so the default is ON. The flag prevents re-enabling after the user
        // turns it OFF manually. A failure is logged but never crashes the app.
        let loginItemKey = AppDelegate.didInitializeLoginItemKey
        if !UserDefaults.standard.bool(forKey: loginItemKey) {
            do {
                try LoginItemManager.setEnabled(true)
                NSLog("[ShakaPachi] First-run: login item registered.")
            } catch {
                NSLog(
                    "[ShakaPachi] First-run: login item registration failed: %@",
                    error.localizedDescription)
            }
            // Mark as initialized regardless of success so we don't retry every
            // launch (a failure likely means sandbox/location restrictions that
            // won't resolve on retry).
            UserDefaults.standard.set(true, forKey: loginItemKey)
            Settings.shared.launchAtLogin = LoginItemManager.isEnabled
        }

        #if DEBUG
            // DEBUG self-check (completion gate): simulate one trigger to get an
            // N1 proxy without synthesising CGEvents. Do this after the tap is set
            // up so the code path is realistic, but use a synthetic t0 = now.
            // Runs whenever the panel exists (independent of the tap/permissions),
            // so it computes its own item list from windowStore/iconCache rather
            // than reaching through the coordinator, which may not be wired yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let panel = self.switcherPanel else { return }
                let items = self.debugCurrentSwitcherItems()
                guard !items.isEmpty else {
                    NSLog("[ShakaPachi] N1 self-check skipped: 0 windows")
                    return
                }
                let syntheticT0 = CFAbsoluteTimeGetCurrent()
                let debugPreviewEnabled =
                    Settings.shared.showWindowPreview
                    && (self.permissionManager?.screenRecordingStatus() == .granted)
                // Initial selection: previous window (index 1) when there are two
                // or more, otherwise the only window (index 0) — same rule the
                // coordinator applies at show time.
                let debugInitialIndex = items.count >= 2 ? 1 : 0
                panel.show(
                    items: items,
                    selectedIndex: debugInitialIndex,
                    previewEnabled: debugPreviewEnabled)
                panel.displayIfNeeded()
                let n1 = (CFAbsoluteTimeGetCurrent() - syntheticT0) * 1000.0
                NSLog(
                    "[ShakaPachi] N1: %.2fms (callback→display, %d windows) [DEBUG self-check]",
                    n1, items.count)
                if n1 > 50.0 {
                    NSLog("[ShakaPachi] N1 GATE FAIL: %.2fms exceeds 50ms budget", n1)
                } else {
                    NSLog("[ShakaPachi] N1 GATE PASS: %.2fms within 50ms budget", n1)
                }
                // Hide after 0.5s so the developer can see the panel.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.switcherPanel?.hide()
                }
            }
        #endif
    }

    @MainActor
    private func startTapIfPossible() {
        guard hotkeyTap == nil,
            permissionManager?.allPermissionsGranted() == true
        else { return }
        let tap = HotkeyTap()

        // Initialize the tap with the current settings values.
        let settings = Settings.shared
        tap.triggerModifierMask = settings.triggerModifier.eventFlagMask
        tap.triggerKeyCode = settings.triggerKey.keyCode

        tap.onStateChange = { [weak self] state in
            switch state {
            case .active:
                self?.statusItemController?.updateTapState(enabled: true, reason: nil)
            case .stopped(let reason):
                self?.statusItemController?.updateTapState(enabled: false, reason: reason)
            }
        }

        // Route all switcher inputs through the SwitchCoordinator, which owns the
        // state machine and executes each returned action. The callback runs on
        // the main run loop and is invoked synchronously within the tap callback
        // (no async hop needed for the consume decision), so the coordinator does
        // only cheap, non-blocking work and returns the consume boolean directly.
        // Requires windowStore/iconCache/activator, all created in
        // applicationDidFinishLaunching before this method can run.
        guard let windowStore = self.windowStore,
            let iconCache = self.iconCache,
            let switcherPanel = self.switcherPanel,
            let activator = self.activator
        else { return }
        let coordinator = SwitchCoordinator(
            windowStore: windowStore,
            iconCache: iconCache,
            switcherPanel: switcherPanel,
            activator: activator,
            permissionManager: permissionManager)
        self.switchCoordinator = coordinator

        // [weak coordinator]: the tap is torn down before the delegate, but the
        // coordinator is delegate-owned, so hold it weakly and fall back to the
        // non-consuming default if it has been released.
        tap.onSwitcherInput = { [weak coordinator] input, t0 in
            coordinator?.handleInput(input, t0: t0) ?? false
        }

        hotkeyTap = tap
        tap.enable()
    }

    #if DEBUG
        /// Enumerate the current windows and map them to switcher items for the
        /// DEBUG N1 self-check. Kept on AppDelegate (rather than reusing the
        /// coordinator's copy) because the self-check runs whenever the panel
        /// exists, even before the tap and coordinator are wired.
        @MainActor
        private func debugCurrentSwitcherItems() -> [SwitcherItem] {
            guard let windowStore, let iconCache else { return [] }
            let settings = Settings.shared
            return windowStore.enumerate(
                currentSpaceOnly: settings.currentSpaceOnly,
                sortMode: settings.sortMode
            ).map { info in
                SwitcherItem(
                    icon: iconCache.icon(for: info.pid, bundleID: info.bundleID),
                    title: info.title,
                    windowID: info.windowID
                )
            }
        }
    #endif

    // MARK: - Settings live-wire

    /// Apply all settings that take effect immediately when they change.
    /// Called via NotificationCenter whenever any Settings value is set.
    @MainActor
    private func applySettingsChanges() {
        let settings = Settings.shared

        // -- triggerModifier / triggerKey → HotkeyTap --
        // Update the stored plain values; the tap reads them inside the callback
        // without calling into Settings/AppKit (hot-path safe).
        if let tap = hotkeyTap {
            tap.triggerModifierMask = settings.triggerModifier.eventFlagMask
            tap.triggerKeyCode = settings.triggerKey.keyCode
        }

        // -- excludedBundleIDs → WindowStore (live update, MRU preserved) --
        windowStore?.excludedBundleIDs = Set(settings.excludedBundleIDs)

        // -- theme → NSApp.appearance --
        applyTheme(settings.theme)

        // currentSpaceOnly and sortMode are read at enumerate() call time (no
        // stored state to update here). showDelayMs is read at show time.
    }

    /// Apply the given theme to NSApp.appearance so the entire UI (including
    /// the switcher panel and settings window) reacts immediately.
    @MainActor
    private func applyTheme(_ theme: Theme) {
        NSApp.appearance = theme.nsAppearance
    }

    // MARK: - Settings window

    /// Open the settings window. Creates it if it doesn't exist yet.
    @MainActor
    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
        }
        settingsWindow?.show()
    }

    /// Open the update window. Creates it if it doesn't exist, then syncs to the current status.
    @MainActor
    private func showUpdateWindow() {
        if updateWindow == nil { updateWindow = UpdateWindow() }
        updateWindow?.show()
        updateWindow?.apply(UpdateManager.shared.status)
    }

    /// Show the onboarding/permissions window. Called from the permissions tab
    /// in SettingsWindow and from the permission status menu item.
    @MainActor
    private func showOnboarding() {
        guard let pm = permissionManager else { return }
        if onboardingWindow == nil {
            let ow = OnboardingWindow(permissionManager: pm) { [weak self] in
                self?.statusItemController?.updatePermissionWarning()
                self?.startTapIfPossible()
            }
            onboardingWindow = ow
        }
        onboardingWindow?.show()
    }

    /// Relaunch the app. Delegates to PermissionManager.relaunchApp() which
    /// opens a new instance via NSWorkspace and then terminates self.
    /// permissionManager is always non-nil after applicationDidFinishLaunching,
    /// and this observer is only registered there, so the guard is always satisfied.
    @MainActor
    private func relaunchApp() {
        guard let pm = permissionManager else { return }
        pm.relaunchApp()
    }

    // MARK: - Prevent spurious quit

    // Prevent AppKit from quitting the process when all windows close.
    // As a menu-bar accessory the app has no main window, so this callback
    // would otherwise trigger immediately and exit the process.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // Tear the tap down so modifier keys are not left in a stuck state
        // after the process exits.
        hotkeyTap?.disable(reason: "app terminating")

        // Remove notification observers to avoid delivering to a deallocated delegate.
        if let token = settingsObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = onboardingObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = relaunchObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Sendable weak wrapper so @Sendable NotificationCenter closures can hold a
    /// reference to the (non-Sendable, @MainActor) delegate without a capture
    /// warning. Access is always re-isolated to the main actor before use.
    private final class WeakDelegateBox: @unchecked Sendable {
        weak var value: AppDelegate?
        init(_ value: AppDelegate?) { self.value = value }
    }

    #if DEBUG
        // Measure WindowStore.enumerate() 10 times and log each result plus
        // min/median/max so the N5 gate (≤5ms) can be verified from the system log.
        @MainActor
        private func measureWindowStoreN5() {
            let store = WindowStore()
            let runs = 10
            var durations: [Double] = []
            var windowCount = 0
            for i in 1...runs {
                let start = Date()
                let windows = store.enumerate()
                let elapsed = Date().timeIntervalSince(start) * 1000.0
                durations.append(elapsed)
                windowCount = windows.count
                NSLog("[ShakaPachi] N5 run %d: %.2fms  windows=%d", i, elapsed, windows.count)
            }
            let sorted = durations.sorted()
            let minMs = sorted.first ?? 0
            let maxMs = sorted.last ?? 0
            let medianMs: Double = {
                let mid = sorted.count / 2
                if sorted.count % 2 == 0 {
                    return (sorted[mid - 1] + sorted[mid]) / 2.0
                }
                return sorted[mid]
            }()
            NSLog(
                "[ShakaPachi] N5 summary: min=%.2fms median=%.2fms max=%.2fms windows=%d",
                minMs, medianMs, maxMs, windowCount)
            if medianMs > 5.0 {
                NSLog("[ShakaPachi] N5 GATE FAIL: median %.2fms exceeds 5ms budget", medianMs)
            } else {
                NSLog("[ShakaPachi] N5 GATE PASS: median %.2fms within 5ms budget", medianMs)
            }
        }
    #endif
}
