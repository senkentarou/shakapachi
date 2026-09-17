// Settings.swift
// Type-safe UserDefaults wrapper for all ShakaPachi preferences.
//
// Design notes:
// - All keys stored as raw String/Int values so UserDefaults can persist them.
// - Enums are String-rawValue and CaseIterable so SwiftUI pickers can iterate.
// - Changes are broadcast via NotificationCenter (.settingsDidChange) so any
//   observer can react live without coupling to this class directly.
// - Tests should inject a separate UserDefaults suite via Settings(defaults:)
//   to avoid polluting the real domain.
// - Settings.shared uses UserDefaults.standard (the real app domain).

import AppKit
import Combine
import CoreGraphics
import SwiftUI

// MARK: - Notification

extension Notification.Name {
    /// Posted on the main queue whenever any Settings value is set.
    static let settingsDidChange = Notification.Name("com.masahirosenda.shakapachi.settingsDidChange")
}

// MARK: - Enums

/// The modifier key used as the switcher trigger.
public enum TriggerModifier: String, CaseIterable, Sendable {
    case command
    case option
    case control

    /// The CGEventFlags mask value corresponding to this modifier.
    public var eventFlagMask: UInt64 {
        switch self {
        case .control: return 0x0000000000040000  // kCGEventFlagMaskControl
        case .option: return 0x0000000000080000  // kCGEventFlagMaskAlternate
        case .command: return 0x0000000000100000  // kCGEventFlagMaskCommand
        }
    }

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .command: return "Command (⌘)"
        case .option: return "Option (⌥)"
        case .control: return "Control (^)"
        }
    }

    /// Bare glyph for the switcher's own shortcut badges, where the name would
    /// not fit and the surrounding context already says what it is.
    public var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "^"
        }
    }
}

/// The key (in combination with the modifier) that triggers the switcher.
public enum TriggerKey: String, CaseIterable, Sendable {
    case tab
    case grave

    /// The CGKeyCode for this key.
    public var keyCode: UInt16 {
        switch self {
        case .tab: return 48
        case .grave: return 50
        }
    }

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .tab: return "Tab"
        case .grave: return "Grave (`)"
        }
    }
}

/// Sort order for the window list.
public enum SortMode: String, CaseIterable, Sendable {
    /// Most-recently-used order (MRU array, sorted by last activation time).
    case mru
    /// Windows grouped by app, with groups ordered by app display name
    /// (case-insensitive ascending). Windows keep MRU order within each group.
    case byApp
    /// Windows grouped by app, with groups ordered by the app's recency (MRU).
    /// Windows keep MRU order within each group.
    case byAppMRU

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .mru: return NSLocalizedString("最近使った順 (MRU)", comment: "Sort mode: most recently used")
        case .byApp: return NSLocalizedString("アプリ別", comment: "Sort mode: by app")
        case .byAppMRU:
            return NSLocalizedString("最近使ったアプリ順", comment: "Sort mode: by recently used app")
        }
    }
}

/// How the switcher groups windows for display.
public enum SwitcherDisplayMode: String, CaseIterable, Sendable {
    /// All windows in a single flat list (the historical behavior).
    case window
    /// Windows grouped by app; the selected app's windows expand.
    case app

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .window:
            return NSLocalizedString("ウィンドウ単位", comment: "Switcher display mode: flat list of all windows")
        case .app:
            return NSLocalizedString("アプリ単位", comment: "Switcher display mode: grouped by app")
        }
    }
}

/// Visual theme for the switcher panel.
public enum Theme: String, CaseIterable, Sendable {
    case light
    case dark
    case system

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .light: return NSLocalizedString("ライト", comment: "Theme: light")
        case .dark: return NSLocalizedString("ダーク", comment: "Theme: dark")
        case .system: return NSLocalizedString("システム", comment: "Theme: system")
        }
    }

    /// The NSAppearance to apply, or nil for system (inherit).
    public var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

/// Accent color for the switcher panel highlight and background tint.
public enum AccentColor: String, CaseIterable, Sendable {
    case pearl
    case blue
    case graphite
    case teal
    case sand
    case plum
    case patina
    case opal

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .pearl: return NSLocalizedString("パール", comment: "Accent color: pearl")
        case .blue: return NSLocalizedString("ブルー", comment: "Accent color: blue")
        case .graphite: return NSLocalizedString("グラファイト", comment: "Accent color: graphite")
        case .teal: return NSLocalizedString("ティール", comment: "Accent color: teal")
        case .sand: return NSLocalizedString("サンド", comment: "Accent color: sand")
        case .plum: return NSLocalizedString("プラム", comment: "Accent color: plum")
        case .patina: return NSLocalizedString("パティナ", comment: "Accent color: patina (evolves with usage count)")
        case .opal: return NSLocalizedString("オパール", comment: "Accent color: opal (iridescent rotating rim)")
        }
    }

    /// Alpha applied to the accent color when tinting the switcher panel
    /// background. Single source of truth shared by SwitcherPanel and the
    /// Settings appearance preview so the two never drift.
    public static let backgroundTintAlpha: CGFloat = 0.14
    /// Alpha applied to the accent color for the selected tile's highlight fill.
    /// Shared by SwitcherListView and the Settings appearance preview.
    public static let selectionHighlightAlpha: CGFloat = 0.30
    /// Alpha for the 1px glass rim border on the switcher panel.
    /// Shared by SwitcherPanel (CALayer borderColor) and AppearancePreviewView (SwiftUI strokeBorder).
    public static let glassBorderAlpha: CGFloat = 0.18
    /// Alpha for the light half of the selected tile's two-tone hairline rim.
    /// Two tones rather than one: the panel is an NSVisualEffectView with
    /// `.behindWindow` blending, so its luminance follows whatever window happens
    /// to sit behind the switcher. A single translucent tone therefore cannot
    /// guarantee contrast — a light accent such as `sand` collapses into a bright
    /// backdrop, a dark one into a dark backdrop. Pairing a light line with an
    /// adjacent dark line keeps one of the two visible at any backdrop luminance.
    /// Shared by SwitcherListView and the Settings appearance preview.
    public static let selectionRimLightAlpha: CGFloat = 0.55
    /// Alpha for the dark half of the selected tile's two-tone hairline rim.
    /// See `selectionRimLightAlpha` for why the rim carries both tones.
    public static let selectionRimDarkAlpha: CGFloat = 0.28

    /// The iridescent (玉虫色) spectrum swept around the selected tile's rim by
    /// the `.opal` accent. Six stops with the first repeated as the last so the
    /// conic sweep closes on itself and the seam never becomes visible as it
    /// rotates. Opaque pastels rather than translucent tones: the rim replaces
    /// the two-tone hairline, so it cannot lean on a light/dark pair to survive
    /// an arbitrary backdrop luminance (see `selectionRimLightAlpha`) and has to
    /// carry its own contrast. Shared by SwitcherListView (CAGradientLayer) and
    /// the Settings appearance preview (SwiftUI AngularGradient) so the two
    /// never drift.
    public static let opalSpectrum: [NSColor] = [
        NSColor(srgbRed: 0.663, green: 0.788, blue: 1.000, alpha: 1.0),  // #A9C9FF pale blue
        NSColor(srgbRed: 0.722, green: 0.647, blue: 1.000, alpha: 1.0),  // #B8A5FF periwinkle
        NSColor(srgbRed: 1.000, green: 0.776, blue: 0.941, alpha: 1.0),  // #FFC6F0 pink
        NSColor(srgbRed: 1.000, green: 0.902, blue: 0.655, alpha: 1.0),  // #FFE6A7 warm cream
        NSColor(srgbRed: 0.725, green: 0.961, blue: 0.878, alpha: 1.0),  // #B9F5E0 mint
        NSColor(srgbRed: 0.663, green: 0.788, blue: 1.000, alpha: 1.0),  // #A9C9FF — repeat, closes the loop
    ]

    /// Seconds for one full turn of the `.opal` rim spectrum. Shared by
    /// SwitcherListView (CABasicAnimation) and the Settings appearance preview
    /// (SwiftUI `.linear(duration:).repeatForever`) so the two never drift.
    public static let opalRimRotationDuration: CFTimeInterval = 7.0

    /// Soft green used by the contribution heatmap cells and legend swatches.
    /// Matches the tray icon soft palette. Kept here alongside the other shared
    /// appearance constants so the heatmap and any future consumer never drift.
    /// SwiftUI `Color` (not `NSColor`) because the heatmap is a SwiftUI view.
    public static let heatmapActivityGreen = Color(red: 0.42, green: 0.69, blue: 0.47)

    /// The NSColor for this accent. Muted / desaturated — this is a work app.
    public var nsColor: NSColor {
        switch self {
        case .pearl:
            // Soft cool silver-white. Neutral default that feels close to the
            // macOS standard for users migrating from the system accent.
            return NSColor(srgbRed: 0.74, green: 0.77, blue: 0.82, alpha: 1.0)
        case .blue:
            // Desaturated steel blue — readable on both light and dark panels.
            return NSColor(srgbRed: 0.30, green: 0.50, blue: 0.75, alpha: 1.0)
        case .graphite:
            // Neutral grey with a slight warm cast.
            return NSColor(srgbRed: 0.50, green: 0.52, blue: 0.55, alpha: 1.0)
        case .teal:
            // Muted teal, low saturation so it doesn't dominate.
            return NSColor(srgbRed: 0.22, green: 0.55, blue: 0.55, alpha: 1.0)
        case .sand:
            // Light warm greige — #C7B89C. Lighter and lower-saturation than patina bronze
            // (#AA9455) and brass (#C8A63C) so it reads as a distinct neutral, not a gold.
            return NSColor(srgbRed: 0.78, green: 0.72, blue: 0.61, alpha: 1.0)
        case .plum:
            // Muted plum — subtle and sophisticated.
            return NSColor(srgbRed: 0.50, green: 0.35, blue: 0.58, alpha: 1.0)
        case .patina:
            // Base (unused) tone; the live color is resolved via resolvedColor(totalCount:).
            return AccentColor.patinaColor(forTotalCount: 0)
        case .opal:
            // Pale pearlescent blue-white. The accent's character lives in the
            // rotating rim (see `opalSpectrum`); the panel tint and selection
            // fill stay near-neutral so they don't compete with it.
            return NSColor(srgbRed: 0.79, green: 0.83, blue: 0.94, alpha: 1.0)
        }
    }

    /// Whether this accent evolves with the lifetime switch count.
    /// Only `.patina` does; every other case is static.
    public var evolvesWithUsage: Bool { self == .patina }

    /// The accent color resolved for a given lifetime switch count.
    /// Static accents ignore `totalCount`; `.patina` steps up through six
    /// discrete stages as the count crosses 5k / 10k / 20k / 50k / 100k.
    public func resolvedColor(totalCount: Int) -> NSColor {
        guard self == .patina else { return nsColor }
        return AccentColor.patinaColor(forTotalCount: totalCount)
    }

    /// One discrete stage of the `.patina` accent, keyed to an inclusive lower
    /// bound on the lifetime switch count. Single source of truth for the color
    /// ramp so the pure stage function and any UI legend can never drift.
    public struct PatinaStage: Sendable {
        /// Inclusive lower bound on the lifetime count that reaches this stage.
        public let minCount: Int
        /// The resolved accent color for this stage.
        public let color: NSColor
        /// Developer-facing label for this stage.
        public let label: String
    }

    /// The six patina stages in ascending order. Raw pewter → vivid gold; the
    /// steps are spaced so consecutive stages differ by a comparable amount
    /// (the previous ramp jumped hardest at the bottom), so every milestone
    /// reads as a distinct step even at the panel's low tint/selection alpha.
    public static let patinaStages: [PatinaStage] = [
        .init(
            minCount: 0,
            color: NSColor(srgbRed: 0.549, green: 0.541, blue: 0.510, alpha: 1.0),  // #8C8A82 raw pewter-grey
            label: "ピューター灰"),
        .init(
            minCount: 5_000,
            color: NSColor(srgbRed: 0.608, green: 0.561, blue: 0.420, alpha: 1.0),  // #9B8F6B aged copper
            label: "古銅"),
        .init(
            minCount: 10_000,
            color: NSColor(srgbRed: 0.667, green: 0.580, blue: 0.333, alpha: 1.0),  // #AA9455 bronze
            label: "ブロンズ"),
        .init(
            minCount: 20_000,
            color: NSColor(srgbRed: 0.784, green: 0.651, blue: 0.235, alpha: 1.0),  // #C8A63C brass gold
            label: "真鍮"),
        .init(
            minCount: 50_000,
            color: NSColor(srgbRed: 0.878, green: 0.714, blue: 0.165, alpha: 1.0),  // #E0B62A rich gold
            label: "リッチゴールド"),
        .init(
            minCount: 100_000,
            color: NSColor(srgbRed: 0.933, green: 0.784, blue: 0.078, alpha: 1.0),  // #EEC814 vivid gold
            label: "ヴィヴィッドゴールド"),
    ]

    /// Pure stage function for the `.patina` accent. Exposed for testing.
    /// Derives from `patinaStages`: returns the color of the last stage whose
    /// `minCount` the count has reached.
    public static func patinaColor(forTotalCount count: Int) -> NSColor {
        var result = patinaStages[0].color
        for stage in patinaStages where count >= stage.minCount {
            result = stage.color
        }
        return result
    }
}

/// Preferred UI language. `.system` follows the macOS system language;
/// `.japanese` / `.english` override it. The override is written to the app's
/// `AppleLanguages` UserDefaults key and takes effect on the next launch.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case japanese
    case english

    /// Human-readable label. `.system` is localized; the concrete languages use
    /// their own endonyms (shown identically in any locale, like macOS does).
    public var displayName: String {
        switch self {
        // `.system` is the only case that is localized: "follow system" is a
        // concept whose wording differs per UI language, so it goes through the
        // catalog. The concrete languages are asymmetric on purpose — they return
        // their own endonym, shown identically in any UI language (like macOS's
        // own language list), so they are intentionally NOT localized.
        case .system: return NSLocalizedString("システム", comment: "Language: follow system")
        case .japanese: return "日本語"  // endonym — intentionally not localized (shown identically in any UI language)
        case .english: return "English"  // endonym — intentionally not localized (shown identically in any UI language)
        }
    }

    /// Value written to `AppleLanguages`, or nil for `.system` (removes override).
    var appleLanguagesValue: [String]? {
        switch self {
        case .system: return nil
        case .japanese: return ["ja"]
        case .english: return ["en"]
        }
    }
}

// MARK: - @propertyWrapper

/// A property wrapper that reads/writes a String-raw-valued enum to UserDefaults.
/// Falls back to `defaultValue` when the stored string is missing or unrecognized.
@propertyWrapper
struct DefaultsEnum<T: RawRepresentable> where T.RawValue == String {
    let key: String
    let defaultValue: T
    nonisolated(unsafe) let defaults: UserDefaults

    var wrappedValue: T {
        get {
            guard let raw = defaults.string(forKey: key),
                let value = T(rawValue: raw)
            else { return defaultValue }
            return value
        }
        // nonmutating: the setter writes to `defaults` (a reference type), never
        // to this struct's own storage, so it needs no exclusive (mutating) access
        // to the wrapper. This matters because .settingsDidChange is delivered
        // synchronously and an observer (Settings' own objectWillChange bridge,
        // and any external subscriber) reads the SAME property while this setter
        // is still on the stack; a mutating set would overlap a write with that
        // read and trip Swift's exclusive-access check (SIGABRT). Writing to
        // defaults is logically non-mutating, so this is also the semantically
        // correct annotation.
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }
}

/// A property wrapper for Int settings.
// nonisolated(unsafe) suppresses the Sendable warning on `defaults` because
// Settings is @MainActor-isolated and these wrappers are only accessed from the
// main actor. UserDefaults itself is thread-safe for simple reads/writes.
@propertyWrapper
struct DefaultsInt {
    let key: String
    let defaultValue: Int
    nonisolated(unsafe) let defaults: UserDefaults

    var wrappedValue: Int {
        get {
            defaults.object(forKey: key) != nil
                ? defaults.integer(forKey: key)
                : defaultValue
        }
        // nonmutating: writes to `defaults`, not self — avoids exclusive-access
        // reentrancy under synchronous .settingsDidChange delivery (see DefaultsEnum).
        nonmutating set {
            defaults.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }
}

/// A property wrapper for Bool settings.
@propertyWrapper
struct DefaultsBool {
    let key: String
    let defaultValue: Bool
    nonisolated(unsafe) let defaults: UserDefaults

    var wrappedValue: Bool {
        get {
            defaults.object(forKey: key) != nil
                ? defaults.bool(forKey: key)
                : defaultValue
        }
        // nonmutating: writes to `defaults`, not self — avoids exclusive-access
        // reentrancy under synchronous .settingsDidChange delivery (see DefaultsEnum).
        nonmutating set {
            defaults.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }
}

/// A property wrapper for [String] settings (stored as plist array).
@propertyWrapper
struct DefaultsStringArray {
    let key: String
    let defaultValue: [String]
    nonisolated(unsafe) let defaults: UserDefaults

    var wrappedValue: [String] {
        get {
            (defaults.array(forKey: key) as? [String]) ?? defaultValue
        }
        // nonmutating: writes to `defaults`, not self — avoids exclusive-access
        // reentrancy under synchronous .settingsDidChange delivery (see DefaultsEnum).
        nonmutating set {
            defaults.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }
}

// MARK: - Settings

/// All ShakaPachi user preferences.
///
/// Use `Settings.shared` in production code.
/// Inject a custom `UserDefaults(suiteName:)` in unit tests so they don't
/// pollute UserDefaults.standard.
///
/// `ObservableObject` conformance lets SwiftUI views bind to `Settings.shared`
/// directly (there is no separate mirror object). `objectWillChange` is fired
/// from `.settingsDidChange` — see the `init(defaults:)` observer below — so it
/// rides the SAME synchronous, `self`-non-mutating path as every setter and
/// preserves the reentrancy contract (details there).
@MainActor
final class Settings: ObservableObject {

    // MARK: Shared instance

    static let shared = Settings()

    // MARK: - UserDefaults keys

    private enum Key {
        static let triggerModifier = "triggerModifier"
        static let triggerKey = "triggerKey"
        static let sortMode = "sortMode"
        static let switcherDisplayMode = "switcherDisplayMode"
        static let theme = "theme"
        static let maxRows = "maxRows"
        static let showDelayMs = "showDelayMs"
        static let panelWidth = "panelWidth"
        static let currentSpaceOnly = "currentSpaceOnly"
        static let launchAtLogin = "launchAtLogin"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let accentColor = "accentColor"
        static let showWindowPreview = "showWindowPreview"
        static let appLanguage = "appLanguage"
        // Apple-defined global key that overrides the bundle's resolved language.
        static let appleLanguages = "AppleLanguages"
        static let switcherIconSize = "switcherIconSize"
        static let windowPreviewWidth = "windowPreviewWidth"
    }

    // MARK: Init

    /// Creates a Settings instance backed by the given UserDefaults.
    /// - Parameter defaults: The backing store. Pass `UserDefaults.standard`
    ///   in production; pass a test suite in unit tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _triggerModifier = DefaultsEnum(key: Key.triggerModifier, defaultValue: .command, defaults: defaults)
        _triggerKey = DefaultsEnum(key: Key.triggerKey, defaultValue: .tab, defaults: defaults)
        _sortMode = DefaultsEnum(key: Key.sortMode, defaultValue: .mru, defaults: defaults)
        _switcherDisplayMode = DefaultsEnum(
            key: Key.switcherDisplayMode, defaultValue: .window, defaults: defaults)
        _theme = DefaultsEnum(key: Key.theme, defaultValue: .system, defaults: defaults)
        _maxRows = DefaultsInt(key: Key.maxRows, defaultValue: 20, defaults: defaults)
        _showDelayMs = DefaultsInt(key: Key.showDelayMs, defaultValue: 0, defaults: defaults)
        _panelWidth = DefaultsInt(key: Key.panelWidth, defaultValue: 480, defaults: defaults)
        _currentSpaceOnly = DefaultsBool(key: Key.currentSpaceOnly, defaultValue: true, defaults: defaults)
        _launchAtLogin = DefaultsBool(key: Key.launchAtLogin, defaultValue: true, defaults: defaults)
        _excludedBundleIDs = DefaultsStringArray(key: Key.excludedBundleIDs, defaultValue: [], defaults: defaults)
        _accentColor = DefaultsEnum(key: Key.accentColor, defaultValue: .pearl, defaults: defaults)
        _showWindowPreview = DefaultsBool(key: Key.showWindowPreview, defaultValue: true, defaults: defaults)
        _appLanguage = DefaultsEnum(key: Key.appLanguage, defaultValue: .system, defaults: defaults)
        _switcherIconSize = DefaultsInt(key: Key.switcherIconSize, defaultValue: 60, defaults: defaults)
        _windowPreviewWidth = DefaultsInt(key: Key.windowPreviewWidth, defaultValue: 320, defaults: defaults)

        // Drive `objectWillChange` from the SAME synchronous `.settingsDidChange`
        // post that every setter already emits, rather than from `@Published`
        // storage. This is deliberate and load-bearing:
        //
        //   * The Defaults* wrappers use `nonmutating set`, so a setter writes
        //     only to `defaults` and never mutates `self`. That is what lets a
        //     synchronous observer read the same property while the setter is
        //     still on the stack without tripping Swift's exclusive-access check
        //     (see DefaultsEnum). `@Published` would mutate Combine storage on
        //     `self` and break that contract.
        //   * `objectWillChange.send()` reads `self` but does NOT mutate it, so
        //     firing it from inside the notification callback is a harmless
        //     shared read — the reentrancy invariant holds.
        //
        // Firing on `.settingsDidChange` (posted AFTER the value is written)
        // means the "willChange" fires post-write, exactly as the old
        // SettingsStore.refresh did; SwiftUI re-reads the fresh value on its next
        // evaluation, so behaviour is unchanged.
        observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Backing store

    private let defaults: UserDefaults

    /// Token for the `.settingsDidChange` self-observer that drives
    /// `objectWillChange` (see `init`). Held so it can be removed on `deinit`.
    private var observer: (any NSObjectProtocol)?

    // MARK: - Settings

    // -- Input --

    /// The modifier key that must be held to trigger the switcher.
    /// Default: .command (Cmd+Tab), which suppresses the standard App Switcher.
    /// During early development this was .option; it was switched to .command
    /// once the app was stable. Users can change it in Settings.
    private var _triggerModifier: DefaultsEnum<TriggerModifier>
    var triggerModifier: TriggerModifier {
        get { _triggerModifier.wrappedValue }
        set { _triggerModifier.wrappedValue = newValue }
    }

    /// The key that, combined with triggerModifier, opens the switcher.
    private var _triggerKey: DefaultsEnum<TriggerKey>
    var triggerKey: TriggerKey {
        get { _triggerKey.wrappedValue }
        set { _triggerKey.wrappedValue = newValue }
    }

    // -- Layout (advisory in v1 — see note below) --

    /// Maximum number of rows to display.
    ///
    /// NOTE: The implementation uses a HORIZONTAL tile layout that auto-sizes
    /// its width to the tile count and shrinks tiles to fit. This property is
    /// retained for model completeness but is NOT wired to the panel in v1 —
    /// the horizontal auto-sizing layout makes it advisory.
    private var _maxRows: DefaultsInt
    var maxRows: Int {
        get { _maxRows.wrappedValue }
        set { _maxRows.wrappedValue = newValue }
    }

    // -- Display --

    /// Delay in milliseconds between trigger and panel appearance.
    /// 0 = immediate (default). Changing this takes effect on the next trigger.
    private var _showDelayMs: DefaultsInt
    var showDelayMs: Int {
        get { _showDelayMs.wrappedValue }
        set { _showDelayMs.wrappedValue = newValue }
    }

    /// When true, only windows on the current Space are enumerated.
    private var _currentSpaceOnly: DefaultsBool
    var currentSpaceOnly: Bool {
        get { _currentSpaceOnly.wrappedValue }
        set { _currentSpaceOnly.wrappedValue = newValue }
    }

    // -- Sorting --

    /// How the window list is sorted.
    private var _sortMode: DefaultsEnum<SortMode>
    var sortMode: SortMode {
        get { _sortMode.wrappedValue }
        set { _sortMode.wrappedValue = newValue }
    }

    // -- Display mode --

    /// How the switcher groups windows: a flat per-window list, or grouped by app.
    /// Default: .window — this ships to existing users, so the default preserves
    /// the flat-list behavior they already know rather than changing it under them.
    private var _switcherDisplayMode: DefaultsEnum<SwitcherDisplayMode>
    var switcherDisplayMode: SwitcherDisplayMode {
        get { _switcherDisplayMode.wrappedValue }
        set { _switcherDisplayMode.wrappedValue = newValue }
    }

    // -- Exclusion --

    /// Bundle IDs excluded from the window list.
    private var _excludedBundleIDs: DefaultsStringArray
    var excludedBundleIDs: [String] {
        get { _excludedBundleIDs.wrappedValue }
        set { _excludedBundleIDs.wrappedValue = newValue }
    }

    // -- Appearance --

    /// Visual theme for the switcher panel.
    private var _theme: DefaultsEnum<Theme>
    var theme: Theme {
        get { _theme.wrappedValue }
        set { _theme.wrappedValue = newValue }
    }

    // -- System integration --

    /// Whether to register the app as a Login Item.
    /// Model only — actual SMAppService registration is handled by LoginItemManager.
    private var _launchAtLogin: DefaultsBool
    var launchAtLogin: Bool {
        get { _launchAtLogin.wrappedValue }
        set { _launchAtLogin.wrappedValue = newValue }
    }

    // -- Accent color --

    /// Accent color applied to the switcher panel highlight and background tint.
    private var _accentColor: DefaultsEnum<AccentColor>
    var accentColor: AccentColor {
        get { _accentColor.wrappedValue }
        set { _accentColor.wrappedValue = newValue }
    }

    // -- Window preview --

    /// When true (and screen recording permission is granted), a live preview of
    /// the selected window is drawn below the title line in the switcher panel.
    /// Default true: users who grant screen recording see it immediately.
    private var _showWindowPreview: DefaultsBool
    var showWindowPreview: Bool {
        get { _showWindowPreview.wrappedValue }
        set { _showWindowPreview.wrappedValue = newValue }
    }

    // -- Language --

    private var _appLanguage: DefaultsEnum<AppLanguage>
    /// The user's preferred UI language. Setting this also writes/removes the
    /// `AppleLanguages` override in the backing store so the bundle resolves the
    /// chosen language on the next launch (a relaunch is required to apply).
    var appLanguage: AppLanguage {
        get { _appLanguage.wrappedValue }
        set {
            _appLanguage.wrappedValue = newValue  // persists + posts .settingsDidChange
            if let langs = newValue.appleLanguagesValue {
                defaults.set(langs, forKey: Key.appleLanguages)
            } else {
                defaults.removeObject(forKey: Key.appleLanguages)
            }
        }
    }

    /// The language selected when the process launched, captured once by
    /// AppDelegate at startup so Settings can show a "restart to apply" prompt.
    @MainActor static var launchLanguage: AppLanguage = .system

    // -- Switcher icon size --

    /// Icon edge in points for switcher tiles. Default 60 (the historical constant).
    /// Effective range 60–96; the tile scales proportionally with the icon.
    private var _switcherIconSize: DefaultsInt
    var switcherIconSize: Int {
        get { _switcherIconSize.wrappedValue }
        set { _switcherIconSize.wrappedValue = newValue }
    }

    // -- Window preview pane size --

    /// Preview pane WIDTH in points; height is derived at 16:10 (width * 200/320).
    /// Default 320; range 240–480.
    private var _windowPreviewWidth: DefaultsInt
    var windowPreviewWidth: Int {
        get { _windowPreviewWidth.wrappedValue }
        set { _windowPreviewWidth.wrappedValue = newValue }
    }

    // -- Panel width (advisory in v1 — see note below) --

    /// Panel width in points.
    ///
    /// NOTE: The implementation derives panel width from the tile count
    /// (auto-sizing). This property is retained for model completeness but is
    /// NOT wired to the panel in v1 — the horizontal auto-sizing layout makes
    /// it advisory.
    private var _panelWidth: DefaultsInt
    var panelWidth: Int {
        get { _panelWidth.wrappedValue }
        set { _panelWidth.wrappedValue = newValue }
    }
}
