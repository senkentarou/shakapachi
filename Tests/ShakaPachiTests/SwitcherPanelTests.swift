// SwitcherPanelTests.swift
// Pure-logic tests for the Step 7 helpers in SwitcherListView / SwitcherLayout.
// No display connection or AppKit UI is required — all tested functions are
// stateless computations on plain values.

import XCTest

@testable import ShakaPachi

final class SwitcherPanelTests: XCTestCase {

    // MARK: - panelSize (horizontal tile row)

    func testPanelSize_oneItem() {
        let size = SwitcherLayout.panelSize(itemCount: 1)
        XCTAssertEqual(
            size.width,
            SwitcherLayout.horizontalMargin * 2 + SwitcherLayout.tileSize)
        XCTAssertEqual(
            size.height,
            SwitcherLayout.topPadding + SwitcherLayout.tileSize
                + SwitcherLayout.titleGap + SwitcherLayout.titleHeight
                + SwitcherLayout.bottomPadding)
    }

    func testPanelSize_zeroItems_treatedAsOne() {
        // An empty list never shows the panel, but the math must not break.
        XCTAssertEqual(
            SwitcherLayout.panelSize(itemCount: 0),
            SwitcherLayout.panelSize(itemCount: 1))
    }

    func testPanelSize_widthGrowsPerItem() {
        let one = SwitcherLayout.panelSize(itemCount: 1)
        let two = SwitcherLayout.panelSize(itemCount: 2)
        XCTAssertEqual(
            two.width - one.width,
            SwitcherLayout.tileSize + SwitcherLayout.tileSpacing,
            "Each additional window adds one tile plus one gap")
    }

    func testPanelSize_heightIndependentOfCount() {
        XCTAssertEqual(
            SwitcherLayout.panelSize(itemCount: 1).height,
            SwitcherLayout.panelSize(itemCount: 30).height,
            "A single-row layout has constant height")
    }

    // MARK: - tileRect

    func testTileRect_firstTileAtMargin() {
        let rect = SwitcherLayout.tileRect(index: 0)
        XCTAssertEqual(rect.origin.x, SwitcherLayout.horizontalMargin)
        XCTAssertEqual(rect.origin.y, SwitcherLayout.topPadding)
        XCTAssertEqual(
            rect.size,
            NSSize(
                width: SwitcherLayout.tileSize,
                height: SwitcherLayout.tileSize))
    }

    func testTileRect_advancesByTileAndSpacing() {
        let r0 = SwitcherLayout.tileRect(index: 0)
        let r1 = SwitcherLayout.tileRect(index: 1)
        XCTAssertEqual(
            r1.origin.x - r0.origin.x,
            SwitcherLayout.tileSize + SwitcherLayout.tileSpacing)
        XCTAssertEqual(r0.origin.y, r1.origin.y, "Single row: same y for all tiles")
    }

    func testTileRect_lastTileFitsInsidePanelWidth() {
        let count = 8
        let last = SwitcherLayout.tileRect(index: count - 1)
        let size = SwitcherLayout.panelSize(itemCount: count)
        XCTAssertEqual(
            last.maxX + SwitcherLayout.horizontalMargin, size.width,
            "Panel width must exactly wrap the last tile plus margin")
    }

    // MARK: - advanceIndex (wrap-around)

    func testAdvanceIndex_normalAdvance() {
        XCTAssertEqual(SwitcherLayout.advanceIndex(0, count: 5), 1)
        XCTAssertEqual(SwitcherLayout.advanceIndex(3, count: 5), 4)
    }

    func testAdvanceIndex_wrapsAround() {
        XCTAssertEqual(
            SwitcherLayout.advanceIndex(4, count: 5), 0,
            "Advancing past the last item must wrap to 0")
    }

    func testAdvanceIndex_singleItem_staysAtZero() {
        XCTAssertEqual(
            SwitcherLayout.advanceIndex(0, count: 1), 0,
            "Single-item list must always return 0")
    }

    func testAdvanceIndex_zeroCount_returnsZero() {
        XCTAssertEqual(
            SwitcherLayout.advanceIndex(0, count: 0), 0,
            "Empty list must return 0 without crashing")
    }

    func testAdvanceIndex_twoItems_cycles() {
        XCTAssertEqual(SwitcherLayout.advanceIndex(0, count: 2), 1)
        XCTAssertEqual(SwitcherLayout.advanceIndex(1, count: 2), 0)
    }

    // MARK: - indicesToRedraw (two-tile optimisation)

    func testIndicesToRedraw_differentIndices_returnsBoth() {
        let set = SwitcherLayout.indicesToRedraw(old: 1, new: 3)
        XCTAssertEqual(
            set, IndexSet([1, 3]),
            "Both old and new indices must be included")
    }

    func testIndicesToRedraw_sameIndex_returnsSingleTile() {
        let set = SwitcherLayout.indicesToRedraw(old: 2, new: 2)
        XCTAssertEqual(
            set, IndexSet(integer: 2),
            "When old == new the set should contain exactly one index")
    }

    func testIndicesToRedraw_adjacentTiles() {
        let set = SwitcherLayout.indicesToRedraw(old: 4, new: 5)
        XCTAssertTrue(set.contains(4))
        XCTAssertTrue(set.contains(5))
        XCTAssertEqual(set.count, 2)
    }

    func testIndicesToRedraw_zeroToLast() {
        let set = SwitcherLayout.indicesToRedraw(old: 0, new: 7)
        XCTAssertEqual(set, IndexSet([0, 7]))
    }

    // MARK: - effectiveTileSize (Step 8 shrink-to-fit)

    func testEffectiveTileSize_fitsAtFullSize_noShrink() {
        // A handful of tiles on a wide screen: no shrink, nominal size.
        let size = SwitcherLayout.effectiveTileSize(itemCount: 5, availableWidth: 2000)
        XCTAssertEqual(size, SwitcherLayout.tileSize)
    }

    func testEffectiveTileSize_shrinksWhenOverflowing() {
        // Many tiles on a narrow screen must shrink below nominal.
        let size = SwitcherLayout.effectiveTileSize(itemCount: 30, availableWidth: 1000)
        XCTAssertLessThan(size, SwitcherLayout.tileSize)
        XCTAssertGreaterThanOrEqual(size, SwitcherLayout.minTileSize)
    }

    func testEffectiveTileSize_neverBelowMinimum() {
        // Absurd count on a small screen clamps at the floor, not below.
        let size = SwitcherLayout.effectiveTileSize(itemCount: 200, availableWidth: 800)
        XCTAssertEqual(size, SwitcherLayout.minTileSize)
    }

    func testEffectiveTileSize_shrunkTilesFitAvailableWidth() {
        // When shrink is active (above the floor), all tiles must fit exactly.
        let count = 20
        let available: CGFloat = 1200
        let tile = SwitcherLayout.effectiveTileSize(itemCount: count, availableWidth: available)
        // Only meaningful when we didn't hit the floor.
        if tile > SwitcherLayout.minTileSize {
            let width = SwitcherLayout.panelSize(itemCount: count, effectiveTile: tile).width
            XCTAssertLessThanOrEqual(
                width, available + 0.5,
                "Shrunk tiles must fit within the available width")
        }
    }

    func testEffectiveTileSize_zeroItems_returnsNominal() {
        XCTAssertEqual(
            SwitcherLayout.effectiveTileSize(itemCount: 0, availableWidth: 500),
            SwitcherLayout.tileSize)
    }

    func testEffectiveIconSize_keepsProportion() {
        // Icon keeps the same ratio to the tile as the nominal 60/76.
        let iconAtNominal = SwitcherLayout.effectiveIconSize(for: SwitcherLayout.tileSize)
        XCTAssertEqual(iconAtNominal, SwitcherLayout.iconSize, accuracy: 0.001)
        let iconAtHalf = SwitcherLayout.effectiveIconSize(for: SwitcherLayout.tileSize / 2)
        XCTAssertEqual(iconAtHalf, SwitcherLayout.iconSize / 2, accuracy: 0.001)
    }

    func testPanelSize_withEffectiveTile_matchesTileMath() {
        let count = 6
        let tile: CGFloat = 50
        let size = SwitcherLayout.panelSize(itemCount: count, effectiveTile: tile)
        let expectedWidth =
            SwitcherLayout.horizontalMargin * 2
            + CGFloat(count) * tile
            + CGFloat(count - 1) * SwitcherLayout.tileSpacing
        XCTAssertEqual(size.width, expectedWidth)
    }

    // MARK: - baseTile parameter (configurable icon size)

    func testPanelSize_baseTile_usesProvidedEdge() {
        // panelSize with a custom baseTile must use that edge, not the constant.
        let size = SwitcherLayout.panelSize(itemCount: 1, baseTile: 152)
        XCTAssertEqual(
            size.width,
            SwitcherLayout.horizontalMargin * 2 + 152,
            "Width must use the provided baseTile, not tileSize constant")
    }

    func testPanelSize_baseTile_default_matchesNominalConstant() {
        // Default baseTile must produce the same result as the old zero-argument form.
        XCTAssertEqual(
            SwitcherLayout.panelSize(itemCount: 1, baseTile: SwitcherLayout.tileSize),
            SwitcherLayout.panelSize(itemCount: 1))
    }

    func testEffectiveTileSize_baseTile_fitsAtFullSize_returnsBaseTile() {
        // Wide screen: no shrink — must return the provided baseTile, not tileSize.
        let result = SwitcherLayout.effectiveTileSize(
            itemCount: 1, availableWidth: 10_000, baseTile: 152)
        XCTAssertEqual(result, 152)
    }

    func testEffectiveTileSize_baseTile_default_matchesNominal() {
        // Without explicit baseTile the behavior is byte-identical to the old API.
        let withDefault = SwitcherLayout.effectiveTileSize(
            itemCount: 5, availableWidth: 2000, baseTile: SwitcherLayout.tileSize)
        let oldCall = SwitcherLayout.effectiveTileSize(itemCount: 5, availableWidth: 2000)
        XCTAssertEqual(withDefault, oldCall)
    }

    func testNominalTile_forIconSize60_is76() {
        // The canonical ratio: icon 60, tile 76 → nominalTile(60) == 76.
        XCTAssertEqual(
            SwitcherLayout.nominalTile(forIconSize: 60),
            SwitcherLayout.tileSize,
            accuracy: 0.001)
    }

    func testNominalTile_roundTripsWithEffectiveIconSize() {
        // effectiveIconSize(for: nominalTile(forIconSize: 60)) must recover 60.
        let tile = SwitcherLayout.nominalTile(forIconSize: 60)
        let icon = SwitcherLayout.effectiveIconSize(for: tile)
        XCTAssertEqual(icon, 60, accuracy: 0.001)
    }
}
