// SwitcherPanel.swift
// NSPanel-based switcher UI.
//
// Lifetime rule: the panel is created ONCE at app startup and retained forever.
// show/hide use orderFrontRegardless / orderOut(nil). Never destroy or recreate
// the panel — doing so would cost hundreds of milliseconds and make N1 ≤ 50ms
// impossible.
//
// The panel is nonactivating: it must NEVER steal focus from the app the user
// is switching away from, because AppDelegate reads "the previously active
// window" after the panel appears.

import AppKit

final class SwitcherPanel {

    // MARK: - Stored panel (created once, never destroyed)

    private let panel: NSPanel
    private let effectView: NSVisualEffectView
    private let listView: SwitcherListView
    private let sheenLayer = CAGradientLayer()
    // Accent background tint: a CALayer behind the tiles at α≈0.08.
    // Inserted below sheenLayer so it sits behind all tile content.
    // Set once per show(); never participates in the selection-move partial redraw.
    private let tintLayer = CALayer()
    // Patina-only gloss layers (static, no animation). Hidden for every other
    // accent so non-patina panels render exactly as before.
    // patinaTintGradient replaces the flat tintLayer color with a vertical
    // polished-metal gradient (brighter top → deeper bottom). Sits just above
    // tintLayer, below sheenLayer.
    private let patinaTintGradient = CAGradientLayer()
    // patinaSpecular is a soft diagonal light streak in the upper-left, layered
    // above sheenLayer to read as a highlight catching the light.
    private let patinaSpecular = CAGradientLayer()

    // Window preview cache: owned here, injected into listView once in init().
    // Not cleared on hide() so cached images survive between panel sessions;
    // the selected window is force-refreshed on each show(), keeping it current.
    // Initialized in init() (not at the property declaration) because
    // WindowPreviewCache is @MainActor and stored-property initializers run in
    // a nonisolated context in Swift 6 strict concurrency.
    private let previewCache: WindowPreviewCache

    /// Liquid-glass corner radius (user request: pronounced rounding).
    private static let cornerRadius: CGFloat = 24

    // MARK: - Init

    @MainActor
    init() {
        // Panel configuration: nonactivating, borderless, floating.
        let initialBaseTile = SwitcherLayout.nominalTile(
            forIconSize: CGFloat(Settings.shared.switcherIconSize))
        let initialSize = SwitcherLayout.panelSize(itemCount: 1, baseTile: initialBaseTile)
        let initialRect = NSRect(origin: .zero, size: initialSize)

        let p = NSPanel(
            contentRect: initialRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        // NSVisualEffectView for liquid-glass styling.
        // .popover (not .hudWindow): the user chose the system-standard look
        // that follows the light/dark appearance over the always-dark HUD.
        let ev = NSVisualEffectView(frame: initialRect.insetBy(dx: 0, dy: 0))
        ev.material = .popover
        ev.blendingMode = .behindWindow
        ev.state = .active
        ev.wantsLayer = true
        // behindWindow blur is clipped by the window server, which ignores
        // layer.cornerRadius — the blur region itself must be shaped through
        // maskImage or the corners stay square.
        ev.maskImage = Self.roundedCornerMask(radius: Self.cornerRadius)
        ev.layer?.cornerRadius = Self.cornerRadius
        ev.layer?.masksToBounds = true
        // Glass rim: 1px light border reads as the edge of a liquid pane.
        ev.layer?.borderWidth = 1
        ev.layer?.borderColor = NSColor.white.withAlphaComponent(AccentColor.glassBorderAlpha).cgColor

        // Accent background tint: inserted first so it sits BELOW the sheen and
        // the listView. backgroundColor is set per-show from Settings.accentColor.
        let tint = tintLayer
        tint.cornerRadius = Self.cornerRadius
        tint.masksToBounds = true
        tint.frame = ev.bounds
        // backgroundColor is left nil here; show() sets it before orderFront.
        ev.layer?.addSublayer(tint)

        // Patina polished-metal tint gradient: sits directly above the flat
        // tintLayer, below the sheen. Colors/visibility are driven per-show;
        // hidden by default so non-patina accents keep the flat tint.
        let patinaTint = patinaTintGradient
        patinaTint.cornerRadius = Self.cornerRadius
        patinaTint.masksToBounds = true
        patinaTint.frame = ev.bounds
        patinaTint.isHidden = true
        ev.layer?.addSublayer(patinaTint)

        // Top sheen gradient for the liquid-glass feel.
        let sheen = sheenLayer
        sheen.colors = [
            NSColor.white.withAlphaComponent(0.14).cgColor,
            NSColor.white.withAlphaComponent(0.04).cgColor,
            NSColor.clear.cgColor,
        ]
        sheen.locations = [0.0, 0.4, 0.75]
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)  // layer coords: y=1 is the top
        sheen.endPoint = CGPoint(x: 0.5, y: 0.0)
        sheen.cornerRadius = Self.cornerRadius
        sheen.masksToBounds = true
        sheen.frame = ev.bounds
        ev.layer?.addSublayer(sheen)

        // Patina diagonal specular highlight: a soft light streak from the
        // top-left, layered above the sheen (but below listView). Static
        // colors/points; only visibility flips per-show. Hidden by default.
        let specular = patinaSpecular
        specular.colors = [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0.06).cgColor,
            NSColor.clear.cgColor,
        ]
        specular.locations = [0.0, 0.25, 0.5]
        specular.startPoint = CGPoint(x: 0.0, y: 1.0)  // top-left (layer coords: y=1 is the top)
        specular.endPoint = CGPoint(x: 1.0, y: 0.0)  // bottom-right
        specular.cornerRadius = Self.cornerRadius
        specular.masksToBounds = true
        specular.frame = ev.bounds
        specular.isHidden = true
        ev.layer?.addSublayer(specular)

        // SwitcherListView fills the effect view; padding is drawn internally.
        let lv = SwitcherListView(frame: ev.bounds)
        lv.translatesAutoresizingMaskIntoConstraints = false
        ev.addSubview(lv)

        NSLayoutConstraint.activate([
            lv.leadingAnchor.constraint(equalTo: ev.leadingAnchor),
            lv.trailingAnchor.constraint(equalTo: ev.trailingAnchor),
            lv.topAnchor.constraint(equalTo: ev.topAnchor),
            lv.bottomAnchor.constraint(equalTo: ev.bottomAnchor),
        ])

        p.contentView = ev

        let cache = WindowPreviewCache()

        self.panel = p
        self.effectView = ev
        self.listView = lv
        self.previewCache = cache

        // Wire the preview cache to the list view.
        // Weak reference from listView avoids a retain cycle (panel owns cache).
        lv.previewCache = cache
        cache.onImageReady = { [weak lv] id in
            lv?.previewDidArrive(for: id)
        }
    }

    /// Inset kept between the panel and each screen edge.
    private static let screenEdgeInset: CGFloat = 20

    // MARK: - Public API

    var isVisible: Bool { panel.isVisible }

    /// The currently highlighted row index, forwarded from the list view.
    var currentSelectedIndex: Int { listView.selectedIndex }

    /// Number of items in the currently shown snapshot.
    var itemCount: Int { listView.count }

    /// Per-show appearance work shared by both display modes: accent colour,
    /// the opal and patina treatments, the preview flag, and the preview pane
    /// size. Returns the pane size so the caller can pass it to the layout.
    @MainActor
    @discardableResult
    private func applyPerShowAppearance(previewEnabled: Bool) -> NSSize {
        // Read accent color once per show — runs once per trigger, not on the
        // hot selection-move path, so calling into Settings here is fine.
        let accent = Settings.shared.accentColor.resolvedColor(
            totalCount: StatsStore.shared.effectiveTotalCount)
        listView.accentColor = accent

        // Opal draws the selected tile's rim from a rotating conic gradient
        // layer inside the list view rather than the two-tone hairline. The
        // panel itself is untouched — the tint and rim below stay flat/white.
        listView.opalRimEnabled = Settings.shared.accentColor == .opal

        // Patina gets a static "gloss / lustre" treatment (gradient tint,
        // diagonal specular, warm rim) to feel special. Every other accent
        // keeps the flat tint + white rim exactly as before. Wrapped in a
        // CATransaction with actions disabled so the per-show color/visibility
        // swaps never animate.
        let isPatina = Settings.shared.accentColor == .patina
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isPatina {
            // Polished-metal vertical gradient replaces the flat tint.
            let topTint = (accent.blended(withFraction: 0.25, of: .white) ?? accent)
                .withAlphaComponent(0.20)
            let bottomTint = (accent.blended(withFraction: 0.10, of: .black) ?? accent)
                .withAlphaComponent(0.10)
            patinaTintGradient.colors = [topTint.cgColor, bottomTint.cgColor]
            patinaTintGradient.startPoint = CGPoint(x: 0.5, y: 1.0)  // top (layer coords: y=1 is the top)
            patinaTintGradient.endPoint = CGPoint(x: 0.5, y: 0.0)  // bottom
            patinaTintGradient.isHidden = false
            patinaSpecular.isHidden = false
            // Flat tint stands down so the gradient reads cleanly.
            tintLayer.backgroundColor = NSColor.clear.cgColor
            // Warm, brighter gold-white rim catches the light for patina.
            effectView.layer?.borderColor =
                NSColor(srgbRed: 1.0, green: 0.95, blue: 0.82, alpha: 1.0)
                .withAlphaComponent(0.30).cgColor
        } else {
            patinaTintGradient.isHidden = true
            patinaSpecular.isHidden = true
            // Restore today's exact flat tint + white rim behavior.
            tintLayer.backgroundColor =
                accent.withAlphaComponent(AccentColor.backgroundTintAlpha).cgColor
            effectView.layer?.borderColor =
                NSColor.white.withAlphaComponent(AccentColor.glassBorderAlpha).cgColor
        }
        CATransaction.commit()

        // Set previewEnabled BEFORE setItems so the first requestPreviews() call
        // inside setItems already sees the correct flag.
        listView.previewEnabled = previewEnabled

        // Compute preview pane size from settings and push it to the list view.
        let paneSize = SwitcherLayout.previewPaneSize(
            forWidth: CGFloat(Settings.shared.windowPreviewWidth))
        listView.previewPaneWidth = paneSize.width
        listView.previewPaneHeight = paneSize.height
        return paneSize
    }

    /// Show the panel with the given items, placing the initial selection at
    /// `selectedIndex`. Repositions to the screen containing the mouse cursor,
    /// shrinking the tiles when the natural width would overflow that screen.
    ///
    /// - Parameter previewEnabled: When true (and screen-recording permission is
    ///   granted by the caller), a live window preview is drawn below the title.
    ///   Defaults to false so existing call sites without the parameter still work.
    @MainActor
    func show(items: [SwitcherItem], selectedIndex: Int, previewEnabled: Bool = false) {
        let paneSize = applyPerShowAppearance(previewEnabled: previewEnabled)

        let screenFrame = targetScreenFrame()
        let availableWidth = screenFrame.width - Self.screenEdgeInset * 2
        let baseTile = SwitcherLayout.nominalTile(
            forIconSize: CGFloat(Settings.shared.switcherIconSize))
        listView.setItems(
            items, selectedIndex: selectedIndex, availableWidth: availableWidth, baseTile: baseTile)

        let effectiveTile = SwitcherLayout.effectiveTileSize(
            itemCount: items.count, availableWidth: availableWidth, baseTile: baseTile)
        repositionPanel(
            itemCount: items.count,
            effectiveTile: effectiveTile,
            screenFrame: screenFrame,
            previewEnabled: previewEnabled,
            previewPaneWidth: paneSize.width,
            previewPaneHeight: paneSize.height)
        panel.orderFrontRegardless()

        // Started only once the panel is on screen and removed again in hide(),
        // so the opal rim never animates while the panel is ordered out.
        listView.startOpalRimAnimation()
    }

    /// Move the highlight to a different row without reloading the table.
    func updateSelection(to newIndex: Int) {
        listView.moveSelection(to: newIndex)
    }

    /// Show — or re-render — the panel in app-unit mode.
    ///
    /// There is no `updateSelection` counterpart for this mode: the panel's own
    /// width changes whenever a `+n` chip appears or disappears, so there is no
    /// stable frame to move a highlight inside. Pass `orderFront: false` to
    /// re-render a panel that is already on screen.
    @MainActor
    func showAppGrouped(
        items: [SwitcherItem],
        groups: [AppGroup],
        appIndex: Int,
        strip: WindowStrip,
        currentFlatIndex: Int,
        focusRow: SwitcherFocusRow,
        previewEnabled: Bool,
        orderFront: Bool
    ) {
        applyPerShowAppearance(previewEnabled: previewEnabled)

        let screenFrame = targetScreenFrame()
        let availableWidth = screenFrame.width - Self.screenEdgeInset * 2
        let baseTile = SwitcherLayout.nominalTile(
            forIconSize: CGFloat(Settings.shared.switcherIconSize))

        listView.setAppGrouped(
            items: items,
            groups: groups,
            appIndex: appIndex,
            strip: strip,
            currentFlatIndex: currentFlatIndex,
            focusRow: focusRow,
            modifierSymbol: Settings.shared.triggerModifier.symbol,
            availableWidth: availableWidth,
            baseTile: baseTile)

        let effectiveTile = SwitcherLayout.effectiveTileSize(
            itemCount: groups.count, availableWidth: availableWidth, baseTile: baseTile)
        // Size from the WIDEST app in this snapshot, not the selected one.
        // Sizing per selection made the panel grow and shrink on every step
        // between apps, which is exactly the moment the user is trying to track
        // a tile in the row above it. Paying some empty width on narrow apps
        // buys a panel that never moves for a whole switcher session.
        let widestPaneCount = min(
            AppGroupedLayout.maxVisibleWindows,
            groups.map(\.windowIndices.count).max() ?? 1)
        let anyGroupOverflows = groups.contains {
            $0.windowIndices.count > AppGroupedLayout.maxVisibleWindows
        }
        let size = SwitcherLayout.appGroupedPanelSize(
            groupCount: groups.count,
            visiblePaneCount: widestPaneCount,
            hasLeftChip: anyGroupOverflows,
            hasRightChip: anyGroupOverflows,
            effectiveTile: effectiveTile)
        setPanelFrame(size: size, screenFrame: screenFrame)

        if orderFront {
            panel.orderFrontRegardless()
            listView.startOpalRimAnimation()
        }
    }

    /// Hide the panel without destroying it (the panel is reused across sessions).
    func hide() {
        panel.orderOut(nil)
        listView.stopOpalRimAnimation()
    }

    /// Force a display pass so the N1/N2 end-timestamp is taken after the
    /// draw has actually happened, not just after the order call.
    func displayIfNeeded() {
        panel.contentView?.displayIfNeeded()
    }

    // MARK: - Layout

    /// The visibleFrame of the screen containing the mouse cursor,
    /// falling back to the main screen and finally a sane default.
    private func targetScreenFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func repositionPanel(
        itemCount: Int,
        effectiveTile: CGFloat,
        screenFrame: NSRect,
        previewEnabled: Bool = false,
        previewPaneWidth: CGFloat = SwitcherLayout.previewWidth,
        previewPaneHeight: CGFloat = SwitcherLayout.previewHeight
    ) {
        let size = SwitcherLayout.panelSize(
            itemCount: itemCount,
            effectiveTile: effectiveTile,
            previewEnabled: previewEnabled,
            previewPaneWidth: previewPaneWidth,
            previewPaneHeight: previewPaneHeight)
        setPanelFrame(size: size, screenFrame: screenFrame)
    }

    /// Centre the panel on `screenFrame` at `size`, capping the width to the
    /// screen and resizing the effect view's layers without implicit animation.
    private func setPanelFrame(size: NSSize, screenFrame: NSRect) {
        // Tiles are shrunk to fit; if the count is so large they hit the 40pt
        // floor, the panel is still capped to the screen and the overflow
        // clips at the panel edge (acceptable, rare edge case).
        let width = min(size.width, screenFrame.width - Self.screenEdgeInset * 2)
        let height = size.height
        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2

        let newFrame = NSRect(x: x, y: y, width: width, height: height)
        panel.setFrame(newFrame, display: false)

        // Resize the effect view and its layers without implicit animations.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectView.frame = NSRect(origin: .zero, size: newFrame.size)
        tintLayer.frame = effectView.bounds
        patinaTintGradient.frame = effectView.bounds
        sheenLayer.frame = effectView.bounds
        patinaSpecular.frame = effectView.bounds
        CATransaction.commit()
    }

    // MARK: - Liquid-glass helpers

    /// Resizable rounded-rect mask that shapes the behind-window blur region.
    private static func roundedCornerMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: radius, left: radius,
            bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
