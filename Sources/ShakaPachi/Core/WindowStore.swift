import AppKit
import CoreGraphics
import Foundation

// WindowStore enumerates on-screen windows via a single CGWindowListCopyWindowInfo
// call and applies filters for layer, visibility, size, process, and store type.
//
// Testability: the heavy lifting (raw dict array → [WindowInfo]) lives in the
// static `filterAndBuild` method which accepts [[String: Any]] so unit tests
// can supply hand-built fixtures without TCC permissions.
// The MRU pure helpers (sortedByMRU, movedToFront, adoptingFrontmost) are also
// static so tests can exercise them without any AppKit or TCC calls.
//
// Concurrency: the class is @MainActor because all callers (AppDelegate, the
// NSWorkspace notification handler) run on the main thread. This satisfies Swift
// 6 strict concurrency without requiring Sendable conformances on NSWorkspace
// observation internals.
@MainActor
final class WindowStore {

    // Bundle IDs to exclude from enumeration results.
    // Live-updatable: AppDelegate updates this from Settings on every change.
    // MRU state is preserved across updates (mruOrder is NOT cleared).
    var excludedBundleIDs: Set<String>

    // Per-instance pid → bundleID cache.  Avoids repeated NSRunningApplication
    // lookups across consecutive enumerate() calls.
    private var bundleIDCache: [pid_t: String?] = [:]

    // Persistent MRU ordering for the lifetime of the process.
    // Index 0 = most recently used window.
    // Never exceeds mruCap entries; tail entries are evicted when the cap is hit.
    private var mruOrder: [CGWindowID] = []
    private let mruCap = 200

    // Retained token for the NSWorkspace activation observer so it can be
    // removed in deinit and avoids a dangling closure after deallocation.
    private var workspaceObserver: (any NSObjectProtocol)?

    init(excludedBundleIDs: Set<String> = []) {
        self.excludedBundleIDs = excludedBundleIDs
        subscribeToWorkspaceActivations()
    }

    deinit {
        if let token = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Public interface

    /// Enumerate on-screen windows and return filtered, title-resolved results
    /// sorted according to the given `sortMode`.
    ///
    /// - Parameters:
    ///   - currentSpaceOnly: When `true` (default) only windows on the current
    ///     Space are included (.optionOnScreenOnly). Pass `false` to use
    ///     .optionAll and include every space.
    ///   - sortMode: How the result list is ordered. Defaults to `.mru`.
    func enumerate(currentSpaceOnly: Bool = true, sortMode: SortMode = .mru) -> [WindowInfo] {
        // currentSpaceOnly == true is the default and hot path: query only the
        // current Space via .optionOnScreenOnly — zero private-API cost.
        // currentSpaceOnly == false: use .optionAll to capture all Spaces, then
        // refine with SpacesEnumerator (private SkyLight) if available. Falls back
        // to the raw .optionAll result if the private call is unavailable.
        let option: CGWindowListOption =
            currentSpaceOnly
            ? .optionOnScreenOnly
            : .optionAll
        // Single CGWindowListCopyWindowInfo call.
        guard
            let rawList = CGWindowListCopyWindowInfo(option, kCGNullWindowID)
                as? [[String: Any]]
        else {
            return []
        }
        var filtered = WindowStore.filterAndBuild(
            rawList: rawList,
            selfPID: getpid(),
            excludedBundleIDs: excludedBundleIDs,
            bundleIDResolver: { [weak self] pid in self?.resolvedBundleID(for: pid) }
        )

        // When enumerating all Spaces, apply the SkyLight-based Space filter to
        // remove off-Space compositing artefacts that .optionAll includes.
        // This is the upgrade over the previous ".optionAll | .optionOnScreenOnly"
        // approach which gave no Space attribution and missed many other-Space windows.
        // If SpacesEnumerator returns nil (private APIs unavailable), keep filtered as-is.
        if !currentSpaceOnly, let allowedIDs = SpacesEnumerator.allSpaceWindowIDs() {
            filtered = SpacesEnumerator.filterToAllowedIDs(filtered, allowedIDs: allowedIDs)
        }

        // Adopt the frontmost window into mruOrder before sorting.  This makes
        // enumerate() deliberately mutate MRU state, because the activation
        // paths that feed mruOrder (switcher confirm + didActivateApplication)
        // miss several ways a window comes to the front: switching windows
        // within one app posts no activation notification, and a freshly
        // launched app has no window yet when its notification fires.  A window
        // that was never recorded would otherwise stay unknown indefinitely no
        // matter how recently it was used.  Reading the z-order top here
        // self-heals those misses and guarantees index 0 is the current window
        // — the assumption press-once-release is built on (SwitcherStateMachine
        // opens the panel at index 1).
        mruOrder = WindowStore.adoptingFrontmost(
            windowIDs: filtered.map { $0.windowID },
            order: mruOrder,
            cap: mruCap
        )

        switch sortMode {
        case .mru:
            // Sort by mruOrder; unknowns spliced in at their z-order position.
            let sortedIDs = WindowStore.sortedByMRU(
                windowIDs: filtered.map { $0.windowID },
                mruOrder: mruOrder
            )
            let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.windowID, $0) })
            return sortedIDs.compactMap { byID[$0] }
        case .byApp:
            // Group windows by app and order groups by app display name (ascending),
            // keeping MRU order within each group.
            let sortedByMRU = {
                let sortedIDs = WindowStore.sortedByMRU(
                    windowIDs: filtered.map { $0.windowID },
                    mruOrder: mruOrder
                )
                let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.windowID, $0) })
                return sortedIDs.compactMap { byID[$0] }
            }()
            return WindowStore.sortedByApp(windows: sortedByMRU)
        case .byAppMRU:
            // Group windows by app and order groups by the app's recency (MRU),
            // keeping MRU order within each group.
            let sortedByMRU = {
                let sortedIDs = WindowStore.sortedByMRU(
                    windowIDs: filtered.map { $0.windowID },
                    mruOrder: mruOrder
                )
                let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.windowID, $0) })
                return sortedIDs.compactMap { byID[$0] }
            }()
            return WindowStore.sortedByAppMRU(windows: sortedByMRU)
        }
    }

    /// Record that `windowID` was just activated (switcher confirmed).
    /// Moves the ID to the front of `mruOrder`.
    /// Call this immediately after `Activator.activate()` on `.confirmSelection`.
    func recordActivation(_ windowID: CGWindowID) {
        mruOrder = WindowStore.movedToFront(windowID, in: mruOrder, cap: mruCap)
    }

    // MARK: - NSWorkspace activation observation

    /// Subscribe to NSWorkspace app-activation events so that windows brought
    /// to the front by means other than the switcher are also tracked.
    private func subscribeToWorkspaceActivations() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main  // always main — safe to mutate mruOrder directly
        ) { [weak self] notification in
            // Use Task { @MainActor in … } to re-enter the MainActor-isolated
            // context from the NotificationCenter closure, which itself arrives
            // on .main OperationQueue but is not automatically @MainActor under
            // Swift 6 strict concurrency.
            Task { @MainActor [weak self] in
                self?.handleAppActivation(notification: notification)
            }
        }
    }

    /// Handle a didActivateApplicationNotification: find the frontmost on-screen
    /// window for the newly activated app's pid and move it to the front of mruOrder.
    private func handleAppActivation(notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        let activatedPID = app.processIdentifier

        // Lightweight CGWindowList query to find the frontmost window of the
        // activated app.  We query on-screen-only (current space) so z-order
        // reflects the visible stack.  Using a fresh query rather than the last
        // enumerate snapshot avoids stale data when the user switches apps
        // between switcher invocations.
        guard
            let rawList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]]
        else { return }

        // The first entry whose ownerPID matches and that passes the basic
        // layer/alpha/size filters is the frontmost window.
        for dict in rawList {
            guard let pidNum = dict[kCGWindowOwnerPID as String] as? Int32,
                pid_t(pidNum) == activatedPID
            else { continue }
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let alpha = dict[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
            guard let wid = dict[kCGWindowNumber as String] as? CGWindowID else { continue }
            mruOrder = WindowStore.movedToFront(wid, in: mruOrder, cap: mruCap)
            return
        }
        // If no on-screen window was found for the pid (e.g. all minimized),
        // do nothing — the mruOrder stays as-is.
    }

    // MARK: - Bundle ID cache

    /// Resolve bundleID for a pid, consulting the in-instance cache first.
    private func resolvedBundleID(for pid: pid_t) -> String? {
        if let cached = bundleIDCache[pid] {
            return cached
        }
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        bundleIDCache[pid] = id
        return id
    }

    // MARK: - Pure sort helpers (unit-testable without AppKit/CGWindowList)

    /// Return windows grouped by app, with groups ordered by app display name
    /// (case-insensitive ascending), preserving the relative order of windows
    /// within each group.
    ///
    /// Groups are sorted by the app's display name using
    /// `localizedCaseInsensitiveCompare`. When two apps have the same display
    /// name, the bundle-ID / app-name key is used as a deterministic tiebreaker.
    /// This order is stable and independent of recency — unlike MRU, switching
    /// apps does not reorder groups.
    ///
    /// - Parameter windows: The input window list (pre-sorted by MRU or z-order).
    /// - Returns: The same windows reordered so all windows of each app are
    ///   contiguous, with inter-app order sorted alphabetically by app display name.
    nonisolated static func sortedByApp(windows: [WindowInfo]) -> [WindowInfo] {
        // Group windows by app (bundleID when available, else appName), then order
        // the groups by app display name (case-insensitive, ascending) so the list
        // is stable regardless of recency — unlike MRU, which reorders by last use.
        // Windows keep their input order within each group (MRU when called from
        // enumerate).
        var grouped: [String: [WindowInfo]] = [:]
        var displayName: [String: String] = [:]
        for window in windows {
            let key = window.bundleID ?? window.appName
            grouped[key, default: []].append(window)
            if displayName[key] == nil { displayName[key] = window.appName }
        }
        let orderedKeys = grouped.keys.sorted { a, b in
            let cmp = (displayName[a] ?? a).localizedCaseInsensitiveCompare(displayName[b] ?? b)
            return cmp == .orderedSame ? a < b : cmp == .orderedAscending
        }
        return orderedKeys.flatMap { grouped[$0] ?? [] }
    }

    /// Return windows grouped by app, with groups ordered by the app's recency
    /// (MRU), preserving the relative order of windows within each group.
    ///
    /// The input is assumed to be already MRU-sorted (as produced by
    /// `sortedByMRU` in `enumerate`). Because the most recently used windows come
    /// first, the first appearance of each app key marks that app's recency rank:
    /// grouping by first-seen order therefore yields "most recently used app"
    /// group order. Unlike `sortedByApp`, which orders groups alphabetically by
    /// display name, this order follows recency — switching apps reorders groups.
    ///
    /// - Parameter windows: The input window list, pre-sorted by MRU.
    /// - Returns: The same windows reordered so all windows of each app are
    ///   contiguous, with inter-app order following the app's MRU (first-seen) rank.
    nonisolated static func sortedByAppMRU(windows: [WindowInfo]) -> [WindowInfo] {
        var grouped: [String: [WindowInfo]] = [:]
        var order: [String] = []
        for window in windows {
            let key = window.bundleID ?? window.appName
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(window)
        }
        return order.flatMap { grouped[$0] ?? [] }
    }

    // MARK: - Pure MRU helpers (unit-testable without AppKit/CGWindowList)

    /// Return window IDs sorted by MRU order.
    ///
    /// IDs that appear in `mruOrder` are ordered by that sequence. IDs missing
    /// from `mruOrder` ("unknown") are placed by their z-order position rather
    /// than being pushed to the end: an unknown window is inserted directly in
    /// front of the nearest known window that sits behind it in z-order, because
    /// being in front of that window implies it was used more recently.  Only
    /// unknowns with no known window behind them go to the end.  Unknowns keep
    /// their relative z-order.
    ///
    /// Treating z-order as an approximation of recency is the same assumption
    /// this function already makes when `mruOrder` is empty (z-order is returned
    /// unchanged).  It matters because `mruOrder` is recorded on a best-effort
    /// basis: a window the user is actively using may never have been recorded
    /// (see `enumerate`), and appending such a window after every stale entry
    /// would rank the most recent window last.
    ///
    /// - Parameters:
    ///   - windowIDs: The IDs of on-screen windows in z-order (index 0 = front).
    ///   - mruOrder: The current MRU sequence (index 0 = most recently used).
    /// - Returns: The same IDs reordered by MRU, with unknowns spliced in at
    ///   their z-order position.
    nonisolated static func sortedByMRU(
        windowIDs: [CGWindowID],
        mruOrder: [CGWindowID]
    ) -> [CGWindowID] {
        guard !mruOrder.isEmpty else { return windowIDs }
        let windowSet = Set(windowIDs)
        // Known IDs: those that exist in windowIDs, in their MRU sequence.
        let known = mruOrder.filter { windowSet.contains($0) }
        let knownSet = Set(known)

        // Walk z-order front to back and attach each run of unknown windows to
        // the known window that immediately follows it — that is the nearest
        // known window behind them, and they must be emitted just before it.
        var unknownsInFrontOf: [CGWindowID: [CGWindowID]] = [:]
        var run: [CGWindowID] = []
        for id in windowIDs {
            if knownSet.contains(id) {
                if !run.isEmpty {
                    unknownsInFrontOf[id] = run
                    run = []
                }
            } else {
                run.append(id)
            }
        }
        // Whatever remains has no known window behind it, so it has no anchor.
        let unanchored = run

        var result: [CGWindowID] = []
        result.reserveCapacity(windowIDs.count)
        for id in known {
            if let unknowns = unknownsInFrontOf[id] {
                result.append(contentsOf: unknowns)
            }
            result.append(id)
        }
        result.append(contentsOf: unanchored)
        return result
    }

    /// Return `order` with the frontmost entry of `windowIDs` promoted to index 0.
    ///
    /// `windowIDs` is in z-order, so its first entry is the window the user is
    /// looking at right now.  Promoting it repairs MRU entries that the
    /// activation paths never recorded — see the call site in `enumerate`.
    ///
    /// - Parameters:
    ///   - windowIDs: On-screen window IDs in z-order (index 0 = front).
    ///   - order: The current MRU array (index 0 = most recently used).
    ///   - cap: Maximum number of entries to retain.
    /// - Returns: `order` unchanged when `windowIDs` is empty, otherwise `order`
    ///   with the frontmost ID moved to the front.
    nonisolated static func adoptingFrontmost(
        windowIDs: [CGWindowID],
        order: [CGWindowID],
        cap: Int
    ) -> [CGWindowID] {
        guard let frontmost = windowIDs.first else { return order }
        return movedToFront(frontmost, in: order, cap: cap)
    }

    /// Return a new order array with `id` moved (or inserted) at the front.
    ///
    /// If `id` already appears in `order`, it is removed first so there are
    /// no duplicates.  The result is then trimmed to at most `cap` entries by
    /// dropping from the tail (oldest entries).
    ///
    /// - Parameters:
    ///   - id: The window ID to promote to the front.
    ///   - order: The current MRU array (index 0 = most recently used).
    ///   - cap: Maximum number of entries to retain.
    /// - Returns: A new array with `id` at index 0, deduplicated, capped at `cap`.
    nonisolated static func movedToFront(
        _ id: CGWindowID,
        in order: [CGWindowID],
        cap: Int
    ) -> [CGWindowID] {
        // Remove any existing occurrence to avoid duplicates.
        var updated = order.filter { $0 != id }
        updated.insert(id, at: 0)
        // Evict from the tail when the cap is exceeded.
        if updated.count > cap {
            updated = Array(updated.prefix(cap))
        }
        return updated
    }

    // MARK: - Pure transformation (testable without TCC)

    /// Convert raw CGWindowList dictionaries into filtered, title-resolved WindowInfo
    /// values.  This static method is intentionally free of AppKit / TCC calls so
    /// that unit tests can invoke it with hand-built fixtures.
    ///
    /// - Parameters:
    ///   - rawList: The array returned by CGWindowListCopyWindowInfo.
    ///   - selfPID: The PID of the current process (own-process exclusion filter).
    ///   - excludedBundleIDs: Bundle IDs that should be omitted.
    ///   - bundleIDResolver: Closure that maps a pid_t to an optional bundle ID.
    ///     Injected so tests can provide a pure lookup without NSRunningApplication.
    nonisolated static func filterAndBuild(
        rawList: [[String: Any]],
        selfPID: pid_t,
        excludedBundleIDs: Set<String>,
        bundleIDResolver: (pid_t) -> String?
    ) -> [WindowInfo] {

        // Phase 1: filter and convert raw dicts to partially-built WindowInfo values
        // (title field holds the raw kCGWindowName / owner-name fallback at this stage;
        // duplicate suffixes are applied in phase 2).
        var candidates: [WindowInfo] = []
        for dict in rawList {
            guard
                let info = windowInfo(
                    from: dict,
                    selfPID: selfPID,
                    excludedBundleIDs: excludedBundleIDs,
                    bundleIDResolver: bundleIDResolver
                )
            else { continue }
            candidates.append(info)
        }

        // Phase 2: apply duplicate-title suffixes in enumeration order.
        return applyDuplicateSuffixes(to: candidates)
    }

    // MARK: - Internal helpers

    /// Attempt to build a WindowInfo from a single CGWindowList dictionary,
    /// returning nil if any filter condition rejects it.
    nonisolated private static func windowInfo(
        from dict: [String: Any],
        selfPID: pid_t,
        excludedBundleIDs: Set<String>,
        bundleIDResolver: (pid_t) -> String?
    ) -> WindowInfo? {

        // Layer must be 0 (normal application windows only).
        guard let layer = dict[kCGWindowLayer as String] as? Int,
            layer == 0
        else { return nil }

        // Window must be visible (alpha > 0).
        guard let alpha = dict[kCGWindowAlpha as String] as? Double,
            alpha > 0
        else { return nil }

        // Bounds must be at least 40×40.
        guard let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
            bounds.width >= 40, bounds.height >= 40
        else { return nil }

        // Exclude own process.
        guard let pidNum = dict[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        let pid = pid_t(pidNum)
        guard pid != selfPID else { return nil }

        // kCGWindowStoreType must be present and non-zero.
        guard let storeType = dict[kCGWindowStoreType as String] as? Int,
            storeType != 0
        else { return nil }

        // Resolve bundle ID (may be nil — not all processes have a bundle ID).
        let bundleID = bundleIDResolver(pid)

        // Exclude explicitly listed bundle IDs.
        if let bid = bundleID, excludedBundleIDs.contains(bid) { return nil }

        // Window ID.
        guard let wid = dict[kCGWindowNumber as String] as? CGWindowID else { return nil }

        // App name (owner name).
        let appName = dict[kCGWindowOwnerName as String] as? String ?? "Unknown"

        // Title fallback — use kCGWindowName if non-empty, else app name.
        let rawTitle = dict[kCGWindowName as String] as? String ?? ""
        let title = rawTitle.isEmpty ? appName : rawTitle

        return WindowInfo(
            windowID: wid,
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            title: title,
            rawTitle: rawTitle,
            bounds: bounds
        )
    }

    /// Apply duplicate-title suffixes to a list of WindowInfo values.
    ///
    /// Windows that share the same title string receive " (2)", " (3)", … suffixes
    /// in enumeration order.  The first occurrence keeps the original title.
    nonisolated static func applyDuplicateSuffixes(to windows: [WindowInfo]) -> [WindowInfo] {
        // Count how many times each title has already been emitted.
        var seen: [String: Int] = [:]
        return windows.map { info in
            let base = info.title
            let count = seen[base, default: 0]
            seen[base] = count + 1
            if count == 0 {
                return info
            }
            // Rebuild with the suffix.  We copy all fields except title;
            // rawTitle is preserved so AX matching still sees the un-suffixed name.
            return WindowInfo(
                windowID: info.windowID,
                pid: info.pid,
                bundleID: info.bundleID,
                appName: info.appName,
                title: "\(base) (\(count + 1))",
                rawTitle: info.rawTitle,
                bounds: info.bounds
            )
        }
    }
}
