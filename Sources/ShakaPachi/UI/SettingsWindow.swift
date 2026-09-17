// SettingsWindow.swift
// Settings window: a borderless-titlebar NSWindow hosting a single SwiftUI
// root view (SettingsRootView). The tab switcher is a custom icon tab bar
// (SettingsTabBar, defined in SettingsChrome.swift) rather than
// NSTabViewController, so the header strip can share the card/row visual
// language the rest of the window uses.
//
// Activation policy: switches to .regular on show and back to .accessory on
// close — but ONLY if the onboarding window is not also open.

import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the Settings window opens (`open: true`) or closes
    /// (`open: false`) so the menu-bar icon can show its blue "info" state.
    static let settingsWindowStateChanged =
        Notification.Name("com.masahirosenda.shakapachi.settingsWindowStateChanged")
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    override init() {
        super.init()
    }

    // MARK: - Public

    func show() {
        NotificationCenter.default.post(
            name: .settingsWindowStateChanged, object: nil, userInfo: ["open": true])
        if let win = window {
            win.raiseToFront()
            return
        }

        // Bring app to front so the window is visible.
        WindowPresentationCoordinator.shared.windowDidOpen()

        let win = makeWindow()
        win.delegate = self
        win.contentViewController = makeSettingsRootController()
        win.setContentSize(NSSize(width: 560, height: 600))
        win.center()
        // Keep the settings window findable: float above other windows and
        // follow the user onto whichever Space is active, so it can't get lost
        // behind other apps once opened.
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.window = win

        win.raiseToFront()
    }

    /// Close the Settings window programmatically (e.g. from the tray menu).
    /// Triggers windowWillClose, which posts the state-change notification and
    /// reverts the activation policy.
    func close() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(
            name: .settingsWindowStateChanged, object: nil, userInfo: ["open": false])
        // Revert to .accessory only when no other presentation-managed window
        // is open. WindowPresentationCoordinator tracks the count so this window
        // and OnboardingWindow share a single revert decision.
        WindowPresentationCoordinator.shared.windowDidClose()
        window = nil
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = NSLocalizedString("ShakaPachi 設定", comment: "Settings window title")
        win.isReleasedWhenClosed = false
        // The content view extends under the title bar (fullSizeContentView) and
        // the tab bar's surface colour is drawn transparently through it, so the
        // header strip and the title bar read as one continuous band.
        win.titlebarAppearsTransparent = true
        win.minSize = NSSize(width: 520, height: 460)
        return win
    }

    /// The window's whole content is one SwiftUI tree (tab bar + page), so this
    /// just hosts `SettingsRootView` — no NSTabViewController, no inset wrapper.
    private func makeSettingsRootController() -> NSViewController {
        NSHostingController(rootView: SettingsRootView())
    }
}

// MARK: - SwiftUI Settings Views

// NSHostingView hosts these SwiftUI views. They bind directly to the shared
// `Settings` ObservableObject (there is no separate mirror store): reads go
// through `@ObservedObject`, and every write assigns `Settings.shared.xxx`,
// which persists the value, posts `.settingsDidChange`, and fires
// `objectWillChange` so the view re-renders. One store, one write path.

// ─── Root ─────────────────────────────────────────────────────────────────────

/// Root of the settings window's SwiftUI tree: the icon tab bar over the
/// selected tab's scrolling page of cards. A plain `switch` on `selection`
/// stands in for NSTabViewController's tab items.
struct SettingsRootView: View {

    @State private var selection: Int = 0

    private static var tabs: [SettingsTabBar.Item] {
        var items = [
            SettingsTabBar.Item(id: 0, title: "動作", symbol: "gearshape"),
            SettingsTabBar.Item(id: 1, title: "外観", symbol: "paintpalette"),
            SettingsTabBar.Item(id: 2, title: "状態", symbol: "checkmark.shield"),
            SettingsTabBar.Item(id: 3, title: "統計", symbol: "chart.bar"),
            SettingsTabBar.Item(id: 4, title: "クレジット", symbol: "info.circle"),
        ]
        #if DEBUG
            items.append(SettingsTabBar.Item(id: 5, title: "開発者", symbol: "hammer"))
        #endif
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(items: Self.tabs, selection: $selection)
            content
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(SettingsChrome.background)
        // The window is `fullSizeContentView`, so SwiftUI hands this tree a top
        // safe-area inset the height of the title bar. The tab bar already
        // reserves that height itself (`SettingsChrome.titleBarHeight`), and
        // keeping both stacks the two insets — the tabs then sit a title bar's
        // height too low. Take the whole window and let the tab bar be the only
        // thing that insets.
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case 0:
            BehaviorSettingsView()
        case 1:
            AppearanceSettingsView()
        case 2:
            StatusSettingsView()
        case 3:
            StatsSettingsView()
        case 4:
            AboutSettingsView()
        #if DEBUG
            case 5:
                DeveloperSettingsView()
        #endif
        default:
            EmptyView()
        }
    }
}

// ─── Behavior tab ─────────────────────────────────────────────────────────────

struct BehaviorSettingsView: View {

    @ObservedObject private var settings = Settings.shared

    var body: some View {
        SettingsPage {
            SettingsCard {
                SettingsRow(title: "言語", caption: "メニューやボタンの表示に使う言語") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { settings.appLanguage },
                            set: { Settings.shared.appLanguage = $0 }
                        )
                    ) {
                        ForEach(AppLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                if settings.appLanguage != Settings.launchLanguage {
                    SettingsRowDivider()
                    SettingsRow(title: "再起動が必要です", caption: "言語の変更は再起動後に反映されます。") {
                        Button("再起動") {
                            NotificationCenter.default.post(name: .relaunchApp, object: nil)
                        }
                    }
                }
            }

            SettingsCard {
                // Launch-at-login via SMAppService. The system status is the
                // source of truth; the Settings bool mirrors it for the UI.
                // Read the live SMAppService status directly (not the cached
                // mirror) so the toggle always reflects reality; the mirror is
                // healed on appear (see .onAppear below) and after every write.
                SettingsRow(title: "ログイン時に起動", caption: "macOS にログインすると常駐を始めます") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { LoginItemManager.isEnabled },
                            set: { newValue in
                                do {
                                    try LoginItemManager.setEnabled(newValue)
                                    Settings.shared.launchAtLogin = LoginItemManager.isEnabled
                                } catch {
                                    // Registration failed — revert the mirror to the real
                                    // status so the toggle reflects reality, and surface it.
                                    Settings.shared.launchAtLogin = LoginItemManager.isEnabled
                                    NSLog(
                                        "[ShakaPachi] Login item change failed: %@",
                                        error.localizedDescription)
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                SettingsRowDivider()

                // Modifier-only picker: the trigger key is fixed to Tab.
                // On set, both modifier and key are written so any previously-
                // stored .grave value is normalized to .tab on first save.
                SettingsRow(title: "トリガー", caption: "切替ウィンドウを呼び出すキー") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { settings.triggerModifier },
                            set: { modifier in
                                Settings.shared.triggerModifier = modifier
                                Settings.shared.triggerKey = .tab
                            }
                        )
                    ) {
                        ForEach(TriggerModifier.allCases, id: \.self) { modifier in
                            Text("\(modifier.displayName) + Tab").tag(modifier)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsRowDivider()

                SettingsRow(title: "並び順", caption: "切替リストに並べる順番") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { settings.sortMode },
                            set: { Settings.shared.sortMode = $0 }
                        )
                    ) {
                        ForEach([SortMode.mru, .byApp, .byAppMRU], id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsRowDivider()

                SettingsRow(title: "表示単位", caption: "切替リストの表示のまとめ方") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { settings.switcherDisplayMode },
                            set: { Settings.shared.switcherDisplayMode = $0 }
                        )
                    ) {
                        ForEach([SwitcherDisplayMode.window, .app], id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsRowDivider()

                SettingsRow(title: "ホバーで前面化", caption: "カーソルを重ねたまま少し待つと、その窓を前面に出します") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settings.hoverRaiseEnabled },
                            set: { Settings.shared.hoverRaiseEnabled = $0 }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
        .onAppear {
            // The real login-item state lives in SMAppService, not the cached
            // bool; heal a stale mirror so the persisted value matches reality.
            // (Previously done in SettingsStore.init, before this view existed.)
            let realLaunchAtLogin = LoginItemManager.isEnabled
            if Settings.shared.launchAtLogin != realLaunchAtLogin {
                Settings.shared.launchAtLogin = realLaunchAtLogin
            }
        }
    }
}

// ─── Appearance tab ───────────────────────────────────────────────────────────

struct AppearanceSettingsView: View {

    @ObservedObject private var settings = Settings.shared

    var body: some View {
        SettingsPage {
            SettingsCard {
                SettingsRow(title: "テーマ", caption: "ウィンドウの明るさ") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { settings.theme },
                            set: { Settings.shared.theme = $0 }
                        )
                    ) {
                        ForEach(Theme.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                SettingsRowDivider()

                SettingsRow(title: "アクセントカラー", caption: "地色と選択行の色") {
                    Picker(
                        "",
                        selection: Binding(
                            get: { settings.accentColor },
                            set: { Settings.shared.accentColor = $0 }
                        )
                    ) {
                        ForEach(AccentColor.allCases, id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsRowDivider()

                SettingsStackedRow(title: "アイコンサイズ", caption: "切替リストのアイコンの大きさ") {
                    HStack(spacing: 12) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.switcherIconSize) },
                                set: { settings.switcherIconSize = Int($0.rounded()) }
                            ),
                            in: 60...96
                        )
                        Text("\(settings.switcherIconSize)px")
                            .font(SettingsChrome.rowCaptionFont)
                            .foregroundColor(SettingsChrome.secondaryText)
                            .monospacedDigit()
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }

                SettingsRowDivider()

                // Show live window preview below the title line.
                // Actual capture is gated on screen-recording permission at show time;
                // turning this off avoids any CGWindowListCreateImage call entirely.
                SettingsRow(title: "ウィンドウプレビューを表示", caption: "選択中のウィンドウの縮小画像を出します") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settings.showWindowPreview },
                            set: { Settings.shared.showWindowPreview = $0 }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                SettingsRowDivider()

                SettingsStackedRow(title: "ウィンドウプレビュー", caption: "プレビュー画像の横幅") {
                    HStack(spacing: 12) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.windowPreviewWidth) },
                                set: { settings.windowPreviewWidth = Int($0.rounded()) }
                            ),
                            in: 240...480
                        )
                        Text("\(settings.windowPreviewWidth)px")
                            .font(SettingsChrome.rowCaptionFont)
                            .foregroundColor(SettingsChrome.secondaryText)
                            .monospacedDigit()
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
                .disabled(!settings.showWindowPreview)
            }

            SettingsSection(header: "プレビュー") {
                AppearancePreviewView(
                    theme: settings.theme,
                    accent: settings.accentColor,
                    iconSize: settings.switcherIconSize,
                    windowPreviewWidth: settings.windowPreviewWidth,
                    showWindowPreview: settings.showWindowPreview,
                    totalCount: StatsStore.shared.totalCount
                )
                .padding(SettingsChrome.rowHorizontalPadding)
            }
        }
    }
}

// ─── Status tab ───────────────────────────────────────────────────────────────

struct StatusSettingsView: View {

    @State private var accessibilityGranted: Bool = false
    @State private var screenRecordingGranted: Bool = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage {
            SettingsSection(header: "アイコンの状態") {
                let states = Array(TrayIconState.allCases.enumerated())
                ForEach(states, id: \.offset) { index, state in
                    // `cardName` / `detail` are already-resolved runtime strings
                    // (not localization keys), so this row is built by hand
                    // instead of `SettingsRow`, which would otherwise route them
                    // through `Text(LocalizedStringKey(...))` and risk a second,
                    // spurious lookup.
                    HStack(alignment: .center, spacing: SettingsChrome.rowControlSpacing) {
                        Image(nsImage: TrayIconRenderer.previewImage(for: state, size: 32))
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.cardName)
                                .font(SettingsChrome.rowTitleFont)
                                .foregroundColor(SettingsChrome.primaryText)
                            Text(state.detail)
                                .font(SettingsChrome.rowCaptionFont)
                                .foregroundColor(SettingsChrome.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                    .padding(.vertical, SettingsChrome.rowVerticalPadding)

                    if index < states.count - 1 {
                        SettingsRowDivider()
                    }
                }
            }

            SettingsSection(header: "権限の状態") {
                SettingsRow(
                    title: "アクセシビリティ",
                    caption: "切替キーの捕捉とウィンドウの前面化に使います。",
                    leading: {
                        Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundColor(accessibilityGranted ? .green : .secondary)
                    },
                    trailing: {
                        if accessibilityGranted {
                            Text("許可済み")
                                .font(SettingsChrome.rowCaptionFont)
                                .foregroundColor(SettingsChrome.secondaryText)
                        } else {
                            Button("設定を開く") {
                                NSWorkspace.shared.open(PermissionManager.accessibilityURL)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                )

                SettingsRowDivider()

                SettingsRow(
                    title: "画面収録",
                    caption: "ウィンドウ名の取得と、プレビュー表示に使います。録画やファイルへの保存はしません。",
                    leading: {
                        Image(systemName: screenRecordingGranted ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundColor(screenRecordingGranted ? .green : .secondary)
                    },
                    trailing: {
                        if screenRecordingGranted {
                            Text("許可済み")
                                .font(SettingsChrome.rowCaptionFont)
                                .foregroundColor(SettingsChrome.secondaryText)
                        } else {
                            Button("設定を開く") {
                                NSWorkspace.shared.open(PermissionManager.screenRecordingURL)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                )
            }

            // Plain onboarding button below the cards, no card wrapper.
            // A wrapper card containing only a button provides no semantic
            // value — the button alone is sufficient.
            HStack {
                Button("オンボーディング画面を開く") {
                    // Post a notification that AppDelegate can observe to open
                    // the onboarding window. Using NotificationCenter avoids a
                    // direct dependency from this SwiftUI view to AppDelegate.
                    NotificationCenter.default.post(
                        name: .showOnboardingWindow, object: nil)
                }
                Spacer()
            }
        }
        .onAppear { refreshPermissions() }
        .onReceive(timer) { _ in refreshPermissions() }
    }

    private func refreshPermissions() {
        let pm = PermissionManager()
        accessibilityGranted = pm.accessibilityStatus() == .granted
        screenRecordingGranted = pm.screenRecordingStatus() == .granted
    }
}

// ─── Stats tab ────────────────────────────────────────────────────────────────

struct StatsSettingsView: View {

    // Snapshot taken at appear time.
    @State private var statsEnabled: Bool = true
    @State private var todayCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var dailyCounts: [String: Int] = [:]
    @State private var firstUseDate: String? = nil
    @State private var showResetConfirm: Bool = false

    // Locale-aware thousands separator (e.g. "1,234").
    private let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    var body: some View {
        SettingsPage {
            // ── Recording ──
            SettingsSection(header: "記録") {
                SettingsRow(title: "統計を記録", caption: "切替回数を端末内に記録します") {
                    Toggle("", isOn: $statsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: statsEnabled) { newValue in
                            StatsStore.shared.setStatsEnabled(newValue)
                        }
                }
            }

            if statsEnabled {
                // ── Switch count ──
                SettingsSection(header: "切替回数") {
                    SettingsRow(title: "今日") {
                        Text(formatted(todayCount))
                            .font(SettingsChrome.rowTitleFont)
                            .foregroundColor(SettingsChrome.secondaryText)
                    }

                    SettingsRowDivider()

                    SettingsRow(title: "累計") {
                        Text(formatted(totalCount))
                            .font(SettingsChrome.rowTitleFont)
                            .foregroundColor(SettingsChrome.secondaryText)
                    }

                    #if DEBUG
                        // The developer tab can set an in-memory override; the real
                        // statistics are never touched. Surface it so the shown
                        // numbers aren't mistaken for the persisted values.
                        if StatsStore.shared.previewTotalCountOverride != nil
                            || StatsStore.shared.previewTodayCountOverride != nil
                        {
                            SettingsRowDivider()
                            HStack {
                                Text("プレビュー中（実際の統計は変更されていません）")
                                    .font(SettingsChrome.rowCaptionFont)
                                    .foregroundColor(SettingsChrome.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                            .padding(.vertical, SettingsChrome.rowVerticalPadding)
                        }
                    #endif
                }

                // ── Activity (heatmap) ──
                SettingsSection(header: "アクティビティ") {
                    ContributionHeatmap(
                        dailyCounts: dailyCounts,
                        firstUseDate: firstUseDate
                    )
                    .padding(SettingsChrome.rowHorizontalPadding)
                }
            }

            // Reset button below the cards — standalone, left-aligned (matches
            // the permissions tab's "Open onboarding" (「オンボーディング画面を開く」) footer button).
            HStack {
                Button("統計をリセット") {
                    showResetConfirm = true
                }
                .foregroundColor(.red)
                .confirmationDialog(
                    "統計をリセットしますか？",
                    isPresented: $showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("リセット", role: .destructive) {
                        StatsStore.shared.reset()
                        reloadSnapshot()
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("切替回数・日次履歴がすべてクリアされます。この操作は元に戻せません。")
                }
                Spacer()
            }
        }
        .onAppear { reloadSnapshot() }
    }

    private func reloadSnapshot() {
        statsEnabled = StatsStore.shared.isStatsEnabled
        // Display the effective counts so a developer preview override is
        // reflected here; in release builds these equal the real values.
        todayCount = StatsStore.shared.effectiveTodayCount
        totalCount = StatsStore.shared.effectiveTotalCount
        dailyCounts = StatsStore.shared.dailyCounts
        firstUseDate = StatsStore.shared.firstUseDate
    }

    private func formatted(_ n: Int) -> String {
        String(
            format: NSLocalizedString("%@ 回", comment: "Switch count with unit"),
            (countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"))
    }
}

// ─── About tab ────────────────────────────────────────────────────────────────

struct AboutSettingsView: View {

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon read directly from the bundled icns (see AppIconImage),
            // shown via SwiftUI Image for clean scaling.
            Image(nsImage: AppIconImage.bundled)
                .resizable()
                .frame(width: 72, height: 72)

            Text("ShakaPachi")
                .font(.title)
                .fontWeight(.bold)

            Text(String(format: NSLocalizedString("バージョン %@", comment: "App version label"), version))
                .foregroundColor(.secondary)

            // Copyright, license, and author credit. The notice is a canonical, non-localized
            // form (kept in English even in the Japanese UI, per macOS convention);
            // the GitHub link credits the author.
            Text(verbatim: "© 2026 Masahiro Senda · Licensed under GPL-3.0")
                .font(.caption)
                .foregroundColor(.secondary)

            Link(
                "github.com/senkentarou/shakapachi",
                destination: URL(string: "https://github.com/senkentarou/shakapachi")!
            )
            .font(.caption)

            Spacer()
        }
        .padding()
        // Fill the whole tab and match the other tabs' page background, since
        // this view (unlike the others) isn't wrapped in `SettingsPage`.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsChrome.background)
    }
}

// ─── Developer tab (DEBUG only) ─────────────────────────────────────────────────

#if DEBUG

    /// Developer-only tab exposing a few dev knobs in a COMPACT four-row layout.
    /// `SettingsStackedRow` lays out the label above a full-width control row, so
    /// each row's (fairly wide) control cluster doesn't have to compete with the
    /// label for horizontal space. Stat overrides are non-destructive (in-memory
    /// only — UserDefaults is never touched); accent is a real setting write (that
    /// is the point of a dev panel). Wrapped in `#if DEBUG` so it is compiled out
    /// of release builds. Strings are hardcoded Japanese (this tab is
    /// developer-only and never localized).
    struct DeveloperSettingsView: View {

        @ObservedObject private var settings = Settings.shared

        // Local stat-override fields; writes go to StatsStore's in-memory
        // overrides. Seeded from the effective counts so they reflect any
        // existing override.
        @State private var previewTotal: Int = StatsStore.shared.effectiveTotalCount
        @State private var previewToday: Int = StatsStore.shared.effectiveTodayCount

        // Locale-aware thousands separator (e.g. "1,234").
        private let countFormatter: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            return f
        }()

        var body: some View {
            SettingsPage {
                SettingsCard {
                    SettingsStackedRow(title: "統計") { statsControls }
                    SettingsRowDivider()
                    SettingsStackedRow(title: "アクセント") { accentControls }
                    SettingsRowDivider()
                    SettingsStackedRow(title: "段階") { stagesControls }
                    SettingsRowDivider()
                    SettingsStackedRow(title: "並び順") { sortControls }
                }
            }
        }

        // MARK: - Row content

        /// 統計 — non-destructive total/today overrides + clear.
        private var statsControls: some View {
            HStack(spacing: 8) {
                Text("累計")
                overrideField(get: { previewTotal }, set: setTotal)
                Text("今日")
                overrideField(get: { previewToday }, set: setToday)
                Button("クリア") { clearOverrides() }
                    .controlSize(.small)
            }
        }

        /// アクセント — real setting write; trailing swatch + hex of the resolved color.
        private var accentControls: some View {
            HStack(spacing: 8) {
                Picker(
                    "",
                    selection: Binding(
                        get: { settings.accentColor },
                        set: { Settings.shared.accentColor = $0 }
                    )
                ) {
                    ForEach(AccentColor.allCases, id: \.self) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                swatch(accentSwatchColor)
                Text(hexString(accentSwatchColor))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }

        /// 段階 — one-row patina mini-legend; each swatch is tappable to jump.
        private var stagesControls: some View {
            HStack(spacing: 8) {
                ForEach(Array(AccentColor.patinaStages.enumerated()), id: \.offset) { index, stage in
                    swatch(stage.color)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(
                                    Color.accentColor,
                                    lineWidth: currentStageIndex == index ? 2 : 0)
                        )
                        .onTapGesture { setTotal(stage.minCount) }
                }
                Text("0 / 5k / 10k / 20k / 50k / 100k")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Text("(現: \(stageShortLabel(currentStageIndex)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        /// 並び順 — real setting write.
        private var sortControls: some View {
            Picker(
                "",
                selection: Binding(
                    get: { settings.sortMode },
                    set: { Settings.shared.sortMode = $0 }
                )
            ) {
                ForEach([SortMode.mru, .byApp, .byAppMRU], id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }

        // MARK: - Row building blocks

        /// A small numeric field + stepper for a clamped (>= 0) override value.
        private func overrideField(get: @escaping () -> Int, set: @escaping (Int) -> Void)
            -> some View
        {
            HStack(spacing: 2) {
                TextField(
                    "",
                    value: Binding(get: get, set: set),
                    formatter: countFormatter
                )
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                // Wide enough for a 1,000,000 (1M) count with separators without clipping.
                .frame(width: 96)
                Stepper("", value: Binding(get: get, set: set), in: 0...Int.max)
                    .labelsHidden()
            }
        }

        private func swatch(_ color: NSColor) -> some View {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: color))
                .frame(width: 18, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5)
                )
        }

        // MARK: - Derived values

        /// The count currently driving the accent resolution.
        private var effectiveCount: Int { StatsStore.shared.effectiveTotalCount }

        /// Trailing swatch color: the live patina color when the accent is
        /// `.patina`, otherwise the selected accent's own resolved color.
        private var accentSwatchColor: NSColor {
            settings.accentColor == .patina
                ? AccentColor.patinaColor(forTotalCount: effectiveCount)
                : settings.accentColor.resolvedColor(totalCount: effectiveCount)
        }

        /// Index of the patina stage the effective count currently falls into.
        private var currentStageIndex: Int {
            var result = 0
            for (i, stage) in AccentColor.patinaStages.enumerated() where effectiveCount >= stage.minCount {
                result = i
            }
            return result
        }

        // MARK: - Actions

        /// Write the (clamped) total override (in-memory only).
        private func setTotal(_ value: Int) {
            let clamped = max(0, value)
            previewTotal = clamped
            StatsStore.shared.previewTotalCountOverride = clamped
        }

        /// Write the (clamped) today override (in-memory only).
        private func setToday(_ value: Int) {
            let clamped = max(0, value)
            previewToday = clamped
            StatsStore.shared.previewTodayCountOverride = clamped
        }

        /// Clear both overrides and reset the fields to the real persisted values.
        private func clearOverrides() {
            StatsStore.shared.previewTotalCountOverride = nil
            StatsStore.shared.previewTodayCountOverride = nil
            previewTotal = StatsStore.shared.totalCount
            previewToday = StatsStore.shared.todayCount
        }

        // MARK: - Formatting

        /// A compact per-stage label for the "現在" readout (0 / 5k / 10k / …).
        private func stageShortLabel(_ index: Int) -> String {
            ["0", "5k", "10k", "20k", "50k", "100k"][safe: index] ?? "0"
        }

        /// "#RRGGBB" for an sRGB NSColor.
        private func hexString(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? color
            let r = Int((c.redComponent * 255).rounded())
            let g = Int((c.greenComponent * 255).rounded())
            let b = Int((c.blueComponent * 255).rounded())
            return String(format: "#%02X%02X%02X", r, g, b)
        }
    }

    /// Safe indexing used only by the developer tab's compact stage labels.
    extension Array {
        fileprivate subscript(safe index: Int) -> Element? {
            indices.contains(index) ? self[index] : nil
        }
    }

#endif

// MARK: - Notification for onboarding open

extension Notification.Name {
    /// Posted by the permissions tab when the user wants to see the onboarding window.
    static let showOnboardingWindow = Notification.Name("com.masahirosenda.shakapachi.showOnboardingWindow")
    /// Posted when the user requests an app relaunch (e.g. to apply a language change).
    static let relaunchApp = Notification.Name("com.masahirosenda.shakapachi.relaunchApp")
}
