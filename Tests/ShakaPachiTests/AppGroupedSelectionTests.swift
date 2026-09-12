// AppGroupedSelectionTests.swift
// Verifies grouping, cursor movement, strip sliding, and per-app memory for
// app-unit switcher mode. No AppKit or CoreGraphics permission required —
// AppGroupedSelection is pure logic.

import CoreGraphics
import Foundation
import XCTest

@testable import ShakaPachi

final class AppGroupedSelectionTests: XCTestCase {

    // MARK: - Helpers

    private func makeWindow(
        id: CGWindowID,
        pid: pid_t = 100,
        bundleID: String?,
        appName: String
    ) -> WindowInfo {
        WindowInfo(
            windowID: id,
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            title: appName,
            bounds: .zero
        )
    }

    // MARK: - groups(from:)

    func testGroupsFromPreservesSnapshotOrderAndGroupsBySharedBundleID() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.b", appName: "B"),
            makeWindow(id: 3, bundleID: "com.a", appName: "A"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        XCTAssertEqual(groups.count, 2, "Two distinct bundle IDs must yield two groups")
        XCTAssertEqual(groups[0].bundleID, "com.a")
        XCTAssertEqual(groups[0].windowIndices, [0, 2], "Group order follows first appearance")
        XCTAssertEqual(groups[1].bundleID, "com.b")
        XCTAssertEqual(groups[1].windowIndices, [1])
    }

    func testGroupsFromUsesAppNameWhenBundleIDIsNil() {
        let windows = [
            makeWindow(id: 1, bundleID: nil, appName: "Finder"),
            makeWindow(id: 2, bundleID: nil, appName: "Notes"),
            makeWindow(id: 3, bundleID: nil, appName: "Finder"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].appName, "Finder")
        XCTAssertEqual(groups[0].windowIndices, [0, 2])
        XCTAssertEqual(groups[1].appName, "Notes")
        XCTAssertEqual(groups[1].windowIndices, [1])
    }

    func testGroupsFromEmptyInputReturnsEmptyArray() {
        XCTAssertEqual(AppGroupedSelection.groups(from: []), [])
    }

    // MARK: - Strip sliding

    func testWindowRowSlidesStripKeepingInvariantOnEachStep() {
        let windows = (0..<8).map { makeWindow(id: CGWindowID($0), bundleID: "com.x", appName: "X") }
        let groups = AppGroupedSelection.groups(from: windows)
        var selection = AppGroupedSelection(groups: groups, flatIndex: 0)
        selection.descend()

        for step in 1...7 {
            selection.moveWithinRow(forward: true)
            let strip = selection.strip
            XCTAssertEqual(selection.windowIndex, step, "windowIndex must advance one per step")
            XCTAssertEqual(
                strip.hiddenLeft + strip.visible.count + strip.hiddenRight, 8,
                "hiddenLeft + visible + hiddenRight must always equal the group's window count")
        }
    }

    func testWindowRowStopsAtEndsWithoutWrapping() {
        let windows = (0..<8).map { makeWindow(id: CGWindowID($0), bundleID: "com.x", appName: "X") }
        let groups = AppGroupedSelection.groups(from: windows)
        var selection = AppGroupedSelection(groups: groups, flatIndex: 0)
        selection.descend()

        XCTAssertEqual(selection.strip.hiddenLeft, 0, "hiddenLeft must be 0 at the front")

        for _ in 0..<7 {
            selection.moveWithinRow(forward: true)
        }
        XCTAssertEqual(selection.windowIndex, 7)
        XCTAssertEqual(selection.strip.hiddenRight, 0, "hiddenRight must be 0 at the tail")

        // One more forward step must not wrap back to the front.
        selection.moveWithinRow(forward: true)
        XCTAssertEqual(selection.windowIndex, 7, "Window row must stop at the last window, not wrap")
        XCTAssertEqual(selection.strip.hiddenRight, 0)
    }

    // MARK: - descend() no-op

    func testDescendIsNoOpWithSingleWindow() {
        let windows = [makeWindow(id: 1, bundleID: "com.x", appName: "X")]
        let groups = AppGroupedSelection.groups(from: windows)
        var selection = AppGroupedSelection(groups: groups, flatIndex: 0)
        selection.descend()
        XCTAssertEqual(selection.focusRow, .app, "descend() must be a no-op for a single-window group")
    }

    // MARK: - nextApp() wraparound and focusRow drop

    func testNextAppWrapsAndDropsFocusRowForSingleWindowApp() {
        // A: 2 windows, B: 1 window, C: 2 windows.
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.a", appName: "A"),
            makeWindow(id: 3, bundleID: "com.b", appName: "B"),
            makeWindow(id: 4, bundleID: "com.c", appName: "C"),
            makeWindow(id: 5, bundleID: "com.c", appName: "C"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        var selection = AppGroupedSelection(groups: groups, flatIndex: 0)
        selection.descend()  // A has 2 windows: .window row
        XCTAssertEqual(selection.focusRow, .window)

        selection.nextApp()  // → B (1 window)
        XCTAssertEqual(selection.appIndex, 1)
        XCTAssertEqual(selection.focusRow, .app, "Landing on a single-window app must drop to .app row")

        selection.nextApp()  // → C (2 windows): arriving focuses the strip
        XCTAssertEqual(selection.appIndex, 2)
        XCTAssertEqual(
            selection.focusRow, .window,
            "Landing on a multi-window app must focus its strip without a separate descend")

        selection.nextApp()  // → wraps past the last group back to A
        XCTAssertEqual(selection.appIndex, 0, "nextApp() must wrap around at the end")
    }

    // MARK: - Per-app memory

    func testPerAppMemoryRestoresWindowIndexOnReturn() {
        // A: 3 windows (indices 0,1,2), B: 1 window (index 3).
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.a", appName: "A"),
            makeWindow(id: 3, bundleID: "com.a", appName: "A"),
            makeWindow(id: 4, bundleID: "com.b", appName: "B"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        var selection = AppGroupedSelection(groups: groups, flatIndex: 0)
        selection.descend()
        selection.moveWithinRow(forward: true)  // windowIndex 1
        selection.moveWithinRow(forward: true)  // windowIndex 2 (3rd window)
        XCTAssertEqual(selection.windowIndex, 2)

        selection.nextApp()  // → B
        XCTAssertEqual(selection.appIndex, 1)

        selection.previousApp()  // → back to A
        XCTAssertEqual(selection.appIndex, 0)
        XCTAssertEqual(selection.windowIndex, 2, "Returning to A must restore its last windowIndex")
        XCTAssertEqual(selection.flatIndex, 2)
    }

    // MARK: - selectVisible(_:)

    func testSelectVisibleSelectsOrdinalAndFocusesWindowRow() {
        let windows = (0..<5).map { makeWindow(id: CGWindowID($0), bundleID: "com.x", appName: "X") }
        let groups = AppGroupedSelection.groups(from: windows)
        var selection = AppGroupedSelection(groups: groups, flatIndex: 0)

        let visibleBefore = selection.strip.visible
        let ok = selection.selectVisible(2)
        XCTAssertTrue(ok)
        XCTAssertEqual(selection.flatIndex, visibleBefore[1], "selectVisible(2) must select strip.visible[1]")
        XCTAssertEqual(selection.focusRow, .window)
    }

    func testSelectVisibleOutOfRangeReturnsFalseAndLeavesStateUnchanged() {
        let windows = (0..<5).map { makeWindow(id: CGWindowID($0), bundleID: "com.x", appName: "X") }
        let groups = AppGroupedSelection.groups(from: windows)
        var selection = AppGroupedSelection(groups: groups, flatIndex: 0)
        selection.selectVisible(2)  // windowIndex 1, .window row, strip still [0,1,2]

        let windowIndexBefore = selection.windowIndex
        let focusRowBefore = selection.focusRow
        let ok = selection.selectVisible(4)
        XCTAssertFalse(ok, "Only 3 panes are visible; ordinal 4 is out of range")
        XCTAssertEqual(selection.windowIndex, windowIndexBefore)
        XCTAssertEqual(selection.focusRow, focusRowBefore)
    }

    // MARK: - flatIndex independence from focusRow

    func testFlatIndexIgnoresFocusRowAndUsesWindowIndex() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.a", appName: "A"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        var selection = AppGroupedSelection(groups: groups, flatIndex: 0)
        XCTAssertEqual(selection.flatIndex, 0)

        selection.descend()
        selection.moveWithinRow(forward: true)  // windowIndex 1, .window row
        let flatIndexOnWindowRow = selection.flatIndex

        selection.ascend()  // back to .app row, windowIndex unchanged
        XCTAssertEqual(
            selection.flatIndex, flatIndexOnWindowRow,
            "flatIndex must resolve the same way regardless of focusRow")
    }

    // MARK: - init(groups:flatIndex:)

    func testInitLocatesGroupContainingFlatIndex() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.a", appName: "A"),
            makeWindow(id: 3, bundleID: "com.b", appName: "B"),
            makeWindow(id: 4, bundleID: "com.c", appName: "C"),
            makeWindow(id: 5, bundleID: "com.c", appName: "C"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        let selection = AppGroupedSelection(groups: groups, flatIndex: 3)
        XCTAssertEqual(selection.appIndex, 2, "flatIndex 3 belongs to group C")
        XCTAssertEqual(selection.windowIndex, 0)
        XCTAssertEqual(
            selection.focusRow, .window,
            "C has 2 windows, so opening on it focuses the strip straight away")
    }

    func testOpeningOnASingleWindowAppStaysOnTheAppRow() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.b", appName: "B"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        let selection = AppGroupedSelection(groups: groups, flatIndex: 0)
        XCTAssertEqual(selection.focusRow, .app, "one window has no strip to focus")
    }

    func testAscendIsStillReachableAfterAutoFocus() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.a", appName: "A"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        var selection = AppGroupedSelection(groups: groups, flatIndex: 0)
        XCTAssertEqual(selection.focusRow, .window)
        selection.ascend()
        XCTAssertEqual(selection.focusRow, .app, "auto-focus must not make the app row unreachable")
    }

    func testInitFallsBackToFrontForOutOfRangeFlatIndex() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.b", appName: "B"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        let selection = AppGroupedSelection(groups: groups, flatIndex: 99)
        XCTAssertEqual(selection.appIndex, 0)
        XCTAssertEqual(selection.windowIndex, 0)
    }

    func testInitWithEmptyGroupsIsSafe() {
        let selection = AppGroupedSelection(groups: [], flatIndex: 0)
        XCTAssertNil(selection.currentGroup)
        XCTAssertNil(selection.flatIndex)
        XCTAssertEqual(selection.strip, WindowStrip(visible: [], hiddenLeft: 0, hiddenRight: 0))
    }

    // MARK: - SwitchCoordinator.appGroupedInitialIndex(groups:shift:)

    func testAppGroupedInitialIndexWithoutShiftStartsOnTheNextApp() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.b", appName: "B"),
            makeWindow(id: 3, bundleID: "com.c", appName: "C"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        let index = SwitchCoordinator.appGroupedInitialIndex(groups: groups, shift: false)
        XCTAssertEqual(index, 1, "no shift: land on the second group (the previous app)")
    }

    func testAppGroupedInitialIndexWithShiftStartsOnTheCurrentApp() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.b", appName: "B"),
            makeWindow(id: 3, bundleID: "com.c", appName: "C"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        let index = SwitchCoordinator.appGroupedInitialIndex(groups: groups, shift: true)
        XCTAssertEqual(index, 0, "shift: land on the first group (the current app)")
    }

    func testAppGroupedInitialIndexWithSingleAppIsZeroRegardlessOfShift() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.a", appName: "A"),
            makeWindow(id: 2, bundleID: "com.a", appName: "A"),
        ]
        let groups = AppGroupedSelection.groups(from: windows)
        XCTAssertEqual(SwitchCoordinator.appGroupedInitialIndex(groups: groups, shift: false), 0)
        XCTAssertEqual(SwitchCoordinator.appGroupedInitialIndex(groups: groups, shift: true), 0)
    }

    func testAppGroupedInitialIndexWithEmptyGroupsIsZero() {
        XCTAssertEqual(SwitchCoordinator.appGroupedInitialIndex(groups: [], shift: false), 0)
        XCTAssertEqual(SwitchCoordinator.appGroupedInitialIndex(groups: [], shift: true), 0)
    }
}
