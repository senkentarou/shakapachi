// WindowStoreSortTests.swift
// Verifies WindowStore sort modes (byApp, byAppMRU, mru).
// All tests use static pure functions — no TCC, no CGWindowList.

import CoreGraphics
import XCTest

@testable import ShakaPachi

final class WindowStoreSortTests: XCTestCase {

    // MARK: - Fixture helper

    private func makeWindow(
        id: CGWindowID,
        pid: pid_t,
        bundleID: String?,
        appName: String,
        title: String = "Window"
    ) -> WindowInfo {
        WindowInfo(
            windowID: id,
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            title: title,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }

    // MARK: - sortedByApp

    func testSortedByApp_emptyInput_returnsEmpty() {
        let result = WindowStore.sortedByApp(windows: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSortedByApp_singleWindow_returnsSame() {
        let w = makeWindow(id: 1, pid: 100, bundleID: "com.apple.safari", appName: "Safari")
        let result = WindowStore.sortedByApp(windows: [w])
        XCTAssertEqual(result.map { $0.windowID }, [1])
    }

    func testSortedByApp_windowsFromSameApp_areContiguous() {
        // Two Safari windows and one Finder window: Safari, Finder, Safari.
        // byApp should group them alphabetically by app name: Finder first, then Safari.
        let s1 = makeWindow(id: 1, pid: 101, bundleID: "com.apple.safari", appName: "Safari", title: "Safari 1")
        let fi = makeWindow(id: 2, pid: 102, bundleID: "com.apple.finder", appName: "Finder", title: "Finder")
        let s2 = makeWindow(id: 3, pid: 101, bundleID: "com.apple.safari", appName: "Safari", title: "Safari 2")

        let result = WindowStore.sortedByApp(windows: [s1, fi, s2])
        // App name ascending: Finder (F) < Safari (S).
        // Safari windows preserve their input order (1, 3) within the group.
        XCTAssertEqual(
            result.map { $0.windowID }, [2, 1, 3],
            "Expected Finder, Safari 1, Safari 2 — byApp orders groups by app name ascending")
    }

    func testSortedByApp_allWindowsFromOneApp_orderPreserved() {
        let w1 = makeWindow(id: 1, pid: 100, bundleID: "com.example.app", appName: "MyApp", title: "A")
        let w2 = makeWindow(id: 2, pid: 100, bundleID: "com.example.app", appName: "MyApp", title: "B")
        let w3 = makeWindow(id: 3, pid: 100, bundleID: "com.example.app", appName: "MyApp", title: "C")
        let result = WindowStore.sortedByApp(windows: [w1, w2, w3])
        // All same app: original order preserved.
        XCTAssertEqual(result.map { $0.windowID }, [1, 2, 3])
    }

    func testSortedByApp_interGroupOrderIsAlphabeticalByAppName() {
        // Input order: B1, A1, A2, B2, C1.
        // App name ascending order: A, B, C.
        // Expected output: A1, A2, B1, B2, C1.
        let b1 = makeWindow(id: 1, pid: 200, bundleID: "com.b", appName: "B")
        let a1 = makeWindow(id: 2, pid: 100, bundleID: "com.a", appName: "A")
        let a2 = makeWindow(id: 3, pid: 100, bundleID: "com.a", appName: "A")
        let b2 = makeWindow(id: 4, pid: 200, bundleID: "com.b", appName: "B")
        let c1 = makeWindow(id: 5, pid: 300, bundleID: "com.c", appName: "C")
        let result = WindowStore.sortedByApp(windows: [b1, a1, a2, b2, c1])
        // Groups are alphabetical: A (id=2,3), B (id=1,4), C (id=5).
        // Windows within each group preserve their input order.
        XCTAssertEqual(result.map { $0.windowID }, [2, 3, 1, 4, 5])
    }

    func testSortedByApp_nilBundleIDGroupsByAppName() {
        // When bundleID is nil, the grouping key falls back to appName.
        // Groups are ordered by app name ascending: AppX < AppY.
        let x1 = makeWindow(id: 1, pid: 10, bundleID: nil, appName: "AppX")
        let y1 = makeWindow(id: 2, pid: 20, bundleID: nil, appName: "AppY")
        let x2 = makeWindow(id: 3, pid: 10, bundleID: nil, appName: "AppX")
        let result = WindowStore.sortedByApp(windows: [x1, y1, x2])
        // App name ascending: AppX (id=1,3), then AppY (id=2).
        XCTAssertEqual(result.map { $0.windowID }, [1, 3, 2])
    }

    func testSortedByApp_singleWindowPerApp_orderedByAppName() {
        // User-reported scenario: one window per app, input in reverse-alphabetical
        // (MRU) order. byApp must still produce alphabetical group order, proving it
        // is independent of MRU input order.
        let z1 = makeWindow(id: 1, pid: 10, bundleID: "com.zed", appName: "Zed")
        let a1 = makeWindow(id: 2, pid: 20, bundleID: "com.apple", appName: "Apple")
        let m1 = makeWindow(id: 3, pid: 30, bundleID: "com.music", appName: "Music")
        let result = WindowStore.sortedByApp(windows: [z1, a1, m1])
        // App name ascending: Apple (id=2), Music (id=3), Zed (id=1).
        // This differs from the MRU input order [1, 2, 3], confirming byApp is
        // not equivalent to MRU even with one window per app.
        XCTAssertEqual(
            result.map { $0.windowID }, [2, 3, 1],
            "byApp must sort by app name ascending, not by MRU input order")
        XCTAssertNotEqual(
            result.map { $0.windowID }, [1, 2, 3],
            "byApp result must differ from MRU input order")
    }

    // MARK: - sortedByAppMRU

    func testSortedByAppMRU_emptyInput_returnsEmpty() {
        let result = WindowStore.sortedByAppMRU(windows: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSortedByAppMRU_groupsOrderedByAppFirstSeen() {
        // Input (MRU order): Safari, Finder, Safari.
        // First-seen app order: Safari (id=1), then Finder (id=2).
        // byAppMRU keeps that recency order — Safari group comes before Finder.
        let s1 = makeWindow(id: 1, pid: 101, bundleID: "com.apple.safari", appName: "Safari", title: "Safari 1")
        let fi = makeWindow(id: 2, pid: 102, bundleID: "com.apple.finder", appName: "Finder", title: "Finder")
        let s2 = makeWindow(id: 3, pid: 101, bundleID: "com.apple.safari", appName: "Safari", title: "Safari 2")

        let result = WindowStore.sortedByAppMRU(windows: [s1, fi, s2])
        // Group order = first-seen app order: Safari (1, 3), then Finder (2).
        XCTAssertEqual(
            result.map { $0.windowID }, [1, 3, 2],
            "byAppMRU orders groups by the app's first-seen (MRU) rank, not alphabetically")
    }

    func testSortedByAppMRU_sameAppWindowsAreContiguous() {
        // Interleaved apps A, B, A, B, A must be regrouped so each app is contiguous.
        let a1 = makeWindow(id: 1, pid: 100, bundleID: "com.a", appName: "A")
        let b1 = makeWindow(id: 2, pid: 200, bundleID: "com.b", appName: "B")
        let a2 = makeWindow(id: 3, pid: 100, bundleID: "com.a", appName: "A")
        let b2 = makeWindow(id: 4, pid: 200, bundleID: "com.b", appName: "B")
        let a3 = makeWindow(id: 5, pid: 100, bundleID: "com.a", appName: "A")
        let result = WindowStore.sortedByAppMRU(windows: [a1, b1, a2, b2, a3])
        // First-seen order: A (1, 3, 5) then B (2, 4).
        XCTAssertEqual(result.map { $0.windowID }, [1, 3, 5, 2, 4])
    }

    func testSortedByAppMRU_withinGroupOrderPreserved() {
        // All windows from one app: relative input order must be preserved.
        let w1 = makeWindow(id: 1, pid: 100, bundleID: "com.example.app", appName: "MyApp", title: "A")
        let w2 = makeWindow(id: 2, pid: 100, bundleID: "com.example.app", appName: "MyApp", title: "B")
        let w3 = makeWindow(id: 3, pid: 100, bundleID: "com.example.app", appName: "MyApp", title: "C")
        let result = WindowStore.sortedByAppMRU(windows: [w1, w2, w3])
        XCTAssertEqual(result.map { $0.windowID }, [1, 2, 3])
    }

    func testSortedByAppMRU_differsFromSortedByApp_whenMRUContradictsAlphabetical() {
        // MRU input order: Zed, Apple, Music (reverse-alphabetical first-seen).
        // byAppMRU keeps recency: Zed, Apple, Music (input group order).
        // byApp sorts alphabetically: Apple, Music, Zed. The two must differ.
        let z1 = makeWindow(id: 1, pid: 10, bundleID: "com.zed", appName: "Zed")
        let a1 = makeWindow(id: 2, pid: 20, bundleID: "com.apple", appName: "Apple")
        let m1 = makeWindow(id: 3, pid: 30, bundleID: "com.music", appName: "Music")
        let input = [z1, a1, m1]

        let mruResult = WindowStore.sortedByAppMRU(windows: input)
        // First-seen (MRU) group order matches the input order here.
        XCTAssertEqual(
            mruResult.map { $0.windowID }, [1, 2, 3],
            "byAppMRU must follow the app's MRU (first-seen) order")

        let appResult = WindowStore.sortedByApp(windows: input)
        // Alphabetical: Apple (2), Music (3), Zed (1).
        XCTAssertEqual(
            appResult.map { $0.windowID }, [2, 3, 1],
            "byApp must sort groups alphabetically by app name")

        XCTAssertNotEqual(
            mruResult.map { $0.windowID },
            appResult.map { $0.windowID },
            "byAppMRU (recency) and byApp (alphabetical) must differ for this input")
    }

    func testSortedByAppMRU_nilBundleIDGroupsByAppNameFirstSeen() {
        // When bundleID is nil, the grouping key falls back to appName.
        // First-seen order: AppY (id=1), then AppX (id=2).
        let y1 = makeWindow(id: 1, pid: 20, bundleID: nil, appName: "AppY")
        let x1 = makeWindow(id: 2, pid: 10, bundleID: nil, appName: "AppX")
        let y2 = makeWindow(id: 3, pid: 20, bundleID: nil, appName: "AppY")
        let result = WindowStore.sortedByAppMRU(windows: [y1, x1, y2])
        // First-seen: AppY (1, 3), then AppX (2) — recency, not alphabetical.
        XCTAssertEqual(result.map { $0.windowID }, [1, 3, 2])
    }

    func testSortedByAppMRU_canBeCalledFromAnyContext() async {
        // sortedByAppMRU is nonisolated static, so it must be callable from any context.
        let w = makeWindow(id: 1, pid: 100, bundleID: "com.example", appName: "App")
        let result = await Task.detached {
            WindowStore.sortedByAppMRU(windows: [w])
        }.value
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - sortedByApp is nonisolated (pure function property)

    func testSortedByApp_canBeCalledFromAnyContext() async {
        // sortedByApp is nonisolated static, so it must be callable from any context.
        let w = makeWindow(id: 1, pid: 100, bundleID: "com.example", appName: "App")
        // Call from a non-MainActor context to verify nonisolated.
        let result = await Task.detached {
            WindowStore.sortedByApp(windows: [w])
        }.value
        XCTAssertEqual(result.count, 1)
    }
}
