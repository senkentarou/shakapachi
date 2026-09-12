// SwitcherStateMachineTests.swift
// Verifies every transition defined by the state machine plus edge cases.
// No AppKit or CoreGraphics required — the machine is pure logic.

import XCTest

@testable import ShakaPachi

final class SwitcherStateMachineTests: XCTestCase {

    // MARK: - Helpers

    private func makeMachine(resolver: ((Int) -> Int?)? = nil) -> SwitcherStateMachine {
        SwitcherStateMachine(sameAppResolver: resolver)
    }

    /// Drive the machine from IDLE into ACTIVE with `count` items.
    /// Returns the machine after the MODIFIER_HELD → ACTIVE transition.
    @discardableResult
    private func activateMachine(_ machine: SwitcherStateMachine, count: Int) -> (
        action: SwitcherAction, consumed: Bool
    ) {
        machine.handle(.modifierDown)
        return machine.handle(.trigger(shift: false), itemCount: count)
    }

    // MARK: - IDLE state

    func testIdleModifierDownTransitionsToModifierHeld() {
        let m = makeMachine()
        let (action, consumed) = m.handle(.modifierDown)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed, "Modifier key itself must not be consumed")
        XCTAssertTrue(m.isModifierHeld)
    }

    func testIdleTriggerIsIgnored() {
        let m = makeMachine()
        let (action, consumed) = m.handle(.trigger(shift: false), itemCount: 5)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed)
        XCTAssertTrue(m.isIdle, "IDLE + trigger must leave state in IDLE")
    }

    func testIdleEscapeIsIgnored() {
        let m = makeMachine()
        let (action, consumed) = m.handle(.escape)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed)
        XCTAssertTrue(m.isIdle)
    }

    func testIdleModifierUpIsIgnored() {
        let m = makeMachine()
        let (action, consumed) = m.handle(.modifierUp)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed)
        XCTAssertTrue(m.isIdle)
    }

    func testIdleArrowForwardIsIgnored() {
        let m = makeMachine()
        let (action, consumed) = m.handle(.arrowRight)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed)
        XCTAssertTrue(m.isIdle)
    }

    func testIdleArrowBackwardIsIgnored() {
        let m = makeMachine()
        let (action, consumed) = m.handle(.arrowLeft)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed)
        XCTAssertTrue(m.isIdle)
    }

    func testIdleOtherKeyIsIgnored() {
        let m = makeMachine()
        let (action, consumed) = m.handle(.otherKey)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed)
        XCTAssertTrue(m.isIdle)
    }

    // MARK: - MODIFIER_HELD state

    func testModifierHeldTriggerShowsPanelWithTwoOrMoreWindows() {
        let m = makeMachine()
        m.handle(.modifierDown)
        let (action, consumed) = m.handle(.trigger(shift: false), itemCount: 3)
        XCTAssertEqual(
            action, .showPanel(initialIndex: 1),
            "initial index=1 when count≥2")
        XCTAssertTrue(consumed, "Trigger must be consumed when showing panel")
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.activeIndex, 1)
    }

    func testModifierHeldTriggerShowsPanelWithOneWindow() {
        let m = makeMachine()
        m.handle(.modifierDown)
        let (action, consumed) = m.handle(.trigger(shift: false), itemCount: 1)
        XCTAssertEqual(
            action, .showPanel(initialIndex: 0),
            "single window uses index 0")
        XCTAssertTrue(consumed)
        XCTAssertEqual(m.activeIndex, 0)
    }

    func testModifierHeldTriggerWithZeroItemsStaysInModifierHeld() {
        let m = makeMachine()
        m.handle(.modifierDown)
        let (action, consumed) = m.handle(.trigger(shift: false), itemCount: 0)
        XCTAssertEqual(action, .none, "No windows: no panel to show")
        XCTAssertTrue(consumed, "Tab is still consumed so the OS doesn't act on it")
        XCTAssertTrue(m.isModifierHeld)
    }

    func testModifierHeldModifierUpReturnsToIdle() {
        let m = makeMachine()
        m.handle(.modifierDown)
        let (action, consumed) = m.handle(.modifierUp)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed, "Modifier release must not be consumed")
        XCTAssertTrue(m.isIdle)
    }

    func testModifierHeldOtherKeyPassesThrough() {
        let m = makeMachine()
        m.handle(.modifierDown)
        let (action, consumed) = m.handle(.otherKey)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed)
        XCTAssertTrue(m.isModifierHeld)
    }

    func testModifierHeldEscapePassesThrough() {
        let m = makeMachine()
        m.handle(.modifierDown)
        let (action, consumed) = m.handle(.escape)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed)
        XCTAssertTrue(m.isModifierHeld)
    }

    // MARK: - ACTIVE: forward / backward navigation

    func testActiveTriggerAdvancesIndex() {
        let m = makeMachine()
        activateMachine(m, count: 4)  // initial index=1
        let (action, consumed) = m.handle(.trigger(shift: false))
        XCTAssertEqual(action, .moveSelection(to: 2))
        XCTAssertTrue(consumed)
        XCTAssertEqual(m.activeIndex, 2)
    }

    func testActiveTriggerWrapsAround() {
        let m = makeMachine()
        activateMachine(m, count: 3)  // index=1
        m.handle(.trigger(shift: false))  // →2
        let (action, consumed) = m.handle(.trigger(shift: false))  // →0 (wrap)
        XCTAssertEqual(action, .moveSelection(to: 0))
        XCTAssertTrue(consumed)
        XCTAssertEqual(m.activeIndex, 0)
    }

    func testActiveShiftTriggerGoesBackward() {
        let m = makeMachine()
        activateMachine(m, count: 4)  // index=1
        let (action, consumed) = m.handle(.trigger(shift: true))  // →0
        XCTAssertEqual(action, .moveSelection(to: 0))
        XCTAssertTrue(consumed)
        XCTAssertEqual(m.activeIndex, 0)
    }

    func testActiveShiftTriggerWrapsBackward() {
        let m = makeMachine()
        activateMachine(m, count: 3)  // index=1
        m.handle(.trigger(shift: true))  // →0
        let (action, consumed) = m.handle(.trigger(shift: true))  // →2 (wrap)
        XCTAssertEqual(action, .moveSelection(to: 2))
        XCTAssertTrue(consumed)
        XCTAssertEqual(m.activeIndex, 2)
    }

    func testActiveArrowForwardAdvances() {
        let m = makeMachine()
        activateMachine(m, count: 4)  // index=1
        let (action, consumed) = m.handle(.arrowRight)
        XCTAssertEqual(action, .moveSelection(to: 2))
        XCTAssertTrue(consumed)
    }

    func testActiveArrowForwardWraps() {
        let m = makeMachine()
        activateMachine(m, count: 2)  // index=1
        let (action, consumed) = m.handle(.arrowRight)  // →0 (wrap)
        XCTAssertEqual(action, .moveSelection(to: 0))
        XCTAssertTrue(consumed)
    }

    func testActiveArrowBackwardRetreats() {
        let m = makeMachine()
        activateMachine(m, count: 4)  // index=1
        let (action, consumed) = m.handle(.arrowLeft)  // →0
        XCTAssertEqual(action, .moveSelection(to: 0))
        XCTAssertTrue(consumed)
    }

    func testActiveArrowBackwardWraps() {
        let m = makeMachine()
        activateMachine(m, count: 3)  // index=1
        m.handle(.arrowLeft)  // →0
        let (action, consumed) = m.handle(.arrowLeft)  // →2 (wrap)
        XCTAssertEqual(action, .moveSelection(to: 2))
        XCTAssertTrue(consumed)
    }

    // MARK: - ACTIVE: escape / cancel

    func testActiveEscapeCancelsAndReturnsToIdle() {
        let m = makeMachine()
        activateMachine(m, count: 4)
        let (action, consumed) = m.handle(.escape)
        XCTAssertEqual(action, .cancel, "Escape must cancel (not confirm)")
        XCTAssertTrue(consumed, "Escape is a defined transition — must be consumed")
        XCTAssertTrue(m.isIdle)
        XCTAssertNil(m.activeIndex)
    }

    func testEscapeProducesNilActiveIndex() {
        let m = makeMachine()
        activateMachine(m, count: 2)
        m.handle(.escape)
        XCTAssertNil(m.activeIndex)
    }

    // MARK: - ACTIVE: modifier release → confirm

    func testActiveModifierUpConfirmsCurrentIndex() {
        let m = makeMachine()
        activateMachine(m, count: 4)  // index=1
        m.handle(.trigger(shift: false))  // →2
        let (action, consumed) = m.handle(.modifierUp)
        XCTAssertEqual(action, .confirmSelection(index: 2))
        XCTAssertFalse(consumed, "Releasing modifier must not be consumed")
        XCTAssertTrue(m.isIdle)
    }

    func testActiveModifierUpAtInitialIndexConfirms() {
        let m = makeMachine()
        activateMachine(m, count: 3)  // initial index=1
        let (action, consumed) = m.handle(.modifierUp)
        XCTAssertEqual(action, .confirmSelection(index: 1))
        XCTAssertFalse(consumed)
    }

    // MARK: - ACTIVE: otherKey

    func testActiveOtherKeyIsNotConsumed() {
        let m = makeMachine()
        activateMachine(m, count: 4)
        let (action, consumed) = m.handle(.otherKey)
        XCTAssertEqual(action, .none, "Undefined key must produce no action")
        XCTAssertFalse(consumed, "Undefined key must NOT be consumed")
        XCTAssertTrue(m.isActive, "State must remain ACTIVE")
    }

    func testActiveOtherKeyDoesNotChangeIndex() {
        let m = makeMachine()
        activateMachine(m, count: 4)  // index=1
        m.handle(.trigger(shift: false))  // →2
        m.handle(.otherKey)
        XCTAssertEqual(m.activeIndex, 2, "otherKey must not change the selection index")
    }

    // MARK: - ACTIVE: sameAppJump (grave)

    func testActiveSameAppJumpWithResolverHit() {
        // Simulate 4 windows, windows 1 and 3 belong to the same app.
        let resolver: (Int) -> Int? = { index in
            if index == 1 { return 3 }
            if index == 3 { return 1 }
            return nil
        }
        let m = makeMachine(resolver: resolver)
        activateMachine(m, count: 4)  // index=1
        let (action, consumed) = m.handle(.sameAppJump)
        XCTAssertEqual(action, .moveSelection(to: 3))
        XCTAssertTrue(consumed, "sameAppJump is a defined key — must be consumed")
        XCTAssertEqual(m.activeIndex, 3)
    }

    func testActiveSameAppJumpWithResolverMiss() {
        // No other window of the same app: resolver returns nil.
        let resolver: (Int) -> Int? = { _ in return nil }
        let m = makeMachine(resolver: resolver)
        activateMachine(m, count: 4)  // index=1
        let (action, consumed) = m.handle(.sameAppJump)
        // Stay at current index (no movement), but key is still consumed.
        XCTAssertEqual(action, .moveSelection(to: 1), "Stay put when no same-app window exists")
        XCTAssertTrue(consumed, "sameAppJump is always consumed even if no jump occurs")
        XCTAssertEqual(m.activeIndex, 1)
    }

    func testActiveSameAppJumpWithNoResolver() {
        // No resolver injected: stays at current index.
        let m = makeMachine(resolver: nil)
        activateMachine(m, count: 4)  // index=1
        let (action, consumed) = m.handle(.sameAppJump)
        XCTAssertEqual(action, .moveSelection(to: 1))
        XCTAssertTrue(consumed)
    }

    // MARK: - Full happy path

    func testFullHappyPathTapOnceRelease() {
        // "Tap once and release" → confirm index 1 (the previous window).
        let m = makeMachine()
        m.handle(.modifierDown)
        let (showAction, _) = m.handle(.trigger(shift: false), itemCount: 5)
        XCTAssertEqual(showAction, .showPanel(initialIndex: 1))
        // Release modifier without pressing Tab again.
        let (confirmAction, consumed) = m.handle(.modifierUp)
        XCTAssertEqual(confirmAction, .confirmSelection(index: 1))
        XCTAssertFalse(consumed)
        XCTAssertTrue(m.isIdle)
    }

    func testFullHappyPathCycleAndRelease() {
        // Option down → Tab → Tab → release: should confirm index 3 (1→2→3).
        let m = makeMachine()
        m.handle(.modifierDown)
        m.handle(.trigger(shift: false), itemCount: 5)  // show, index=1
        m.handle(.trigger(shift: false))  // →2
        m.handle(.trigger(shift: false))  // →3
        let (action, _) = m.handle(.modifierUp)
        XCTAssertEqual(action, .confirmSelection(index: 3))
    }

    func testFullHappyPathEscapeDoesNotConfirm() {
        let m = makeMachine()
        m.handle(.modifierDown)
        m.handle(.trigger(shift: false), itemCount: 5)
        m.handle(.trigger(shift: false))  // →2
        let (action, _) = m.handle(.escape)
        XCTAssertEqual(action, .cancel, "Escape must cancel, not confirm")
        XCTAssertTrue(m.isIdle)
    }

    func testFullHappyPathSingleWindow() {
        // Single window: initial index=0, confirm returns index 0.
        let m = makeMachine()
        m.handle(.modifierDown)
        let (showAction, _) = m.handle(.trigger(shift: false), itemCount: 1)
        XCTAssertEqual(showAction, .showPanel(initialIndex: 0))
        let (confirmAction, _) = m.handle(.modifierUp)
        XCTAssertEqual(confirmAction, .confirmSelection(index: 0))
    }

    func testFullHappyPathShiftReverseWrap() {
        // 3 windows, initial index=1; Shift+Tab twice → 0 → 2 (wrap).
        let m = makeMachine()
        m.handle(.modifierDown)
        m.handle(.trigger(shift: false), itemCount: 3)  // index=1
        m.handle(.trigger(shift: true))  // →0
        let (action, _) = m.handle(.trigger(shift: true))  // →2 (wrap)
        XCTAssertEqual(action, .moveSelection(to: 2))
        let (confirmAction, _) = m.handle(.modifierUp)
        XCTAssertEqual(confirmAction, .confirmSelection(index: 2))
    }

    func testArrowKeysNavigate() {
        let m = makeMachine()
        m.handle(.modifierDown)
        m.handle(.trigger(shift: false), itemCount: 4)  // index=1
        XCTAssertEqual(m.handle(.arrowRight).action, .moveSelection(to: 2))
        XCTAssertEqual(m.handle(.arrowRight).action, .moveSelection(to: 3))
        XCTAssertEqual(m.handle(.arrowLeft).action, .moveSelection(to: 2))
    }

    // MARK: - State reuse after cancel / confirm

    func testMachineIsReusableAfterCancel() {
        let m = makeMachine()
        // First session: cancel.
        m.handle(.modifierDown)
        m.handle(.trigger(shift: false), itemCount: 3)
        m.handle(.escape)
        XCTAssertTrue(m.isIdle)
        // Second session: should work identically.
        m.handle(.modifierDown)
        let (action, _) = m.handle(.trigger(shift: false), itemCount: 2)
        XCTAssertEqual(action, .showPanel(initialIndex: 1))
    }

    func testMachineIsReusableAfterConfirm() {
        let m = makeMachine()
        m.handle(.modifierDown)
        m.handle(.trigger(shift: false), itemCount: 3)
        m.handle(.modifierUp)
        XCTAssertTrue(m.isIdle)
        // New session.
        m.handle(.modifierDown)
        let (action, _) = m.handle(.trigger(shift: false), itemCount: 3)
        XCTAssertEqual(action, .showPanel(initialIndex: 1))
    }

    // MARK: - reset()

    func testResetRestoresIdle() {
        let m = makeMachine()
        m.handle(.modifierDown)
        m.handle(.trigger(shift: false), itemCount: 3)
        XCTAssertTrue(m.isActive)
        m.reset()
        XCTAssertTrue(m.isIdle)
    }

    // MARK: - Consume / passthrough matrix

    func testConsumeMatrix() {
        // Verify all defined transitions produce the expected consumed flag.
        struct Case {
            let input: SwitcherInput
            let shouldConsume: Bool
            let label: String
        }

        // From IDLE: nothing is consumed.
        let idleCases: [Case] = [
            .init(input: .modifierDown, shouldConsume: false, label: "IDLE+modifierDown"),
            .init(input: .modifierUp, shouldConsume: false, label: "IDLE+modifierUp"),
            .init(input: .escape, shouldConsume: false, label: "IDLE+escape"),
            .init(input: .otherKey, shouldConsume: false, label: "IDLE+otherKey"),
            .init(input: .trigger(shift: false), shouldConsume: false, label: "IDLE+trigger"),
        ]
        for c in idleCases {
            let fresh = SwitcherStateMachine()
            let (_, consumed) = fresh.handle(c.input)
            XCTAssertEqual(consumed, c.shouldConsume, c.label)
        }

        // From MODIFIER_HELD
        let mhCases: [Case] = [
            .init(input: .modifierUp, shouldConsume: false, label: "MH+modifierUp"),
            .init(input: .otherKey, shouldConsume: false, label: "MH+otherKey"),
            .init(input: .trigger(shift: false), shouldConsume: true, label: "MH+trigger"),
        ]
        for c in mhCases {
            let fresh = SwitcherStateMachine()
            fresh.handle(.modifierDown)
            let (_, consumed) = fresh.handle(c.input, itemCount: 3)
            XCTAssertEqual(consumed, c.shouldConsume, c.label)
        }

        // From ACTIVE
        let activeCases: [Case] = [
            .init(input: .trigger(shift: false), shouldConsume: true, label: "ACTIVE+trigger"),
            .init(input: .trigger(shift: true), shouldConsume: true, label: "ACTIVE+shiftTrigger"),
            .init(input: .arrowRight, shouldConsume: true, label: "ACTIVE+arrowRight"),
            .init(input: .arrowLeft, shouldConsume: true, label: "ACTIVE+arrowLeft"),
            .init(input: .escape, shouldConsume: true, label: "ACTIVE+escape"),
            .init(input: .sameAppJump, shouldConsume: true, label: "ACTIVE+sameAppJump"),
            .init(input: .otherKey, shouldConsume: false, label: "ACTIVE+otherKey"),
            .init(input: .modifierUp, shouldConsume: false, label: "ACTIVE+modifierUp"),
        ]
        for c in activeCases {
            let fresh = SwitcherStateMachine()
            fresh.handle(.modifierDown)
            fresh.handle(.trigger(shift: false), itemCount: 4)
            let (_, consumed) = fresh.handle(c.input)
            XCTAssertEqual(consumed, c.shouldConsume, c.label)
        }
    }

    // MARK: - isActive / isIdle / isModifierHeld helpers

    func testStateHelpers() {
        let m = makeMachine()
        XCTAssertTrue(m.isIdle)
        XCTAssertFalse(m.isModifierHeld)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(m.activeIndex)

        m.handle(.modifierDown)
        XCTAssertFalse(m.isIdle)
        XCTAssertTrue(m.isModifierHeld)
        XCTAssertFalse(m.isActive)

        m.handle(.trigger(shift: false), itemCount: 3)
        XCTAssertFalse(m.isIdle)
        XCTAssertFalse(m.isModifierHeld)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.activeIndex, 1)
    }

    // MARK: - Vertical arrows and digits in flat mode

    func testFlatModeCollapsesVerticalArrowsOntoTheSingleAxis() {
        let m = makeMachine()
        activateMachine(m, count: 4)  // index=1
        XCTAssertEqual(m.handle(.arrowDown).action, .moveSelection(to: 2))
        XCTAssertEqual(m.handle(.arrowUp).action, .moveSelection(to: 1))
    }

    func testFlatModeLeavesDigitsToTheFrontApp() {
        let m = makeMachine()
        activateMachine(m, count: 4)
        let (action, consumed) = m.handle(.digit(2))
        XCTAssertEqual(action, .none)
        XCTAssertFalse(consumed, "modifier+digit is a real shortcut in the front app")
        XCTAssertEqual(m.activeIndex, 1, "the selection must not move")
    }

    // MARK: - Injected navigator (app-unit mode)

    func testNavigatorTakesOverEveryMovementInput() {
        let m = makeMachine()
        var seen: [SwitcherInput] = []
        m.navigator = { input, _ in
            seen.append(input)
            return 3
        }
        activateMachine(m, count: 8)

        for input in [SwitcherInput.arrowRight, .arrowLeft, .arrowUp, .arrowDown, .digit(2), .sameAppJump] {
            let (action, consumed) = m.handle(input)
            XCTAssertEqual(action, .moveSelection(to: 3), "\(input) should route through the navigator")
            XCTAssertTrue(consumed, "\(input) is a defined transition and must be swallowed")
        }
        XCTAssertEqual(seen.count, 6)
    }

    func testNavigatorReturningNilHoldsTheSelectionStill() {
        let m = makeMachine()
        m.navigator = { _, _ in nil }
        activateMachine(m, count: 8)  // index=1
        let (action, consumed) = m.handle(.arrowRight)
        XCTAssertEqual(action, .moveSelection(to: 1), "a cursor at its end stays put")
        XCTAssertTrue(consumed, "still swallowed — the key is not the front app's")
    }

    func testNavigatorDoesNotOwnEscapeOrModifierRelease() {
        let m = makeMachine()
        m.navigator = { _, _ in 5 }
        activateMachine(m, count: 8)
        XCTAssertEqual(m.handle(.escape).action, .cancel)

        let m2 = makeMachine()
        m2.navigator = { _, _ in 5 }
        activateMachine(m2, count: 8)
        m2.handle(.arrowRight)
        XCTAssertEqual(m2.handle(.modifierUp).action, .confirmSelection(index: 5))
    }

    func testInitialIndexProviderOverridesTheDefaultStartingIndex() {
        let m = makeMachine()
        m.initialIndexProvider = { count, _ in
            XCTAssertEqual(count, 6)
            return 4
        }
        m.handle(.modifierDown)
        let (action, _) = m.handle(.trigger(shift: false), itemCount: 6)
        XCTAssertEqual(action, .showPanel(initialIndex: 4))
        XCTAssertEqual(m.activeIndex, 4)
    }

    func testInitialIndexProviderReceivesTheShiftFlagVerbatim() {
        // Stands in for app-unit mode: the provider decides the starting
        // group/window purely from the shift flag it is handed.
        let m = makeMachine()
        var seenShift: Bool?
        m.initialIndexProvider = { _, shift in
            seenShift = shift
            return shift ? 0 : 4
        }

        m.handle(.modifierDown)
        let (shiftAction, _) = m.handle(.trigger(shift: true), itemCount: 6)
        XCTAssertEqual(seenShift, true)
        XCTAssertEqual(shiftAction, .showPanel(initialIndex: 0))

        m.handle(.escape)
        m.handle(.modifierDown)
        let (noShiftAction, _) = m.handle(.trigger(shift: false), itemCount: 6)
        XCTAssertEqual(seenShift, false)
        XCTAssertEqual(noShiftAction, .showPanel(initialIndex: 4))
    }

    // MARK: - Shift+Tab initial selection (flat mode)

    func testShiftTriggerStartsOnTheCurrentItemInFlatMode() {
        let m = makeMachine()
        m.handle(.modifierDown)
        let (action, consumed) = m.handle(.trigger(shift: true), itemCount: 4)
        XCTAssertEqual(
            action, .showPanel(initialIndex: 0),
            "Cmd+Shift+Tab must open on the current item, not the next one")
        XCTAssertTrue(consumed)
        XCTAssertEqual(m.activeIndex, 0)
    }

    func testNonShiftTriggerStartsOnTheNextItemInFlatMode() {
        let m = makeMachine()
        m.handle(.modifierDown)
        let (action, consumed) = m.handle(.trigger(shift: false), itemCount: 4)
        XCTAssertEqual(action, .showPanel(initialIndex: 1))
        XCTAssertTrue(consumed)
        XCTAssertEqual(m.activeIndex, 1)
    }

    func testShiftTriggerWithSingleWindowStartsAtZero() {
        let m = makeMachine()
        m.handle(.modifierDown)
        let (action, _) = m.handle(.trigger(shift: true), itemCount: 1)
        XCTAssertEqual(
            action, .showPanel(initialIndex: 0),
            "single window: index 0 regardless of shift")
    }

    func testNonShiftTriggerWithSingleWindowStartsAtZero() {
        let m = makeMachine()
        m.handle(.modifierDown)
        let (action, _) = m.handle(.trigger(shift: false), itemCount: 1)
        XCTAssertEqual(
            action, .showPanel(initialIndex: 0),
            "single window: index 0 regardless of shift")
    }
}
