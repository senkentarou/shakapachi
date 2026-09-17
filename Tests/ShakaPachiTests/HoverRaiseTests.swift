// HoverRaiseTests.swift
// Verifies the hover-to-raise decision and the cursor hit test.
//
// Both sides are pure: the tracker takes its hit test as a closure (which the
// tests also use to count how often it runs), and the hit test takes hand-built
// CGWindowList dictionaries, so nothing here needs a display or TCC permissions.

import XCTest

@testable import ShakaPachi

final class HoverRaiseTests: XCTestCase {

    // MARK: - Fixtures

    private let dwell: TimeInterval = 0.4
    private let selfPID: pid_t = 99999

    private func hit(
        _ windowID: CGWindowID,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        isFrontmost: Bool = false
    ) -> HoverHit {
        HoverHit(windowID: windowID, bounds: frame, isFrontmost: isFrontmost)
    }

    /// A tracker that has already seen the cursor once, so the next tick counts
    /// as movement. Production does the same on its first poll after being
    /// enabled: the pointer has to be used before it takes over.
    private func primedTracker() -> HoverRaiseTracker {
        var tracker = HoverRaiseTracker(dwell: dwell)
        _ = tracker.step(point: .zero, now: 0) { _ in
            XCTFail("The tick that only records the cursor position must not hit-test")
            return nil
        }
        return tracker
    }

    /// Build a raw CGWindowList entry. Defaults produce an eligible window.
    private func dict(
        windowID: CGWindowID,
        frame: CGRect,
        layer: Int = 0,
        alpha: Double = 1.0,
        pid: Int32 = 1234,
        storeType: Int = 1,
        ownerName: String = "TestApp",
        windowName: String? = "My Window"
    ) -> [String: Any] {
        var entry: [String: Any] = [
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowOwnerPID as String: pid,
            kCGWindowStoreType as String: storeType,
            kCGWindowOwnerName as String: ownerName,
            kCGWindowNumber as String: windowID,
        ]
        if let boundsDict = frame.dictionaryRepresentation as? [String: CGFloat] {
            entry[kCGWindowBounds as String] = boundsDict
        }
        if let windowName {
            entry[kCGWindowName as String] = windowName
        }
        return entry
    }

    private func hitTest(
        _ rawList: [[String: Any]],
        at point: CGPoint,
        excludedBundleIDs: Set<String> = [],
        bundleIDResolver: ((pid_t) -> String?)? = nil
    ) -> (window: WindowInfo, isFrontmost: Bool)? {
        WindowStore.hitTest(
            rawList: rawList,
            point: point,
            selfPID: selfPID,
            excludedBundleIDs: excludedBundleIDs,
            bundleIDResolver: bundleIDResolver ?? { _ in nil }
        )
    }

    // MARK: - Dwell

    func testDwell_notElapsed_doesNotRaise() {
        var tracker = primedTracker()
        let point = CGPoint(x: 10, y: 10)

        XCTAssertNil(tracker.step(point: point, now: 0) { _ in self.hit(1) })
        XCTAssertNil(
            tracker.step(point: point, now: 0.3) { _ in self.hit(1) },
            "Below the dwell the window must stay where it is")
    }

    func testDwell_elapsed_raises() {
        var tracker = primedTracker()
        let point = CGPoint(x: 10, y: 10)

        _ = tracker.step(point: point, now: 0) { _ in self.hit(1) }
        XCTAssertEqual(tracker.step(point: point, now: 0.4) { _ in self.hit(1) }, 1)
    }

    func testDwell_restartsWhenTheWindowUnderTheCursorChanges() {
        var tracker = primedTracker()
        let point = CGPoint(x: 10, y: 10)

        _ = tracker.step(point: point, now: 0) { _ in self.hit(1) }
        // Crossing into another window at 0.25s: window 2 has its own countdown,
        // so passing over window 1 on the way never raises it.
        XCTAssertNil(tracker.step(point: point, now: 0.25) { _ in self.hit(2) })
        XCTAssertNil(
            tracker.step(point: point, now: 0.5) { _ in self.hit(2) },
            "Window 2 has only been under the cursor for 0.25s")
        XCTAssertEqual(tracker.step(point: point, now: 0.75) { _ in self.hit(2) }, 2)
    }

    func testFrontmostWindow_isNeverRaised() {
        var tracker = primedTracker()
        let point = CGPoint(x: 10, y: 10)

        _ = tracker.step(point: point, now: 0) { _ in self.hit(1, isFrontmost: true) }
        XCTAssertNil(tracker.step(point: point, now: 10) { _ in self.hit(1, isFrontmost: true) })
    }

    func testSameWindow_isNotRaisedTwiceDuringOneHover() {
        var tracker = primedTracker()
        let point = CGPoint(x: 10, y: 10)

        _ = tracker.step(point: point, now: 0) { _ in self.hit(1) }
        XCTAssertEqual(tracker.step(point: point, now: 0.4) { _ in self.hit(1) }, 1)
        // The app ignored the raise, so the hit test still reports it as behind.
        // Asking again every dwell period would fight it; the cursor has to
        // leave and come back first.
        XCTAssertNil(tracker.step(point: point, now: 1.0) { _ in self.hit(1) })
        XCTAssertNil(tracker.step(point: point, now: 2.0) { _ in self.hit(1) })
    }

    func testNothingUnderTheCursor_clearsTheDwell() {
        var tracker = primedTracker()

        // Over window 1, out across the desktop, and back onto window 1.
        _ = tracker.step(point: CGPoint(x: 10, y: 10), now: 0) { _ in self.hit(1) }
        XCTAssertNil(tracker.step(point: CGPoint(x: 200, y: 10), now: 0.25) { _ in nil })
        XCTAssertNil(
            tracker.step(point: CGPoint(x: 12, y: 10), now: 0.5) { _ in self.hit(1) },
            "Crossing the desktop restarts the countdown")
        XCTAssertEqual(tracker.step(point: CGPoint(x: 12, y: 10), now: 1.0) { _ in self.hit(1) }, 1)
    }

    func testReset_clearsTheDwell() {
        var tracker = primedTracker()
        let point = CGPoint(x: 10, y: 10)
        let moved = CGPoint(x: 11, y: 10)

        _ = tracker.step(point: point, now: 0) { _ in self.hit(1) }
        tracker.reset()
        XCTAssertNil(
            tracker.step(point: moved, now: 0.4) { _ in self.hit(1) },
            "Time spent while suppressed must not count toward the dwell")
        XCTAssertEqual(tracker.step(point: moved, now: 0.8) { _ in self.hit(1) }, 1)
    }

    // MARK: - Re-arming

    func testAfterReset_aStationaryCursorRaisesNothing() {
        var tracker = primedTracker()
        let point = CGPoint(x: 10, y: 10)

        _ = tracker.step(point: point, now: 0) { _ in self.hit(1) }
        // The switcher just confirmed a window while the cursor sat over
        // another one. Raising that one would undo the switch.
        tracker.reset()
        for tick in 1...20 {
            XCTAssertNil(
                tracker.step(point: point, now: Double(tick) * 0.1) { _ in self.hit(1) },
                "The keyboard wins until the pointer is used again")
        }
    }

    func testAfterReset_movingTheCursorTakesOverAgain() {
        var tracker = primedTracker()

        _ = tracker.step(point: CGPoint(x: 10, y: 10), now: 0) { _ in self.hit(1) }
        tracker.reset()
        XCTAssertNil(tracker.step(point: CGPoint(x: 20, y: 10), now: 0.1) { _ in self.hit(1) })
        XCTAssertEqual(tracker.step(point: CGPoint(x: 20, y: 10), now: 0.5) { _ in self.hit(1) }, 1)
    }

    // MARK: - Hit-test frequency

    func testInsideTheFrontmostWindow_doesNotRunTheHitTest() {
        var tracker = primedTracker()
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        var probes = 0

        _ = tracker.step(point: CGPoint(x: 10, y: 10), now: 0) { _ in
            probes += 1
            return self.hit(1, frame: frame, isFrontmost: true)
        }
        XCTAssertEqual(probes, 1)

        for tick in 1...20 {
            _ = tracker.step(point: CGPoint(x: 10 + tick, y: 10), now: Double(tick) * 0.1) { _ in
                probes += 1
                return self.hit(1, frame: frame, isFrontmost: true)
            }
        }
        XCTAssertEqual(probes, 1, "Nothing can be above the frontmost window, so its rect is trusted")
    }

    func testParkedOverNothing_doesNotRunTheHitTest() {
        var tracker = primedTracker()
        let point = CGPoint(x: 10, y: 10)
        var probes = 0

        // Over the desktop, or under an open menu: the hit test says "nothing".
        _ = tracker.step(point: point, now: 0) { _ in
            probes += 1
            return nil
        }
        XCTAssertEqual(probes, 1)

        for tick in 1...20 {
            _ = tracker.step(point: point, now: Double(tick) * 0.1) { _ in
                probes += 1
                return nil
            }
        }
        XCTAssertEqual(probes, 1, "A parked pointer cannot change what is under it")

        _ = tracker.step(point: CGPoint(x: 11, y: 10), now: 3) { _ in
            probes += 1
            return nil
        }
        XCTAssertEqual(probes, 2, "Moving it asks again")
    }

    func testLeavingTheFrontmostWindow_runsTheHitTestAgain() {
        var tracker = primedTracker()
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        var probes = 0

        _ = tracker.step(point: CGPoint(x: 10, y: 10), now: 0) { _ in
            probes += 1
            return self.hit(1, frame: frame, isFrontmost: true)
        }
        _ = tracker.step(point: CGPoint(x: 500, y: 10), now: 0.1) { _ in
            probes += 1
            return nil
        }
        XCTAssertEqual(probes, 2)
    }

    // MARK: - Hit test

    func testHitTest_returnsTheTopmostWindowCoveringThePoint() {
        let back = dict(windowID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let front = dict(windowID: 2, frame: CGRect(x: 100, y: 100, width: 100, height: 100))
        // Index 0 is the front of the z-order.
        let result = hitTest([front, back], at: CGPoint(x: 150, y: 150))

        XCTAssertEqual(result?.window.windowID, 2)
        XCTAssertTrue(result?.isFrontmost ?? false)
    }

    func testHitTest_reportsAWindowBehindTheFrontOne() {
        let front = dict(windowID: 2, frame: CGRect(x: 100, y: 100, width: 100, height: 100))
        let back = dict(windowID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let result = hitTest([front, back], at: CGPoint(x: 10, y: 10))

        XCTAssertEqual(result?.window.windowID, 1)
        XCTAssertFalse(
            result?.isFrontmost ?? true,
            "Window 1 is the hover target but not the front window — that is what earns a raise")
    }

    func testHitTest_abortsWhenANonEligibleWindowIsOnTop() {
        // Layer 0 is the eligible band; an open menu sits above it. The window
        // it covers must not be raised out from under the menu.
        let menu = dict(
            windowID: 9, frame: CGRect(x: 100, y: 100, width: 200, height: 300), layer: 101,
            ownerName: "TestApp", windowName: nil)
        let window = dict(windowID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 400))

        XCTAssertNil(hitTest([menu, window], at: CGPoint(x: 150, y: 150)))
        XCTAssertEqual(
            hitTest([menu, window], at: CGPoint(x: 50, y: 50))?.window.windowID, 1,
            "Beside the menu the window underneath is still a target")
    }

    func testHitTest_abortsUnderOurOwnPanel() {
        let panel = dict(
            windowID: 9, frame: CGRect(x: 100, y: 100, width: 200, height: 100),
            pid: Int32(selfPID), ownerName: "ShakaPachi")
        let window = dict(windowID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 400))

        XCTAssertNil(hitTest([panel, window], at: CGPoint(x: 150, y: 150)))
    }

    func testHitTest_abortsOverAnExcludedApp() {
        let excluded = dict(
            windowID: 9, frame: CGRect(x: 100, y: 100, width: 200, height: 100), pid: 2222)
        let window = dict(windowID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let result = hitTest(
            [excluded, window], at: CGPoint(x: 150, y: 150),
            excludedBundleIDs: ["com.example.excluded"],
            bundleIDResolver: { pid in pid == 2222 ? "com.example.excluded" : nil })

        XCTAssertNil(
            result,
            "A window the switcher hides is not a target, and it still covers what is below it")
    }

    func testHitTest_seesThroughATransparentWindow() {
        let overlay = dict(
            windowID: 9, frame: CGRect(x: 0, y: 0, width: 400, height: 400), alpha: 0)
        let window = dict(windowID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 400))

        XCTAssertEqual(hitTest([overlay, window], at: CGPoint(x: 50, y: 50))?.window.windowID, 1)
    }

    func testHitTest_returnsNilOverTheDesktop() {
        let window = dict(windowID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertNil(hitTest([window], at: CGPoint(x: 500, y: 500)))
    }

    func testHitTest_returnsNilForAnEmptyList() {
        XCTAssertNil(hitTest([], at: CGPoint(x: 10, y: 10)))
    }
}
