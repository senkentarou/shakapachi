// StatsStoreTests.swift
// Verifies: first record, accumulation on the same day, day-rollover resets
// todayCount while total keeps climbing, and cross-instance persistence.
//
// Each test injects a fresh UserDefaults suite (unique name) to stay isolated
// from other tests and from UserDefaults.standard. The suite is removed in
// teardown so the filesystem stays clean.

import XCTest

@testable import ShakaPachi

@MainActor
final class StatsStoreTests: XCTestCase {

    // MARK: - Helpers

    private var suiteName: String = ""
    private var defaults: UserDefaults!

    /// Creates a fresh UserDefaults suite and a StatsStore backed by it.
    private func makeStore() -> StatsStore {
        StatsStore(defaults: defaults)
    }

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.shakapachi.tests.StatsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - (a) First record → today=1, total=1

    func testFirstRecord_todayAndTotalBothOne() {
        let store = makeStore()
        store.recordSwitch()
        XCTAssertEqual(store.todayCount, 1, "todayCount should be 1 after the first switch")
        XCTAssertEqual(store.totalCount, 1, "totalCount should be 1 after the first switch")
    }

    // MARK: - (b) Several records on the same day accumulate both counters

    func testSameDay_countersAccumulate() {
        let store = makeStore()
        let today = Date()
        store.recordSwitch(now: today)
        store.recordSwitch(now: today)
        store.recordSwitch(now: today)
        XCTAssertEqual(store.todayCount, 3, "todayCount should accumulate across same-day records")
        XCTAssertEqual(store.totalCount, 3, "totalCount should accumulate across same-day records")
    }

    // MARK: - (c) A record on a later calendar day resets todayCount but not totalCount

    func testDayRollover_resetsToday_keepsTotal() {
        let store = makeStore()

        // Record three switches "today" (2026-07-20).
        let today = date(year: 2026, month: 7, day: 20)
        store.recordSwitch(now: today)
        store.recordSwitch(now: today)
        store.recordSwitch(now: today)
        XCTAssertEqual(store.todayCount, 3)
        XCTAssertEqual(store.totalCount, 3)

        // Record one switch "tomorrow" (2026-07-21) — triggers a day rollover.
        let tomorrow = date(year: 2026, month: 7, day: 21)
        store.recordSwitch(now: tomorrow)

        XCTAssertEqual(
            store.todayCount, 1,
            "todayCount must reset to 1 after a calendar day change")
        XCTAssertEqual(
            store.totalCount, 4,
            "totalCount must continue climbing across day boundaries")
    }

    // MARK: - (d) Values persist across a new StatsStore instance on the same suite

    func testPersistence_acrossInstances() {
        let store1 = makeStore()
        store1.recordSwitch()
        store1.recordSwitch()

        // Create a second instance backed by the same UserDefaults suite.
        let store2 = makeStore()
        XCTAssertEqual(
            store2.todayCount, 2,
            "todayCount must survive across a new StatsStore instance")
        XCTAssertEqual(
            store2.totalCount, 2,
            "totalCount must survive across a new StatsStore instance")
    }

    // MARK: - (e) dailyCounts accumulates per day

    func testDailyCounts_accumulatesPerDay() {
        let store = makeStore()
        let day1 = date(year: 2026, month: 7, day: 20)
        let day2 = date(year: 2026, month: 7, day: 21)
        store.recordSwitch(now: day1)
        store.recordSwitch(now: day1)
        store.recordSwitch(now: day2)
        let counts = store.dailyCounts
        let key1 = StreakStats.stringFromDate(day1)
        let key2 = StreakStats.stringFromDate(day2)
        XCTAssertEqual(counts[key1], 2, "day1 should have 2 switches")
        XCTAssertEqual(counts[key2], 1, "day2 should have 1 switch")
    }

    // MARK: - (f) firstUseDate is set on first record and unchanged afterwards

    func testFirstUseDate_setOnFirstRecord_unchangedAfter() {
        let store = makeStore()
        let day1 = date(year: 2026, month: 7, day: 20)
        let day2 = date(year: 2026, month: 7, day: 21)
        store.recordSwitch(now: day1)
        let first = store.firstUseDate
        XCTAssertNotNil(first, "firstUseDate must be set after first record")
        store.recordSwitch(now: day2)
        XCTAssertEqual(store.firstUseDate, first, "firstUseDate must not change after subsequent records")
    }

    // MARK: - (g) isStatsEnabled defaults to true

    func testIsStatsEnabled_defaultsToTrue() {
        let store = makeStore()
        XCTAssertTrue(store.isStatsEnabled, "isStatsEnabled should default to true")
    }

    // MARK: - (h) When disabled, recordSwitch does not count

    func testSetStatsEnabled_false_recordSwitchIgnored() {
        let store = makeStore()
        store.setStatsEnabled(false)
        store.recordSwitch(now: date(year: 2026, month: 7, day: 21))
        XCTAssertEqual(store.totalCount, 0, "totalCount must not increment when stats disabled")
        XCTAssertEqual(store.dailyCounts.values.reduce(0, +), 0, "dailyCounts must not accumulate when stats disabled")
    }

    // MARK: - (i) reset clears all data and sets firstUseDate to reset date

    func testReset_clearsAllAndSetsFirstUseDate() {
        let store = makeStore()
        let day1 = date(year: 2026, month: 7, day: 20)
        store.recordSwitch(now: day1)
        store.recordSwitch(now: day1)
        XCTAssertEqual(store.totalCount, 2)

        let resetDay = date(year: 2026, month: 7, day: 21)
        store.reset(now: resetDay)

        XCTAssertEqual(store.totalCount, 0, "totalCount must be 0 after reset")
        XCTAssertEqual(store.todayCount, 0, "todayCount must be 0 after reset")
        XCTAssertTrue(store.dailyCounts.isEmpty, "dailyCounts must be empty after reset")
        let expectedFirstUse = StreakStats.stringFromDate(resetDay)
        XCTAssertEqual(
            store.firstUseDate, expectedFirstUse,
            "firstUseDate must be set to the reset date")
    }

    // MARK: - Private helpers

    /// Build a Date in the local timezone for a specific calendar date.
    private func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12  // Midday — avoids any edge case around midnight.
        comps.minute = 0
        comps.second = 0
        return Calendar.current.date(from: comps)!
    }
}
