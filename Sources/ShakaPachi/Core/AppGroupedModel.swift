// AppGroupedModel.swift
// Value types shared by the app-unit switcher mode: how a flat window snapshot
// is grouped per app, and which slice of one app's windows is on screen.
//
// App-unit mode is a DERIVED VIEW over the flat snapshot the coordinator
// already takes at show time — groups carry indices into that snapshot rather
// than copies of it. Confirming a selection therefore still resolves to a flat
// index, so the activation path is untouched by this mode.
//
// AppKit-free and pure so both the selection logic and the renderer can build
// on these without either depending on the other.

import CoreGraphics
import Foundation

// MARK: - Focus row

/// Which of the two rows the keyboard cursor is on.
///
/// The distinction is visible on screen (the selection rim sits on an app tile
/// or on a window pane), so it is state the user can see rather than a mode
/// they have to remember.
enum SwitcherFocusRow: Equatable {
    /// The app tile row along the top.
    case app
    /// The window preview strip below the selected app.
    case window
}

// MARK: - App group

/// One app's windows within a flat snapshot.
struct AppGroup: Equatable {
    let appName: String
    let bundleID: String?
    let pid: pid_t
    /// Indices into the flat snapshot, in the snapshot's own order.
    /// Never empty — a group exists because at least one window produced it.
    let windowIndices: [Int]

    init(appName: String, bundleID: String?, pid: pid_t, windowIndices: [Int]) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.windowIndices = windowIndices
    }

    /// The key two windows must share to land in the same group.
    /// Mirrors the key `WindowStore` already uses for its `.byApp` sort modes so
    /// app-unit mode groups exactly the way the chosen sort order implies.
    static func key(bundleID: String?, appName: String) -> String {
        bundleID ?? appName
    }
}

// MARK: - Window strip

/// The slice of one group's windows currently drawn, plus the counts folded
/// away on each side and shown as `+n` chips.
///
/// `hiddenLeft + visible.count + hiddenRight` always equals the group's window
/// count, which is what makes the two chips readable as "how much is left".
struct WindowStrip: Equatable {
    /// Flat snapshot indices of the panes actually drawn.
    /// At most `AppGroupedLayout.maxVisibleWindows` entries.
    let visible: [Int]
    /// Windows folded away before `visible` (0 means no left chip).
    let hiddenLeft: Int
    /// Windows folded away after `visible` (0 means no right chip).
    let hiddenRight: Int

    init(visible: [Int], hiddenLeft: Int, hiddenRight: Int) {
        self.visible = visible
        self.hiddenLeft = hiddenLeft
        self.hiddenRight = hiddenRight
    }
}

// MARK: - Layout constants

/// Geometry constants specific to app-unit mode.
/// The pane metrics live here rather than in `SwitcherLayout` because they are
/// fixed rather than derived: panes do not shrink to fit, the strip slides.
enum AppGroupedLayout {
    /// Window panes drawn side by side at once. Beyond this the strip slides to
    /// follow the selection and the remainder becomes `+n` chips on either side.
    ///
    /// Three is what the direct-jump shortcuts can address one-handed with the
    /// trigger modifier held, and it is also what keeps panes at their native
    /// 320x200 instead of shrinking them past legibility.
    static let maxVisibleWindows = 3

    /// Direct-jump shortcut count. Tied to `maxVisibleWindows` because a badge
    /// can only address a pane that is on screen.
    static var directJumpCount: Int { maxVisibleWindows }

    /// Gap between adjacent window panes.
    static let paneSpacing: CGFloat = 10

    /// Gap between a pane and the `+n` chip beside it.
    static let chipSpacing: CGFloat = 10

    /// Width of a `+n` chip. Narrow on purpose: it is an indicator, not a target
    /// competing with the panes for attention.
    static let chipWidth: CGFloat = 44

    /// Corner radius of a `+n` chip.
    static let chipCornerRadius: CGFloat = 8

    /// Height of the per-pane title line drawn directly under each preview.
    static let paneTitleHeight: CGFloat = 18

    /// Gap between a preview pane and its own title line.
    static let paneTitleGap: CGFloat = 4

    /// Opacity applied to the title of a pane that is not the current window.
    /// The current window stays fully opaque, which is what makes "which one am
    /// I on" readable without a second highlight.
    static let unselectedTitleAlpha: CGFloat = 0.45

    /// Fill behind the letterboxed area of a preview whose window is not 16:10.
    /// A dark plate rather than transparency: the panel material shows through
    /// transparency and reads as a hole in the pane.
    static let letterboxPlateAlpha: CGFloat = 0.55
}
