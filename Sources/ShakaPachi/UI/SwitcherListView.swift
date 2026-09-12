// SwitcherListView.swift
// Native App-Switcher-style horizontal icon-tile row (user decision). Each tile
// is ONE WINDOW (not an app) — windows of the same app repeat the app icon,
// AltTab-style — and the selected window's title is drawn beneath the row.
// Custom draw(_:) implementation: tiles plus a single title line, so a full
// pass is trivial and selective redraw reduces to invalidating two tile rects
// plus the title strip.

import AppKit
import CoreGraphics

// MARK: - SwitcherItem

/// Lightweight value type carrying display data for one row.
struct SwitcherItem: Equatable {
    let icon: NSImage?
    let title: String
    /// CGWindowID for the window preview cache lookup.
    /// 0 is a safe sentinel for items that have no associated window (e.g. tests).
    let windowID: CGWindowID
    /// App-unit mode fields below. Defaulted so every existing call site and
    /// test (which only knows about single-window mode) keeps compiling
    /// unchanged; app-unit mode is the only caller that fills them in.
    let appName: String
    let bundleID: String?
    let pid: pid_t
    /// Real window frame, used to letterbox the live preview at its true
    /// aspect ratio instead of stretching it to the fixed pane size.
    let bounds: CGRect

    init(
        icon: NSImage?,
        title: String,
        windowID: CGWindowID = 0,
        appName: String = "",
        bundleID: String? = nil,
        pid: pid_t = 0,
        bounds: CGRect = .zero
    ) {
        self.icon = icon
        self.title = title
        self.windowID = windowID
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.bounds = bounds
    }
}

// MARK: - Layout constants shared with SwitcherPanel

/// Shared layout constants used by both the tile row and the panel.
/// All geometry functions are pure — unit-testable.
enum SwitcherLayout {
    /// Square highlight tile per window — the nominal (maximum) size.
    static let tileSize: CGFloat = 76
    /// App icon drawn centered inside the nominal tile.
    static let iconSize: CGFloat = 60
    /// Minimum tile edge when shrink-to-fit kicks in.
    static let minTileSize: CGFloat = 40
    /// Gap between adjacent tiles.
    static let tileSpacing: CGFloat = 8
    /// Left/right panel margin around the tile row.
    static let horizontalMargin: CGFloat = 20
    /// Space above the tile row.
    static let topPadding: CGFloat = 20
    /// Gap between the tile row and the title line.
    static let titleGap: CGFloat = 6
    /// Height of the selected-window title line.
    static let titleHeight: CGFloat = 20
    /// Space below the title line.
    static let bottomPadding: CGFloat = 14

    // MARK: - Window preview constants

    /// Width of the optional live-preview pane (16:10 ratio with previewHeight).
    static let previewWidth: CGFloat = 320
    /// Height of the optional live-preview pane.
    static let previewHeight: CGFloat = 200
    /// Gap between the title line and the top of the preview pane.
    static let previewTopGap: CGFloat = 10

    // MARK: - Shrink-to-fit

    /// Return the effective tile edge so that all `itemCount` tiles fit inside
    /// `availableWidth`.  The result is clamped to [minTileSize, tileSize].
    ///
    /// The formula solves for `t` in:
    ///   margin*2 + count*t + (count-1)*spacing ≤ availableWidth
    ///   → t ≤ (availableWidth - margin*2 + spacing) / (count + spacing/t)
    /// Simplified (spacing treated proportionally):
    ///   t = (availableWidth - margin*2 + spacing) / count - spacing
    ///   but clamped so it never goes below minTileSize.
    ///
    /// Below minTileSize the tiles are allowed to clip off-screen (acceptable,
    /// rare edge case per spec).
    static func effectiveTileSize(
        itemCount: Int, availableWidth: CGFloat, baseTile: CGFloat = tileSize
    ) -> CGFloat {
        guard itemCount > 0 else { return baseTile }
        let natural = panelSize(itemCount: itemCount, baseTile: baseTile).width
        if natural <= availableWidth {
            return baseTile  // fits at full size — no shrink needed
        }
        // Largest t such that: margin*2 + count*t + (count-1)*spacing ≤ availableWidth
        //   t ≤ (availableWidth - margin*2 - (count-1)*spacing) / count
        let usable =
            availableWidth - horizontalMargin * 2
            - CGFloat(itemCount - 1) * tileSpacing
        let fitted = usable / CGFloat(itemCount)
        return max(fitted, minTileSize)
    }

    /// Icon inset inside a tile of the given effective size (keeps same visual
    /// proportion as the nominal 76pt tile / 60pt icon).
    static func effectiveIconSize(for effectiveTile: CGFloat) -> CGFloat {
        let ratio = iconSize / tileSize  // 60/76 ≈ 0.789
        return effectiveTile * ratio
    }

    /// Total panel size for a given window count.
    /// Pass `baseTile` to use a non-nominal tile edge (default = `tileSize` = 76).
    /// Use `panelSize(itemCount:effectiveTile:)` when shrinking is active.
    static func panelSize(itemCount: Int, baseTile: CGFloat = tileSize) -> NSSize {
        let count = max(itemCount, 1)
        let width =
            horizontalMargin * 2
            + CGFloat(count) * baseTile
            + CGFloat(count - 1) * tileSpacing
        let height = topPadding + baseTile + titleGap + titleHeight + bottomPadding
        return NSSize(width: width, height: height)
    }

    /// Converts a user-chosen icon-size (in points) to the corresponding nominal
    /// tile edge, preserving the canonical icon/tile ratio (60/76 ≈ 0.789).
    /// Example: nominalTile(forIconSize: 60) == 76.
    static func nominalTile(forIconSize iconPoints: CGFloat) -> CGFloat {
        iconPoints * tileSize / iconSize  // 60 → 76
    }

    /// Total panel size using the given effective tile edge (used when tiles are
    /// shrunk so all fit within the screen width).
    static func panelSize(itemCount: Int, effectiveTile: CGFloat) -> NSSize {
        panelSize(itemCount: itemCount, effectiveTile: effectiveTile, previewEnabled: false)
    }

    /// Total panel size using the given effective tile edge, with an optional
    /// preview pane below the title.
    ///
    /// When `previewEnabled` is true:
    ///   - Width is widened to at least (previewPaneWidth + horizontalMargin*2) so
    ///     the preview box always fits without clipping.
    ///   - Height gains `previewTopGap + previewPaneHeight` below the title.
    ///
    /// The two-argument overload without `previewEnabled` forwards here with
    /// `false` so all existing callers and tests remain source-compatible.
    /// `previewPaneWidth`/`previewPaneHeight` default to the static constants so
    /// zero-arg and existing callers remain byte-identical.
    static func panelSize(
        itemCount: Int,
        effectiveTile: CGFloat,
        previewEnabled: Bool,
        previewPaneWidth: CGFloat = previewWidth,
        previewPaneHeight: CGFloat = previewHeight
    ) -> NSSize {
        let count = max(itemCount, 1)
        let tileRowWidth =
            horizontalMargin * 2
            + CGFloat(count) * effectiveTile
            + CGFloat(count - 1) * tileSpacing
        let baseHeight = topPadding + effectiveTile + titleGap + titleHeight + bottomPadding
        if previewEnabled {
            let minPreviewPanelWidth = previewPaneWidth + horizontalMargin * 2
            return NSSize(
                width: max(tileRowWidth, minPreviewPanelWidth),
                height: baseHeight + previewTopGap + previewPaneHeight
            )
        }
        return NSSize(width: tileRowWidth, height: baseHeight)
    }

    /// Preview pane rect in flipped (top-left origin) coordinates, consistent
    /// with `SwitcherListView.isFlipped == true`.
    ///
    /// - Parameters:
    ///   - width: The total panel width (used to center the pane horizontally).
    ///   - effectiveTile: The effective tile edge currently in use.
    ///   - previewPaneWidth: Width of the preview pane (default: `previewWidth` constant).
    ///   - previewPaneHeight: Height of the preview pane (default: `previewHeight` constant).
    static func previewRect(
        inBoundsWidth width: CGFloat,
        effectiveTile: CGFloat,
        previewPaneWidth: CGFloat = previewWidth,
        previewPaneHeight: CGFloat = previewHeight
    ) -> NSRect {
        let x = (width - previewPaneWidth) / 2
        let y = topPadding + effectiveTile + titleGap + titleHeight + previewTopGap
        return NSRect(x: x, y: y, width: previewPaneWidth, height: previewPaneHeight)
    }

    /// Returns the preview pane size for a given width, maintaining 16:10 aspect ratio.
    /// Example: previewPaneSize(forWidth: 320) == 320×200, previewPaneSize(forWidth: 480) == 480×300.
    static func previewPaneSize(forWidth w: CGFloat) -> NSSize {
        NSSize(width: w, height: w * previewHeight / previewWidth)
    }

    /// Tile rect for the given index using the nominal tile size, in flipped
    /// (top-left origin) coordinates.
    static func tileRect(index: Int) -> NSRect {
        tileRect(index: index, effectiveTile: tileSize)
    }

    /// Tile rect for the given index using a specified effective tile edge.
    static func tileRect(index: Int, effectiveTile: CGFloat) -> NSRect {
        NSRect(
            x: horizontalMargin + CGFloat(index) * (effectiveTile + tileSpacing),
            y: topPadding,
            width: effectiveTile,
            height: effectiveTile
        )
    }

    /// Tile rect shifted right by `offsetX` relative to the 2-arg overload.
    /// Used to center the tile row when the panel is wider than the natural
    /// tile-row width (e.g. when the preview pane widens the panel).
    static func tileRect(index: Int, effectiveTile: CGFloat, offsetX: CGFloat) -> NSRect {
        let base = tileRect(index: index, effectiveTile: effectiveTile)
        return NSRect(
            x: base.origin.x + offsetX,
            y: base.origin.y,
            width: base.width,
            height: base.height
        )
    }

    /// Returns the horizontal offset needed to center the whole tile row within
    /// `boundsWidth`. When the preview pane widens the panel, the tile row
    /// would otherwise cluster at the left margin; this offset shifts the entire
    /// row rightward so its center aligns with the panel center (matching the
    /// already-centered preview pane and title). Never returns a negative value:
    /// if the row is wider than `boundsWidth`, returns 0 so nothing shifts
    /// left off-screen.
    static func tileRowOffsetX(
        itemCount: Int,
        effectiveTile: CGFloat,
        boundsWidth: CGFloat
    ) -> CGFloat {
        let count = max(itemCount, 1)
        let rowWidth =
            horizontalMargin * 2
            + CGFloat(count) * effectiveTile
            + CGFloat(count - 1) * tileSpacing
        let offset = (boundsWidth - rowWidth) / 2
        return max(offset, 0)
    }

    /// Advance the selection index by +1 with wrap-around.
    static func advanceIndex(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current + 1) % count
    }

    /// The tile indices needing redraw when the selection moves.
    static func indicesToRedraw(old: Int, new: Int) -> IndexSet {
        var set = IndexSet()
        set.insert(old)
        if new != old { set.insert(new) }
        return set
    }

    // MARK: - App-grouped mode geometry
    //
    // App-unit mode stacks a fixed vertical sequence (top to bottom): the app
    // tile row (shrink-to-fit, same as single-window mode), the selected app's
    // name, the window-pane row (never shrinks — panes stay at their native
    // previewWidth x previewHeight and the strip scrolls instead), and each
    // visible pane's own title. Panes are laid out side by side rather than
    // stacked, so panel height never depends on how many panes are visible —
    // only panel width does, alongside the app row's own natural width.

    /// Total panel size for app-grouped mode.
    ///
    /// Width is the max of the app-tile row's natural width and the
    /// window-pane row's natural width (the wider row dictates the panel;
    /// the narrower one is then centered inside it via `tileRowOffsetX` /
    /// `windowRowOffsetX`). Height is fixed given `effectiveTile` — panes sit
    /// side by side, not stacked, so `visiblePaneCount` never affects it.
    static func appGroupedPanelSize(
        groupCount: Int,
        visiblePaneCount: Int,
        hasLeftChip: Bool,
        hasRightChip: Bool,
        effectiveTile: CGFloat = tileSize
    ) -> NSSize {
        let appRowWidth = panelSize(itemCount: groupCount, baseTile: effectiveTile).width
        let windowRowWidth = appGroupedWindowRowWidth(
            visiblePaneCount: visiblePaneCount, hasLeftChip: hasLeftChip, hasRightChip: hasRightChip)
        let height =
            topPadding + effectiveTile + titleGap + titleHeight
            + previewTopGap + previewHeight
            + AppGroupedLayout.paneTitleGap + AppGroupedLayout.paneTitleHeight
            + bottomPadding
        return NSSize(width: max(appRowWidth, windowRowWidth), height: height)
    }

    /// Natural (unclamped) width of the window-pane row alone: margins, the
    /// optional chips, `n` panes and the `n-1` gaps between them. Shared by
    /// `appGroupedPanelSize` and `windowRowOffsetX` so "how wide is the pane
    /// row" is computed in exactly one place.
    private static func appGroupedWindowRowWidth(
        visiblePaneCount: Int, hasLeftChip: Bool, hasRightChip: Bool
    ) -> CGFloat {
        let n = max(visiblePaneCount, 0)
        var width = horizontalMargin * 2 + CGFloat(n) * previewWidth
        if n > 1 { width += CGFloat(n - 1) * AppGroupedLayout.paneSpacing }
        if hasLeftChip { width += AppGroupedLayout.chipWidth + AppGroupedLayout.chipSpacing }
        if hasRightChip { width += AppGroupedLayout.chipSpacing + AppGroupedLayout.chipWidth }
        return width
    }

    /// Horizontal offset to center the window-pane row within `panelWidth`,
    /// mirroring what `tileRowOffsetX` already does for the app-tile row (that
    /// existing function is reused as-is for the app row — it never assumed
    /// anything preview-specific). Never negative: if the pane row is wider
    /// than `panelWidth` it is left-aligned rather than pushed off-screen.
    static func windowRowOffsetX(
        visiblePaneCount: Int, hasLeftChip: Bool, hasRightChip: Bool, panelWidth: CGFloat
    ) -> CGFloat {
        let rowWidth = appGroupedWindowRowWidth(
            visiblePaneCount: visiblePaneCount, hasLeftChip: hasLeftChip, hasRightChip: hasRightChip)
        return max((panelWidth - rowWidth) / 2, 0)
    }

    /// Top y of the window-pane row (flipped coordinates) — the y every
    /// pane, chip and pane-title rect below shares.
    private static func appGroupedPaneRowTop(effectiveTile: CGFloat) -> CGFloat {
        topPadding + effectiveTile + titleGap + titleHeight + previewTopGap
    }

    /// Rect for the `ordinal`-th (0-based) visible pane. `rowOffsetX` is the
    /// value `windowRowOffsetX` returned for the current strip/panel width —
    /// callers compute it once per draw pass and pass it to every pane/chip
    /// rect call rather than each rect re-deriving it.
    static func paneRect(
        ordinal: Int, hasLeftChip: Bool, effectiveTile: CGFloat, rowOffsetX: CGFloat
    ) -> NSRect {
        var x = rowOffsetX + horizontalMargin
        if hasLeftChip { x += AppGroupedLayout.chipWidth + AppGroupedLayout.chipSpacing }
        x += CGFloat(ordinal) * (previewWidth + AppGroupedLayout.paneSpacing)
        return NSRect(
            x: x, y: appGroupedPaneRowTop(effectiveTile: effectiveTile),
            width: previewWidth, height: previewHeight)
    }

    /// Left `+n` chip rect, or nil when `hiddenLeft` is 0 (nothing folded away
    /// to the left, so there is nothing for the chip to summarize).
    static func leftChipRect(
        hiddenLeft: Int, effectiveTile: CGFloat, rowOffsetX: CGFloat
    ) -> NSRect? {
        guard hiddenLeft > 0 else { return nil }
        return NSRect(
            x: rowOffsetX + horizontalMargin,
            y: appGroupedPaneRowTop(effectiveTile: effectiveTile),
            width: AppGroupedLayout.chipWidth,
            height: previewHeight
        )
    }

    /// Right `+n` chip rect, or nil when `hiddenRight` is 0.
    static func rightChipRect(
        hiddenRight: Int,
        visiblePaneCount: Int,
        hasLeftChip: Bool,
        effectiveTile: CGFloat,
        rowOffsetX: CGFloat
    ) -> NSRect? {
        guard hiddenRight > 0 else { return nil }
        var x = rowOffsetX + horizontalMargin
        if hasLeftChip { x += AppGroupedLayout.chipWidth + AppGroupedLayout.chipSpacing }
        let n = max(visiblePaneCount, 0)
        x += CGFloat(n) * previewWidth
        if n > 1 { x += CGFloat(n - 1) * AppGroupedLayout.paneSpacing }
        x += AppGroupedLayout.chipSpacing
        return NSRect(
            x: x, y: appGroupedPaneRowTop(effectiveTile: effectiveTile),
            width: AppGroupedLayout.chipWidth, height: previewHeight)
    }

    /// Rect for the `ordinal`-th pane's own title line, directly beneath it.
    static func paneTitleRect(
        ordinal: Int, hasLeftChip: Bool, effectiveTile: CGFloat, rowOffsetX: CGFloat
    ) -> NSRect {
        let pane = paneRect(
            ordinal: ordinal, hasLeftChip: hasLeftChip, effectiveTile: effectiveTile,
            rowOffsetX: rowOffsetX)
        return NSRect(
            x: pane.origin.x,
            y: pane.origin.y + previewHeight + AppGroupedLayout.paneTitleGap,
            width: pane.width,
            height: AppGroupedLayout.paneTitleHeight
        )
    }

    /// Rect for the selected app's name line, spanning the full panel width
    /// (same shape as single-window mode's title line).
    static func appNameRect(panelWidth: CGFloat, effectiveTile: CGFloat) -> NSRect {
        NSRect(
            x: 0,
            y: topPadding + effectiveTile + titleGap,
            width: panelWidth,
            height: titleHeight
        )
    }

    /// Fits `windowBounds`'s aspect ratio inside `paneRect` (contain, never
    /// crop), centered on both axes — a real window is almost never exactly
    /// 16:10, so the capture is letterboxed rather than stretched or cropped.
    /// Falls back to `paneRect` itself when `windowBounds` has a
    /// non-positive width or height (e.g. not resolved yet), which is safer
    /// than dividing by zero or drawing a degenerate rect.
    static func letterboxRect(for windowBounds: CGRect, in paneRect: NSRect) -> NSRect {
        guard windowBounds.width > 0, windowBounds.height > 0 else { return paneRect }
        let scale = min(
            paneRect.width / windowBounds.width,
            paneRect.height / windowBounds.height)
        let fitW = windowBounds.width * scale
        let fitH = windowBounds.height * scale
        return NSRect(
            x: paneRect.midX - fitW / 2,
            y: paneRect.midY - fitH / 2,
            width: fitW,
            height: fitH
        )
    }
}

// MARK: - SwitcherListView

/// Horizontal icon-tile row with the selected window's title beneath it.
/// Fully custom-drawn: no subviews, no Auto Layout in the hot path.
final class SwitcherListView: NSView {

    // MARK: State

    private var items: [SwitcherItem] = []
    private(set) var selectedIndex: Int = 0
    // Effective tile edge, set by setItems/setAppGrouped; may be < tileSize
    // when shrink-to-fit kicks in for wide lists.
    private var effectiveTile: CGFloat = SwitcherLayout.tileSize

    // MARK: App-grouped mode state
    //
    // Set only by setAppGrouped(); setItems() resets isAppGrouped to false so
    // draw() always reflects whichever setter ran most recently. Single-window
    // mode's own state (items/selectedIndex/effectiveTile) is reused rather
    // than duplicated — app-grouped mode's `items` is the same flat snapshot,
    // just presented differently.
    private var isAppGrouped = false
    private var groups: [AppGroup] = []
    private var appIndex = 0
    private var strip = WindowStrip(visible: [], hiddenLeft: 0, hiddenRight: 0)
    private var currentFlatIndex = 0
    private var focusRow: SwitcherFocusRow = .app
    private var modifierSymbol = ""

    // Pushed by SwitcherPanel before each show so draw() stays pure — it reads
    // a stored value rather than calling into Settings during the draw pass.
    var accentColor: NSColor = .controlAccentColor

    // When true, a live preview pane is drawn below the title.
    // Pushed by the panel on each show(); never changes during a session.
    var previewEnabled: Bool = false

    // Preview pane dimensions — pushed by the panel on each show() from Settings.
    // Defaults match the static constants so a zero-push scenario draws identically.
    var previewPaneWidth: CGFloat = SwitcherLayout.previewWidth
    var previewPaneHeight: CGFloat = SwitcherLayout.previewHeight

    // Owned by the panel; injected once in SwitcherPanel.init().
    // Weak to avoid a retain cycle: panel → cache ← listView.
    weak var previewCache: WindowPreviewCache?

    // When true the selected tile's rim comes from the opal layer stack below
    // instead of the two-tone hairline drawn in draw(_:). Pushed by the panel on
    // each show(), like accentColor, so draw() never reads Settings.
    var opalRimEnabled: Bool = false {
        didSet {
            guard opalRimEnabled != oldValue else { return }
            if !opalRimEnabled { stopOpalRimAnimation() }
            updateOpalRimLayout()
            needsDisplay = true
        }
    }

    // Top-left origin so tile math matches SwitcherLayout directly.
    override var isFlipped: Bool { true }

    // MARK: Opal rim layers

    /// Corner radius of the selected tile's highlight, shared by the drawn
    /// highlight and the opal rim's ring mask so the two can never diverge.
    private static let selectionCornerRadius: CGFloat = 14

    /// Corner radius of a selected window pane's highlight in app-grouped
    /// mode. Deliberately not `selectionCornerRadius`: panes are wide 320x200
    /// rectangles rather than near-square tiles, and the tile radius reads as
    /// too tight on them.
    private static let paneSelectionCornerRadius: CGFloat = 10

    /// Animation key for the opal rim's rotation, so it can be removed on hide.
    private static let opalRimAnimationKey = "opalRimSpin"

    // MARK: App-grouped mode drawing constants
    //
    // Grouped here (rather than inlined at each call site) because these are
    // the values expected to be tuned after a first visual pass — a single
    // named spot to change per knob.

    /// Corner radius of a preview pane's own rounded rect (the letterbox
    /// plate and its image clip).
    private static let paneCornerRadius: CGFloat = 10

    /// Direct-jump badge (e.g. "⌘1") drawn in a pane's top-left corner.
    private static let badgeInset: CGFloat = 6
    private static let badgeHeight: CGFloat = 16
    private static let badgeHorizontalPadding: CGFloat = 5
    private static let badgeCornerRadius: CGFloat = 5
    private static let badgeFontSize: CGFloat = 11
    private static let badgeBackgroundAlpha: CGFloat = 0.55
    private static let badgeTextColor = NSColor.white

    /// `+n` chip beside the pane row.
    private static let chipFontSize: CGFloat = 14
    private static let chipBackgroundAlpha: CGFloat = 0.35
    private static let chipTextColor = NSColor.white

    /// Outline-only "this is the current window" indicator drawn on the
    /// current pane while the cursor is on the app row (see
    /// `drawWeakOutline`).
    private static let weakPaneOutlineAlpha: CGFloat = 0.35
    private static let weakPaneOutlineWidth: CGFloat = 1.5

    /// Horizontal inset for a pane's own title text — smaller than the panel
    /// margin used for the app-name line since a pane is only 320pt wide.
    private static let paneTitleHorizontalInset: CGFloat = 6

    // Iridescent rim for the `.opal` accent. Two layers, deliberately:
    //   opalRimContainer — frame = the selected tile, masked to a 1px rounded
    //     rect ring. Never rotates.
    //   opalRimGradient  — child conic gradient carrying the spectrum, inflated
    //     past the container's diagonal so no corner of it can turn into view.
    //     This is the layer the rotation is attached to.
    // Masking the rotating gradient directly would spin the ring itself and make
    // the tile's rounded corners visibly swing.
    private let opalRimContainer = CALayer()
    private let opalRimMask = CAShapeLayer()
    private let opalRimGradient = CAGradientLayer()

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpOpalRimLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpOpalRimLayers()
    }

    /// Build the opal rim layers once, at init. The panel that owns this view is
    /// created at startup and never rebuilt, so neither is this layer stack —
    /// show() only flips its visibility and moves its frame.
    private func setUpOpalRimLayers() {
        // The panel's NSVisualEffectView already backs this whole subtree, so
        // this only guarantees `layer` is non-nil here in init.
        wantsLayer = true

        opalRimGradient.type = .conic
        opalRimGradient.colors = AccentColor.opalSpectrum.map(\.cgColor)
        opalRimGradient.startPoint = CGPoint(x: 0.5, y: 0.5)  // conic center
        opalRimGradient.endPoint = CGPoint(x: 0.5, y: 0.0)  // angle the sweep starts from
        opalRimContainer.addSublayer(opalRimGradient)

        opalRimMask.fillRule = .evenOdd  // outer rect minus inner rect = the ring
        opalRimMask.fillColor = NSColor.black.cgColor
        opalRimContainer.mask = opalRimMask
        opalRimContainer.isHidden = true
        layer?.addSublayer(opalRimContainer)
    }

    // MARK: Public API

    /// Number of items currently displayed (the snapshot taken at show time).
    var count: Int { items.count }

    /// Replace the full item list and select the given index.
    /// Pass the available panel width so the shrink-to-fit tile size can be
    /// computed; when zero the nominal tile size is used.
    /// Pass `baseTile` when the user has configured a non-default icon size.
    func setItems(
        _ items: [SwitcherItem],
        selectedIndex: Int,
        availableWidth: CGFloat = 0,
        baseTile: CGFloat = SwitcherLayout.tileSize
    ) {
        self.items = items
        self.isAppGrouped = false
        self.selectedIndex = clamp(selectedIndex, count: items.count)
        if availableWidth > 0 {
            effectiveTile = SwitcherLayout.effectiveTileSize(
                itemCount: items.count, availableWidth: availableWidth, baseTile: baseTile)
        } else {
            effectiveTile = baseTile
        }
        needsDisplay = true
        updateOpalRimLayout()
        if previewEnabled { requestPreviews() }
    }

    /// Replace the full app-grouped presentation: the app tile row, the
    /// selected app's window-pane strip, and which row the keyboard cursor is
    /// on. `items` is the same flat snapshot `setItems` would receive —
    /// `groups`/`strip` only describe how to present it, never copy it.
    ///
    /// Unlike `moveSelection`, every call does a full redraw: app-grouped mode
    /// has no equivalent of "just the two affected tiles" (which row changed,
    /// which app, which pane, and whether the strip slid can each move
    /// different rects), so partial invalidation would need to reconstruct
    /// that diff for marginal benefit on a view this small.
    ///
    /// - Parameter availableWidth: Screen-width constraint for the app tile
    ///   row's shrink-to-fit, same role as `setItems`'s parameter of the same
    ///   name. Zero (the default) means "use the nominal tile size" — the
    ///   window-pane row never shrinks regardless, so this only ever affects
    ///   the app row.
    func setAppGrouped(
        items: [SwitcherItem],
        groups: [AppGroup],
        appIndex: Int,
        strip: WindowStrip,
        currentFlatIndex: Int,
        focusRow: SwitcherFocusRow,
        modifierSymbol: String,
        availableWidth: CGFloat = 0,
        baseTile: CGFloat = SwitcherLayout.tileSize
    ) {
        self.items = items
        self.isAppGrouped = true
        self.groups = groups
        self.appIndex = groups.indices.contains(appIndex) ? appIndex : 0
        self.strip = strip
        self.currentFlatIndex = currentFlatIndex
        self.focusRow = focusRow
        self.modifierSymbol = modifierSymbol
        if availableWidth > 0 {
            effectiveTile = SwitcherLayout.effectiveTileSize(
                itemCount: groups.count, availableWidth: availableWidth, baseTile: baseTile)
        } else {
            effectiveTile = baseTile
        }
        needsDisplay = true
        updateOpalRimLayout()
        if previewEnabled { requestAppGroupedPreviews() }
    }

    /// Move the selection highlight, invalidating only the two affected tiles
    /// and the title strip.
    func moveSelection(to newIndex: Int) {
        let old = selectedIndex
        let new = clamp(newIndex, count: items.count)
        guard new != old else { return }

        selectedIndex = new
        let offsetX = tileRowOffsetX
        for index in SwitcherLayout.indicesToRedraw(old: old, new: new) {
            setNeedsDisplay(
                SwitcherLayout.tileRect(
                    index: index,
                    effectiveTile: effectiveTile,
                    offsetX: offsetX
                )
                .insetBy(dx: -2, dy: -2))
        }
        setNeedsDisplay(titleRect)
        // Moves layers only — the two tile rects invalidated above stay the
        // whole redraw cost of a selection move.
        updateOpalRimLayout()
        if previewEnabled {
            setNeedsDisplay(previewRect)
            requestPreviews()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // bounds.width feeds tileRowOffsetX, so the rim has to follow the panel
        // resize that show() performs before ordering the panel front.
        updateOpalRimLayout()
    }

    // MARK: - Opal rim

    /// The rect + corner radius the opal rim should currently sit on, or nil
    /// when there is nothing selected to sit on. Single source of truth for
    /// all three selection targets the rim can track: the single-window tile,
    /// the app-grouped app tile, and the app-grouped window pane — so the rim
    /// always follows whichever rect draw(_:) is currently drawing the strong
    /// highlight on.
    private var opalRimTarget: (rect: NSRect, radius: CGFloat)? {
        guard isAppGrouped else {
            guard items.indices.contains(selectedIndex) else { return nil }
            let rect = SwitcherLayout.tileRect(
                index: selectedIndex, effectiveTile: effectiveTile, offsetX: tileRowOffsetX)
            return (rect, Self.selectionCornerRadius)
        }
        switch focusRow {
        case .app:
            guard groups.indices.contains(appIndex) else { return nil }
            let offsetX = SwitcherLayout.tileRowOffsetX(
                itemCount: groups.count, effectiveTile: effectiveTile, boundsWidth: bounds.width)
            let rect = SwitcherLayout.tileRect(index: appIndex, effectiveTile: effectiveTile, offsetX: offsetX)
            return (rect, Self.selectionCornerRadius)
        case .window:
            guard let ordinal = strip.visible.firstIndex(of: currentFlatIndex) else { return nil }
            let rect = appGroupedPaneRect(ordinal: ordinal)
            return (rect, Self.paneSelectionCornerRadius)
        }
    }

    /// Park the opal rim over `opalRimTarget` and rebuild its ring mask.
    /// No-op for every other accent.
    private func updateOpalRimLayout() {
        let target = opalRimEnabled ? opalRimTarget : nil
        let visible = target != nil
        // Free for every other accent: this is called from the selection-move
        // path, and once the rim is hidden its frame stops mattering.
        guard visible || !opalRimContainer.isHidden else { return }
        // Frames and visibility only; disable implicit actions so the rim never
        // slides between tiles. The explicit rotation is the only animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opalRimContainer.isHidden = !visible
        if let target {
            let rect = target.rect
            let radius = target.radius
            opalRimContainer.frame = rect
            opalRimMask.frame = opalRimContainer.bounds
            opalRimMask.path = Self.rimRingPath(in: opalRimContainer.bounds, radius: radius)
            // Square the gradient off past the container's diagonal so a corner
            // of it can never rotate into the ring and expose the gradient's
            // edge. The diagonal on its own is the tangent case — the ring's
            // corners land exactly on the rotating square's edge at four angles
            // — so carry a margin instead of sitting on the boundary.
            let diagonal = (rect.width * rect.width + rect.height * rect.height).squareRoot()
            let side = (diagonal + 2).rounded(.up)
            opalRimGradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            opalRimGradient.position = CGPoint(x: rect.width / 2, y: rect.height / 2)
        }
        CATransaction.commit()
    }

    /// The 1px ring the opal rim is masked to: the tile's rounded outline minus
    /// the same outline inset by one point, filled even-odd. Matches the
    /// outermost line of the two-tone hairline it replaces.
    private static func rimRingPath(in rect: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        path.addRoundedRect(
            in: rect.insetBy(dx: 1, dy: 1), cornerWidth: radius - 1, cornerHeight: radius - 1)
        return path
    }

    /// Start the rim's rotation. Called by the panel on show and paired with
    /// `stopOpalRimAnimation()` on hide, so nothing ticks while the panel is
    /// ordered out. Core Animation runs it on the render server, so the main
    /// thread does no per-frame work.
    func startOpalRimAnimation() {
        guard opalRimEnabled,
            opalRimGradient.animation(forKey: Self.opalRimAnimationKey) == nil
        else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = AccentColor.opalRimRotationDuration
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        opalRimGradient.add(spin, forKey: Self.opalRimAnimationKey)
    }

    /// Stop the rim's rotation (panel hidden, or the accent moved off opal).
    func stopOpalRimAnimation() {
        opalRimGradient.removeAnimation(forKey: Self.opalRimAnimationKey)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isAppGrouped {
            drawAppGrouped(dirtyRect)
            return
        }
        let tile = effectiveTile
        let iconEdge = SwitcherLayout.effectiveIconSize(for: tile)
        let offsetX = tileRowOffsetX
        for (index, item) in items.enumerated() {
            let tileRect = SwitcherLayout.tileRect(index: index, effectiveTile: tile, offsetX: offsetX)
            guard tileRect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) else { continue }

            if index == selectedIndex {
                drawStrongSelection(in: tileRect, cornerRadius: Self.selectionCornerRadius)
            }

            let inset = (tile - iconEdge) / 2
            let iconRect = tileRect.insetBy(dx: inset, dy: inset)
            item.icon?.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        }

        if titleRect.intersects(dirtyRect), items.indices.contains(selectedIndex) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle  // middle-truncate long titles
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            let textRect = titleRect.insetBy(dx: SwitcherLayout.horizontalMargin, dy: 0)
            (items[selectedIndex].title as NSString).draw(in: textRect, withAttributes: attributes)
        }

        // Live preview pane — only drawn when enabled and the dirty rect overlaps.
        // draw() is kept pure/fast: only reads from the cache dict, never triggers
        // a capture (that happens in requestPreviews, called from setItems/moveSelection).
        if previewEnabled,
            previewRect.intersects(dirtyRect),
            items.indices.contains(selectedIndex)
        {
            drawPreview(in: previewRect, for: items[selectedIndex])
        }
    }

    /// The accent-tinted fill + rim highlight shared by every "strongly
    /// selected" shape: the single-window tile, the app-grouped app tile, and
    /// the app-grouped current pane. Factored out of the single-window path
    /// above rather than duplicated so app-grouped mode's highlight can never
    /// visually drift from it.
    private func drawStrongSelection(in rect: NSRect, cornerRadius radius: CGFloat) {
        // Accent-tinted rounded highlight — clearly shows the chosen accent
        // colour while staying tasteful. Color is pushed by the panel before
        // each show so this path stays pure/fast.
        let highlight = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        accentColor.withAlphaComponent(AccentColor.selectionHighlightAlpha).setFill()
        highlight.fill()

        // The opal accent supplies the rim from its rotating gradient layer
        // instead (see updateOpalRimLayout), so the hairline is skipped
        // rather than drawn underneath it.
        if !opalRimEnabled {
            // Two-tone hairline rim over the fill. The fill alone is a
            // source-over blend, so it disappears whenever the panel's
            // .behindWindow material lands on the accent's own luminance; a
            // dark line with a light line immediately inside it always leaves
            // one of the two contrasting. Strokes straddle their path, so
            // both are inset by half a line width to stay inside rect.
            let darkRim = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: radius - 0.5, yRadius: radius - 0.5)
            darkRim.lineWidth = 1
            NSColor.black.withAlphaComponent(AccentColor.selectionRimDarkAlpha).setStroke()
            darkRim.stroke()

            let lightRim = NSBezierPath(
                roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
                xRadius: radius - 1.5, yRadius: radius - 1.5)
            lightRim.lineWidth = 1
            NSColor.white.withAlphaComponent(AccentColor.selectionRimLightAlpha).setStroke()
            lightRim.stroke()
        }
    }

    /// Outline-only "this is the current window" indicator: no fill, so it
    /// reads as secondary information rather than competing with whichever
    /// row currently has the strong highlight.
    private func drawWeakOutline(in rect: NSRect, cornerRadius radius: CGFloat) {
        let outline = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: radius - 0.5, yRadius: radius - 0.5)
        outline.lineWidth = Self.weakPaneOutlineWidth
        accentColor.withAlphaComponent(Self.weakPaneOutlineAlpha).setStroke()
        outline.stroke()
    }

    /// Centered, middle-truncated single-line text — the app name line and
    /// each pane's own title both use this, differing only in inset (a pane
    /// is much narrower than the full panel) and color (an unselected pane's
    /// title is dimmed).
    private func drawCenteredTruncatedText(
        _ text: String, in rect: NSRect, fontSize: CGFloat, color: NSColor, horizontalInset: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let textRect = rect.insetBy(dx: horizontalInset, dy: 0)
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    /// Draw the app-grouped presentation: the app tile row, the selected
    /// app's name, the window-pane strip (each pane letterboxed + titled +
    /// badged), and the `+n` chips when the strip has folded panes on either
    /// side. Mirrors draw()'s single-window path in spirit — pure/fast, reads
    /// only from state already pushed by setAppGrouped/setItems-style setters
    /// and the preview cache, never triggers a capture itself.
    private func drawAppGrouped(_ dirtyRect: NSRect) {
        let tile = effectiveTile
        let panelWidth = bounds.width
        // Chip SLOTS are reserved per group; a chip is only painted when that
        // side actually has something folded away (see `leftChipRect`).
        let reservesChips = reservesChipSlots
        let appOffsetX = SwitcherLayout.tileRowOffsetX(
            itemCount: groups.count, effectiveTile: tile, boundsWidth: panelWidth)
        let paneOffsetX = SwitcherLayout.windowRowOffsetX(
            visiblePaneCount: strip.visible.count, hasLeftChip: reservesChips, hasRightChip: reservesChips,
            panelWidth: panelWidth)

        // --- App tile row: one tile per group, icon = that group's first window's icon.
        let iconEdge = SwitcherLayout.effectiveIconSize(for: tile)
        for (groupOrdinal, group) in groups.enumerated() {
            let tileRect = SwitcherLayout.tileRect(index: groupOrdinal, effectiveTile: tile, offsetX: appOffsetX)
            guard tileRect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) else { continue }

            if groupOrdinal == appIndex {
                drawStrongSelection(in: tileRect, cornerRadius: Self.selectionCornerRadius)
            }

            guard let firstFlatIndex = group.windowIndices.first, items.indices.contains(firstFlatIndex) else {
                continue
            }
            let inset = (tile - iconEdge) / 2
            let iconRect = tileRect.insetBy(dx: inset, dy: inset)
            items[firstFlatIndex].icon?.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        }

        // --- Selected app's name.
        let nameRect = SwitcherLayout.appNameRect(panelWidth: panelWidth, effectiveTile: tile)
        if nameRect.intersects(dirtyRect), groups.indices.contains(appIndex) {
            drawCenteredTruncatedText(
                groups[appIndex].appName, in: nameRect, fontSize: 13, color: .labelColor,
                horizontalInset: SwitcherLayout.horizontalMargin)
        }

        // --- Window-pane row.
        for (ordinal, flatIndex) in strip.visible.enumerated() {
            guard items.indices.contains(flatIndex) else { continue }
            let item = items[flatIndex]
            let paneRect = SwitcherLayout.paneRect(
                ordinal: ordinal, hasLeftChip: reservesChips, effectiveTile: tile, rowOffsetX: paneOffsetX)
            guard paneRect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) else { continue }

            let isCurrentPane = flatIndex == currentFlatIndex
            if isCurrentPane {
                drawStrongSelection(in: paneRect, cornerRadius: Self.paneSelectionCornerRadius)
                if focusRow == .app {
                    // The strong highlight above is on the app tile, not this
                    // pane — draw a lighter outline so "which window is
                    // current" survives even while the cursor is on the app row.
                    drawWeakOutline(in: paneRect, cornerRadius: Self.paneSelectionCornerRadius)
                }
            }

            drawAppGroupedPane(item, in: paneRect)

            let paneTitle = SwitcherLayout.paneTitleRect(
                ordinal: ordinal, hasLeftChip: reservesChips, effectiveTile: tile, rowOffsetX: paneOffsetX)
            let titleAlpha: CGFloat = isCurrentPane ? 1.0 : AppGroupedLayout.unselectedTitleAlpha
            drawCenteredTruncatedText(
                item.title, in: paneTitle, fontSize: 13,
                color: NSColor.labelColor.withAlphaComponent(titleAlpha),
                horizontalInset: Self.paneTitleHorizontalInset)

            drawBadge("\(modifierSymbol)\(ordinal + 1)", in: paneRect)
        }

        // --- `+n` chips.
        if let leftRect = SwitcherLayout.leftChipRect(
            hiddenLeft: strip.hiddenLeft, effectiveTile: tile, rowOffsetX: paneOffsetX)
        {
            drawChip("+\(strip.hiddenLeft)", in: leftRect)
        }
        if let rightRect = SwitcherLayout.rightChipRect(
            hiddenRight: strip.hiddenRight, visiblePaneCount: strip.visible.count,
            hasLeftChip: reservesChips, effectiveTile: tile, rowOffsetX: paneOffsetX)
        {
            drawChip("+\(strip.hiddenRight)", in: rightRect)
        }
    }

    /// Draw one pane's contents: a dark letterbox plate, then the cached
    /// capture (if any) fit to `item.bounds`'s real aspect ratio and clipped
    /// to the pane's rounded rect. No cached image yet (not captured, or
    /// preview disabled) simply leaves the plate showing — the same
    /// "placeholder before real content" strategy `drawPreview` uses for
    /// single-window mode, minus the dimmed-icon treatment (three small panes
    /// side by side read as busy with three faded icons layered in).
    private func drawAppGroupedPane(_ item: SwitcherItem, in paneRect: NSRect) {
        let plate = NSBezierPath(roundedRect: paneRect, xRadius: Self.paneCornerRadius, yRadius: Self.paneCornerRadius)
        NSColor.black.withAlphaComponent(AppGroupedLayout.letterboxPlateAlpha).setFill()
        plate.fill()

        guard let img = previewCache?.cachedImage(for: item.windowID) else { return }
        let fitRect = SwitcherLayout.letterboxRect(for: item.bounds, in: paneRect)
        // Saved/restored around the clip (rather than the `setClip()` single-shot
        // single-window drawPreview uses) because this runs once per pane in a
        // loop — an un-restored clip would keep shrinking and corrupt every
        // pane drawn after the first.
        NSGraphicsContext.saveGraphicsState()
        plate.setClip()
        img.draw(
            in: fitRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Direct-jump badge (e.g. "⌘2") in a pane's top-left corner.
    private func drawBadge(_ text: String, in paneRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Self.badgeFontSize, weight: .semibold),
            .foregroundColor: Self.badgeTextColor,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let badgeRect = NSRect(
            x: paneRect.minX + Self.badgeInset,
            y: paneRect.minY + Self.badgeInset,
            width: textSize.width + Self.badgeHorizontalPadding * 2,
            height: Self.badgeHeight
        )
        let background = NSBezierPath(
            roundedRect: badgeRect, xRadius: Self.badgeCornerRadius, yRadius: Self.badgeCornerRadius)
        NSColor.black.withAlphaComponent(Self.badgeBackgroundAlpha).setFill()
        background.fill()
        let textOrigin = NSPoint(
            x: badgeRect.minX + Self.badgeHorizontalPadding,
            y: badgeRect.minY + (badgeRect.height - textSize.height) / 2)
        (text as NSString).draw(at: textOrigin, withAttributes: attributes)
    }

    /// `+n` chip beside the pane row, summarizing panes folded off-screen.
    private func drawChip(_ text: String, in rect: NSRect) {
        let background = NSBezierPath(
            roundedRect: rect, xRadius: AppGroupedLayout.chipCornerRadius,
            yRadius: AppGroupedLayout.chipCornerRadius)
        NSColor.black.withAlphaComponent(Self.chipBackgroundAlpha).setFill()
        background.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Self.chipFontSize, weight: .medium),
            .foregroundColor: Self.chipTextColor,
            .paragraphStyle: paragraph,
        ]
        let textHeight = (text as NSString).size(withAttributes: attributes).height
        let textRect = NSRect(
            x: rect.minX, y: rect.minY + (rect.height - textHeight) / 2,
            width: rect.width, height: textHeight)
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    /// Draw the preview pane for the given item.
    /// Called only from draw(_:); assumes previewEnabled is already checked.
    private func drawPreview(in rect: NSRect, for item: SwitcherItem) {
        let clip = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        let borderColor = NSColor.white.withAlphaComponent(0.18)

        if let img = previewCache?.cachedImage(for: item.windowID) {
            // Aspect-fit the capture inside the preview rect (letterbox if needed).
            let fitRect = aspectFitRect(imageSize: img.size, inRect: rect)
            clip.setClip()
            img.draw(
                in: fitRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            // Faint glass-rim border drawn over the image.
            borderColor.setStroke()
            clip.lineWidth = 1
            clip.stroke()
        } else {
            // Placeholder: translucent filled box + dimmed app icon.
            // The box has the same geometry as the real preview, so no layout
            // reflow occurs when the real image arrives — minimises flicker.
            NSColor.white.withAlphaComponent(0.05).setFill()
            clip.fill()

            if let icon = item.icon {
                let iconEdge: CGFloat = 64
                let iconRect = NSRect(
                    x: rect.midX - iconEdge / 2,
                    y: rect.midY - iconEdge / 2,
                    width: iconEdge,
                    height: iconEdge
                )
                icon.draw(
                    in: iconRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 0.25,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high.rawValue]
                )
            }

            borderColor.setStroke()
            clip.lineWidth = 1
            clip.stroke()
        }
    }

    /// Returns the largest rect that fits `imageSize` aspect-fitted inside `container`,
    /// centered on both axes.
    private func aspectFitRect(imageSize: NSSize, inRect container: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let scale = min(
            container.width / imageSize.width,
            container.height / imageSize.height)
        let fitW = imageSize.width * scale
        let fitH = imageSize.height * scale
        return NSRect(
            x: container.midX - fitW / 2,
            y: container.midY - fitH / 2,
            width: fitW,
            height: fitH
        )
    }

    // MARK: - Preview callbacks

    /// Called by the panel when the cache delivers a new image.
    /// Invalidates only the affected rect so a full-view redraw is avoided.
    func previewDidArrive(for id: CGWindowID) {
        if isAppGrouped {
            guard
                let ordinal = strip.visible.firstIndex(where: {
                    items.indices.contains($0) && items[$0].windowID == id
                })
            else { return }
            setNeedsDisplay(appGroupedPaneRect(ordinal: ordinal))
            return
        }
        guard items.indices.contains(selectedIndex),
            items[selectedIndex].windowID == id
        else { return }
        setNeedsDisplay(previewRect)
    }

    // MARK: - Private helpers

    /// Horizontal offset to center the tile row within the current panel width.
    /// Returns 0 when preview is disabled (panel width equals the natural tile-row
    /// width, so no shift is needed).
    private var tileRowOffsetX: CGFloat {
        SwitcherLayout.tileRowOffsetX(
            itemCount: items.count,
            effectiveTile: effectiveTile,
            boundsWidth: bounds.width
        )
    }

    /// Preview rect in flipped (top-left origin) coordinates.
    private var previewRect: NSRect {
        SwitcherLayout.previewRect(
            inBoundsWidth: bounds.width,
            effectiveTile: effectiveTile,
            previewPaneWidth: previewPaneWidth,
            previewPaneHeight: previewPaneHeight)
    }

    /// Rect for the `ordinal`-th visible pane under the *current* app-grouped
    /// state (strip/effectiveTile/bounds). Shared by drawAppGrouped,
    /// previewDidArrive and opalRimTarget so none of them can derive a
    /// different answer for "where is this pane".
    private func appGroupedPaneRect(ordinal: Int) -> NSRect {
        let offsetX = SwitcherLayout.windowRowOffsetX(
            visiblePaneCount: strip.visible.count,
            hasLeftChip: reservesChipSlots, hasRightChip: reservesChipSlots,
            panelWidth: bounds.width)
        return SwitcherLayout.paneRect(
            ordinal: ordinal, hasLeftChip: reservesChipSlots, effectiveTile: effectiveTile,
            rowOffsetX: offsetX)
    }

    /// Whether the current group lays out both `+n` chip slots.
    ///
    /// Decided per group rather than from `strip.hiddenLeft/Right`, which
    /// change as the strip slides: keying the layout off those made every pane
    /// jump sideways the moment a chip appeared or vanished mid-scroll. A group
    /// that can never overflow reserves nothing, so short lists stay compact.
    private var reservesChipSlots: Bool {
        guard groups.indices.contains(appIndex) else { return false }
        return groups[appIndex].windowIndices.count > AppGroupedLayout.maxVisibleWindows
    }

    /// Kick off (or refresh) captures for the selected window and its neighbors.
    private func requestPreviews() {
        guard previewEnabled, items.indices.contains(selectedIndex) else { return }
        // Force-refresh the currently-visible window so it's always fresh.
        previewCache?.prefetch(items[selectedIndex].windowID, force: true)
        // Prefetch neighbors with force:false so cached images are reused.
        if selectedIndex > 0 {
            previewCache?.prefetch(items[selectedIndex - 1].windowID, force: false)
        }
        if selectedIndex < items.count - 1 {
            previewCache?.prefetch(items[selectedIndex + 1].windowID, force: false)
        }
    }

    /// Kick off (or refresh) captures for every pane currently visible in the
    /// strip. Unlike `requestPreviews`, there is no single "selected index" to
    /// force-refresh and neighbors to soft-prefetch — every visible pane is
    /// equally on screen, so the current window (the one the trigger key
    /// would activate) is force-refreshed and the rest are soft-prefetched.
    private func requestAppGroupedPreviews() {
        guard previewEnabled else { return }
        for flatIndex in strip.visible where items.indices.contains(flatIndex) {
            previewCache?.prefetch(items[flatIndex].windowID, force: flatIndex == currentFlatIndex)
        }
    }

    private var titleRect: NSRect {
        NSRect(
            x: 0,
            y: SwitcherLayout.topPadding + effectiveTile + SwitcherLayout.titleGap,
            width: bounds.width,
            height: SwitcherLayout.titleHeight
        )
    }

    private func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(index, count - 1))
    }
}
