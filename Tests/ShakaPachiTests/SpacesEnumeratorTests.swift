// SpacesEnumeratorTests.swift
// Tests the pure SpacesEnumerator.filterToAllowedIDs helper.
//
// SpacesEnumerator.allSpaceWindowIDs() is NOT tested here: it calls private
// SkyLight symbols (CGSCopyManagedDisplaySpaces, CGSCopySpacesForWindows) that
// require a real display, TCC permissions, and an active Spaces session — none
// of which are available in the headless swift test runner.
//
// filterToAllowedIDs is a pure function (Set<CGWindowID> × [WindowInfo] → [WindowInfo])
// and can be exhaustively tested without any system resources.

import XCTest

@testable import ShakaPachi

final class SpacesEnumeratorTests: XCTestCase {

    // MARK: - Fixture helper

    private func makeWindow(
        windowID: CGWindowID,
        title: String = "Window"
    ) -> WindowInfo {
        WindowInfo(
            windowID: windowID,
            pid: 1234,
            bundleID: nil,
            appName: "TestApp",
            title: title,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }

    // MARK: - filterToAllowedIDs

    func testFilter_emptyWindows_returnsEmpty() {
        let result = SpacesEnumerator.filterToAllowedIDs([], allowedIDs: [1, 2, 3])
        XCTAssertTrue(result.isEmpty, "Empty input must produce empty output")
    }

    func testFilter_emptyAllowedIDs_returnsEmpty() {
        let windows = [makeWindow(windowID: 1), makeWindow(windowID: 2)]
        let result = SpacesEnumerator.filterToAllowedIDs(windows, allowedIDs: [])
        XCTAssertTrue(
            result.isEmpty,
            "Empty allowedIDs must reject all windows")
    }

    func testFilter_allWindowsAllowed_returnsAll() {
        let windows = [
            makeWindow(windowID: 10, title: "A"),
            makeWindow(windowID: 20, title: "B"),
            makeWindow(windowID: 30, title: "C"),
        ]
        let result = SpacesEnumerator.filterToAllowedIDs(windows, allowedIDs: [10, 20, 30])
        XCTAssertEqual(result.count, 3, "All windows must pass when all IDs are allowed")
    }

    func testFilter_someWindowsAllowed_keepsOnlyAllowed() {
        let windows = [
            makeWindow(windowID: 1, title: "Space1Window"),
            makeWindow(windowID: 2, title: "Space2Window"),
            makeWindow(windowID: 3, title: "OffSpaceGhost"),
        ]
        let result = SpacesEnumerator.filterToAllowedIDs(windows, allowedIDs: [1, 2])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains { $0.windowID == 1 })
        XCTAssertTrue(result.contains { $0.windowID == 2 })
        XCTAssertFalse(
            result.contains { $0.windowID == 3 },
            "Window not in allowedIDs must be excluded")
    }

    func testFilter_noOverlap_returnsEmpty() {
        let windows = [
            makeWindow(windowID: 100),
            makeWindow(windowID: 200),
        ]
        let result = SpacesEnumerator.filterToAllowedIDs(windows, allowedIDs: [999])
        XCTAssertTrue(
            result.isEmpty,
            "No overlap between window IDs and allowedIDs must yield empty result")
    }

    func testFilter_preservesOrder() {
        // The filter must not reorder windows — input order is MRU or z-order
        // and must be preserved for the sort pass that follows.
        let windows = [
            makeWindow(windowID: 30, title: "Third"),
            makeWindow(windowID: 10, title: "First"),
            makeWindow(windowID: 20, title: "Second"),
        ]
        let result = SpacesEnumerator.filterToAllowedIDs(windows, allowedIDs: [10, 20, 30])
        XCTAssertEqual(
            result.map { $0.windowID }, [30, 10, 20],
            "filterToAllowedIDs must preserve the input order")
    }

    func testFilter_allowedIDsSuperset_onlyPresentWindowsReturned() {
        // allowedIDs may contain IDs for windows that are not in the input list
        // (e.g. the window was closed between the CGWindowList call and filtering).
        // Only IDs that appear in both input and allowedIDs should be returned.
        let windows = [makeWindow(windowID: 1)]
        let result = SpacesEnumerator.filterToAllowedIDs(
            windows,
            allowedIDs: [1, 999, 1000]  // extra IDs that have no matching window
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].windowID, 1)
    }

    func testFilter_singleWindowAllowed() {
        let windows = [
            makeWindow(windowID: 1, title: "A"),
            makeWindow(windowID: 2, title: "B"),
            makeWindow(windowID: 3, title: "C"),
        ]
        let result = SpacesEnumerator.filterToAllowedIDs(windows, allowedIDs: [2])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].windowID, 2)
        XCTAssertEqual(result[0].title, "B")
    }
}
