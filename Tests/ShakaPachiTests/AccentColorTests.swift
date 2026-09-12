// AccentColorTests.swift
// Verifies: default accent is .pearl, every case has a non-empty displayName,
// all cases have sRGB-representable NSColor values, rawValue round-trips work
// for all cases, and the Settings.accentColor property persists correctly.

import XCTest

@testable import ShakaPachi

@MainActor
final class AccentColorTests: XCTestCase {

    // MARK: - Helpers

    private func makeSuite(name: String = #function) -> (UserDefaults, Settings) {
        let suiteName = "com.shakapachi.tests.AccentColorTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, settings)
    }

    // MARK: - .pearl nsColor value

    func testPearl_nsColor_value() {
        let srgb = AccentColor.pearl.nsColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(srgb.redComponent, 0.74, accuracy: 0.001)
        XCTAssertEqual(srgb.greenComponent, 0.77, accuracy: 0.001)
        XCTAssertEqual(srgb.blueComponent, 0.82, accuracy: 0.001)
    }

    // MARK: - Every case has a non-empty displayName

    func testAllCases_displayNameNonEmpty() {
        for color in AccentColor.allCases {
            XCTAssertFalse(
                color.displayName.isEmpty,
                "displayName for .\(color) must not be empty"
            )
        }
    }

    // MARK: - rawValue round-trips for all cases

    func testRawValueRoundTrip_allCases() {
        for color in AccentColor.allCases {
            let raw = color.rawValue
            let recovered = AccentColor(rawValue: raw)
            XCTAssertEqual(
                recovered, color,
                "AccentColor(rawValue: \"\(raw)\") should round-trip to .\(color)"
            )
        }
    }

    // MARK: - Settings.accentColor defaults to .pearl

    func testDefault_accentColor_isPearl() {
        let (_, settings) = makeSuite()
        XCTAssertEqual(
            settings.accentColor, .pearl,
            "Default accentColor must be .pearl"
        )
    }

    // MARK: - Settings.accentColor persists a set value

    func testPersistence_accentColor_roundTrips() {
        let (_, settings) = makeSuite()
        for color in AccentColor.allCases {
            settings.accentColor = color
            XCTAssertEqual(
                settings.accentColor, color,
                "accentColor must persist .\(color) and read it back"
            )
        }
    }

    func testPatina_stageBoundaries() {
        func red(_ count: Int) -> CGFloat {
            AccentColor.patinaColor(forTotalCount: count).usingColorSpace(.sRGB)!.redComponent
        }
        XCTAssertEqual(red(0), 0.549, accuracy: 0.001)
        XCTAssertEqual(red(4_999), 0.549, accuracy: 0.001)
        XCTAssertEqual(red(5_000), 0.608, accuracy: 0.001)
        XCTAssertEqual(red(9_999), 0.608, accuracy: 0.001)
        XCTAssertEqual(red(10_000), 0.667, accuracy: 0.001)
        XCTAssertEqual(red(19_999), 0.667, accuracy: 0.001)
        XCTAssertEqual(red(20_000), 0.784, accuracy: 0.001)
        XCTAssertEqual(red(49_999), 0.784, accuracy: 0.001)
        XCTAssertEqual(red(50_000), 0.878, accuracy: 0.001)
        XCTAssertEqual(red(99_999), 0.878, accuracy: 0.001)
        XCTAssertEqual(red(100_000), 0.933, accuracy: 0.001)
        XCTAssertEqual(red(50_000_000), 0.933, accuracy: 0.001)
    }

    func testResolvedColor_staticIgnoresCount() {
        XCTAssertEqual(
            AccentColor.blue.resolvedColor(totalCount: 999_999).usingColorSpace(.sRGB),
            AccentColor.blue.nsColor.usingColorSpace(.sRGB),
            "static accent must ignore totalCount")
    }

    func testResolvedColor_patinaMatchesStage() {
        XCTAssertEqual(
            AccentColor.patina.resolvedColor(totalCount: 12_345).usingColorSpace(.sRGB),
            AccentColor.patinaColor(forTotalCount: 12_345).usingColorSpace(.sRGB))
    }

    func testEvolvesWithUsage() {
        XCTAssertTrue(AccentColor.patina.evolvesWithUsage)
        for c in AccentColor.allCases where c != .patina {
            XCTAssertFalse(c.evolvesWithUsage, "\(c) must be static")
        }
    }
}
