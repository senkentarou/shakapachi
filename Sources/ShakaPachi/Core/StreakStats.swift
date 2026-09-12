// StreakStats.swift
// Pure functions for computing heatmap thresholds and level from daily switch counts.
// AppKit-independent and @MainActor-free so they are easily unit-tested.

import Foundation

enum StreakStats {

    // MARK: - Thresholds

    /// Compute relative-scale thresholds (p25, p50, p75) from an array of counts.
    ///
    /// Only non-zero values participate so that inactive days don't compress the scale.
    /// Returns (1, 2, 3) when there are no active days to avoid division by zero.
    static func thresholds(for counts: [Int]) -> (Int, Int, Int) {
        let active = counts.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return (1, 2, 3) }
        func percentile(_ p: Double) -> Int {
            // Nearest-rank method.
            let idx = max(0, Int(ceil(p * Double(active.count))) - 1)
            return active[min(idx, active.count - 1)]
        }
        return (percentile(0.25), percentile(0.50), percentile(0.75))
    }

    // MARK: - Level

    /// Map a switch count to a display level 0–4.
    ///
    /// - 0: no activity
    /// - 1–4: increasing intensity based on relative thresholds
    static func level(for count: Int, thresholds t: (Int, Int, Int)) -> Int {
        guard count > 0 else { return 0 }
        if count <= t.0 { return 1 }
        if count <= t.1 { return 2 }
        if count <= t.2 { return 3 }
        return 4
    }

    // MARK: - Private helpers

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.calendar = Calendar.current
        return f
    }()

    static func dateFromString(_ s: String) -> Date? {
        formatter.date(from: s)
    }

    static func stringFromDate(_ d: Date) -> String {
        formatter.string(from: d)
    }
}
