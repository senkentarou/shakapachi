// SettingsTabBarDragTests.swift
// Verifies: the settings header strip is backed by a window-drag handle over
// its empty area, and that the handle stays behind the tab buttons — a drag
// handle placed in front of them would silently swallow every tab click.

import AppKit
import SwiftUI
import XCTest

@testable import ShakaPachi

@MainActor
final class SettingsTabBarDragTests: XCTestCase {

    private struct Harness: View {

        static let items: [SettingsTabBar.Item] = [
            .init(id: 0, title: "動作", symbol: "gearshape"),
            .init(id: 1, title: "外観", symbol: "paintpalette"),
            .init(id: 2, title: "状態", symbol: "checkmark.shield"),
        ]

        @State var selection = 0

        var body: some View {
            SettingsTabBar(items: Self.items, selection: $selection)
        }
    }

    private static let stripWidth: CGFloat = 560
    private static let stripHeight =
        SettingsChrome.titleBarHeight + 10 + SettingsChrome.tabSize.height + 10

    /// Hosts the tab bar in a real (never ordered-front) window: hit testing
    /// only resolves down to a representable's NSView once the hierarchy sits
    /// in a window.
    private func makeStrip() throws -> (NSWindow, WindowDragHandle.DragView) {
        let frame = NSRect(x: 0, y: 0, width: Self.stripWidth, height: Self.stripHeight)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Harness())
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        return (window, try XCTUnwrap(Self.findDragView(host), "The header strip has no drag handle"))
    }

    private static func findDragView(_ view: NSView) -> WindowDragHandle.DragView? {
        if let handle = view as? WindowDragHandle.DragView { return handle }
        for subview in view.subviews {
            if let handle = findDragView(subview) { return handle }
        }
        return nil
    }

    /// Centre of the first tab button, in the drag handle's own coordinates.
    /// The tabs are one centred row, and the handle is not flipped, so the row
    /// is measured down from the strip's top edge.
    private func firstTabCentre(in drag: WindowDragHandle.DragView) -> NSPoint {
        let count = CGFloat(Harness.items.count)
        let rowWidth =
            count * SettingsChrome.tabSize.width + (count - 1) * SettingsChrome.tabSpacing
        let fromTop = SettingsChrome.titleBarHeight + 10 + SettingsChrome.tabSize.height / 2
        return NSPoint(
            x: drag.bounds.midX - rowWidth / 2 + SettingsChrome.tabSize.width / 2,
            y: drag.bounds.maxY - fromTop)
    }

    func testDragHandle_coversTheStrip() throws {
        let (_, drag) = try makeStrip()
        XCTAssertEqual(drag.bounds.width, Self.stripWidth, accuracy: 0.5)
        XCTAssertEqual(drag.bounds.height, Self.stripHeight, accuracy: 0.5)
    }

    func testEmptyStripArea_hitsTheDragHandle() throws {
        let (window, drag) = try makeStrip()
        let gutter = drag.convert(NSPoint(x: 10, y: drag.bounds.midY), to: nil)
        XCTAssertTrue(
            window.contentView?.hitTest(gutter) is WindowDragHandle.DragView,
            "The strip beside the tabs must reach the drag handle, or the window can't be moved by it")
    }

    func testTabButton_isNotSwallowedByTheDragHandle() throws {
        let (window, drag) = try makeStrip()
        let tab = drag.convert(firstTabCentre(in: drag), to: nil)
        let hit = window.contentView?.hitTest(tab)
        XCTAssertNotNil(hit, "The tab centre must land inside the strip, or this test proves nothing")
        XCTAssertFalse(
            hit is WindowDragHandle.DragView,
            "A tab must keep its own click — the drag handle belongs behind the buttons")
    }
}
