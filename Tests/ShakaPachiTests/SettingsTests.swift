// SettingsTests.swift
// Verifies: default values when unset, enum round-trips, [String] round-trip,
// and modifier→mask / key→keyCode mappings.
//
// Each test creates its own UserDefaults suite so tests are isolated from each
// other and from UserDefaults.standard.

import XCTest

@testable import ShakaPachi

@MainActor
final class SettingsTests: XCTestCase {

    // MARK: - Helpers

    /// Returns a fresh, empty UserDefaults suite and a Settings instance backed by it.
    /// The suite is removed after the test via addTeardownBlock so test state is isolated.
    private func makeSuite(name: String = #function) -> (UserDefaults, Settings) {
        let suiteName = "com.shakapachi.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, settings)
    }

    // MARK: - Default values

    func testDefault_triggerModifier_isCommand() {
        let (_, settings) = makeSuite()
        XCTAssertEqual(
            settings.triggerModifier, .command,
            "Default triggerModifier is .command — the shipping default")
    }

    func testDefault_triggerKey_isTab() {
        let (_, settings) = makeSuite()
        XCTAssertEqual(settings.triggerKey, .tab)
    }

    func testDefault_maxRows_is20() {
        let (_, settings) = makeSuite()
        XCTAssertEqual(settings.maxRows, 20)
    }

    func testDefault_showDelayMs_is0() {
        let (_, settings) = makeSuite()
        XCTAssertEqual(settings.showDelayMs, 0)
    }

    func testDefault_currentSpaceOnly_isTrue() {
        let (_, settings) = makeSuite()
        XCTAssertTrue(settings.currentSpaceOnly)
    }

    func testDefault_sortMode_isMRU() {
        let (_, settings) = makeSuite()
        XCTAssertEqual(settings.sortMode, .mru)
    }

    func testDefault_switcherDisplayMode_isWindow() {
        let (_, settings) = makeSuite()
        XCTAssertEqual(
            settings.switcherDisplayMode, .window,
            "Default switcherDisplayMode is .window — preserves existing users' behavior")
    }

    func testDefault_excludedBundleIDs_isEmpty() {
        let (_, settings) = makeSuite()
        XCTAssertTrue(settings.excludedBundleIDs.isEmpty)
    }

    func testDefault_theme_isSystem() {
        let (_, settings) = makeSuite()
        XCTAssertEqual(settings.theme, .system)
    }

    func testDefault_launchAtLogin_isTrue() {
        let (_, settings) = makeSuite()
        XCTAssertTrue(settings.launchAtLogin)
    }

    func testDefault_panelWidth_is480() {
        let (_, settings) = makeSuite()
        XCTAssertEqual(settings.panelWidth, 480)
    }

    func testDefault_hoverRaiseEnabled_isFalse() {
        let (_, settings) = makeSuite()
        XCTAssertFalse(
            settings.hoverRaiseEnabled,
            "Hover raise changes what the pointer does system-wide, so it is opt-in")
    }

    func testRoundTrip_hoverRaiseEnabled() {
        let (defaults, settings) = makeSuite()
        settings.hoverRaiseEnabled = true
        XCTAssertTrue(settings.hoverRaiseEnabled)
        XCTAssertTrue(defaults.bool(forKey: "hoverRaiseEnabled"))
    }

    // MARK: - TriggerModifier round-trip

    func testRoundTrip_triggerModifier_command() {
        let (_, settings) = makeSuite()
        settings.triggerModifier = .command
        XCTAssertEqual(settings.triggerModifier, .command)
    }

    func testRoundTrip_triggerModifier_option() {
        let (_, settings) = makeSuite()
        settings.triggerModifier = .option
        XCTAssertEqual(settings.triggerModifier, .option)
    }

    func testRoundTrip_triggerModifier_control() {
        let (_, settings) = makeSuite()
        settings.triggerModifier = .control
        XCTAssertEqual(settings.triggerModifier, .control)
    }

    func testRoundTrip_triggerModifier_persists_as_rawValue() {
        let (defaults, settings) = makeSuite()
        settings.triggerModifier = .command
        // Verify the raw value stored is "command", not some other encoding.
        XCTAssertEqual(defaults.string(forKey: "triggerModifier"), "command")
    }

    // MARK: - TriggerKey round-trip

    func testRoundTrip_triggerKey_tab() {
        let (_, settings) = makeSuite()
        settings.triggerKey = .tab
        XCTAssertEqual(settings.triggerKey, .tab)
    }

    func testRoundTrip_triggerKey_grave() {
        let (_, settings) = makeSuite()
        settings.triggerKey = .grave
        XCTAssertEqual(settings.triggerKey, .grave)
    }

    func testRoundTrip_triggerKey_persists_as_rawValue() {
        let (defaults, settings) = makeSuite()
        settings.triggerKey = .grave
        XCTAssertEqual(defaults.string(forKey: "triggerKey"), "grave")
    }

    // MARK: - SortMode round-trip

    func testRoundTrip_sortMode_mru() {
        let (_, settings) = makeSuite()
        settings.sortMode = .mru
        XCTAssertEqual(settings.sortMode, .mru)
    }

    func testRoundTrip_sortMode_byApp() {
        let (_, settings) = makeSuite()
        settings.sortMode = .byApp
        XCTAssertEqual(settings.sortMode, .byApp)
    }

    func testRoundTrip_sortMode_byAppMRU() {
        let (_, settings) = makeSuite()
        settings.sortMode = .byAppMRU
        XCTAssertEqual(settings.sortMode, .byAppMRU)
    }

    func testFallback_sortMode_unknownRawValueDefaultsToMRU() {
        // Verifies DefaultsEnum falls back to .mru when the stored string is
        // unrecognized — e.g. a user who had "zOrder" persisted before removal.
        let (defaults, settings) = makeSuite()
        defaults.set("zOrder", forKey: "sortMode")
        XCTAssertEqual(
            settings.sortMode, .mru,
            "Unrecognized raw value must fall back to the default (.mru)")
    }

    // MARK: - SwitcherDisplayMode round-trip

    func testRoundTrip_switcherDisplayMode_window() {
        let (_, settings) = makeSuite()
        settings.switcherDisplayMode = .window
        XCTAssertEqual(settings.switcherDisplayMode, .window)
    }

    func testRoundTrip_switcherDisplayMode_app() {
        let (_, settings) = makeSuite()
        settings.switcherDisplayMode = .app
        XCTAssertEqual(settings.switcherDisplayMode, .app)
    }

    func testFallback_switcherDisplayMode_unknownRawValueDefaultsToWindow() {
        // Verifies DefaultsEnum falls back to .window when the stored string is
        // unrecognized — e.g. a value from a future version this build doesn't know.
        let (defaults, settings) = makeSuite()
        defaults.set("perMonitor", forKey: "switcherDisplayMode")
        XCTAssertEqual(
            settings.switcherDisplayMode, .window,
            "Unrecognized raw value must fall back to the default (.window)")
    }

    // MARK: - Theme round-trip

    func testRoundTrip_theme_light() {
        let (_, settings) = makeSuite()
        settings.theme = .light
        XCTAssertEqual(settings.theme, .light)
    }

    func testRoundTrip_theme_dark() {
        let (_, settings) = makeSuite()
        settings.theme = .dark
        XCTAssertEqual(settings.theme, .dark)
    }

    func testRoundTrip_theme_system() {
        let (_, settings) = makeSuite()
        settings.theme = .system
        XCTAssertEqual(settings.theme, .system)
    }

    // MARK: - Bool round-trip

    func testRoundTrip_currentSpaceOnly_false() {
        let (_, settings) = makeSuite()
        settings.currentSpaceOnly = false
        XCTAssertFalse(settings.currentSpaceOnly)
    }

    func testRoundTrip_launchAtLogin_true() {
        let (_, settings) = makeSuite()
        settings.launchAtLogin = true
        XCTAssertTrue(settings.launchAtLogin)
    }

    // MARK: - Int round-trip

    func testRoundTrip_maxRows() {
        let (_, settings) = makeSuite()
        settings.maxRows = 10
        XCTAssertEqual(settings.maxRows, 10)
    }

    func testRoundTrip_showDelayMs() {
        let (_, settings) = makeSuite()
        settings.showDelayMs = 200
        XCTAssertEqual(settings.showDelayMs, 200)
    }

    func testRoundTrip_panelWidth() {
        let (_, settings) = makeSuite()
        settings.panelWidth = 640
        XCTAssertEqual(settings.panelWidth, 640)
    }

    // MARK: - [String] round-trip

    func testRoundTrip_excludedBundleIDs_singleEntry() {
        let (_, settings) = makeSuite()
        settings.excludedBundleIDs = ["com.apple.finder"]
        XCTAssertEqual(settings.excludedBundleIDs, ["com.apple.finder"])
    }

    func testRoundTrip_excludedBundleIDs_multipleEntries() {
        let (_, settings) = makeSuite()
        let ids = ["com.apple.finder", "com.apple.safari", "com.example.app"]
        settings.excludedBundleIDs = ids
        XCTAssertEqual(settings.excludedBundleIDs, ids)
    }

    func testRoundTrip_excludedBundleIDs_empty() {
        let (_, settings) = makeSuite()
        settings.excludedBundleIDs = ["com.apple.finder"]
        settings.excludedBundleIDs = []
        XCTAssertTrue(settings.excludedBundleIDs.isEmpty)
    }

    // MARK: - Modifier → event flag mask

    func testModifierMask_control() {
        XCTAssertEqual(TriggerModifier.control.eventFlagMask, 0x0000000000040000)
    }

    func testModifierMask_option() {
        XCTAssertEqual(TriggerModifier.option.eventFlagMask, 0x0000000000080000)
    }

    func testModifierMask_command() {
        XCTAssertEqual(TriggerModifier.command.eventFlagMask, 0x0000000000100000)
    }

    /// Verify that the option mask matches CGEventFlags.maskAlternate (0x80000).
    func testModifierMask_option_matchesCGEventFlagsMaskAlternate() {
        // CGEventFlags.maskAlternate raw value is 0x80000 (= 524288 decimal).
        XCTAssertEqual(TriggerModifier.option.eventFlagMask, UInt64(CGEventFlags.maskAlternate.rawValue))
    }

    /// Verify that the command mask matches CGEventFlags.maskCommand (0x100000).
    func testModifierMask_command_matchesCGEventFlagsMaskCommand() {
        XCTAssertEqual(TriggerModifier.command.eventFlagMask, UInt64(CGEventFlags.maskCommand.rawValue))
    }

    /// Verify that the control mask matches CGEventFlags.maskControl (0x40000).
    func testModifierMask_control_matchesCGEventFlagsMaskControl() {
        XCTAssertEqual(TriggerModifier.control.eventFlagMask, UInt64(CGEventFlags.maskControl.rawValue))
    }

    // MARK: - Key → key code

    func testKeyCode_tab_is48() {
        XCTAssertEqual(TriggerKey.tab.keyCode, 48)
    }

    func testKeyCode_grave_is50() {
        XCTAssertEqual(TriggerKey.grave.keyCode, 50)
    }

    // MARK: - windowPreviewWidth

    func testWindowPreviewWidthDefaultAndRoundTrip() {
        let (defaults, settings) = makeSuite()
        // Default is 320 (the historical constant).
        XCTAssertEqual(settings.windowPreviewWidth, 320)
        // Write and verify it persists.
        settings.windowPreviewWidth = 400
        XCTAssertEqual(settings.windowPreviewWidth, 400)
        // Re-open the SAME suite (simulates re-launch) and confirm it survived.
        let settings2 = Settings(defaults: defaults)
        XCTAssertEqual(settings2.windowPreviewWidth, 400)
    }

    // MARK: - switcherIconSize

    func testSwitcherIconSizeDefaultAndRoundTrip() {
        let (defaults, settings) = makeSuite()
        // Default is 60 — byte-for-byte identical to the historic constant.
        XCTAssertEqual(settings.switcherIconSize, 60)
        // Write and verify it persists.
        settings.switcherIconSize = 84
        XCTAssertEqual(settings.switcherIconSize, 84)
        // Re-open the SAME suite (simulates re-launch) and confirm it survived.
        let settings2 = Settings(defaults: defaults)
        XCTAssertEqual(settings2.switcherIconSize, 84)
    }

    // MARK: - NotificationCenter change notification

    func testNotification_postedOnChange() {
        let (_, settings) = makeSuite()
        let expectation = expectation(description: "settingsDidChange posted")
        let token = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: .main
        ) { _ in
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.triggerModifier = .command
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - CaseIterable

    func testCaseIterable_triggerModifier_hasAllThreeCases() {
        XCTAssertEqual(TriggerModifier.allCases.count, 3)
        XCTAssertTrue(TriggerModifier.allCases.contains(.command))
        XCTAssertTrue(TriggerModifier.allCases.contains(.option))
        XCTAssertTrue(TriggerModifier.allCases.contains(.control))
    }

    func testCaseIterable_triggerKey_hasBothCases() {
        XCTAssertEqual(TriggerKey.allCases.count, 2)
        XCTAssertTrue(TriggerKey.allCases.contains(.tab))
        XCTAssertTrue(TriggerKey.allCases.contains(.grave))
    }

    func testCaseIterable_sortMode_hasAllThreeCases() {
        XCTAssertEqual(SortMode.allCases.count, 3)
        XCTAssertTrue(SortMode.allCases.contains(.mru))
        XCTAssertTrue(SortMode.allCases.contains(.byApp))
        XCTAssertTrue(SortMode.allCases.contains(.byAppMRU))
    }

    func testCaseIterable_theme_hasAllThreeCases() {
        XCTAssertEqual(Theme.allCases.count, 3)
        XCTAssertTrue(Theme.allCases.contains(.light))
        XCTAssertTrue(Theme.allCases.contains(.dark))
        XCTAssertTrue(Theme.allCases.contains(.system))
    }

    func testCaseIterable_switcherDisplayMode_hasBothCases() {
        XCTAssertEqual(SwitcherDisplayMode.allCases.count, 2)
        XCTAssertTrue(SwitcherDisplayMode.allCases.contains(.window))
        XCTAssertTrue(SwitcherDisplayMode.allCases.contains(.app))
    }
}
