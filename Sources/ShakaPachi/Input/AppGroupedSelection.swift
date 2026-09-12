// AppGroupedSelection.swift
// Pure cursor logic for app-unit switcher mode: how the keyboard cursor moves
// across an AppGroupedLayout derived from a flat window snapshot.
//
// No AppKit or CoreGraphics dependency (beyond what AppGroupedModel already
// pulls in) — fully unit-testable, same spirit as SwitcherStateMachine.

import Foundation

// MARK: - AppGroupedSelection

/// Cursor over an app-grouped view of a flat window snapshot.
///
/// `AppGroup.windowIndices` are indices into the snapshot the coordinator
/// already took, so this type never copies window data — it only tracks
/// *where* the cursor is. Resolving a selection back to a flat index
/// (`flatIndex`) is all that is needed to hand off to the existing
/// activation path.
///
/// Lifetime: one instance covers one switcher session. The per-app memory
/// described below lives only as long as the instance does.
struct AppGroupedSelection {

    // MARK: - State

    private let groups: [AppGroup]

    /// Index into `groups` for the app currently focused.
    private(set) var appIndex: Int

    /// Position within `groups[appIndex].windowIndices` — a group-relative
    /// index, not a flat one. Keeping it group-relative (rather than flat) is
    /// what lets each app's cursor be saved and restored independently of
    /// where its windows happen to sit in the flat snapshot.
    private(set) var windowIndex: Int

    private(set) var focusRow: SwitcherFocusRow

    /// Left edge of the visible strip for the current group.
    /// Slides by the minimum amount needed to keep `windowIndex` on screen;
    /// see `slideStripToShowWindowIndex()`.
    private var stripStart: Int

    /// Per-app memory of `(windowIndex, stripStart)`, keyed by
    /// `AppGroup.key`. Leaving a group snapshots its cursor here; returning
    /// restores it, so tabbing away and back does not lose the user's place.
    /// Scoped to this instance only — nothing here outlives one session.
    private var memory: [String: (windowIndex: Int, stripStart: Int)] = [:]

    // MARK: - Init

    /// - Parameters:
    ///   - groups: The app-grouped view to navigate, as produced by `groups(from:)`.
    ///   - flatIndex: The snapshot index to start the cursor on.
    ///     Falls back to the first group's first window (0, 0) when `groups`
    ///     is empty or `flatIndex` is not present in any group.
    init(groups: [AppGroup], flatIndex: Int) {
        self.groups = groups
        guard !groups.isEmpty else {
            appIndex = 0
            windowIndex = 0
            stripStart = 0
            focusRow = .app
            return
        }

        var located: (appIndex: Int, windowIndex: Int)?
        for (index, group) in groups.enumerated() {
            if let windowIndex = group.windowIndices.firstIndex(of: flatIndex) {
                located = (index, windowIndex)
                break
            }
        }

        appIndex = located?.appIndex ?? 0
        windowIndex = located?.windowIndex ?? 0
        stripStart = 0
        focusRow = .app
        adoptFocusRowForCurrentGroup()
        slideStripToShowWindowIndex()
    }

    // MARK: - Grouping

    /// Group a flat window snapshot by app.
    ///
    /// Groups are ordered by first appearance in `windows` (the position of
    /// each app's first window), and windows keep their relative order within
    /// their group. This mirrors `WindowStore.sortedByAppMRU`'s grouping loop
    /// — same key (`AppGroup.key`), same first-seen ordering — so app-unit
    /// mode groups the snapshot exactly the way that sort mode already does.
    /// `windowIndices` are indices into `windows`; no empty group is ever
    /// produced because a group only exists once a window has created it.
    static func groups(from windows: [WindowInfo]) -> [AppGroup] {
        guard !windows.isEmpty else { return [] }

        var order: [String] = []
        var indices: [String: [Int]] = [:]
        var appName: [String: String] = [:]
        var bundleID: [String: String?] = [:]
        var pid: [String: pid_t] = [:]

        for (index, window) in windows.enumerated() {
            let key = AppGroup.key(bundleID: window.bundleID, appName: window.appName)
            if indices[key] == nil {
                order.append(key)
                appName[key] = window.appName
                bundleID[key] = window.bundleID
                pid[key] = window.pid
            }
            indices[key, default: []].append(index)
        }

        return order.map { key in
            AppGroup(
                appName: appName[key] ?? key,
                bundleID: bundleID[key] ?? nil,
                pid: pid[key] ?? 0,
                windowIndices: indices[key] ?? []
            )
        }
    }

    // MARK: - Read-only accessors

    var currentGroup: AppGroup? {
        groups.indices.contains(appIndex) ? groups[appIndex] : nil
    }

    /// The flat snapshot index the cursor currently resolves to.
    ///
    /// Always derived from `windowIndex`, never from `focusRow`: a group
    /// that has just been entered has `windowIndex == 0`, i.e. its frontmost
    /// window, so this resolves correctly with no row-specific branching. Not
    /// branching by row also guarantees the on-screen highlight and the
    /// activation target never disagree — whichever row the rim is drawn on,
    /// releasing the trigger activates what `flatIndex` points at.
    var flatIndex: Int? {
        guard let group = currentGroup, group.windowIndices.indices.contains(windowIndex) else {
            return nil
        }
        return group.windowIndices[windowIndex]
    }

    /// The slice of the current group's windows currently on screen.
    var strip: WindowStrip {
        guard let group = currentGroup else {
            return WindowStrip(visible: [], hiddenLeft: 0, hiddenRight: 0)
        }
        let count = group.windowIndices.count
        let maxVisible = AppGroupedLayout.maxVisibleWindows
        let end = min(stripStart + maxVisible, count)
        let visible = Array(group.windowIndices[stripStart..<end])
        return WindowStrip(
            visible: visible,
            hiddenLeft: stripStart,
            hiddenRight: count - (stripStart + visible.count)
        )
    }

    // MARK: - Mutating operations

    /// Move to the next app group, wrapping past the last back to the first.
    mutating func nextApp() {
        moveToApp(offsetBy: 1)
    }

    /// Move to the previous app group, wrapping past the first to the last.
    mutating func previousApp() {
        moveToApp(offsetBy: -1)
    }

    /// `.app` row: same as `nextApp()`/`previousApp()` (wraps).
    /// `.window` row: moves `windowIndex` within the current group and stops
    /// at the edges. Windows deliberately do not wrap — wrapping there would
    /// let a fast repeated key press fling the cursor from the last pane
    /// straight back to the first with no visual cue that it looped, which
    /// the app row's wrap (a full step to a new tile) does not risk.
    mutating func moveWithinRow(forward: Bool) {
        switch focusRow {
        case .app:
            if forward {
                nextApp()
            } else {
                previousApp()
            }
        case .window:
            guard let group = currentGroup else { return }
            let newIndex = forward ? windowIndex + 1 : windowIndex - 1
            guard group.windowIndices.indices.contains(newIndex) else { return }
            windowIndex = newIndex
            slideStripToShowWindowIndex()
        }
    }

    /// Drop focus into the window row, but only when there is more than one
    /// window to navigate between — with a single window the row would have
    /// nowhere to move, so staying on `.app` keeps the row switch meaningful.
    mutating func descend() {
        guard let group = currentGroup, group.windowIndices.count >= 2 else { return }
        focusRow = .window
    }

    /// Return focus to the app row.
    mutating func ascend() {
        focusRow = .app
    }

    /// Select the `ordinal`-th (1-based) pane currently visible in `strip`.
    ///
    /// - Returns: `true` and updates the cursor (`windowIndex`, `focusRow`)
    ///   on success. `false` with no state change when `ordinal` is outside
    ///   `1...strip.visible.count`.
    @discardableResult
    mutating func selectVisible(_ ordinal: Int) -> Bool {
        let visibleCount = strip.visible.count
        guard ordinal >= 1, ordinal <= visibleCount else { return false }
        windowIndex = stripStart + (ordinal - 1)
        focusRow = .window
        slideStripToShowWindowIndex()
        return true
    }

    // MARK: - Internal helpers

    private mutating func moveToApp(offsetBy offset: Int) {
        guard groups.count > 1 else { return }
        saveMemoryForCurrentGroup()
        appIndex = (appIndex + offset + groups.count) % groups.count
        restoreMemoryForCurrentGroup()
        adoptFocusRowForCurrentGroup()
    }

    /// Put the cursor on the row the group actually has something to offer.
    ///
    /// Landing on a multi-window app focuses its strip rather than the app
    /// tile, so the arrows and the direct-jump shortcuts act on windows the
    /// moment the app is reached. Requiring a separate keystroke to descend
    /// made every visit to a multi-window app cost one extra press, which is
    /// the opposite of what expanding the strip is for. `ascend()` still moves
    /// back up deliberately; this only decides where arriving puts you.
    private mutating func adoptFocusRowForCurrentGroup() {
        guard let group = currentGroup else {
            focusRow = .app
            return
        }
        focusRow = group.windowIndices.count >= 2 ? .window : .app
    }

    private mutating func saveMemoryForCurrentGroup() {
        guard let group = currentGroup else { return }
        let key = AppGroup.key(bundleID: group.bundleID, appName: group.appName)
        memory[key] = (windowIndex: windowIndex, stripStart: stripStart)
    }

    private mutating func restoreMemoryForCurrentGroup() {
        guard let group = currentGroup else {
            windowIndex = 0
            stripStart = 0
            return
        }
        let key = AppGroup.key(bundleID: group.bundleID, appName: group.appName)
        if let remembered = memory[key], group.windowIndices.indices.contains(remembered.windowIndex) {
            windowIndex = remembered.windowIndex
            stripStart = remembered.stripStart
        } else {
            windowIndex = 0
            stripStart = 0
        }
        slideStripToShowWindowIndex()
    }

    /// Slide `stripStart` by the minimum amount needed to keep `windowIndex`
    /// inside the visible window, then clamp so the strip never scrolls past
    /// the group's edges. Called after every change to `windowIndex`.
    private mutating func slideStripToShowWindowIndex() {
        guard let group = currentGroup else {
            stripStart = 0
            return
        }
        let count = group.windowIndices.count
        let maxVisible = AppGroupedLayout.maxVisibleWindows
        if windowIndex < stripStart {
            stripStart = windowIndex
        } else if windowIndex >= stripStart + maxVisible {
            stripStart = windowIndex - (maxVisible - 1)
        }
        stripStart = min(max(stripStart, 0), max(0, count - maxVisible))
    }
}
