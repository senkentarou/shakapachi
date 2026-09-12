// LanguageSettingsTests.swift
// Verifies: AppLanguage.appleLanguagesValue mappings, non-empty displayNames,
// and that Settings.appLanguage writes/removes AppleLanguages in UserDefaults.

import XCTest

@testable import ShakaPachi

@MainActor
final class LanguageSettingsTests: XCTestCase {

    // MARK: - Helpers

    private func makeSuite(name: String = #function) -> (UserDefaults, String, Settings) {
        let suiteName = "com.shakapachi.tests.LanguageSettingsTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, suiteName, settings)
    }

    /// Returns true if `key` is absent from the suite's own persistent domain
    /// (not inherited from a parent domain in the search chain).
    private func keyAbsentInSuite(_ key: String, suite: UserDefaults, suiteName: String) -> Bool {
        let domain = suite.persistentDomain(forName: suiteName) ?? [:]
        return domain[key] == nil
    }

    // MARK: - appleLanguagesValue

    func testAppleLanguagesValue_system_isNil() {
        XCTAssertNil(
            AppLanguage.system.appleLanguagesValue,
            ".system must return nil (removes the override)")
    }

    func testAppleLanguagesValue_japanese_isJa() {
        XCTAssertEqual(AppLanguage.japanese.appleLanguagesValue, ["ja"])
    }

    func testAppleLanguagesValue_english_isEn() {
        XCTAssertEqual(AppLanguage.english.appleLanguagesValue, ["en"])
    }

    // MARK: - displayName non-empty

    func testAllCases_displayNameNonEmpty() {
        for lang in AppLanguage.allCases {
            XCTAssertFalse(
                lang.displayName.isEmpty,
                "displayName for .\(lang) must not be empty")
        }
    }

    // MARK: - Behavioral: AppleLanguages written/removed via Settings

    func testSetEnglish_writesAppleLanguages() {
        let (suite, _, s) = makeSuite()
        s.appLanguage = .english
        XCTAssertEqual(suite.stringArray(forKey: "AppleLanguages"), ["en"])
    }

    func testSetJapanese_writesAppleLanguages() {
        let (suite, _, s) = makeSuite()
        s.appLanguage = .japanese
        XCTAssertEqual(suite.stringArray(forKey: "AppleLanguages"), ["ja"])
    }

    func testSetSystem_removesAppleLanguages() {
        // suite.array(forKey:) searches all UserDefaults domains (including the
        // system-level AppleLanguages key), so we must inspect the suite's own
        // persistent domain to confirm the key was actually removed from it.
        let (suite, suiteName, s) = makeSuite()
        s.appLanguage = .english  // write into this suite's domain
        s.appLanguage = .system  // remove from this suite's domain
        XCTAssertTrue(
            keyAbsentInSuite("AppleLanguages", suite: suite, suiteName: suiteName),
            "Setting .system must remove AppleLanguages from the suite's own domain")
    }

    func testRoundTrip_allLanguages() {
        let (suite, suiteName, s) = makeSuite()
        s.appLanguage = .english
        XCTAssertEqual(suite.stringArray(forKey: "AppleLanguages"), ["en"])
        s.appLanguage = .japanese
        XCTAssertEqual(suite.stringArray(forKey: "AppleLanguages"), ["ja"])
        // After reverting to .system the suite's own domain no longer has the key.
        s.appLanguage = .system
        XCTAssertTrue(
            keyAbsentInSuite("AppleLanguages", suite: suite, suiteName: suiteName),
            "After .system the AppleLanguages key must be absent from the suite domain")
    }

    // MARK: - Default value

    func testDefault_appLanguage_isSystem() {
        let (_, _, s) = makeSuite()
        XCTAssertEqual(
            s.appLanguage, .system,
            "Default appLanguage must be .system")
    }

    // MARK: - rawValue round-trip

    func testRawValueRoundTrip_allCases() {
        for lang in AppLanguage.allCases {
            let raw = lang.rawValue
            let recovered = AppLanguage(rawValue: raw)
            XCTAssertEqual(
                recovered, lang,
                "AppLanguage(rawValue: \"\(raw)\") should round-trip to .\(lang)")
        }
    }
}
