// AXWindowListSubroleTests.swift
// Verifies which subroles earn a row in the switcher.  An app reports its own
// chrome in the same AX window list as its windows, and the subrole is what
// tells the two apart.
// Pure static function — no AX, no TCC.

import XCTest

@testable import ShakaPachi

final class AXWindowListSubroleTests: XCTestCase {

    func testIsSwitchable_acceptsStandardWindow() {
        XCTAssertTrue(AXWindowList.isSwitchable(subrole: "AXStandardWindow"))
    }

    func testIsSwitchable_acceptsDialog() {
        // Also what a minimized window reports in place of its usual subrole.
        XCTAssertTrue(AXWindowList.isSwitchable(subrole: "AXDialog"))
    }

    func testIsSwitchable_rejectsUnknown() {
        // The subrole Chrome attaches to its "Global Media Controls" bubble,
        // which is the second Chrome row this filter exists to remove.
        XCTAssertFalse(AXWindowList.isSwitchable(subrole: "AXUnknown"))
    }

    func testIsSwitchable_rejectsFloatingWindow() {
        XCTAssertFalse(AXWindowList.isSwitchable(subrole: "AXFloatingWindow"))
    }

    func testIsSwitchable_keepsWindowThatReportsNoSubrole() {
        XCTAssertTrue(AXWindowList.isSwitchable(subrole: nil))
    }
}
