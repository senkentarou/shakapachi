// UpdateWindow.swift
// Hosts the SwiftUI UpdateView in an NSWindow.
// Mirrors SettingsWindow.swift: NSObject + NSWindowDelegate, NSHostingController,
// WindowPresentationCoordinator for activation-policy management.

import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the Update window opens (`open: true`) or closes (`open: false`)
    /// so the menu-bar icon can show its blue "info" state, mirroring
    /// settingsWindowStateChanged.
    static let updateWindowStateChanged =
        Notification.Name("com.masahirosenda.shakapachi.updateWindowStateChanged")
}

// MARK: - UpdateWindow

@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let viewModel = UpdateViewModel()

    // Fixed window size: sized for the richest state (update available with
    // release notes). Simpler states center their content within the same frame
    // so the window never resizes as the status changes.
    private static let windowSize = NSSize(width: 460, height: 520)

    // MARK: - Public

    func show() {
        NotificationCenter.default.post(
            name: .updateWindowStateChanged, object: nil, userInfo: ["open": true])
        if let win = window {
            win.raiseToFront()
            return
        }

        WindowPresentationCoordinator.shared.windowDidOpen()

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = NSLocalizedString("アップデート", comment: "Update window title")
        win.isReleasedWhenClosed = false
        win.center()
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.delegate = self

        let closeAction: () -> Void = { [weak self] in self?.close() }
        let hostingController = NSHostingController(
            rootView: UpdateView(viewModel: viewModel, onClose: closeAction))
        win.contentViewController = hostingController
        win.setContentSize(Self.windowSize)

        self.window = win
        win.raiseToFront()
    }

    func close() {
        window?.close()
    }

    /// Forward a new status into the view model so the SwiftUI view re-renders.
    /// AppDelegate calls this whenever UpdateManager.onStatusChange fires.
    func apply(_ status: UpdateManager.Status) {
        viewModel.status = status
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(
            name: .updateWindowStateChanged, object: nil, userInfo: ["open": false])
        WindowPresentationCoordinator.shared.windowDidClose()
        window = nil
    }
}

// MARK: - UpdateViewModel

final class UpdateViewModel: ObservableObject {
    @Published var status: UpdateManager.Status = .idle
}

// MARK: - UpdateView

/// A macOS-native update dialog. Every status shares one frame: an identity
/// header (app icon + name + a one-line status subtitle) on top, then a body
/// that fills the rest with the state-specific content and a bottom action bar.
struct UpdateView: View {

    @ObservedObject var viewModel: UpdateViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 460, height: 520)
    }

    // MARK: - Header

    /// App identity + one-line status, shown in every state so the window is
    /// always recognisable and never anonymous.
    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(appName)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(statusSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var statusSubtitle: String {
        switch viewModel.status {
        case .idle, .checking:
            return NSLocalizedString("アップデートを確認しています…", comment: "Update header subtitle: checking")
        case .upToDate:
            return NSLocalizedString("お使いのバージョンは最新です", comment: "Update header subtitle: up to date")
        case .available:
            return NSLocalizedString("新しいバージョンがあります", comment: "Update header subtitle: update available")
        case .downloading:
            return NSLocalizedString("ダウンロードしています…", comment: "Update header subtitle: downloading")
        case .verifying:
            return NSLocalizedString("署名を検証しています…", comment: "Update header subtitle: verifying")
        case .installing:
            return NSLocalizedString("インストールしています…", comment: "Update header subtitle: installing")
        case .failed:
            return NSLocalizedString("エラーが発生しました", comment: "Update header subtitle: error")
        }
    }

    // MARK: - Body content

    @ViewBuilder
    private var content: some View {
        switch viewModel.status {
        case .idle, .checking:
            centeredStatus(caption: nil, closable: true)
        case .upToDate:
            upToDateContent
        case .available(let release):
            availableContent(release: release)
        case .downloading(let progress):
            downloadingContent(progress: progress)
        case .verifying:
            centeredStatus(caption: nil, closable: false)
        case .installing:
            centeredStatus(
                caption: NSLocalizedString(
                    "まもなくアプリが再起動します", comment: "Installing caption: app will restart"),
                closable: false)
        case .failed(let message):
            failedContent(message: message)
        }
    }

    /// Update available: version transition, release notes in a subtle inset, and
    /// a bottom action bar (skip on the left as a subtle link; Later + the primary
    /// Install button on the right, following macOS convention).
    private func availableContent(release: ReleaseInfo) -> some View {
        let notesBlocks = ReleaseNotesMarkdown.parse(releaseNotesText(release))
        return VStack(alignment: .leading, spacing: 14) {
            // Compact version transition.
            HStack(spacing: 8) {
                Text(UpdateManager.shared.currentVersion.description)
                    .foregroundColor(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(release.version.description)
                    .fontWeight(.semibold)
            }
            .font(.callout)

            // Release-notes section caption with a subtle "open on GitHub" link.
            HStack {
                Text(NSLocalizedString("リリースノート", comment: "Section caption: release notes"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Button(NSLocalizedString("GitHub で開く", comment: "Link: open release page on GitHub")) {
                    UpdateManager.shared.openReleasePage()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            // Release notes (markdown-rendered) in a subtle inset that grows to fill.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    // ReleaseNoteBlock is not Identifiable, so key the ForEach off
                    // the array offset — blocks never reorder within one render.
                    ForEach(Array(notesBlocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            // Bottom action bar: Later + the primary Install button (macOS convention).
            HStack(spacing: 10) {
                Spacer()
                Button(NSLocalizedString("後で", comment: "Button: remind later")) {
                    onClose()
                }
                Button(
                    NSLocalizedString(
                        "インストールして再起動", comment: "Button: install and relaunch")
                ) {
                    UpdateManager.shared.downloadAndInstall()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    /// Up to date: a reassuring checkmark, the current version, and a close button.
    private var upToDateContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.green)
            Text(
                String(
                    format: NSLocalizedString(
                        "バージョン %@ をお使いです", comment: "Up to date: current version"),
                    UpdateManager.shared.currentVersion.description)
            )
            .font(.callout)
            .foregroundColor(.secondary)
            Spacer()
            HStack {
                if UpdateManager.shared.latestRelease != nil {
                    Button(NSLocalizedString("GitHub で開く", comment: "Link: open release page on GitHub")) {
                        UpdateManager.shared.openReleasePage()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Spacer()
                Button(NSLocalizedString("閉じる", comment: "Button: close")) { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    /// Downloading: a linear progress bar plus a percentage caption.
    private func downloadingContent(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text(
                String(
                    format: NSLocalizedString("%d%% 完了", comment: "Download progress percent"),
                    Int(progress * 100))
            )
            .font(.caption)
            .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    /// Shared centered spinner for the transient checking / verifying / installing
    /// states. `caption` is optional extra text; `closable` adds a close button.
    private func centeredStatus(caption: String?, closable: Bool) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if closable {
                HStack {
                    Spacer()
                    Button(NSLocalizedString("閉じる", comment: "Button: close")) { onClose() }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    /// Failure: an icon, the error message, and retry / close actions.
    private func failedContent(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button(NSLocalizedString("閉じる", comment: "Button: close")) { onClose() }
                Button(NSLocalizedString("再試行", comment: "Button: retry update check")) {
                    UpdateManager.shared.checkForUpdates(userInitiated: true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    // MARK: - Helpers

    /// The app's display name, read from the bundle (falls back to the product name).
    private var appName: String {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "ShakaPachi"
    }

    /// Release notes with a redundant leading "ShakaPachi vX.Y.Z" title (and any
    /// following dash/separator) stripped — the header and version row already
    /// convey the app name and version, so repeating them in the notes is noise.
    /// The remainder is then narrowed to the section matching the app's current
    /// language (see ReleaseNotesMarkdown.localizedSection), so a bilingual
    /// release body only shows the reader's language.
    private func releaseNotesText(_ release: ReleaseInfo) -> String {
        let trimmed = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return NSLocalizedString(
                "（リリースノートはありません）", comment: "Placeholder when a release has no notes")
        }
        let prefix = "\(appName) v\(release.version.description)"
        let titleStripped: String
        if trimmed.hasPrefix(prefix) {
            let separators = CharacterSet(charactersIn: " -—–ー・:：\t")
            let remainder = trimmed.dropFirst(prefix.count).drop { ch in
                ch.unicodeScalars.allSatisfy { separators.contains($0) }
            }
            let result = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
            titleStripped = result.isEmpty ? trimmed : result
        } else {
            titleStripped = trimmed
        }
        return ReleaseNotesMarkdown.localizedSection(
            from: titleStripped, language: releaseNotesLanguageCode)
    }

    /// The app's current UI language, for picking a release-notes section.
    /// This app switches language by writing `AppleLanguages` and letting
    /// `Bundle.main` resolve it, so `Locale.current` would not reflect an
    /// in-app override — `Bundle.main.preferredLocalizations` does.
    private var releaseNotesLanguageCode: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return String(preferred.split(separator: "-").first ?? Substring(preferred))
    }

    // MARK: - Release-notes markdown

    /// Parse a single line's inline markdown (bold/italic/links/code), preserving
    /// whitespace. Block-level structure (headings, lists, tables, ...) is
    /// resolved beforehand by ReleaseNotesMarkdown.parse; this only handles the
    /// text inside one block.
    private func inlineMarkdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(string)
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNoteBlock) -> some View {
        switch block {
        case .heading(_, let text):
            Text(inlineMarkdown(text))
                .font(.callout)
                .fontWeight(.bold)
                .padding(.top, 6)
        case .listItem(let indent, let marker, let text):
            listItemView(indent: indent, marker: marker, text: text)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let lines):
            quoteView(lines)
        case .table(let table):
            tableView(table)
        case .code(let raw):
            codeView(raw)
        case .rule:
            Divider().padding(.vertical, 4)
        case .blank:
            Color.clear.frame(height: 2)
        }
    }

    /// `•` for a bullet, or `"n."` for an ordered item, indented per nesting level.
    private func listItemView(indent: Int, marker: ReleaseNoteListMarker, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker.label).foregroundColor(.secondary)
            Text(inlineMarkdown(text))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    /// A left-hand accent bar (stretched to the text height by the HStack)
    /// followed by the quoted lines, dimmed to read as secondary content.
    private func quoteView(_ lines: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(inlineMarkdown(line))
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// GFM table rendered with a native Grid: bold header row, a full-width
    /// divider, then one GridRow per body row. Column alignment comes from the
    /// delimiter row and is applied once via the header cells.
    private func tableView(_ table: ReleaseNoteTable) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { columnIndex, cell in
                    Text(inlineMarkdown(cell))
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridColumnAlignment(table.alignments[columnIndex].horizontalAlignment)
                }
            }
            GridRow {
                // Unsized on the horizontal axis so the full-width divider does
                // not itself dictate a column's width.
                Divider()
                    .gridCellColumns(table.header.count)
                    .gridCellUnsizedAxes(.horizontal)
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(inlineMarkdown(cell))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Fenced code block: monospaced, unparsed, on a subtle full-width backing.
    private func codeView(_ raw: String) -> some View {
        Text(raw)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension ReleaseNoteListMarker {
    fileprivate var label: String {
        switch self {
        case .bullet: return "•"
        case .ordered(let n): return "\(n)."
        }
    }
}

extension ReleaseNoteTableAlignment {
    fileprivate var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
