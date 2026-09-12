// WindowStoreTests.swift
// Verifies the window enumeration logic using hand-built CGWindowList fixtures.
// No TCC permissions are required because all tests go through the static
// WindowStore.filterAndBuild() entry point.

import XCTest

@testable import ShakaPachi

final class WindowStoreTests: XCTestCase {

    // MARK: - Fixture helpers

    private let selfPID: pid_t = 99999

    /// Build a minimal valid window dictionary from the given overrides.
    /// Defaults produce a window that passes every filter.
    private func validDict(
        layer: Int = 0,
        alpha: Double = 1.0,
        width: CGFloat = 100,
        height: CGFloat = 100,
        pid: Int32 = 1234,
        storeType: Int = 1,
        windowName: String? = "My Window",
        ownerName: String = "TestApp",
        windowID: CGWindowID = 42
    ) -> [String: Any] {
        var dict: [String: Any] = [
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowOwnerPID as String: pid,
            kCGWindowStoreType as String: storeType,
            kCGWindowOwnerName as String: ownerName,
            kCGWindowNumber as String: windowID,
        ]
        // Build bounds dictionary using CGRect → NSDictionary conversion.
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if let boundsDict = bounds.dictionaryRepresentation as? [String: CGFloat] {
            dict[kCGWindowBounds as String] = boundsDict
        }
        if let name = windowName {
            dict[kCGWindowName as String] = name
        }
        return dict
    }

    /// Run filterAndBuild with a no-op bundleIDResolver (returns nil for every pid).
    private func build(
        rawList: [[String: Any]],
        excludedBundleIDs: Set<String> = [],
        bundleIDResolver: ((pid_t) -> String?)? = nil
    ) -> [WindowInfo] {
        WindowStore.filterAndBuild(
            rawList: rawList,
            selfPID: selfPID,
            excludedBundleIDs: excludedBundleIDs,
            bundleIDResolver: bundleIDResolver ?? { _ in nil }
        )
    }

    // MARK: - Filter: layer != 0

    func testFilter_nonZeroLayer_rejected() {
        let dict = validDict(layer: 1)
        let result = build(rawList: [dict])
        XCTAssertTrue(result.isEmpty, "Windows with layer != 0 must be rejected")
    }

    func testFilter_zeroLayer_accepted() {
        let dict = validDict(layer: 0)
        let result = build(rawList: [dict])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Filter: alpha <= 0

    func testFilter_zeroAlpha_rejected() {
        let dict = validDict(alpha: 0.0)
        let result = build(rawList: [dict])
        XCTAssertTrue(result.isEmpty, "Invisible windows (alpha == 0) must be rejected")
    }

    func testFilter_negativeAlpha_rejected() {
        let dict = validDict(alpha: -0.5)
        let result = build(rawList: [dict])
        XCTAssertTrue(result.isEmpty, "Windows with alpha < 0 must be rejected")
    }

    func testFilter_positiveAlpha_accepted() {
        let dict = validDict(alpha: 0.5)
        let result = build(rawList: [dict])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Filter: bounds < 40x40

    func testFilter_tooNarrow_rejected() {
        let dict = validDict(width: 39, height: 100)
        let result = build(rawList: [dict])
        XCTAssertTrue(result.isEmpty, "Windows narrower than 40pt must be rejected")
    }

    func testFilter_tooShort_rejected() {
        let dict = validDict(width: 100, height: 39)
        let result = build(rawList: [dict])
        XCTAssertTrue(result.isEmpty, "Windows shorter than 40pt must be rejected")
    }

    func testFilter_exactly40x40_accepted() {
        let dict = validDict(width: 40, height: 40)
        let result = build(rawList: [dict])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Filter: ownerPID == selfPID

    func testFilter_selfPID_rejected() {
        let dict = validDict(pid: selfPID)
        let result = build(rawList: [dict])
        XCTAssertTrue(result.isEmpty, "Own-process windows must be rejected")
    }

    func testFilter_otherPID_accepted() {
        let dict = validDict(pid: 1234)
        let result = build(rawList: [dict])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Filter: kCGWindowStoreType

    func testFilter_missingStoreType_rejected() {
        var dict = validDict()
        dict.removeValue(forKey: kCGWindowStoreType as String)
        let result = build(rawList: [dict])
        XCTAssertTrue(result.isEmpty, "Windows without kCGWindowStoreType must be rejected")
    }

    func testFilter_zeroStoreType_rejected() {
        let dict = validDict(storeType: 0)
        let result = build(rawList: [dict])
        XCTAssertTrue(result.isEmpty, "Windows with kCGWindowStoreType == 0 must be rejected")
    }

    func testFilter_nonZeroStoreType_accepted() {
        let dict = validDict(storeType: 1)
        let result = build(rawList: [dict])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Filter: excluded bundle IDs

    func testFilter_excludedBundleID_rejected() {
        let dict = validDict(pid: 1234)
        let result = build(
            rawList: [dict],
            excludedBundleIDs: ["com.example.excluded"],
            bundleIDResolver: { _ in "com.example.excluded" }
        )
        XCTAssertTrue(result.isEmpty, "Windows whose bundle ID is in the exclusion list must be rejected")
    }

    func testFilter_nonExcludedBundleID_accepted() {
        let dict = validDict(pid: 1234)
        let result = build(
            rawList: [dict],
            excludedBundleIDs: ["com.example.other"],
            bundleIDResolver: { _ in "com.example.mine" }
        )
        XCTAssertEqual(result.count, 1)
    }

    func testFilter_nilBundleID_notRejectedByExclusionList() {
        let dict = validDict(pid: 1234)
        let result = build(
            rawList: [dict],
            excludedBundleIDs: ["com.example.excluded"],
            bundleIDResolver: { _ in nil }
        )
        // A nil bundleID cannot match any entry in the exclusion list.
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Title fallback: kCGWindowName → appName

    func testTitleFallback_nonEmptyWindowName_used() {
        let dict = validDict(windowName: "My Window", ownerName: "TestApp")
        let result = build(rawList: [dict])
        XCTAssertEqual(result.first?.title, "My Window")
    }

    func testTitleFallback_emptyWindowName_fallsBackToAppName() {
        let dict = validDict(windowName: "", ownerName: "TestApp")
        let result = build(rawList: [dict])
        XCTAssertEqual(
            result.first?.title, "TestApp",
            "Empty kCGWindowName must fall back to kCGWindowOwnerName")
    }

    func testTitleFallback_missingWindowName_fallsBackToAppName() {
        let dict = validDict(windowName: nil, ownerName: "TestApp")
        let result = build(rawList: [dict])
        XCTAssertEqual(
            result.first?.title, "TestApp",
            "Missing kCGWindowName must fall back to kCGWindowOwnerName")
    }

    // MARK: - Duplicate-title numbering

    func testDuplicateSuffixes_twoIdenticalTitles() {
        let dicts = [
            validDict(pid: 1001, windowName: "Safari", windowID: 1),
            validDict(pid: 1002, windowName: "Safari", windowID: 2),
        ]
        let result = build(rawList: dicts)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].title, "Safari")
        XCTAssertEqual(result[1].title, "Safari (2)")
    }

    func testDuplicateSuffixes_threeIdenticalTitles() {
        let dicts = [
            validDict(pid: 1001, windowName: "Safari", windowID: 1),
            validDict(pid: 1002, windowName: "Safari", windowID: 2),
            validDict(pid: 1003, windowName: "Safari", windowID: 3),
        ]
        let result = build(rawList: dicts)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].title, "Safari")
        XCTAssertEqual(result[1].title, "Safari (2)")
        XCTAssertEqual(result[2].title, "Safari (3)")
    }

    func testDuplicateSuffixes_uniqueTitles_noSuffix() {
        let dicts = [
            validDict(pid: 1001, windowName: "Alpha", windowID: 1),
            validDict(pid: 1002, windowName: "Beta", windowID: 2),
        ]
        let result = build(rawList: dicts)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].title, "Alpha")
        XCTAssertEqual(result[1].title, "Beta")
    }

    func testDuplicateSuffixes_mixedDuplicatesAndUniques() {
        let dicts = [
            validDict(pid: 1001, windowName: "Finder", windowID: 1),
            validDict(pid: 1002, windowName: "Safari", windowID: 2),
            validDict(pid: 1003, windowName: "Finder", windowID: 3),
        ]
        let result = build(rawList: dicts)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].title, "Finder")
        XCTAssertEqual(result[1].title, "Safari")
        XCTAssertEqual(result[2].title, "Finder (2)")
    }

    func testDuplicateSuffixes_appNameFallbackDuplicates() {
        // When two windows have no title, both fall back to the same app name.
        let dicts = [
            validDict(pid: 1001, windowName: "", ownerName: "Finder", windowID: 1),
            validDict(pid: 1002, windowName: "", ownerName: "Finder", windowID: 2),
        ]
        let result = build(rawList: dicts)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].title, "Finder")
        XCTAssertEqual(result[1].title, "Finder (2)")
    }

    // MARK: - applyDuplicateSuffixes directly

    func testApplyDuplicateSuffixes_emptyInput() {
        let result = WindowStore.applyDuplicateSuffixes(to: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testApplyDuplicateSuffixes_singleWindow() {
        let info = WindowInfo(
            windowID: 1, pid: 10, bundleID: nil,
            appName: "App", title: "App", bounds: .zero)
        let result = WindowStore.applyDuplicateSuffixes(to: [info])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "App")
    }
}
