// WindowStoreAXFilterTests.swift
// Verifies that the AX cross-check keeps the windows an app reports over the
// Accessibility API and drops the overlay surfaces it does not, without ever
// removing an app whose AX answer is unusable.
// Pure static function — no AX, no TCC, no CGWindowList.

import CoreGraphics
import XCTest

@testable import ShakaPachi

final class WindowStoreAXFilterTests: XCTestCase {

    // MARK: - Fixture helper

    private func makeWindow(
        id: CGWindowID,
        pid: pid_t,
        appName: String = "Google Chrome"
    ) -> WindowInfo {
        WindowInfo(
            windowID: id,
            pid: pid,
            bundleID: "com.google.Chrome",
            appName: appName,
            title: "Window \(id)",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }

    // MARK: - Windows AX does not report

    func testFilterToAXKnownWindows_dropsWindowAXDoesNotReport() {
        // Chrome's browser window plus the media overlay that shares its pid:
        // AX reports only the browser window.
        let windows = [makeWindow(id: 1, pid: 100), makeWindow(id: 2, pid: 100)]

        let result = WindowStore.filterToAXKnownWindows(windows) { _ in [1] }

        XCTAssertEqual(result.map { $0.windowID }, [1])
    }

    func testFilterToAXKnownWindows_keepsEveryWindowAXReports() {
        let windows = [makeWindow(id: 1, pid: 100), makeWindow(id: 2, pid: 100)]

        let result = WindowStore.filterToAXKnownWindows(windows) { _ in [1, 2] }

        XCTAssertEqual(result.map { $0.windowID }, [1, 2])
    }

    func testFilterToAXKnownWindows_preservesInputOrder() {
        let windows = [
            makeWindow(id: 3, pid: 100),
            makeWindow(id: 2, pid: 100),
            makeWindow(id: 1, pid: 100),
        ]

        let result = WindowStore.filterToAXKnownWindows(windows) { _ in [1, 3] }

        XCTAssertEqual(result.map { $0.windowID }, [3, 1])
    }

    // MARK: - Apps that give no usable answer

    func testFilterToAXKnownWindows_nilAnswerKeepsTheAppsWindows() {
        let windows = [makeWindow(id: 1, pid: 100), makeWindow(id: 2, pid: 100)]

        let result = WindowStore.filterToAXKnownWindows(windows) { _ in nil }

        XCTAssertEqual(result.map { $0.windowID }, [1, 2])
    }

    func testFilterToAXKnownWindows_answerMatchingNoWindowIsDiscarded() {
        // An AX view that contradicts every CGWindowList entry is the wrong view,
        // so the app must not disappear from the switcher.
        let windows = [makeWindow(id: 1, pid: 100), makeWindow(id: 2, pid: 100)]

        let result = WindowStore.filterToAXKnownWindows(windows) { _ in [98, 99] }

        XCTAssertEqual(result.map { $0.windowID }, [1, 2])
    }

    // MARK: - Which apps are asked

    func testFilterToAXKnownWindows_singleWindowAppIsNotAsked() {
        let windows = [makeWindow(id: 1, pid: 100), makeWindow(id: 2, pid: 200)]

        var asked: [pid_t] = []
        let result = WindowStore.filterToAXKnownWindows(windows) { pid in
            asked.append(pid)
            return []
        }

        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(result.map { $0.windowID }, [1, 2])
    }

    func testFilterToAXKnownWindows_onlyAppsWithTwoOrMoreWindowsAreAsked() {
        let windows = [
            makeWindow(id: 1, pid: 100),
            makeWindow(id: 2, pid: 100),
            makeWindow(id: 3, pid: 200),
        ]

        var asked: [pid_t] = []
        let result = WindowStore.filterToAXKnownWindows(windows) { pid in
            asked.append(pid)
            return [1]
        }

        XCTAssertEqual(asked, [100])
        XCTAssertEqual(result.map { $0.windowID }, [1, 3])
    }

    func testFilterToAXKnownWindows_filtersOneAppWithoutTouchingAnother() {
        // Chrome loses its overlay; the terminal's two real windows both stay.
        let windows = [
            makeWindow(id: 1, pid: 100),
            makeWindow(id: 2, pid: 100),
            makeWindow(id: 3, pid: 200, appName: "iTerm2"),
            makeWindow(id: 4, pid: 200, appName: "iTerm2"),
        ]

        let result = WindowStore.filterToAXKnownWindows(windows) { pid in
            pid == 100 ? [1] : nil
        }

        XCTAssertEqual(result.map { $0.windowID }, [1, 3, 4])
    }

    // MARK: - Degenerate input

    func testFilterToAXKnownWindows_emptyInputReturnsEmpty() {
        var asked = false
        let result = WindowStore.filterToAXKnownWindows([]) { _ in
            asked = true
            return []
        }

        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(asked)
    }
}
