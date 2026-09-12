// AppearancePreviewTests.swift
// Verifies: alpha constants haven't drifted, the two-tone selection rim keeps
// its light > dark ordering within valid alpha bounds, tint/selection colors
// carry the correct alpha, selection shares the accent hue, and
// backgroundBaseColor produces distinct light/dark values and respects
// Theme.system, and the opal rim's spectrum closes its loop and stays opaque.

import XCTest

@testable import ShakaPachi

@MainActor
final class AppearancePreviewTests: XCTestCase {

    // MARK: - Alpha constant drift guards

    func testBackgroundTintAlpha_isExact() {
        XCTAssertEqual(
            AccentColor.backgroundTintAlpha, 0.14,
            "backgroundTintAlpha must be 0.14 — changing it drifts the preview from the real panel")
    }

    func testSelectionHighlightAlpha_isExact() {
        XCTAssertEqual(
            AccentColor.selectionHighlightAlpha, 0.30,
            "selectionHighlightAlpha must be 0.30 — changing it drifts the preview from the real panel")
    }

    func testSelectionRimAlphas_areExact() {
        XCTAssertEqual(
            AccentColor.selectionRimLightAlpha, 0.55,
            "selectionRimLightAlpha must be 0.55 — changing it drifts the preview from the real panel")
        XCTAssertEqual(
            AccentColor.selectionRimDarkAlpha, 0.28,
            "selectionRimDarkAlpha must be 0.28 — changing it drifts the preview from the real panel")
    }

    func testSelectionRimAlphas_lightIsStrongerThanDark() {
        XCTAssertGreaterThan(
            AccentColor.selectionRimLightAlpha, AccentColor.selectionRimDarkAlpha,
            "The light rim is the tone that has to carry the selection on dark panels")
    }

    func testSelectionRimAlphas_areValidAlphas() {
        for alpha in [AccentColor.selectionRimLightAlpha, AccentColor.selectionRimDarkAlpha] {
            XCTAssertGreaterThan(alpha, 0, "A rim alpha of 0 would draw nothing")
            XCTAssertLessThanOrEqual(alpha, 1, "Alpha must stay within the 0...1 range")
        }
    }

    // MARK: - Opal rim constants

    func testOpalSpectrum_closesTheLoop() throws {
        let first = try XCTUnwrap(AccentColor.opalSpectrum.first?.usingColorSpace(.sRGB))
        let last = try XCTUnwrap(AccentColor.opalSpectrum.last?.usingColorSpace(.sRGB))
        let seam = "The conic sweep wraps, so the last stop must repeat the first or the seam shows"
        XCTAssertEqual(first.redComponent, last.redComponent, accuracy: 0.001, seam)
        XCTAssertEqual(first.greenComponent, last.greenComponent, accuracy: 0.001, seam)
        XCTAssertEqual(first.blueComponent, last.blueComponent, accuracy: 0.001, seam)
    }

    func testOpalSpectrum_stopsAreSRGBAndOpaque() throws {
        XCTAssertGreaterThan(
            AccentColor.opalSpectrum.count, 2,
            "A conic sweep needs more than one transition to read as iridescent")
        for stop in AccentColor.opalSpectrum {
            let srgb = try XCTUnwrap(
                stop.usingColorSpace(.sRGB), "Every opal stop must be sRGB-representable")
            XCTAssertEqual(
                srgb.alphaComponent, 1.0, accuracy: 0.001,
                "Opal stops stay opaque — the rim drops the two-tone hairline, so it cannot lean on the backdrop for contrast"
            )
        }
    }

    func testOpalRimRotationDuration_isPositive() {
        XCTAssertGreaterThan(
            AccentColor.opalRimRotationDuration, 0,
            "A non-positive period makes the rim's rotation animation degenerate")
    }

    // MARK: - tintColor alpha

    func testTintColor_alpha_matchesConstant() throws {
        // Use .blue — a static sRGB color that reads back reliably (unlike
        // .system which is a dynamic catalog color and doesn't expose alpha).
        let color = AppearancePreview.tintColor(accent: .blue)
        let srgb = try XCTUnwrap(
            color.usingColorSpace(.sRGB),
            "Failed to convert tintColor to sRGB")
        XCTAssertEqual(
            srgb.alphaComponent, AccentColor.backgroundTintAlpha, accuracy: 0.001,
            "tintColor alpha must equal backgroundTintAlpha")
    }

    // MARK: - selectionColor alpha

    func testSelectionColor_alpha_matchesConstant() throws {
        let color = AppearancePreview.selectionColor(accent: .blue)
        let srgb = try XCTUnwrap(
            color.usingColorSpace(.sRGB),
            "Failed to convert selectionColor to sRGB")
        XCTAssertEqual(
            srgb.alphaComponent, AccentColor.selectionHighlightAlpha, accuracy: 0.001,
            "selectionColor alpha must equal selectionHighlightAlpha")
    }

    // MARK: - selectionColor shares the accent hue

    func testSelectionColor_sharesAccentHue_blue() throws {
        // Both colors must be in sRGB before comparing components; otherwise
        // dynamic catalog colors return arbitrary component values.
        let selSRGB = try XCTUnwrap(
            AppearancePreview.selectionColor(accent: .blue).usingColorSpace(.sRGB),
            "selectionColor(.blue) not representable in sRGB")
        let accentSRGB = try XCTUnwrap(
            AccentColor.blue.nsColor.usingColorSpace(.sRGB),
            "AccentColor.blue.nsColor not representable in sRGB")

        // Premultiplied vs straight: selectionColor has alpha < 1; nsColor has alpha = 1.
        // Compare the RGB triplet (alpha-independent) to confirm they share the same hue.
        XCTAssertEqual(selSRGB.redComponent, accentSRGB.redComponent, accuracy: 0.001)
        XCTAssertEqual(selSRGB.greenComponent, accentSRGB.greenComponent, accuracy: 0.001)
        XCTAssertEqual(selSRGB.blueComponent, accentSRGB.blueComponent, accuracy: 0.001)
    }

    func testSelectionColor_sharesAccentHue_teal() throws {
        let selSRGB = try XCTUnwrap(
            AppearancePreview.selectionColor(accent: .teal).usingColorSpace(.sRGB),
            "selectionColor(.teal) not representable in sRGB")
        let accentSRGB = try XCTUnwrap(
            AccentColor.teal.nsColor.usingColorSpace(.sRGB),
            "AccentColor.teal.nsColor not representable in sRGB")

        XCTAssertEqual(selSRGB.redComponent, accentSRGB.redComponent, accuracy: 0.001)
        XCTAssertEqual(selSRGB.greenComponent, accentSRGB.greenComponent, accuracy: 0.001)
        XCTAssertEqual(selSRGB.blueComponent, accentSRGB.blueComponent, accuracy: 0.001)
    }

    // MARK: - backgroundBaseColor light vs dark

    func testBackgroundBaseColor_lightAndDarkDiffer() {
        let light = AppearancePreview.backgroundBaseColor(theme: .light, systemIsDark: false)
        let dark = AppearancePreview.backgroundBaseColor(theme: .dark, systemIsDark: false)
        // Light base should have a higher red component than the dark base.
        let lightSRGB = light.usingColorSpace(.sRGB)!
        let darkSRGB = dark.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(
            lightSRGB.redComponent, darkSRGB.redComponent,
            "Light base must be brighter than dark base")
    }

    func testBackgroundBaseColor_system_followsSystemIsDark() {
        let dark = AppearancePreview.backgroundBaseColor(theme: .dark, systemIsDark: false)
        let light = AppearancePreview.backgroundBaseColor(theme: .light, systemIsDark: false)

        let sysWhenDark = AppearancePreview.backgroundBaseColor(theme: .system, systemIsDark: true)
        let sysWhenLight = AppearancePreview.backgroundBaseColor(theme: .system, systemIsDark: false)

        // .system resolves to the dark value when systemIsDark is true.
        XCTAssertEqual(
            sysWhenDark.usingColorSpace(.sRGB)!.redComponent,
            dark.usingColorSpace(.sRGB)!.redComponent,
            accuracy: 0.001,
            "Theme.system + systemIsDark:true must equal the .dark base color")

        // .system resolves to the light value when systemIsDark is false.
        XCTAssertEqual(
            sysWhenLight.usingColorSpace(.sRGB)!.redComponent,
            light.usingColorSpace(.sRGB)!.redComponent,
            accuracy: 0.001,
            "Theme.system + systemIsDark:false must equal the .light base color")
    }
}
