// TrayIconRenderer.swift
// Shared rendering + copy for the four menu-bar icon states ("cards").
// Used by StatusItemController (the live menu-bar icon) and the Settings
// "Status" (「状態」) tab (preview + explanation), so the glyph geometry and the state
// colours are defined in exactly one place.

import AppKit

/// The four menu-bar icon states, framed as coloured "cards" for the user.
/// Live-icon precedence is permission > restricted > settings > normal
/// (see StatusItemController.refreshStatus); the case order here is the
/// explanation order shown to the user (normal → blue → yellow → red).
enum TrayIconState: CaseIterable {
    case normal  // normal card
    case settings  // blue card
    case permission  // yellow card
    case restricted  // red card

    /// User-facing card name.
    var cardName: String {
        switch self {
        case .normal: return NSLocalizedString("ノーマルカード", comment: "Card name: normal")
        case .settings: return NSLocalizedString("ブルーカード", comment: "Card name: blue (settings open)")
        case .permission: return NSLocalizedString("イエローカード", comment: "Card name: yellow (permission missing)")
        case .restricted: return NSLocalizedString("レッドカード", comment: "Card name: red (tap stopped)")
        }
    }

    /// One-line explanation shown under the card name.
    var detail: String {
        switch self {
        case .normal:
            return NSLocalizedString("機能が有効な状態です。", comment: "Card detail: feature is active")
        case .settings:
            return NSLocalizedString(
                "設定画面を開いている状態です。開いている間はウィンドウの移動ができないことがあるため、機能を有効にするには一度設定を閉じてください。",
                comment: "Card detail: settings window is open")
        case .permission:
            return NSLocalizedString(
                "利用に必要な権限が足りない状態です。mac の設定から権限を追加してください。", comment: "Card detail: permissions missing")
        case .restricted:
            return NSLocalizedString(
                "ShakaPachi の利用を一時的に制限している状態です。mac 標準のアプリ切り替え機能にフォールバックします。メニューバーの「ウィンドウ切替を有効化」から再開できます。",
                comment: "Card detail: tap is paused")
        }
    }

    /// Colour applied to the *filled* front window. Only the fill is tinted;
    /// the outline stays neutral (requirement: tint only the filled area, not the outline). Normal uses the
    /// adaptive label colour so the glyph matches the menu bar as before.
    var fillColor: NSColor {
        switch self {
        case .normal: return .labelColor
        case .settings: return NSColor(srgbRed: 0.52, green: 0.68, blue: 0.92, alpha: 1.0)  // soft blue
        case .permission: return NSColor(srgbRed: 0.95, green: 0.81, blue: 0.45, alpha: 1.0)  // soft amber
        case .restricted: return NSColor(srgbRed: 0.92, green: 0.53, blue: 0.51, alpha: 1.0)  // soft coral
        }
    }

    /// Colour of the dot beside the menu heading. Coloured states reuse the icon
    /// fill so the dot and the menu-bar icon always read as the same state; normal
    /// uses a fixed soft green instead of `fillColor`'s `.labelColor`, signalling
    /// "actively running" in the same soft-toned style as the other states.
    var headingDotColor: NSColor {
        switch self {
        case .normal: return NSColor(srgbRed: 0.45, green: 0.78, blue: 0.55, alpha: 1.0)  // soft green
        default: return fillColor
        }
    }
}

enum TrayIconRenderer {

    /// Menu-bar icon (18×18). Normal is a template image so it adapts to the
    /// menu-bar appearance exactly as before. Coloured states are non-template:
    /// only the front-window fill carries the state colour; the outline is the
    /// adaptive label colour.
    static func menuBarImage(for state: TrayIconState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        if state == .normal {
            let image = NSImage(size: size, flipped: false) { bounds in
                drawGlyph(in: bounds, outline: .black, fill: .black)
                return true
            }
            image.isTemplate = true
            return image
        }
        let fill = state.fillColor
        let image = NSImage(size: size, flipped: false) { bounds in
            drawGlyph(in: bounds, outline: .labelColor, fill: fill)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Larger preview used in the Settings "Status" (「状態」) tab. Always non-template and
    /// concrete. Coloured states fill the front window with the state colour and
    /// outline in the adaptive label colour. Normal has no state colour, so its
    /// front window is filled with a solid appearance-adaptive foreground (white
    /// in dark mode, black in light) — resolving `.labelColor` inside an
    /// offscreen image yields an unfilled-looking glyph, so we pick the concrete
    /// colour explicitly to match the live template icon.
    static func previewImage(for state: TrayIconState, size: CGFloat) -> NSImage {
        let px = NSSize(width: size, height: size)
        let image = NSImage(size: px, flipped: false) { bounds in
            if state == .normal {
                let fg = adaptiveForeground()
                drawGlyph(in: bounds, outline: fg, fill: fg)
            } else {
                drawGlyph(in: bounds, outline: .labelColor, fill: state.fillColor)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Solid foreground colour matching the current appearance (white in dark
    /// mode, black in light), used for the normal preview so its filled front
    /// window is opaque rather than a see-through outline.
    static func adaptiveForeground() -> NSColor {
        // NSApplication.shared (not NSApp, which is nil in unit tests) so the
        // appearance query is safe headless as well as in the live app.
        let appearance = NSApplication.shared.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? .white : .black
    }

    /// Draws the ShakaPachi glyph — two overlapping windows — with the back
    /// window as an outline (`outline`) and the front window as a solid fill
    /// (`fill`) with a matching-`outline` border. Splitting outline vs fill lets
    /// callers tint only the filled area. Geometry mirrors the app icon
    /// (back lower-left, front upper-right).
    static func drawGlyph(in bounds: NSRect, outline: NSColor, fill: NSColor) {
        let s = bounds.width / 16.0
        let w = 9.5 * s
        let r = 1.65 * s
        let line = 1.3 * s

        // Back window frame (outline) — lower-left.
        outline.setStroke()
        let backRect = NSRect(x: bounds.minX + 1.25 * s, y: bounds.minY + 1.25 * s, width: w, height: w)
        let back = NSBezierPath(roundedRect: backRect, xRadius: r, yRadius: r)
        back.lineWidth = line
        back.stroke()

        // Front window — upper-right: state-coloured fill, neutral outline border
        // so only the filled area carries the colour.
        let frontRect = NSRect(x: bounds.minX + 5.25 * s, y: bounds.minY + 5.25 * s, width: w, height: w)
        let front = NSBezierPath(roundedRect: frontRect, xRadius: r, yRadius: r)
        fill.setFill()
        front.fill()
        outline.setStroke()
        front.lineWidth = line
        front.stroke()
    }
}
