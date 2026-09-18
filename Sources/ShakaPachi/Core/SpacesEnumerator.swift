// SpacesEnumerator.swift
// Thin defensive wrapper over private SkyLight/CoreGraphicsServices APIs that
// provide real all-Spaces window enumeration.
// Beginners: you can treat this file as a black box — the rest of the app works without understanding its internals.
// Read the header for *what* it does; skip the *how*.
//
// The public CGWindowList API (.optionAll) does not reliably return windows on
// other Mission Control Spaces and gives no Space attribution. The private
// CGSCopyManagedDisplaySpaces + CGSCopyWindowsWithOptionsAndTags approach is
// the well-trodden workaround used by AltTab, Hammerspoon, yabai, and others.
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

// CGSCopyWindowsWithOptionsAndTags lists the windows that live in the given
// Spaces. owner 0 means every process and options 2 means every window of those
// Spaces; the two tag masks are in/out parameters this call does not need, so
// they are passed empty. Returns a CFArray of CFNumber (window IDs), or nil on
// failure.
//
// Note the direction: this asks the Spaces for their windows. The sibling call
// CGSCopySpacesForWindows goes the other way and returns the Space IDs the given
// windows occupy — a flat CFArray, not a per-window mapping — which is why it
// cannot answer "does this window belong to a managed Space".
@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
private func CGSCopyWindowsWithOptionsAndTags(
    _ cid: Int32,
    _ owner: Int32,
    _ spaces: CFArray,
    _ options: Int32,
    _ setTags: UnsafeMutablePointer<Int>,
    _ clearTags: UnsafeMutablePointer<Int>
) -> CFArray?

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
    /// 2. Ask CGSCopyWindowsWithOptionsAndTags which windows live in them.
    ///
    /// Asking the Spaces for their windows, rather than asking a window list for
    /// its Spaces, is what makes the result a filter: transient compositing
    /// buffers, off-Space ghosts and other CGWindowList artefacts belong to no
    /// managed Space, so they are simply absent from the answer.
    nonisolated static func allSpaceWindowIDs() -> Set<CGWindowID>? {
        let cid = CGSMainConnectionID()

        // Collect all managed Space IDs.
        guard let managedSpaceIDs = collectManagedSpaceIDs(cid: cid),
            !managedSpaceIDs.isEmpty
        else {
            NSLog("[ShakaPachi] SpacesEnumerator: fallback – CGSCopyManagedDisplaySpaces " + "returned no Spaces")
            return nil
        }

        // Ask those Spaces for their windows.
        guard let result = windowIDs(cid: cid, inSpaces: managedSpaceIDs) else {
            NSLog(
                "[ShakaPachi] SpacesEnumerator: fallback – CGSCopyWindowsWithOptionsAndTags " + "returned no windows")
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

    /// Ask CGSCopyWindowsWithOptionsAndTags for every window ID living in the
    /// given Spaces. Returns nil on failure or an empty answer.
    private nonisolated static func windowIDs(
        cid: Int32,
        inSpaces spaceIDs: Set<Int>
    ) -> Set<CGWindowID>? {
        // Build a CFArray of CFNumber from the Space IDs.
        // Use sInt64Type because a Space ID is the 64-bit "id64" value.
        let cfNumbers = spaceIDs.map { id in
            var val = Int64(id)
            return CFNumberCreate(kCFAllocatorDefault, .sInt64Type, &val)
                as CFNumber? ?? 0 as CFNumber
        }

        // The tag masks are in/out parameters this call does not need.
        var setTags = 0
        var clearTags = 0
        guard
            let resultCF = CGSCopyWindowsWithOptionsAndTags(
                cid,
                0,
                cfNumbers as CFArray,
                2,
                &setTags,
                &clearTags
            )
        else {
            return nil
        }

        guard CFGetTypeID(resultCF) == CFArrayGetTypeID() else {
            NSLog(
                "[ShakaPachi] SpacesEnumerator: CGSCopyWindowsWithOptionsAndTags returned "
                    + "unexpected CF type %lu",
                CFGetTypeID(resultCF))
            return nil
        }
        guard let numbers = resultCF as? [NSNumber] else {
            return nil
        }

        let ids = Set(numbers.map { CGWindowID($0.uint32Value) })
        return ids.isEmpty ? nil : ids
    }
}
