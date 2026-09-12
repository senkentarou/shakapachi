// WindowStoreMRUTests.swift
// Verifies the MRU ordering pure helpers in WindowStore.
// No AppKit, no TCC, no CGWindowList — all tests are deterministic.

import XCTest

@testable import ShakaPachi

final class WindowStoreMRUTests: XCTestCase {

    // MARK: - sortedByMRU

    /// When mruOrder is empty, z-order is returned unchanged.
    func testSortedByMRU_emptyOrder_returnsZOrder() {
        let ids: [CGWindowID] = [1, 2, 3]
        let result = WindowStore.sortedByMRU(windowIDs: ids, mruOrder: [])
        XCTAssertEqual(result, [1, 2, 3])
    }

    /// When windowIDs is empty, result is also empty.
    func testSortedByMRU_emptyWindowIDs_returnsEmpty() {
        let result = WindowStore.sortedByMRU(windowIDs: [], mruOrder: [10, 20])
        XCTAssertTrue(result.isEmpty)
    }

    /// Known IDs follow the mruOrder sequence; each unknown is spliced in
    /// directly in front of the nearest known window behind it in z-order.
    func testSortedByMRU_knownsInMRUOrder_unknownsSplicedAtZOrderPosition() {
        // z-order from CGWindowList: [1, 2, 3, 4]
        // mruOrder: [3, 1]  (3 used most recently, then 1)
        let ids: [CGWindowID] = [1, 2, 3, 4]
        let result = WindowStore.sortedByMRU(windowIDs: ids, mruOrder: [3, 1])
        // 2 sits in front of known 3 in z-order, so it is emitted just before 3.
        // 4 has no known window behind it, so it lands at the end.
        XCTAssertEqual(result, [2, 3, 1, 4])
    }

    /// Regression: a window the MRU never recorded but that is frontmost in
    /// z-order must NOT be pushed behind a stale MRU entry.
    ///
    /// Reported symptom: the app in active use appeared after an untouched app
    /// that happened to be the only recorded MRU entry.
    func testSortedByMRU_unknownInFrontOfKnown_rankedBeforeIt() {
        let active: CGWindowID = 1  // in active use, never recorded in mruOrder
        let stale: CGWindowID = 2  // used once long ago, still in mruOrder
        let other: CGWindowID = 3  // unknown, behind everything

        // z-order says active is frontmost, so it is the most recently used.
        let result = WindowStore.sortedByMRU(
            windowIDs: [active, stale, other],
            mruOrder: [stale]
        )
        XCTAssertEqual(
            result, [active, stale, other],
            "The frontmost window must rank first even when it is absent from mruOrder")
    }

    /// An unknown window behind a known window stays behind it.
    func testSortedByMRU_unknownBehindKnown_rankedAfterIt() {
        // z-order: known 10 in front, unknown 20 behind it.
        let result = WindowStore.sortedByMRU(windowIDs: [10, 20], mruOrder: [10])
        XCTAssertEqual(result, [10, 20])
    }

    /// Consecutive unknown windows keep their relative z-order when spliced in.
    func testSortedByMRU_consecutiveUnknowns_keepRelativeZOrder() {
        // z-order: [5, 6, 7, 1, 8, 9] — 1 is the only known window.
        // 5, 6, 7 sit in front of 1 and keep their order; 8, 9 trail behind.
        let result = WindowStore.sortedByMRU(
            windowIDs: [5, 6, 7, 1, 8, 9],
            mruOrder: [1]
        )
        XCTAssertEqual(result, [5, 6, 7, 1, 8, 9])
    }

    /// Unknowns are anchored to the NEAREST known window behind them, so each
    /// run is spliced in at its own known window rather than all at the front.
    func testSortedByMRU_unknownsAnchorToNearestKnownBehind() {
        // z-order: [7, 1, 8, 2]; mruOrder ranks 2 ahead of 1.
        // 7 is anchored to 1, 8 is anchored to 2 — each moves with its anchor.
        let result = WindowStore.sortedByMRU(
            windowIDs: [7, 1, 8, 2],
            mruOrder: [2, 1]
        )
        XCTAssertEqual(result, [8, 2, 7, 1])
    }

    /// No known window is on screen — z-order is returned unchanged.
    func testSortedByMRU_noKnownWindowsOnScreen_returnsZOrder() {
        let result = WindowStore.sortedByMRU(windowIDs: [5, 6, 7], mruOrder: [98, 99])
        XCTAssertEqual(result, [5, 6, 7])
    }

    /// An mruOrder entry that is no longer on-screen is silently skipped.
    func testSortedByMRU_staleMRUEntrySkipped() {
        let ids: [CGWindowID] = [1, 2]
        // 99 is in mruOrder but not in the current window list
        let result = WindowStore.sortedByMRU(windowIDs: ids, mruOrder: [99, 2, 1])
        XCTAssertEqual(result, [2, 1])
    }

    /// All on-screen windows are known in mruOrder — no unknowns to append.
    func testSortedByMRU_allKnown_returnsInMRUOrder() {
        let ids: [CGWindowID] = [10, 20, 30]
        let result = WindowStore.sortedByMRU(windowIDs: ids, mruOrder: [30, 10, 20])
        XCTAssertEqual(result, [30, 10, 20])
    }

    /// All on-screen windows are unknown — returns z-order unchanged.
    func testSortedByMRU_allUnknown_returnsZOrder() {
        let ids: [CGWindowID] = [5, 6, 7]
        let result = WindowStore.sortedByMRU(windowIDs: ids, mruOrder: [1, 2, 3])
        XCTAssertEqual(result, [5, 6, 7])
    }

    /// Single window, known in mruOrder.
    func testSortedByMRU_singleWindowKnown() {
        let result = WindowStore.sortedByMRU(windowIDs: [42], mruOrder: [42])
        XCTAssertEqual(result, [42])
    }

    /// Single window, unknown in mruOrder.
    func testSortedByMRU_singleWindowUnknown() {
        let result = WindowStore.sortedByMRU(windowIDs: [42], mruOrder: [99])
        XCTAssertEqual(result, [42])
    }

    // MARK: - movedToFront

    /// Inserting into an empty order produces a one-element array.
    func testMovedToFront_emptyOrder_insertsAtFront() {
        let result = WindowStore.movedToFront(5, in: [], cap: 200)
        XCTAssertEqual(result, [5])
    }

    /// A new ID is prepended to an existing order.
    func testMovedToFront_newID_prependedWithoutDuplicate() {
        let result = WindowStore.movedToFront(1, in: [2, 3, 4], cap: 200)
        XCTAssertEqual(result, [1, 2, 3, 4])
    }

    /// An existing ID at the front is a no-op (still at front, count unchanged).
    func testMovedToFront_alreadyAtFront_noChange() {
        let result = WindowStore.movedToFront(1, in: [1, 2, 3], cap: 200)
        XCTAssertEqual(result, [1, 2, 3])
    }

    /// An existing ID not at the front is moved to the front without duplication.
    func testMovedToFront_existingMidID_movedToFrontNoDupe() {
        let result = WindowStore.movedToFront(2, in: [1, 2, 3, 4], cap: 200)
        XCTAssertEqual(result, [2, 1, 3, 4])
    }

    /// An existing ID at the tail is moved to the front without duplication.
    func testMovedToFront_existingTailID_movedToFront() {
        let result = WindowStore.movedToFront(4, in: [1, 2, 3, 4], cap: 200)
        XCTAssertEqual(result, [4, 1, 2, 3])
    }

    /// When the result would exceed cap, the tail is trimmed.
    func testMovedToFront_capEvictsFromTail() {
        // Fill with IDs 1…5, cap = 5
        let existing: [CGWindowID] = [1, 2, 3, 4, 5]
        let result = WindowStore.movedToFront(6, in: existing, cap: 5)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.first, 6)
        // Tail (ID 5) must be dropped
        XCTAssertFalse(result.contains(5))
    }

    /// Cap of 200 is enforced correctly when adding to a full list.
    func testMovedToFront_cap200_evictsTail() {
        let existing: [CGWindowID] = Array(1...200)
        let result = WindowStore.movedToFront(999, in: existing, cap: 200)
        XCTAssertEqual(result.count, 200)
        XCTAssertEqual(result.first, 999)
        // The oldest entry (200) must be dropped
        XCTAssertFalse(result.contains(200))
        // All entries 1…199 are still present
        for i: CGWindowID in 1...199 {
            XCTAssertTrue(result.contains(i), "Entry \(i) should survive cap eviction")
        }
    }

    /// When cap == 1, only the most recent entry survives.
    func testMovedToFront_capOne_keepsOnlyFront() {
        let result = WindowStore.movedToFront(7, in: [1, 2, 3], cap: 1)
        XCTAssertEqual(result, [7])
    }

    /// Promotes an ID from the middle of a full-cap list; no duplication.
    func testMovedToFront_promoteFromMiddleInFullList_noExtraEntries() {
        let existing: [CGWindowID] = Array(1...200)
        // Promoting ID 100 (which already exists): no duplication, count stays 200
        let result = WindowStore.movedToFront(100, in: existing, cap: 200)
        XCTAssertEqual(result.count, 200)
        XCTAssertEqual(result.first, 100)
        // 100 appears exactly once
        XCTAssertEqual(result.filter { $0 == 100 }.count, 1)
    }

    // MARK: - adoptingFrontmost

    /// The z-order head is recorded even when mruOrder has never seen it.
    func testAdoptingFrontmost_unrecordedFrontmost_becomesMostRecent() {
        let result = WindowStore.adoptingFrontmost(windowIDs: [1, 2, 3], order: [9], cap: 200)
        XCTAssertEqual(result, [1, 9])
    }

    /// Adoption then sorting puts the frontmost window at index 0 — the
    /// guarantee press-once-release depends on.
    func testAdoptingFrontmost_thenSort_frontmostIsIndexZero() {
        let zOrder: [CGWindowID] = [1, 2, 3]
        let order = WindowStore.adoptingFrontmost(windowIDs: zOrder, order: [2], cap: 200)
        let sorted = WindowStore.sortedByMRU(windowIDs: zOrder, mruOrder: order)
        XCTAssertEqual(sorted.first, 1)
    }

    /// An empty window list leaves the order untouched.
    func testAdoptingFrontmost_emptyWindowIDs_orderUnchanged() {
        let result = WindowStore.adoptingFrontmost(windowIDs: [], order: [1, 2], cap: 200)
        XCTAssertEqual(result, [1, 2])
    }

    /// Re-adopting a window that is already the most recent is a no-op.
    func testAdoptingFrontmost_alreadyMostRecent_noChange() {
        let result = WindowStore.adoptingFrontmost(windowIDs: [1, 2], order: [1, 2, 3], cap: 200)
        XCTAssertEqual(result, [1, 2, 3])
    }

    /// Adoption promotes an existing entry without duplicating it.
    func testAdoptingFrontmost_existingEntry_promotedNoDupe() {
        let result = WindowStore.adoptingFrontmost(windowIDs: [3, 1], order: [1, 2, 3], cap: 200)
        XCTAssertEqual(result, [3, 1, 2])
    }

    /// The cap is enforced through adoption just as it is through movedToFront.
    func testAdoptingFrontmost_respectsCap() {
        let result = WindowStore.adoptingFrontmost(windowIDs: [9], order: [1, 2, 3], cap: 2)
        XCTAssertEqual(result, [9, 1])
    }

    // MARK: - Alternating activation round-trip

    /// Simulates alternating between window A and window B using the pure helpers.
    /// After each swap, "press once release" (initial index 1) returns to the
    /// other window — verifying the core MRU invariant for Step 11.
    func testAlternatingActivation_mruOrderStaysConsistent() {
        let a: CGWindowID = 100
        let b: CGWindowID = 200
        var order: [CGWindowID] = []
        let cap = 200

        // First: user activates A
        order = WindowStore.movedToFront(a, in: order, cap: cap)
        XCTAssertEqual(order.first, a)

        // Then: user activates B (e.g. via switcher choosing index 1)
        order = WindowStore.movedToFront(b, in: order, cap: cap)
        XCTAssertEqual(order, [b, a])

        // Now enumerate returns [b, a, ...]; index 1 = a → press-once-release goes to A.
        let sorted1 = WindowStore.sortedByMRU(windowIDs: [a, b], mruOrder: order)
        XCTAssertEqual(sorted1, [b, a])  // index 0=b (current), index 1=a (previous)

        // User activates A again
        order = WindowStore.movedToFront(a, in: order, cap: cap)
        XCTAssertEqual(order, [a, b])

        let sorted2 = WindowStore.sortedByMRU(windowIDs: [a, b], mruOrder: order)
        XCTAssertEqual(sorted2, [a, b])  // index 0=a (current), index 1=b (previous)
    }
}
