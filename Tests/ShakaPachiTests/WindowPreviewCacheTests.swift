// WindowPreviewCacheTests.swift
// Tests for WindowPreviewCache using a stub capturer and a synchronous scheduler.
//
// The synchronous scheduler `{ work in work() }` runs capture immediately on the
// calling thread (main actor in tests). The DispatchQueue.main.async block inside
// prefetch() is also executed synchronously when already on the main queue, so
// assertions can be made immediately after prefetch() returns without expectations.

import XCTest

@testable import ShakaPachi

@MainActor
final class WindowPreviewCacheTests: XCTestCase {

    // MARK: - Helpers

    /// A tiny 1×1 NSImage used as a stub capture result.
    private func stubImage() -> NSImage {
        NSImage(size: NSSize(width: 1, height: 1))
    }

    /// Build a cache with a synchronous scheduler and a stub capturer.
    /// `captureIDs` will contain every ID passed to the capture closure,
    /// allowing dedup and call-count assertions.
    private func makeCache(
        returnsImageForID: CGWindowID? = 1,
        captureCallIDs: inout [CGWindowID]
    ) -> WindowPreviewCache {
        let img = stubImage()
        let box = UncheckedBox(captureCallIDs)  // ferry mutable array into @Sendable closure
        let cache = WindowPreviewCache(
            capture: { id in
                box.value.append(id)
                return id == returnsImageForID ? img : nil
            },
            schedule: { work in work() }  // synchronous: runs work() inline
        )
        // Write back so the caller sees the mutations.
        // (The box holds a reference — mutations are visible through it.)
        // Bind the box back to the inout parameter at end of each test by
        // reading box.value. We expose the box via the returned closure trick below.
        _ = box  // retained by closure inside cache
        return cache
    }

    // MARK: - prefetch populates cachedImage

    func testPrefetch_populatesCache() {
        var calls: [CGWindowID] = []
        var boxRef: UncheckedBox<[CGWindowID]>? = nil

        let img = stubImage()
        let box = UncheckedBox<[CGWindowID]>([])
        boxRef = box

        let cache = WindowPreviewCache(
            capture: { id in
                box.value.append(id)
                return id == 42 ? img : nil
            },
            schedule: { work in work() }
        )

        XCTAssertNil(cache.cachedImage(for: 42))
        cache.prefetch(42, force: true)
        XCTAssertNotNil(cache.cachedImage(for: 42), "Image should be in cache after synchronous prefetch")
        calls = boxRef?.value ?? []
        XCTAssertEqual(calls, [42], "Capture should be called exactly once")
    }

    // MARK: - onImageReady fires with the correct ID

    func testPrefetch_onImageReady_firesWithCorrectID() {
        let img = stubImage()
        var firedIDs: [CGWindowID] = []
        let cache = WindowPreviewCache(
            capture: { id in id == 7 ? img : nil },
            schedule: { work in work() }
        )
        cache.onImageReady = { id in firedIDs.append(id) }

        cache.prefetch(7, force: true)
        XCTAssertEqual(firedIDs, [7], "onImageReady must fire with the captured window ID")
    }

    func testPrefetch_nilCapture_doesNotFireOnImageReady() {
        // When capture returns nil, onImageReady must not fire.
        var firedIDs: [CGWindowID] = []
        let cache = WindowPreviewCache(
            capture: { _ in nil },
            schedule: { work in work() }
        )
        cache.onImageReady = { id in firedIDs.append(id) }

        cache.prefetch(99, force: true)
        XCTAssertTrue(firedIDs.isEmpty, "onImageReady must not fire when capture returns nil")
    }

    // MARK: - Dedup: second prefetch while in-flight does not duplicate

    func testPrefetch_dedup_doesNotCallCaptureTwice() {
        // With a synchronous scheduler, the first prefetch completes before the
        // second call is even made, so the dedup guard clears after the first
        // completes. We test the in-flight guard by using an asynchronous
        // scheduler that keeps the work pending.
        var captureCount = 0
        let img = stubImage()
        var pendingWork: (() -> Void)? = nil

        let cache = WindowPreviewCache(
            capture: { _ in
                captureCount += 1
                return img
            },
            schedule: { work in
                // Defer execution — simulate an async scheduler.
                pendingWork = work
            }
        )

        // First prefetch: enqueues work but does not run it yet.
        cache.prefetch(5, force: true)
        XCTAssertEqual(captureCount, 0, "Capture not called yet (async scheduler deferred)")

        // Second prefetch while first is still in-flight: should be a no-op.
        cache.prefetch(5, force: true)

        // Now flush the deferred work (simulates scheduler completing).
        pendingWork?()

        XCTAssertEqual(
            captureCount, 1,
            "Capture must be called exactly once — the in-flight dedup must block the second call")
    }

    // MARK: - force:false skips already-cached entries

    func testPrefetch_forceFlase_skipsCachedEntry() {
        var captureCount = 0
        let img = stubImage()
        let cache = WindowPreviewCache(
            capture: { _ in
                captureCount += 1
                return img
            },
            schedule: { work in work() }
        )

        cache.prefetch(3, force: true)  // populate
        XCTAssertEqual(captureCount, 1)

        cache.prefetch(3, force: false)  // should skip — already cached
        XCTAssertEqual(captureCount, 1, "force:false must not re-capture an already-cached entry")
    }

    func testPrefetch_forceTrue_recaptures() {
        var captureCount = 0
        let img = stubImage()
        let cache = WindowPreviewCache(
            capture: { _ in
                captureCount += 1
                return img
            },
            schedule: { work in work() }
        )

        cache.prefetch(3, force: true)
        cache.prefetch(3, force: true)  // force: should recapture
        XCTAssertEqual(captureCount, 2, "force:true must re-capture even if already cached")
    }

    // MARK: - LRU eviction drops the oldest entry past the cap

    func testLRUEviction_dropsOldestPastCap() {
        let img = stubImage()
        let cap = 48  // WindowPreviewCache.maxEntries

        let cache = WindowPreviewCache(
            capture: { _ in img },
            schedule: { work in work() }
        )

        // Fill the cache to the cap.
        for id in CGWindowID(1)...CGWindowID(cap) {
            cache.prefetch(id, force: true)
        }
        // ID 1 should still be present (cap not exceeded yet).
        XCTAssertNotNil(cache.cachedImage(for: 1), "Entry should survive at cap size")

        // Add one more to exceed the cap — ID 1 (oldest) should be evicted.
        cache.prefetch(CGWindowID(cap + 1), force: true)
        XCTAssertNil(
            cache.cachedImage(for: 1),
            "Oldest entry must be evicted when the cap is exceeded")
        XCTAssertNotNil(
            cache.cachedImage(for: 2),
            "Second-oldest entry must still be present after one eviction")
    }
}

// MARK: - Internal test helper

/// A reference-type box that lets a @Sendable capture closure mutate an array
/// without Swift 6 Sendable warnings. Used only in test code.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
