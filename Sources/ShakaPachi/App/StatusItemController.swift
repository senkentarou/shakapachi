import AppKit

/// Manages the menu bar status item for ShakaPachi.
// Created and accessed exclusively from applicationDidFinishLaunching (@MainActor).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let permissionManager: PermissionManager

    // Held references to menu items that need runtime updates.
    private var permissionStatusItem: NSMenuItem?
    private var toggleItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?
    private var updateCheckItem: NSMenuItem?
    private var headingItem: NSMenuItem?

    // Tap state mirrored from HotkeyTap for icon/menu rendering.
    private var tapEnabled = false
    private var tapStopReason: String?

    // Whether the Settings window is open — drives the blue "info" icon state.
    private var settingsOpen = false

    // Whether the Update window is open — also drives the blue "info" icon state.
    private var updateWindowOpen = false

    // Retained observer token for the settingsWindowStateChanged subscription.
    private var settingsWindowObserver: (any NSObjectProtocol)?

    // Retained observer token for the updateWindowStateChanged subscription.
    private var updateWindowObserver: (any NSObjectProtocol)?

    /// Called when the user toggles "Enable window switching" (「ウィンドウ切替を有効化」).
    /// Receives the desired new state.
    var onToggleTap: ((Bool) -> Void)?

    /// Called when the user chooses "Settings…" (「設定…」) from the menu.
    var onOpenSettings: (() -> Void)?

    /// Called when the user chooses "Close settings" (「設定を閉じる」) while the Settings window is open.
    var onCloseSettings: (() -> Void)?

    /// Called when the user chooses "Check for Updates…" (「アップデートを確認…」) from the menu.
    var onCheckForUpdates: (() -> Void)?

    init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupButton()
        setupMenu()
        updatePermissionWarning()

        // Show a blue "info" icon while the Settings window is open.
        settingsWindowObserver = NotificationCenter.default.addObserver(
            forName: .settingsWindowStateChanged, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.settingsOpen = (note.userInfo?["open"] as? Bool) ?? false
                self?.refreshSettingsMenuItem()
                self?.refreshStatus()
            }
        }

        // Show a blue "info" icon while the Update window is open, too.
        updateWindowObserver = NotificationCenter.default.addObserver(
            forName: .updateWindowStateChanged, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.updateWindowOpen = (note.userInfo?["open"] as? Bool) ?? false
                self?.refreshStatus()
            }
        }
    }

    deinit {
        if let token = settingsWindowObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = updateWindowObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Public

    /// Refresh the permission badge on the status icon and menu item, reorder items, and
    /// enable/disable the toggle based on whether permissions are granted.
    func updatePermissionWarning() {
        let allGranted = permissionManager.allPermissionsGranted()

        // Fix #3: Gray out the toggle when permissions are missing so the user
        // cannot click something that has no effect. Re-enable when granted.
        toggleItem?.isEnabled = allGranted

        // The "Permission status…" (「権限の状態…」) item is shown ONLY when a permission is missing,
        // pinned to the very top of the menu. When everything is granted it is
        // removed entirely (it is not useful in the normal state). Guard on
        // whether it is currently in the menu so repeated calls never duplicate
        // it or leave a stray separator.
        if let permItem = permissionStatusItem {
            let inMenu = menu.index(of: permItem) >= 0
            // Indices 0/1 are permanently occupied by the status heading and its
            // separator (added in setupMenu()), so this item is pinned just below them.
            if !allGranted && !inMenu {
                menu.insertItem(permItem, at: 2)
                menu.insertItem(.separator(), at: 3)
            } else if allGranted && inMenu {
                let idx = menu.index(of: permItem)
                if idx + 1 < menu.numberOfItems,
                    menu.item(at: idx + 1)?.isSeparatorItem == true
                {
                    menu.removeItem(at: idx + 1)
                }
                menu.removeItem(permItem)
            }
        }

        refreshToggleItem()
        refreshStatus()
    }

    /// Reflect the event-tap state on the toggle item and status icon.
    func updateTapState(enabled: Bool, reason: String?) {
        tapEnabled = enabled
        tapStopReason = reason
        refreshToggleItem()
        refreshStatus()
    }

    /// The current icon state together with the copy that describes it. Icon,
    /// tooltip and menu heading are all derived here so they cannot disagree.
    /// Precedence: permission problem > tap stopped > settings/update window open > normal.
    private func currentStatus() -> (state: TrayIconState, tooltip: String, heading: String) {
        if !permissionManager.allPermissionsGranted() {
            return (
                .permission,
                NSLocalizedString("ShakaPachi — 権限が不足しています", comment: "Tooltip: missing permissions"),
                NSLocalizedString("ShakaPachi 停止中（権限が不足しています）", comment: "Menu heading: missing permissions")
            )
        } else if !tapEnabled {
            let tooltip =
                NSLocalizedString("ShakaPachi — 停止中", comment: "Tooltip: tap is paused")
                + (tapStopReason.map { " (\($0))" } ?? "")
            return (
                .restricted,
                tooltip,
                NSLocalizedString("ShakaPachi 停止中（一時的に無効）", comment: "Menu heading: tap temporarily disabled")
            )
        } else if settingsOpen || updateWindowOpen {
            // Both the Settings and Update windows use the blue "info" icon.
            let tooltip =
                settingsOpen
                ? NSLocalizedString("ShakaPachi — 設定を開いています", comment: "Tooltip: settings window is open")
                : NSLocalizedString("ShakaPachi — アップデート画面を開いています", comment: "Tooltip: update window is open")
            let heading =
                settingsOpen
                ? NSLocalizedString("ShakaPachi 稼働中（設定画面を表示中）", comment: "Menu heading: settings window open")
                : NSLocalizedString("ShakaPachi 稼働中（アップデート画面を表示中）", comment: "Menu heading: update window open")
            return (.settings, tooltip, heading)
        } else {
            return (
                .normal,
                "ShakaPachi",
                NSLocalizedString("ShakaPachi 稼働中", comment: "Menu heading: running normally")
            )
        }
    }

    /// Update the status icon, its tooltip and the menu heading from `currentStatus()`
    /// so the three never fall out of sync with each other.
    private func refreshStatus() {
        let (state, tooltip, heading) = currentStatus()
        if let button = statusItem.button {
            button.image = TrayIconRenderer.menuBarImage(for: state)
            button.toolTip = tooltip
        }
        refreshHeadingItem(state: state, heading: heading)
    }

    /// Apply the heading text and coloured dot to the non-clickable menu heading item.
    private func refreshHeadingItem(state: TrayIconState, heading: String) {
        headingItem?.title = heading
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: state.headingDotColor))
        let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        dot?.isTemplate = false
        headingItem?.image = dot
    }

    // MARK: - Private: button

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = TrayIconRenderer.menuBarImage(for: .normal)
    }

    // MARK: - Private: menu

    private func setupMenu() {
        // autoenablesItems = false so that explicit isEnabled assignments on menu items
        // are honored without being overridden by AppKit's automatic validation pass.
        // Required for Fix #3 (gray out toggle when permissions missing).
        menu.autoenablesItems = false

        // Non-clickable status heading — a coloured dot plus a short state
        // sentence, pinned to the very top of the menu. Its title/image are
        // filled in by refreshStatus() (via updatePermissionWarning()).
        let heading = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        headingItem = heading

        menu.addItem(.separator())

        // Tap enable/disable toggle — also the recovery path after a
        // deadman fire without relaunching the app.
        let toggle = NSMenuItem(
            title: NSLocalizedString("ウィンドウ切替を有効化", comment: "Menu item: enable window switching"),
            action: #selector(toggleTap),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        menu.addItem(.separator())

        // Settings… with Cmd+, shortcut
        let settingsItem = NSMenuItem(
            title: NSLocalizedString("設定…", comment: "Menu item: open settings"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)
        settingsMenuItem = settingsItem

        // "Check for Updates…" item — always visible, placed right after Settings.
        let updateCheck = NSMenuItem(
            title: NSLocalizedString("アップデートを確認…", comment: "Menu item: check for updates"),
            action: #selector(checkForUpdatesTapped),
            keyEquivalent: ""
        )
        updateCheck.target = self
        menu.addItem(updateCheck)
        updateCheckItem = updateCheck

        // Permission status item — created but NOT added here. It is shown ONLY
        // when a permission is missing, pinned to the top of the menu by
        // updatePermissionWarning(); in the normal (granted) state it is absent.
        let permItem = NSMenuItem(
            title: NSLocalizedString("⚠ 権限の状態…", comment: "Menu item: permission status warning"),
            action: #selector(showPermissions),
            keyEquivalent: ""
        )
        permItem.target = self
        permissionStatusItem = permItem

        menu.addItem(.separator())

        // Restart item — Cmd+R, an unused key that does not collide with Quit's Cmd+Q.
        let restartItem = NSMenuItem(
            title: NSLocalizedString("再起動", comment: "Menu item: restart the app"),
            action: #selector(restartApp),
            keyEquivalent: "r"
        )
        restartItem.keyEquivalentModifierMask = .command
        restartItem.target = self
        menu.addItem(restartItem)

        // "Quit" item with Cmd+Q shortcut
        let quitItem = NSMenuItem(
            title: NSLocalizedString("終了", comment: "Menu item: quit"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    /// Permissions can be changed in System Settings while the app is idle and there
    /// is no polling, so the state is re-read at the moment the menu is read.
    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionWarning()
    }

    /// Reflect the Settings-window open state on the settings menu item: while
    /// open it reads "Close settings" (「設定を閉じる」), and selecting it closes the window.
    /// The verb title conveys the state, so no check mark is used — a check next to
    /// an action verb ("Close settings ✓") reads as if the action were already applied.
    private func refreshSettingsMenuItem() {
        settingsMenuItem?.title =
            settingsOpen
            ? NSLocalizedString("設定を閉じる", comment: "Menu item: close settings")
            : NSLocalizedString("設定…", comment: "Menu item: open settings")
        settingsMenuItem?.state = .off
    }

    /// Update the tap-toggle menu item title based on tap-enable state and permissions.
    /// The title names the action a click performs (mirroring refreshSettingsMenuItem):
    /// - If tap is enabled: "Disable window switching"
    /// - If tap is disabled and all permissions granted: "⚠ Enable window switching" (warning marker)
    /// - If permissions missing: "Enable window switching" (no marker; permissions item owns the warning)
    /// No check mark is used: the verb title already conveys state, so a check next to
    /// "Disable window switching" would misread as the disabled action being active.
    private func refreshToggleItem() {
        let allGranted = permissionManager.allPermissionsGranted()
        if tapEnabled {
            toggleItem?.title = NSLocalizedString(
                "ウィンドウ切替を一時的に無効化", comment: "Menu item: temporarily disable window switching")
        } else if allGranted {
            toggleItem?.title = NSLocalizedString(
                "⚠ ウィンドウ切替を有効化", comment: "Menu item: enable window switching (needs attention)")
        } else {
            toggleItem?.title = NSLocalizedString("ウィンドウ切替を有効化", comment: "Menu item: enable window switching")
        }
        toggleItem?.state = .off
    }

    // MARK: - Update availability

    /// Reflect update availability on the "Check for Updates…" item itself:
    /// when an update is available the item gains a blue "download" badge icon
    /// and shows the version in its title; otherwise it is the plain check item.
    /// There is no separate menu row and no emoji.
    /// - Parameter versionText: Non-nil to mark an update available (with version); nil to clear.
    func setUpdateAvailable(_ versionText: String?) {
        guard let checkItem = updateCheckItem else { return }
        if let versionText {
            checkItem.title = String(
                format: NSLocalizedString(
                    "アップデートを確認… (%@)",
                    comment: "Menu item: check for updates, annotated with the available version"),
                versionText)
            let config = NSImage.SymbolConfiguration(hierarchicalColor: .controlAccentColor)
            let badge = NSImage(
                systemSymbolName: "arrow.down.circle.fill",
                accessibilityDescription: NSLocalizedString(
                    "アップデートが利用可能", comment: "Accessibility: update available badge"))?
                .withSymbolConfiguration(config)
            badge?.isTemplate = false
            checkItem.image = badge
        } else {
            checkItem.title = NSLocalizedString("アップデートを確認…", comment: "Menu item: check for updates")
            checkItem.image = nil
        }
    }

    // MARK: - Menu actions

    @objc private func checkForUpdatesTapped() { onCheckForUpdates?() }

    @objc private func toggleTap() {
        onToggleTap?(!tapEnabled)
    }

    @objc private func openSettings() {
        if settingsOpen {
            onCloseSettings?()
        } else {
            onOpenSettings?()
        }
    }

    @objc private func showPermissions() {
        // Delegate to AppDelegate via notification so the single construction
        // point (AppDelegate.showOnboarding) is used. This also ensures that
        // startTapIfPossible is called when permissions are granted via this path.
        NotificationCenter.default.post(name: .showOnboardingWindow, object: nil)
    }

    @objc private func restartApp() {
        // Reuse the same .relaunchApp bus the language-switcher restart button
        // posts to (SettingsWindow.swift), rather than a tray-specific relaunch
        // path, so the app restarts the same way regardless of which menu the
        // user triggered it from.
        NotificationCenter.default.post(name: .relaunchApp, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
