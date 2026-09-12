import AppKit
import XCTest

@testable import ShakaPachi

final class TrayIconRendererTests: XCTestCase {

    func testAllFourStatesDefined() {
        XCTAssertEqual(TrayIconState.allCases.count, 4)
    }

    func testNormalMenuBarImageIsTemplate() {
        XCTAssertTrue(TrayIconRenderer.menuBarImage(for: .normal).isTemplate)
    }

    func testColouredMenuBarImagesAreNotTemplate() {
        for state in [TrayIconState.settings, .permission, .restricted] {
            XCTAssertFalse(TrayIconRenderer.menuBarImage(for: state).isTemplate)
        }
    }

    func testEveryStateHasCardNameAndDetail() {
        for state in TrayIconState.allCases {
            XCTAssertFalse(state.cardName.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
        }
    }

    func testRestrictedDetailContainsResolutionHint() {
        let detail = TrayIconState.restricted.detail
        XCTAssertTrue(
            detail.contains("ウィンドウ切替を有効化"), "Restricted detail must include enable-switch menu action for resolution")
    }

    func testPreviewImageHasRequestedSize() {
        let img = TrayIconRenderer.previewImage(for: .normal, size: 32)
        XCTAssertEqual(img.size.width, 32, accuracy: 0.01)
        XCTAssertEqual(img.size.height, 32, accuracy: 0.01)
    }

    func testHeadingDotColorNormalDiffersFromFillColor() {
        XCTAssertNotEqual(TrayIconState.normal.headingDotColor, TrayIconState.normal.fillColor)
    }

    func testHeadingDotColorMatchesFillColorForColouredStates() {
        for state in [TrayIconState.settings, .permission, .restricted] {
            XCTAssertEqual(state.headingDotColor, state.fillColor)
        }
    }

    func testNormalPreviewFrontWindowIsOpaque() {
        // The centre pixel lands inside the filled front window; it must be
        // opaque. Regression guard: the normal card previously rendered as a
        // see-through outline because .labelColor did not resolve offscreen.
        let img = TrayIconRenderer.previewImage(for: .normal, size: 32)
        guard let tiff = img.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else {
            return XCTFail("could not rasterise preview")
        }
        let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        XCTAssertNotNil(color)
        XCTAssertGreaterThan(color!.alphaComponent, 0.5)
    }
}
