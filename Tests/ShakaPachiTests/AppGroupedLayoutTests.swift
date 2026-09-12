// AppGroupedLayoutTests.swift
// Verifies the app-grouped mode geometry added to SwitcherLayout:
//   - appGroupedPanelSize (width = max of app row / window row, fixed height)
//   - windowRowOffsetX (centers the narrower row)
//   - paneRect / leftChipRect / rightChipRect / paneTitleRect adjacency
//   - letterboxRect (contain-fit, centered, never crops)
//
// Pure geometry only — drawing itself is not covered here (SwitcherListView's
// draw(_:) has no unit-testable output).

import XCTest

@testable import ShakaPachi

final class AppGroupedLayoutTests: XCTestCase {

    // MARK: - appGroupedPanelSize: width

    func testPanelWidth_threePanesNoChips_is1020() {
        // 20*2 + 3*320 + 2*10 = 40 + 960 + 20 = 1020.
        let size = SwitcherLayout.appGroupedPanelSize(
            groupCount: 1, visiblePaneCount: 3, hasLeftChip: false, hasRightChip: false)
        XCTAssertEqual(size.width, 1020, accuracy: 0.001)
    }

    func testPanelWidth_threePanesBothChips_is1128() {
        // 1020 + 2*(44 + 10) = 1020 + 108 = 1128.
        let size = SwitcherLayout.appGroupedPanelSize(
            groupCount: 1, visiblePaneCount: 3, hasLeftChip: true, hasRightChip: true)
        XCTAssertEqual(size.width, 1128, accuracy: 0.001)
    }

    func testPanelWidth_manyGroups_usesAppRowWidthWhenWider() {
        // 20 groups at the nominal 76pt tile is far wider than a 3-pane strip,
        // so the app row must dictate the panel width.
        let size = SwitcherLayout.appGroupedPanelSize(
            groupCount: 20, visiblePaneCount: 3, hasLeftChip: false, hasRightChip: false)
        let appRowWidth = SwitcherLayout.panelSize(itemCount: 20, baseTile: SwitcherLayout.tileSize).width
        XCTAssertEqual(size.width, appRowWidth, accuracy: 0.001)
    }

    // MARK: - appGroupedPanelSize: height

    func testPanelHeight_nominalTile_is368() {
        // 20 + 76 + 6 + 20 + 10 + 200 + 4 + 18 + 14 = 368.
        let size = SwitcherLayout.appGroupedPanelSize(
            groupCount: 1, visiblePaneCount: 3, hasLeftChip: false, hasRightChip: false)
        XCTAssertEqual(size.height, 368, accuracy: 0.001)
    }

    func testPanelHeight_independentOfVisiblePaneCount() {
        // Panes sit side by side, not stacked — 1 vs 3 visible panes must not
        // change panel height.
        let one = SwitcherLayout.appGroupedPanelSize(
            groupCount: 1, visiblePaneCount: 1, hasLeftChip: false, hasRightChip: false)
        let three = SwitcherLayout.appGroupedPanelSize(
            groupCount: 1, visiblePaneCount: 3, hasLeftChip: false, hasRightChip: false)
        XCTAssertEqual(one.height, three.height, accuracy: 0.001)
    }

    func testPanelHeight_shrunkTile_reflectsEffectiveTile() {
        // Passing a shrunk effectiveTile must lower the height by exactly the
        // tile delta (all other rows are fixed).
        let nominal = SwitcherLayout.appGroupedPanelSize(
            groupCount: 1, visiblePaneCount: 1, hasLeftChip: false, hasRightChip: false,
            effectiveTile: SwitcherLayout.tileSize)
        let shrunk = SwitcherLayout.appGroupedPanelSize(
            groupCount: 1, visiblePaneCount: 1, hasLeftChip: false, hasRightChip: false,
            effectiveTile: 50)
        XCTAssertEqual(
            nominal.height - shrunk.height, SwitcherLayout.tileSize - 50, accuracy: 0.001)
    }

    // MARK: - Pane adjacency

    func testPaneRects_adjacentPanesAreSeparatedByExactlyPaneSpacing() {
        let tile = SwitcherLayout.tileSize
        let offsetX: CGFloat = 0
        let pane0 = SwitcherLayout.paneRect(ordinal: 0, hasLeftChip: false, effectiveTile: tile, rowOffsetX: offsetX)
        let pane1 = SwitcherLayout.paneRect(ordinal: 1, hasLeftChip: false, effectiveTile: tile, rowOffsetX: offsetX)
        let pane2 = SwitcherLayout.paneRect(ordinal: 2, hasLeftChip: false, effectiveTile: tile, rowOffsetX: offsetX)

        XCTAssertEqual(pane1.minX - pane0.maxX, AppGroupedLayout.paneSpacing, accuracy: 0.001)
        XCTAssertEqual(pane2.minX - pane1.maxX, AppGroupedLayout.paneSpacing, accuracy: 0.001)
        // Panes never overlap.
        XCTAssertFalse(pane0.intersects(pane1))
        XCTAssertFalse(pane1.intersects(pane2))
    }

    func testPaneRects_allShareTheSameSizeAndY() {
        let tile = SwitcherLayout.tileSize
        let pane0 = SwitcherLayout.paneRect(ordinal: 0, hasLeftChip: false, effectiveTile: tile, rowOffsetX: 0)
        let pane1 = SwitcherLayout.paneRect(ordinal: 1, hasLeftChip: false, effectiveTile: tile, rowOffsetX: 0)
        XCTAssertEqual(pane0.width, SwitcherLayout.previewWidth)
        XCTAssertEqual(pane0.height, SwitcherLayout.previewHeight)
        XCTAssertEqual(pane0.origin.y, pane1.origin.y, accuracy: 0.001)
    }

    func testPaneRect_leftChipShiftsFirstPaneRight() {
        let tile = SwitcherLayout.tileSize
        let withoutChip = SwitcherLayout.paneRect(ordinal: 0, hasLeftChip: false, effectiveTile: tile, rowOffsetX: 0)
        let withChip = SwitcherLayout.paneRect(ordinal: 0, hasLeftChip: true, effectiveTile: tile, rowOffsetX: 0)
        XCTAssertEqual(
            withChip.origin.x - withoutChip.origin.x,
            AppGroupedLayout.chipWidth + AppGroupedLayout.chipSpacing,
            accuracy: 0.001)
    }

    // MARK: - Chip rects

    func testLeftChipRect_nilWhenNothingHiddenLeft() {
        let rect = SwitcherLayout.leftChipRect(hiddenLeft: 0, effectiveTile: SwitcherLayout.tileSize, rowOffsetX: 0)
        XCTAssertNil(rect)
    }

    func testLeftChipRect_nonNilWhenSomethingHiddenLeft() {
        let rect = SwitcherLayout.leftChipRect(hiddenLeft: 2, effectiveTile: SwitcherLayout.tileSize, rowOffsetX: 0)
        XCTAssertNotNil(rect)
        XCTAssertEqual(rect?.width, AppGroupedLayout.chipWidth)
    }

    func testRightChipRect_nilWhenNothingHiddenRight() {
        let rect = SwitcherLayout.rightChipRect(
            hiddenRight: 0, visiblePaneCount: 3, hasLeftChip: false,
            effectiveTile: SwitcherLayout.tileSize, rowOffsetX: 0)
        XCTAssertNil(rect)
    }

    func testRightChipRect_nonNilAndSitsAfterLastPane() {
        let tile = SwitcherLayout.tileSize
        let lastPane = SwitcherLayout.paneRect(ordinal: 2, hasLeftChip: false, effectiveTile: tile, rowOffsetX: 0)
        let rightChip = SwitcherLayout.rightChipRect(
            hiddenRight: 1, visiblePaneCount: 3, hasLeftChip: false, effectiveTile: tile, rowOffsetX: 0)
        XCTAssertNotNil(rightChip)
        XCTAssertEqual(
            rightChip!.origin.x - lastPane.maxX, AppGroupedLayout.chipSpacing, accuracy: 0.001)
    }

    // MARK: - Pane title rect

    func testPaneTitleRect_sitsDirectlyBelowItsPaneWithPaneTitleGap() {
        let tile = SwitcherLayout.tileSize
        let pane = SwitcherLayout.paneRect(ordinal: 1, hasLeftChip: false, effectiveTile: tile, rowOffsetX: 0)
        let title = SwitcherLayout.paneTitleRect(ordinal: 1, hasLeftChip: false, effectiveTile: tile, rowOffsetX: 0)
        XCTAssertEqual(title.origin.x, pane.origin.x, accuracy: 0.001)
        XCTAssertEqual(title.width, pane.width, accuracy: 0.001)
        XCTAssertEqual(
            title.origin.y - pane.maxY, AppGroupedLayout.paneTitleGap, accuracy: 0.001)
        XCTAssertEqual(title.height, AppGroupedLayout.paneTitleHeight, accuracy: 0.001)
    }

    // MARK: - Letterbox

    func testLetterboxRect_wideWindow_fillsWidthShrinksHeightAndCenters() {
        let paneRect = NSRect(x: 100, y: 50, width: 320, height: 200)
        let windowBounds = CGRect(x: 0, y: 0, width: 2560, height: 1080)
        let rect = SwitcherLayout.letterboxRect(for: windowBounds, in: paneRect)
        XCTAssertEqual(rect.width, 320, accuracy: 0.001, "Wide window must fill the pane's width")
        XCTAssertEqual(rect.height, 135, accuracy: 0.5, "2560x1080 scaled to width 320 gives height 135")
        XCTAssertEqual(rect.midX, paneRect.midX, accuracy: 0.001)
        XCTAssertEqual(rect.midY, paneRect.midY, accuracy: 0.001)
    }

    func testLetterboxRect_tallWindow_fillsHeightShrinksWidthAndCenters() {
        let paneRect = NSRect(x: 100, y: 50, width: 320, height: 200)
        let windowBounds = CGRect(x: 0, y: 0, width: 700, height: 1100)
        let rect = SwitcherLayout.letterboxRect(for: windowBounds, in: paneRect)
        XCTAssertEqual(rect.height, 200, accuracy: 0.001, "Tall window must fill the pane's height")
        XCTAssertEqual(rect.width, 127.27, accuracy: 0.1, "700x1100 scaled to height 200 gives width ~127.27")
        XCTAssertEqual(rect.midX, paneRect.midX, accuracy: 0.001)
        XCTAssertEqual(rect.midY, paneRect.midY, accuracy: 0.001)
    }

    func testLetterboxRect_exact16x10_matchesPaneRectExactly() {
        let paneRect = NSRect(x: 100, y: 50, width: 320, height: 200)
        let windowBounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let rect = SwitcherLayout.letterboxRect(for: windowBounds, in: paneRect)
        XCTAssertEqual(rect, paneRect)
    }

    func testLetterboxRect_zeroBounds_returnsPaneRectUnchanged() {
        let paneRect = NSRect(x: 100, y: 50, width: 320, height: 200)
        let rect = SwitcherLayout.letterboxRect(for: .zero, in: paneRect)
        XCTAssertEqual(rect, paneRect)
    }

    func testLetterboxRect_zeroWidthOnly_returnsPaneRectUnchanged() {
        let paneRect = NSRect(x: 100, y: 50, width: 320, height: 200)
        let degenerate = CGRect(x: 0, y: 0, width: 0, height: 500)
        let rect = SwitcherLayout.letterboxRect(for: degenerate, in: paneRect)
        XCTAssertEqual(rect, paneRect)
    }

    // MARK: - Centering the narrower row

    func testWindowRowOffsetX_positiveWhenAppRowIsWiderPanel() {
        // A single group's app-tile row (just one 76pt tile + margins) is much
        // narrower than a 3-pane strip, so the panel width is dictated by the
        // pane row and the (nonexistent, single-tile) app row would be the
        // narrow one. Exercise the inverse instead: a wide app row (many
        // groups) forces windowRowOffsetX (for a single visible pane) positive.
        let panelWidth = SwitcherLayout.appGroupedPanelSize(
            groupCount: 20, visiblePaneCount: 1, hasLeftChip: false, hasRightChip: false
        ).width
        let offset = SwitcherLayout.windowRowOffsetX(
            visiblePaneCount: 1, hasLeftChip: false, hasRightChip: false, panelWidth: panelWidth)
        XCTAssertGreaterThan(offset, 0, "Window row must be centered when the app row dictates panel width")
    }

    func testTileRowOffsetX_positiveWhenWindowRowIsWiderPanel() {
        // A single app group's tile row is narrower than a 3-pane strip, so
        // reusing the existing tileRowOffsetX for the app row must center it
        // (positive offset) inside the wider, pane-row-dictated panel.
        let panelWidth = SwitcherLayout.appGroupedPanelSize(
            groupCount: 1, visiblePaneCount: 3, hasLeftChip: false, hasRightChip: false
        ).width
        let offset = SwitcherLayout.tileRowOffsetX(
            itemCount: 1, effectiveTile: SwitcherLayout.tileSize, boundsWidth: panelWidth)
        XCTAssertGreaterThan(offset, 0, "App tile row must be centered when the window row dictates panel width")
    }

    func testWindowRowOffsetX_zeroWhenPaneRowExactlyFillsPanel() {
        let panelWidth = SwitcherLayout.appGroupedPanelSize(
            groupCount: 1, visiblePaneCount: 3, hasLeftChip: false, hasRightChip: false
        ).width
        let offset = SwitcherLayout.windowRowOffsetX(
            visiblePaneCount: 3, hasLeftChip: false, hasRightChip: false, panelWidth: panelWidth)
        XCTAssertEqual(offset, 0, accuracy: 0.001)
    }

    // MARK: - appNameRect

    func testAppNameRect_spansFullPanelWidthAndSitsBelowTileRow() {
        let tile = SwitcherLayout.tileSize
        let rect = SwitcherLayout.appNameRect(panelWidth: 500, effectiveTile: tile)
        XCTAssertEqual(rect.width, 500, accuracy: 0.001)
        XCTAssertEqual(rect.height, SwitcherLayout.titleHeight, accuracy: 0.001)
        let expectedY = SwitcherLayout.topPadding + tile + SwitcherLayout.titleGap
        XCTAssertEqual(rect.origin.y, expectedY, accuracy: 0.001)
    }
}
