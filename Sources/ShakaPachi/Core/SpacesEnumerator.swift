// SpacesEnumerator.swift
// Thin defensive wrapper over private SkyLight/CoreGraphicsServices APIs that
// provide real all-Spaces window enumeration.
// Beginners: you can treat this file as a black box — the rest of the app works without understanding its internals.
// Read the header for *what* it does; skip the *how*.
//
// The public CGWindowList API (.optionAll) does not reliably return windows on
// other Mission Control Spaces and gives no Space attribution. The private
// CGSCopyManagedDisplaySpaces + CGSCopySpacesForWindows approach is the
// well-trodden workaround used by AltTab, Hammerspoon, yabai, and others.
//
// Every private call is wrapped defensively. Any unexpected/empty return causes
// this module to return nil so the caller can fall back gracefully — no crash,
// no hang, no force-unwrap.
//
// Threading: all methods are nonisolated so they can be called from @MainActor
// callers without hopping. The underlying CGS functions are documented as
// thread-safe (they use the connection ID, not a shared object).

import CoreGraphics
import Foundation

// MARK: - Private SkyLight symbol declarations

// (Skippable: private SkyLight (CGS*) plumbing. The public path above is the one to read.)
// CGSMainConnectionID() returns the per-process CGS connection used for all
// SkyLight calls. Same pattern as _AXUIElementGetWindow in Activator.swift.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

// CGSCopyManagedDisplaySpaces returns a CFArray of CFDictionary describing
// every display's managed Spaces. Each dict has keys "Spaces" (array of dicts
// each with key "id64" for the Space ID) and "Current Space" (dict with same
// shape for the frontmost Space). Returns an unretained CF object — assign to
// a let immediately so ARC retains it.
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

// CGSCopySpacesForWindows maps an array of CGWindowID values to the Space IDs
// they belong to. The mask parameter selects which Spaces to consider;
// 0x7 means "all" (current + other + full-screen per AltTab/Hammerspoon usage).
// Returns a CFDictionary mapping window ID (CFNumber) → array of space IDs
// (CFArray of CFNumber), or nil on failure.
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(
    _ cid: Int32,
    _ mask: Int32,
    _ windowIDs: CFArray
) -> CFDictionary?

// MARK: - SpacesEnumerator

enum SpacesEnumerator {

    // MARK: - Public API

    /// Return the set of CGWindowIDs that belong to ANY managed Space across
    /// all displays, or nil if the private SkyLight calls are unavailable or
    /// produced empty/unexpected results.
    ///
    /// The caller should fall back to its current behavior when this returns nil.
    /// A one-line NSLog is emitted on every fallback path so the cause is visible
    /// in the system log without needing a debugger.
    ///
    /// Algorithm:
    /// 1. Get all managed Space IDs from CGSCopyManagedDisplaySpaces.
    /// 2. Get all on-screen+off-screen window IDs from CGWindowList (.optionAll).
    /// 3. Ask CGSCopySpacesForWindows which of those IDs belong to a managed Space.
    /// 4. Return the union of matching window IDs.
    ///
    /// CGSCopySpacesForWindows naturally filters out transient system compositing
    /// buffers, off-Space ghosts, and other CGWindowList artefacts that have no
    /// Space attribution — those simply do not appear in the returned dictionary.
    nonisolated static func allSpaceWindowIDs() -> Set<CGWindowID>? {
        let cid = CGSMainConnectionID()

        // Collect all managed Space IDs.
        guard let managedSpaceIDs = collectManagedSpaceIDs(cid: cid),
            !managedSpaceIDs.isEmpty
        else {
            NSLog("[ShakaPachi] SpacesEnumerator: fallback – CGSCopyManagedDisplaySpaces " + "returned no Spaces")
            return nil
        }

        // Enumerate ALL window IDs via the public API.
        guard let allWindowIDs = collectAllWindowIDs(),
            !allWindowIDs.isEmpty
        else {
            NSLog("[ShakaPachi] SpacesEnumerator: fallback – CGWindowListCopyWindowInfo " + "returned no windows")
            return nil
        }

        // Map window IDs to Space IDs via the private API.
        guard
            let windowToSpaces = windowSpaceMap(
                cid: cid,
                windowIDs: allWindowIDs
            )
        else {
            NSLog("[ShakaPachi] SpacesEnumerator: fallback – CGSCopySpacesForWindows failed")
            return nil
        }

        // Keep only window IDs that map to at least one managed Space.
        // This discards off-Space compositing artefacts and system-only windows.
        let managedSet = managedSpaceIDs
        var result: Set<CGWindowID> = []
        for (windowID, spaceIDs) in windowToSpaces {
            if spaceIDs.contains(where: { managedSet.contains($0) }) {
                result.insert(windowID)
            }
        }

        if result.isEmpty {
            NSLog(
                "[ShakaPachi] SpacesEnumerator: fallback – intersection of all-windows "
                    + "and managed-Spaces yielded no windows")
            return nil
        }

        return result
    }

    // MARK: - Pure filter helper (unit-testable)

    /// Given a set of allowed window IDs and an array of WindowInfo values,
    /// return only those whose windowID is in `allowedIDs`.
    ///
    /// This is intentionally a pure function (no private API calls, no TCC) so
    /// it can be exhaustively unit-tested without a real display or Spaces setup.
    nonisolated static func filterToAllowedIDs(
        _ windows: [WindowInfo],
        allowedIDs: Set<CGWindowID>
    ) -> [WindowInfo] {
        windows.filter { allowedIDs.contains($0.windowID) }
    }

    // MARK: - Private helpers

    /// Parse CGSCopyManagedDisplaySpaces output and return all Space IDs found
    /// across all displays. Returns nil on any CF-type mismatch.
    private nonisolated static func collectManagedSpaceIDs(cid: Int32) -> Set<Int>? {
        guard let displaySpacesCF = CGSCopyManagedDisplaySpaces(cid) else {
            return nil
        }

        // The return value is a CFArray of CFDictionary (one per display).
        guard CFGetTypeID(displaySpacesCF) == CFArrayGetTypeID() else {
            NSLog(
                "[ShakaPachi] SpacesEnumerator: CGSCopyManagedDisplaySpaces returned " + "unexpected CF type %lu",
                CFGetTypeID(displaySpacesCF))
            return nil
        }
        guard let displaysArray = displaySpacesCF as? [[String: Any]] else {
            return nil
        }

        var spaceIDs: Set<Int> = []
        for displayDict in displaysArray {
            // Each display dict has a "Spaces" key containing an array of Space dicts.
            guard let spacesArray = displayDict["Spaces"] as? [[String: Any]] else {
                continue
            }
            for spaceDict in spacesArray {
                // Space ID is stored under "id64" as a number.
                if let spaceID = spaceDict["id64"] as? Int {
                    spaceIDs.insert(spaceID)
                } else if let spaceID = spaceDict["id64"] as? Int64 {
                    spaceIDs.insert(Int(spaceID))
                }
            }
        }

        return spaceIDs.isEmpty ? nil : spaceIDs
    }

    /// Return all CGWindowIDs visible via CGWindowList .optionAll (on all Spaces,
    /// including minimized, off-screen, etc.). Returns nil on failure.
    private nonisolated static func collectAllWindowIDs() -> [CGWindowID]? {
        guard
            let rawList = CGWindowListCopyWindowInfo(
                .optionAll, kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return nil
        }
        let ids: [CGWindowID] = rawList.compactMap { dict in
            dict[kCGWindowNumber as String] as? CGWindowID
        }
        return ids.isEmpty ? nil : ids
    }

    /// Ask CGSCopySpacesForWindows which Spaces each window ID belongs to.
    /// Returns a dictionary mapping CGWindowID → [Space IDs], or nil on failure.
    private nonisolated static func windowSpaceMap(
        cid: Int32,
        windowIDs: [CGWindowID]
    ) -> [CGWindowID: [Int]]? {
        // Build a CFArray of CFNumber from the window IDs.
        // Use sInt64Type so IDs above Int32.max (0x7FFF_FFFF) are not sign-flipped.
        let cfNumbers = windowIDs.map { id in
            var val = Int64(id)
            return CFNumberCreate(kCFAllocatorDefault, .sInt64Type, &val)
                as CFNumber? ?? 0 as CFNumber
        }
        // Use NSArray bridging to create the CFArray.
        let cfArray = cfNumbers as CFArray

        // mask 0x7 = kCGSAllSpacesMask (current | others | fullscreen).
        guard let resultCF = CGSCopySpacesForWindows(cid, 0x7, cfArray) else {
            return nil
        }

        guard CFGetTypeID(resultCF) == CFDictionaryGetTypeID() else {
            NSLog(
                "[ShakaPachi] SpacesEnumerator: CGSCopySpacesForWindows returned " + "unexpected CF type %lu",
                CFGetTypeID(resultCF))
            return nil
        }

        // The dictionary maps CFNumber (window ID) → CFArray of CFNumber (space IDs).
        guard let resultDict = resultCF as? [NSNumber: [NSNumber]] else {
            // Try alternate casting paths sometimes returned by SkyLight.
            guard let altDict = resultCF as? [NSNumber: Any] else {
                return nil
            }
            var map: [CGWindowID: [Int]] = [:]
            for (key, value) in altDict {
                let wid = CGWindowID(key.uint32Value)
                if let spaceArray = value as? [NSNumber] {
                    map[wid] = spaceArray.map { $0.intValue }
                }
            }
            return map.isEmpty ? nil : map
        }

        var map: [CGWindowID: [Int]] = [:]
        for (key, value) in resultDict {
            let wid = CGWindowID(key.uint32Value)
            map[wid] = value.map { $0.intValue }
        }
        return map.isEmpty ? nil : map
    }
}
