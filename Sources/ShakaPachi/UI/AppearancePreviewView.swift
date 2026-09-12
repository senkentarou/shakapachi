// AppearancePreviewView.swift
// A live preview of the switcher panel colors shown in the Appearance (外観) settings tab.
//
// Design: the preview must faithfully reproduce the real panel's colors so the
// user sees exactly what they'll get. Color logic lives in a pure, testable
// enum (AppearancePreview) with no SwiftUI dependency; the view composes it.

import AppKit
import SwiftUI

// MARK: - Pure color helper (testable without SwiftUI)

/// Computes the preview colors that approximate the real switcher panel.
/// All methods are pure functions — no side effects, no SwiftUI, no @MainActor.
enum AppearancePreview {

    /// Opaque base color approximating the switcher panel's popover material
    /// for the given theme. `systemIsDark` is used only for Theme.system.
    ///
    /// These are opaque approximations of the translucent NSVisualEffectView
    /// .popover material — the actual material blends with whatever is behind
    /// the panel, so we pick representative sRGB values for a neutral desktop.
    static func backgroundBaseColor(theme: Theme, systemIsDark: Bool) -> NSColor {
        let isDark: Bool
        switch theme {
        case .light: isDark = false
        case .dark: isDark = true
        case .system: isDark = systemIsDark
        }
        if isDark {
            // Near-black — representative dark popover on a dark desktop.
            return NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
        } else {
            // Near-white — representative light popover on a light desktop.
            return NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        }
    }

    /// The accent tint drawn over the panel base (accent at backgroundTintAlpha).
    static func tintColor(accent: AccentColor, totalCount: Int = 0) -> NSColor {
        accent.resolvedColor(totalCount: totalCount).withAlphaComponent(AccentColor.backgroundTintAlpha)
    }

    /// The selected-tile highlight color (accent at selectionHighlightAlpha).
    static func selectionColor(accent: AccentColor, totalCount: Int = 0) -> NSColor {
        accent.resolvedColor(totalCount: totalCount).withAlphaComponent(AccentColor.selectionHighlightAlpha)
    }
}

// MARK: - SwiftUI preview view

/// A mini mock of the switcher panel showing the chosen theme + accent color.
/// Passed as arguments rather than reading Settings directly so the struct
/// stays a pure, reusable view (the parent decides when to re-render).
struct AppearancePreviewView: View {

    let theme: Theme
    let accent: AccentColor
    /// The switcher icon size in points (60 = default). Tiles scale proportionally.
    var iconSize: Int = 60
    /// The window preview pane width in points (320 = default). Mock scales proportionally.
    var windowPreviewWidth: Int = 320
    /// Whether to show a window preview placeholder below the title.
    var showWindowPreview: Bool = true
    /// Lifetime switch count, used only to resolve the evolving `.patina` accent.
    var totalCount: Int = 0

    // Used to resolve Theme.system to light or dark base color.
    @Environment(\.colorScheme) private var colorScheme

    /// Drives the `.opal` rim rotation, one full turn per
    /// `AccentColor.opalRimRotationDuration` — the same period as the real panel.
    @State private var opalAngle: Double = 0

    var body: some View {
        if accent == .patina {
            patinaPreview
        } else if accent == .opal {
            opalPreview
        } else {
            standardPreview
        }
    }

    private var standardPreview: some View { panelPreview(opalRim: false) }

    /// Opal preview: the standard panel mock with the selected tile's rim
    /// replaced by the rotating iridescent ring, so the settings screen shows
    /// the motion the real panel has rather than a still frame of it.
    private var opalPreview: some View {
        panelPreview(opalRim: true)
            .onAppear {
                // Reset first: on a second appearance the angle is already at
                // 360, and animating a value to itself starts nothing.
                opalAngle = 0
                withAnimation(
                    .linear(duration: AccentColor.opalRimRotationDuration)
                        .repeatForever(autoreverses: false)
                ) {
                    opalAngle = 360
                }
            }
    }

    /// The panel mock shared by every non-patina accent. `opalRim` swaps the
    /// selected tile's two-tone hairline for the `.opal` accent's rotating
    /// iridescent ring; everything else renders identically for all accents.
    private func panelPreview(opalRim: Bool) -> some View {
        let systemIsDark = colorScheme == .dark
        let base = AppearancePreview.backgroundBaseColor(theme: theme, systemIsDark: systemIsDark)
        let tint = AppearancePreview.tintColor(accent: accent, totalCount: totalCount)
        let selection = AppearancePreview.selectionColor(accent: accent, totalCount: totalCount)
        let scale = CGFloat(iconSize) / 60

        // Resolve the preview's own color scheme from the chosen theme so the
        // foreground semantic colors (.secondary icon/title) flip to match the
        // mock panel's base — otherwise picking a theme opposite to the current
        // system appearance (e.g. Dark while the OS is Light) would render
        // low-contrast chrome on top of the flipped base color.
        let resolvedScheme: ColorScheme = {
            switch theme {
            case .light: return .light
            case .dark: return .dark
            case .system: return colorScheme
            }
        }()

        return ZStack {
            // Panel background: base color overlaid with the accent tint, matching
            // how SwitcherPanel composites tintLayer over the NSVisualEffectView.
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: base))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: tint))
                )
                // Glass rim — 1px light border reads as the edge of a liquid pane,
                // matching the real panel's ev.layer?.borderColor.
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(AccentColor.glassBorderAlpha), lineWidth: 1)
                )

            // Content: icon row + title line + optional preview pane
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        TileView(
                            isSelected: index == 1, selectionColor: selection, scale: scale,
                            opalRim: opalRim, opalAngle: opalAngle)
                    }
                }
                Text("ウィンドウ名")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if showWindowPreview {
                    // Scaled placeholder representing the window screenshot pane.
                    // Base size is 120×75 (16:10) at the 320-point default;
                    // scales linearly with the configured preview width.
                    let previewScale = CGFloat(windowPreviewWidth) / 320
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 120 * previewScale, height: 75 * previewScale)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
        }
        .frame(minHeight: 120)
        .environment(\.colorScheme, resolvedScheme)
    }

    /// Patina preview: keeps the switcher panel mock (tiles) but splits the
    /// accent tint into six vertical bands — one per milestone — so the whole
    /// dull-bronze → gold evolution is shown across the real preview. Each band
    /// is annotated with the switch count that reaches that stage, and the stage
    /// the user has currently reached is marked. Bands use the real panel tint
    /// alpha (subtle by design); the full-strength chip shows the true colour.
    private var patinaPreview: some View {
        let systemIsDark = colorScheme == .dark
        let base = AppearancePreview.backgroundBaseColor(theme: theme, systemIsDark: systemIsDark)
        let scale = CGFloat(iconSize) / 60
        let resolvedScheme: ColorScheme = {
            switch theme {
            case .light: return .light
            case .dark: return .dark
            case .system: return colorScheme
            }
        }()

        // Milestones the patina accent steps through, labelled by switch count.
        let stages: [(label: String, lower: Int)] = [
            ("0回", 0),
            ("5,000回", 5_000),
            ("10,000回", 10_000),
            ("20,000回", 20_000),
            ("50,000回", 50_000),
            ("100,000回", 100_000),
        ]
        // The selection tile reflects the user's actual current stage.
        let selection = AccentColor.patinaColor(forTotalCount: totalCount)
            .withAlphaComponent(AccentColor.selectionHighlightAlpha)

        return ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: base))
                // Tint split into six vertical bands at the real panel alpha, so
                // this reads as the actual panel aged across each milestone.
                .overlay(
                    HStack(spacing: 0) {
                        ForEach(0..<stages.count, id: \.self) { i in
                            Color(nsColor: AccentColor.patinaColor(forTotalCount: stages[i].lower))
                                .opacity(Double(AccentColor.backgroundTintAlpha))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(AccentColor.glassBorderAlpha), lineWidth: 1)
                )

            VStack(spacing: 6) {
                Text("切替回数で色が育つ")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                // Switch-count labels aligned to the six tint bands.
                HStack(spacing: 0) {
                    ForEach(0..<stages.count, id: \.self) { i in
                        Text(stages[i].label)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                // Real switcher content so this still reads as a preview.
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        TileView(isSelected: index == 1, selectionColor: selection, scale: scale)
                    }
                }
                Text("ウィンドウ名")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if showWindowPreview {
                    // Same window-screenshot placeholder as the standard preview,
                    // so toggling the option affects both accents identically.
                    let previewScale = CGFloat(windowPreviewWidth) / 320
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 120 * previewScale, height: 75 * previewScale)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        }
        .frame(minHeight: 140)
        .environment(\.colorScheme, resolvedScheme)
    }
}

// MARK: - Tile subview

/// A single icon tile in the preview row.
private struct TileView: View {

    let isSelected: Bool
    let selectionColor: NSColor
    /// Scale factor derived from the user's icon-size setting (1.0 = 60pt default).
    var scale: CGFloat = 1.0
    /// When true the rim is the `.opal` accent's rotating iridescent ring
    /// instead of the two-tone hairline every other accent uses.
    var opalRim: Bool = false
    /// Current rotation of the opal rim in degrees, driven by the parent so the
    /// preview keeps a single clock.
    var opalAngle: Double = 0

    var body: some View {
        let tileEdge = 44 * scale
        let cornerRadius = 10 * scale
        ZStack {
            if isSelected {
                // Highlight fill matching SwitcherListView's selection draw path.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(nsColor: selectionColor))
                if opalRim {
                    // SwiftUI counterpart of SwitcherListView's masked conic
                    // layer: the gradient rotates, the ring it is masked to does
                    // not. Oversized before the rotation so a corner of the
                    // gradient can never turn into the ring, then framed back to
                    // the tile so the mask lines up.
                    AngularGradient(
                        colors: AccentColor.opalSpectrum.map { Color(nsColor: $0) },
                        center: .center
                    )
                    .frame(width: tileEdge * 1.5, height: tileEdge * 1.5)
                    .rotationEffect(.degrees(opalAngle))
                    .frame(width: tileEdge, height: tileEdge)
                    .mask(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.black, lineWidth: 1)
                    )
                } else {
                    // Two-tone hairline rim, same alphas and stacking order as the
                    // real panel: dark line on the tile edge, light line just inside.
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.black.opacity(AccentColor.selectionRimDarkAlpha), lineWidth: 1)
                    RoundedRectangle(cornerRadius: cornerRadius - 1)
                        .strokeBorder(Color.white.opacity(AccentColor.selectionRimLightAlpha), lineWidth: 1)
                        .padding(1)
                }
            }
            // Placeholder icon — uses a semantic color so it stays legible on
            // both light and dark base colors without forcing a colorScheme override.
            Image(systemName: "macwindow")
                .font(.system(size: 22 * scale))
                .foregroundColor(.secondary)
        }
        .frame(width: tileEdge, height: tileEdge)
    }
}
