// StreakStatsTests.swift
// Verifies: thresholds compute correct percentiles, level mapping covers 0–4.

import XCTest

@testable import ShakaPachi

final class StreakStatsTests: XCTestCase {

    // MARK: - thresholds

    func testThresholds_emptyInput_returnsDefault() {
        let t = StreakStats.thresholds(for: [])
        XCTAssertEqual(t.0, 1)
        XCTAssertEqual(t.1, 2)
        XCTAssertEqual(t.2, 3)
    }

    func testThresholds_allSameNonZero_noAllocation() {
        // All values equal — still returns valid thresholds without crash.
        let t = StreakStats.thresholds(for: [5, 5, 5, 5])
        XCTAssertEqual(t.0, 5)
        XCTAssertEqual(t.1, 5)
        XCTAssertEqual(t.2, 5)
    }

    func testThresholds_heavyDistribution_differentLevels() {
        let counts = [50, 100, 150, 200, 250, 300, 350, 400, 450, 500]
        let t = StreakStats.thresholds(for: counts)
        // p25 < p50 < p75 must hold for a spread distribution.
        XCTAssertLessThanOrEqual(t.0, t.1, "p25 must be <= p50")
        XCTAssertLessThanOrEqual(t.1, t.2, "p50 must be <= p75")
        XCTAssertLessThan(t.0, t.2, "p25 and p75 must differ for a spread distribution")
    }

    func testThresholds_zeroCountsExcluded() {
        // Only non-zero values should participate.
        let t = StreakStats.thresholds(for: [0, 0, 0, 10, 20])
        // p25 of [10, 20] = 10
        XCTAssertEqual(t.0, 10)
    }

    // MARK: - level

    func testLevel_zeroCount_isZero() {
        let t = (1, 2, 3)
        XCTAssertEqual(StreakStats.level(for: 0, thresholds: t), 0)
    }

    func testLevel_belowP25_isOne() {
        let t = (10, 20, 30)
        XCTAssertEqual(StreakStats.level(for: 5, thresholds: t), 1)
        XCTAssertEqual(StreakStats.level(for: 10, thresholds: t), 1)
    }

    func testLevel_betweenP25andP50_isTwo() {
        let t = (10, 20, 30)
        XCTAssertEqual(StreakStats.level(for: 11, thresholds: t), 2)
        XCTAssertEqual(StreakStats.level(for: 20, thresholds: t), 2)
    }

    func testLevel_betweenP50andP75_isThree() {
        let t = (10, 20, 30)
        XCTAssertEqual(StreakStats.level(for: 21, thresholds: t), 3)
        XCTAssertEqual(StreakStats.level(for: 30, thresholds: t), 3)
    }

    func testLevel_aboveP75_isFour() {
        let t = (10, 20, 30)
        XCTAssertEqual(StreakStats.level(for: 31, thresholds: t), 4)
        XCTAssertEqual(StreakStats.level(for: 1000, thresholds: t), 4)
    }

}
