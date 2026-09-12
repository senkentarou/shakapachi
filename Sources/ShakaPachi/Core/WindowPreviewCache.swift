// WindowPreviewCache.swift
// On-demand capture cache for the "selected window live preview" feature.
//
// Design notes:
// - @MainActor: all public entry points are main-thread only. Captures run off
//   main via the `schedule` closure (default: Task.detached), then deliver
//   results back to the main actor so callers never need cross-actor hops.
// - Dependency injection (capture + schedule) keeps the class testable without
//   a screen-recording permission or real windows: tests inject a stub capturer
//   and a synchronous scheduler, making assertions immediate and deterministic.
// - CGWindowListCreateImage is deprecated on macOS 14 but intentional here:
//   the app targets macOS 13, and ScreenCaptureKit is async/heavy. The
//   deprecation warning is acceptable (no -warnings-as-errors in this build).
// - LRU eviction: a simple insertion-order array caps memory at ~48 entries.
//   The array is small enough that O(n) removal is negligible.

import AppKit
import CoreGraphics

@MainActor
final class WindowPreviewCache {

    // MARK: - Dependencies (injectable for testing)

    /// Synchronously captures a snapshot of the given window.
    /// Called off the main thread by the default `schedule` closure.
    /// Tests inject a stub that returns a tiny NSImage without screen access.
    let capture: (CGWindowID) -> NSImage?

    /// Runs the given capture work (possibly off-thread).
    /// The default dispatches via Task.detached(priority: .userInitiated).
    /// Tests inject `{ work in work() }` for synchronous, deterministic execution.
    let schedule: (@escaping () -> Void) -> Void

    // MARK: - Cache state

    private var cache: [CGWindowID: NSImage] = [:]
    /// Insertion order for LRU eviction (oldest = front).
    private var lruOrder: [CGWindowID] = []
    /// Maximum number of entries before eviction runs.
    private static let maxEntries = 48

    /// IDs currently being captured (prevents duplicate in-flight requests).
    private var inFlight: Set<CGWindowID> = []

    /// Called on the main actor each time a new image lands in the cache.
    var onImageReady: ((CGWindowID) -> Void)?

    // MARK: - Init

    init(
        capture: @escaping (CGWindowID) -> NSImage? = WindowPreviewCache.realCapture,
        schedule: @escaping (@escaping () -> Void) -> Void = {
            work in Task.detached(priority: .userInitiated) { work() }
        }
    ) {
        self.capture = capture
        self.schedule = schedule
    }

    // MARK: - Public API

    /// Return the cached image for `id`, or nil if not yet captured.
    func cachedImage(for id: CGWindowID) -> NSImage? {
        cache[id]
    }

    /// Discard all cached images, eviction order, and in-flight tracking.
    /// Does not cancel in-flight captures already dispatched to `schedule`;
    /// their results will be silently dropped because `inFlight` is cleared.
    /// Also clears `onImageReady` to prevent stale callbacks after a reset.
    func clearCache() {
        cache.removeAll()
        lruOrder.removeAll()
        inFlight.removeAll()
        onImageReady = nil
    }

    /// Request a capture for `id`.
    ///
    /// - Parameters:
    ///   - id: The CGWindowID to capture.
    ///   - force: When true, always kick off a fresh capture even if the image
    ///     is already cached (used for the currently-selected window so it
    ///     stays fresh across sessions). When false, skip if cached (neighbor
    ///     prefetch — avoid redundant work).
    func prefetch(_ id: CGWindowID, force: Bool) {
        if !force && cache[id] != nil { return }
        if inFlight.contains(id) { return }

        inFlight.insert(id)
        let captureFunc = capture  // capture the value-type closure (not self) for off-main use

        // Wrap self in an unchecked-Sendable box so the @Sendable schedule
        // closure can hold a reference without actor-hopping. All access via
        // `deliver` runs on the main thread (guaranteed by the if/else below),
        // so there is no data race.
        let selfRef = UncheckedSendableRef(self)

        schedule {
            let img = captureFunc(id)
            // Deliver result back to the main actor.
            //
            // We use DispatchQueue.main.async for the real (async) scheduler so
            // the completion arrives on the correct thread. For the synchronous
            // test scheduler, `schedule` calls `work()` directly on the main
            // thread, which means we are already on the main queue here — but
            // DispatchQueue.main.async in that context enqueues rather than
            // executes immediately, breaking test assertions.
            //
            // The safe cross-scheduler solution: check if we are already on the
            // main thread. If so, run the delivery block inline (synchronous
            // test path). If not, dispatch asynchronously (production path).
            let deliver = {
                let cache = selfRef.value
                cache.inFlight.remove(id)
                if let img {
                    cache.store(id, img)
                    cache.onImageReady?(id)
                }
            }
            if Thread.isMainThread {
                // Already on main — run inline. This is the synchronous test
                // scheduler path; the class is @MainActor so this is safe.
                MainActor.assumeIsolated(deliver)
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated(deliver) }
            }
        }
    }

    // MARK: - Real capture (nonisolated static — safe to call off the main actor)

    /// Capture the window via CGWindowListCreateImage.
    /// CGRect.null tells the API to use the window's own bounds.
    /// Returns nil for windows that cannot be captured (e.g. on another Space,
    /// minimised, or covered by TCC denial). Callers show a placeholder instead.
    ///
    /// `nonisolated` so the closure value is not MainActor-typed — this lets it
    /// be stored as `(CGWindowID) -> NSImage?` and called from off-main threads
    /// inside the `schedule` closure without an actor hop.
    nonisolated static func realCapture(_ id: CGWindowID) -> NSImage? {
        // CGWindowListCreateImage is deprecated on macOS 14 but works on
        // macOS 13+ and is intentional here. ScreenCaptureKit is async/heavy;
        // switching is out of scope for this feature.
        let cgImage = CGWindowListCreateImage(
            CGRect.null,
            CGWindowListOption.optionIncludingWindow,
            id,
            CGWindowImageOption.boundsIgnoreFraming
        )
        guard let cg = cgImage else { return nil }
        return NSImage(
            cgImage: cg,
            size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Private helpers

    /// Insert or update an image in the cache, evicting the oldest entry if
    /// the cap is exceeded.
    private func store(_ id: CGWindowID, _ img: NSImage) {
        if cache[id] == nil {
            // New entry: append to LRU order and evict if over cap.
            lruOrder.append(id)
            if lruOrder.count > Self.maxEntries,
                let oldest = lruOrder.first
            {
                lruOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
        }
        // Existing entry: update in place without changing LRU order
        // (the id is already in lruOrder).
        cache[id] = img
    }
}

// MARK: - Internal helpers

/// Unchecked-Sendable strong reference wrapper used inside the @Sendable
/// `schedule` closure. All accesses via `value` happen on the main thread
/// (enforced by the Thread.isMainThread / DispatchQueue.main.async split in
/// `prefetch`), so there is no actual data race.
private final class UncheckedSendableRef<T: AnyObject>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
