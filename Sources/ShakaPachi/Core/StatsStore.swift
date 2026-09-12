// StatsStore.swift
// Lightweight switch-count statistics, persisted to UserDefaults.
//
// Design notes:
// - Backed by an injected UserDefaults so tests can isolate state cleanly.
// - todayCount resets at the local calendar midnight; comparison is done by
//   the "yyyy-MM-dd" string in the local timezone to avoid UTC skew.
// - Does NOT post .settingsDidChange — stats are decoupled from the settings
//   broadcast so observers don't redraw on every switch.
// - Stores only aggregate integers and a date string — never which apps or
//   windows were visited (privacy by design).

import Foundation

@MainActor
final class StatsStore {

    // MARK: - UserDefaults keys

    private enum Key {
        static let totalCount = "statsTotalCount"
        static let todayCount = "statsTodayCount"
        static let todayDate = "statsTodayDate"
        static let statsDailyCounts = "statsDailyCounts"
        static let statsFirstUseDate = "statsFirstUseDate"
        static let statsEnabled = "statsEnabled"
    }

    // MARK: - Backing store

    // nonisolated(unsafe) mirrors the pattern in Settings: StatsStore is
    // @MainActor-isolated, so all access happens on the main thread.
    // UserDefaults is thread-safe for simple reads/writes.
    nonisolated(unsafe) private let defaults: UserDefaults

    // MARK: - Shared instance

    /// The single production instance, backed by UserDefaults.standard.
    /// AppDelegate and SettingsWindow both read from this so they see the same counts.
    static let shared = StatsStore()

    // MARK: - Init

    /// Creates a StatsStore backed by the given UserDefaults.
    /// - Parameter defaults: Pass `.standard` in production; pass a test
    ///   suite in unit tests to avoid polluting the real domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Public properties

    /// Lifetime switch count, persisted across launches.
    var totalCount: Int {
        defaults.integer(forKey: Key.totalCount)
    }

    #if DEBUG
        /// Developer-only, in-memory (non-persistent) override for previewing how the
        /// patina accent evolves at different lifetime counts. nil = use the real count.
        /// Never written to UserDefaults — the real statistics are left untouched.
        var previewTotalCountOverride: Int?
    #endif

    /// Count used for accent-color resolution. Release builds always return the real
    /// lifetime count; debug builds honor a developer preview override when set.
    var effectiveTotalCount: Int {
        #if DEBUG
            if let override = previewTotalCountOverride { return override }
        #endif
        return totalCount
    }

    /// Switches counted today (local calendar day). Resets at midnight.
    var todayCount: Int {
        defaults.integer(forKey: Key.todayCount)
    }

    #if DEBUG
        /// Developer-only, in-memory (non-persistent) override for previewing the
        /// today count. nil = use the real count. Never written to UserDefaults —
        /// the real statistics are left untouched.
        var previewTodayCountOverride: Int?
    #endif

    /// Count used for the today display. Release builds always return the real
    /// today count; debug builds honor a developer preview override when set.
    var effectiveTodayCount: Int {
        #if DEBUG
            if let override = previewTodayCountOverride { return override }
        #endif
        return todayCount
    }

    /// Per-day switch counts keyed by "yyyy-MM-dd". Empty dict if no data.
    var dailyCounts: [String: Int] {
        guard let raw = defaults.dictionary(forKey: Key.statsDailyCounts) else { return [:] }
        var result: [String: Int] = [:]
        for (key, value) in raw {
            if let count = value as? Int {
                result[key] = count
            }
        }
        return result
    }

    /// ISO date string (yyyy-MM-dd) of the first recorded switch, or nil if no records yet.
    var firstUseDate: String? {
        defaults.string(forKey: Key.statsFirstUseDate)
    }

    /// Whether stats recording is enabled. Defaults to true when key is absent.
    var isStatsEnabled: Bool {
        defaults.object(forKey: Key.statsEnabled) != nil
            ? defaults.bool(forKey: Key.statsEnabled)
            : true
    }

    // MARK: - Public API

    /// Enable or disable stats recording.
    func setStatsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.statsEnabled)
    }

    /// Reset all statistics. Sets firstUseDate to the reset date.
    func reset(now: Date = Date()) {
        defaults.removeObject(forKey: Key.totalCount)
        defaults.removeObject(forKey: Key.todayCount)
        defaults.removeObject(forKey: Key.todayDate)
        defaults.removeObject(forKey: Key.statsDailyCounts)
        defaults.set(StreakStats.stringFromDate(now), forKey: Key.statsFirstUseDate)
    }

    /// Record one window switch at the given instant.
    ///
    /// - Parameter now: The current time. Defaults to `Date()`.
    ///   Pass a synthetic date in tests to verify day-rollover behaviour.
    func recordSwitch(now: Date = Date()) {
        guard isStatsEnabled else { return }

        let today = StreakStats.stringFromDate(now)
        let storedDate = defaults.string(forKey: Key.todayDate) ?? ""

        // Reset the daily counter when the calendar day has changed.
        if storedDate != today {
            defaults.set(0, forKey: Key.todayCount)
            defaults.set(today, forKey: Key.todayDate)
        }

        let newToday = defaults.integer(forKey: Key.todayCount) + 1
        let newTotal = defaults.integer(forKey: Key.totalCount) + 1
        defaults.set(newToday, forKey: Key.todayCount)
        defaults.set(newTotal, forKey: Key.totalCount)

        // Set firstUseDate on the very first switch.
        if defaults.string(forKey: Key.statsFirstUseDate) == nil {
            defaults.set(today, forKey: Key.statsFirstUseDate)
        }

        // Accumulate per-day counts.
        var d = dailyCounts
        d[today, default: 0] += 1
        defaults.set(d, forKey: Key.statsDailyCounts)
    }

}
