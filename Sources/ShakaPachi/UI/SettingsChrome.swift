// SettingsChrome.swift
// Shared look of the settings window: palette, metrics, and the card / row /
// tab-bar building blocks every settings tab is assembled from.
//
// The settings screen is deliberately NOT built on SwiftUI's `Form(.grouped)`:
// grouped Form owns its own insets, header typography, and separator placement,
// none of which can be pushed to the flatter card look this window wants (a
// 10pt card with a hairline border, 13pt title over an 11pt caption, and a
// separator that stops before the last row). Composing the card out of plain
// containers keeps all of those values in this one file.
//
// Colours are declared as dynamic NSColors rather than asset catalog entries so
// they resolve against whichever NSAppearance the window is running under — the
// window follows the app's theme setting, which can differ from the system one.

import AppKit
import SwiftUI

// MARK: - Tokens

enum SettingsChrome {

    // MARK: Metrics

    /// Corner radius of a settings card.
    static let cardRadius: CGFloat = 10
    /// Corner radius of a tab-bar button's tint.
    static let tabRadius: CGFloat = 10
    /// Padding inside a row, left and right.
    static let rowHorizontalPadding: CGFloat = 16
    /// Padding inside a row, top and bottom.
    static let rowVerticalPadding: CGFloat = 14
    /// Gap between the label block and the trailing control of a row.
    static let rowControlSpacing: CGFloat = 16
    /// Vertical gap between cards on a page.
    static let cardSpacing: CGFloat = 16
    /// Page margin around the stack of cards.
    static let pagePadding: CGFloat = 20
    /// Height reserved for the transparent title bar the header is drawn under.
    /// `SettingsTabBar` is the single place that pays this inset, which is why
    /// the root view ignores the safe area — otherwise the system inset and
    /// this one stack up.
    static let titleBarHeight: CGFloat = 28
    /// Size of one tab-bar button.
    static let tabSize = CGSize(width: 76, height: 50)
    /// Gap between tab-bar buttons.
    static let tabSpacing: CGFloat = 8

    // MARK: Fonts

    static let rowTitleFont = Font.system(size: 13)
    static let rowCaptionFont = Font.system(size: 11)
    static let sectionHeaderFont = Font.system(size: 11, weight: .semibold)
    static let tabLabelFont = Font.system(size: 11)

    // MARK: Palette

    /// Page background, behind the cards.
    static let background = dynamic(dark: rgb(0x1C, 0x1C, 0x1E), light: rgb(0xF2, 0xF2, 0xF7))
    /// Card fill, and the header strip that merges with the title bar.
    static let surface = dynamic(dark: rgb(0x2C, 0x2C, 0x2E), light: rgb(0xFF, 0xFF, 0xFF))
    /// Card border and the hairline between rows.
    static let border = dynamic(dark: rgb(0x38, 0x38, 0x3A), light: rgb(0xD1, 0xD1, 0xD6))
    /// Row titles.
    static let primaryText = dynamic(dark: rgb(0xF5, 0xF5, 0xF7), light: rgb(0x1C, 0x1C, 0x1E))
    /// Row captions and unselected tabs.
    static let secondaryText = dynamic(dark: rgb(0x98, 0x98, 0x9D), light: rgb(0x8E, 0x8E, 0x93))
    /// Section headers above a card.
    static let tertiaryText = dynamic(dark: rgb(0x63, 0x63, 0x66), light: rgb(0xAE, 0xAE, 0xB2))

    /// Fill behind the selected tab. The system accent is used here rather than
    /// the app's own `AccentColor` setting: that palette is tuned for the
    /// switcher panel (low saturation, and `.patina` even shifts with usage), so
    /// as a selection tint it reads as "no tab is selected".
    static var selectedTabTint: Color { Color.accentColor.opacity(0.16) }

    // MARK: Colour helpers

    /// A colour that resolves per appearance, so the window can be dark while
    /// the system is light (and the other way round).
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

// MARK: - Page

/// One tab's content: a scrolling column of cards over the page background.
/// Scrolling lives inside the page so switching tabs never resizes the window.
struct SettingsPage<Content: View>: View {

    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsChrome.cardSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsChrome.pagePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsChrome.background)
    }
}

// MARK: - Card

/// A rounded, bordered container holding one or more rows. Rows are separated
/// by `SettingsRowDivider`, placed explicitly by the caller — SwiftUI has no
/// public way to inject a separator between an opaque `ViewBuilder`'s children,
/// and an implicit "every row draws its own top hairline" rule would put one
/// above the first row too.
struct SettingsCard<Content: View>: View {

    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        // Cards span the page even when their content has an intrinsic width
        // (the heatmap and the appearance preview do), so every card on a page
        // lines up on both edges instead of one shrinking to fit its content.
        .frame(maxWidth: .infinity)
        .background(SettingsChrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsChrome.cardRadius, style: .continuous)
                .strokeBorder(SettingsChrome.border, lineWidth: 1)
        )
    }
}

/// A card with a small header above it (the header sits outside the card, so
/// the card's own top edge stays a clean rounded corner).
struct SettingsSection<Content: View>: View {

    let header: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(header))
                .font(SettingsChrome.sectionHeaderFont)
                .foregroundColor(SettingsChrome.tertiaryText)
                .padding(.leading, 4)
            SettingsCard { content }
        }
    }
}

/// The hairline between two rows of a card.
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsChrome.border)
            .frame(height: 1)
    }
}

// MARK: - Row

/// One settings line: an optional leading badge, a 13pt title over an optional
/// 11pt caption, and a trailing control.
struct SettingsRow<Leading: View, Trailing: View>: View {

    let title: String
    var caption: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: SettingsChrome.rowControlSpacing) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(SettingsChrome.rowTitleFont)
                    .foregroundColor(SettingsChrome.primaryText)
                if let caption {
                    Text(LocalizedStringKey(caption))
                        .font(SettingsChrome.rowCaptionFont)
                        .foregroundColor(SettingsChrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
        .padding(.vertical, SettingsChrome.rowVerticalPadding)
    }
}

extension SettingsRow where Leading == EmptyView {

    init(title: String, caption: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, caption: caption, leading: { EmptyView() }, trailing: trailing)
    }
}

extension SettingsRow where Leading == EmptyView, Trailing == EmptyView {

    init(title: String, caption: String? = nil) {
        self.init(title: title, caption: caption, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// A row whose control is too wide to sit beside the label (sliders, pickers
/// with long option names): the control is stacked under the label block and
/// spans the full row width.
struct SettingsStackedRow<Content: View>: View {

    let title: String
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(SettingsChrome.rowTitleFont)
                    .foregroundColor(SettingsChrome.primaryText)
                if let caption {
                    Text(LocalizedStringKey(caption))
                        .font(SettingsChrome.rowCaptionFont)
                        .foregroundColor(SettingsChrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
        .padding(.vertical, SettingsChrome.rowVerticalPadding)
    }
}

// MARK: - Tab bar

/// The header strip: icon-over-label tabs on the same surface colour as the
/// title bar. The window draws its content under a transparent title bar, so
/// the strip's top padding is what keeps the tabs clear of the traffic lights.
struct SettingsTabBar: View {

    struct Item: Identifiable, Equatable {
        let id: Int
        /// Localization key for the tab label.
        let title: String
        /// SF Symbol name.
        let symbol: String
    }

    let items: [Item]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: SettingsChrome.tabSpacing) {
            ForEach(items) { item in
                tab(item)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, SettingsChrome.titleBarHeight + 10)
        .padding(.bottom, 10)
        // The strip reads as one band with the title bar, so it drags the
        // window like one. The handle is scoped to the strip rather than turned
        // on window-wide (`isMovableByWindowBackground`), which would also move
        // the window when a drag starts on a card or the page background.
        .background {
            WindowDragHandle()
                .background(SettingsChrome.surface)
        }
        .overlay(alignment: .bottom) { SettingsRowDivider() }
    }

    private func tab(_ item: Item) -> some View {
        let isSelected = item.id == selection
        return Button {
            selection = item.id
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18, weight: .light))
                Text(LocalizedStringKey(item.title))
                    .font(SettingsChrome.tabLabelFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: SettingsChrome.tabSize.width, height: SettingsChrome.tabSize.height)
            .foregroundColor(isSelected ? Color.accentColor : SettingsChrome.secondaryText)
            .background(
                RoundedRectangle(cornerRadius: SettingsChrome.tabRadius, style: .continuous)
                    .fill(isSelected ? SettingsChrome.selectedTabTint : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: SettingsChrome.tabRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(item.title)))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Window drag

/// An invisible AppKit view that starts a window drag on mouse-down, so the
/// SwiftUI view it backs can be grabbed like a title bar. Put it in the
/// `.background` of that view: SwiftUI hit-tests it under the foreground
/// content, so controls drawn on top keep their own clicks.
struct WindowDragHandle: NSViewRepresentable {

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ nsView: DragView, context: Context) {}

    /// Draws nothing; it is in the hierarchy only to receive the mouse-down
    /// that hands the gesture over to the window.
    final class DragView: NSView {

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
