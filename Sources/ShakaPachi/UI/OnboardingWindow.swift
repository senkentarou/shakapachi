// OnboardingWindow.swift
// Permission onboarding: app-icon header, one rounded card per permission
// with live status, and a single action per card.
// Switching to .regular activation policy while open lets the window come
// to front; reverts to .accessory on close.
// TCC grants happen in System Settings, outside this process, so the window
// polls permission status once per second while open instead of requiring
// the user to restart just to see the new state.

import AppKit

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let permissionManager: PermissionManager
    private let onStatusChange: (() -> Void)?
    private var pollTimer: Timer?

    private var accessibilityCard: PermissionCardView?
    private var screenRecordingCard: PermissionCardView?

    init(permissionManager: PermissionManager, onStatusChange: (() -> Void)? = nil) {
        self.permissionManager = permissionManager
        self.onStatusChange = onStatusChange
        super.init()
    }

    // MARK: - Public

    /// Returns true when the onboarding window is currently displayed.
    /// SettingsWindow uses this to decide whether to revert the activation policy.
    var isWindowOpen: Bool { window != nil }

    func show() {
        if let win = window {
            // Re-triggering must reliably surface the window: activating and
            // ordering front regardless is what makes it appear when the app is
            // not frontmost or the window sits on another Space (otherwise the
            // button looks like it did nothing).
            win.raiseToFront()
            return
        }

        // Bring app to front so the window is visible.
        WindowPresentationCoordinator.shared.windowDidOpen()

        let win = makeWindow()
        win.delegate = self
        let content = makeContentView()
        win.contentView = content
        // The content rect passed to NSWindow.init is a placeholder; size the
        // window from the Auto Layout fitting size so wrapped labels never clip.
        win.setContentSize(content.fittingSize)
        win.center()
        // Keep the onboarding window findable: float above other windows and
        // follow the user onto whichever Space is active.
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.window = win

        win.raiseToFront()
        startPolling()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        // Revert to .accessory only when no other presentation-managed window
        // is open. WindowPresentationCoordinator tracks the shared count so
        // closing this window while Settings is open does not revert the policy.
        WindowPresentationCoordinator.shared.windowDidClose()
        window = nil
    }

    // MARK: - Live status polling

    private func startPolling() {
        refreshStatuses()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            // Timers scheduled on the main run loop fire on the main thread.
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.refreshStatuses()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refreshStatuses() {
        accessibilityCard?.setGranted(permissionManager.accessibilityStatus() == .granted)
        screenRecordingCard?.setGranted(permissionManager.screenRecordingStatus() == .granted)
        onStatusChange?()
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "ShakaPachi"
        win.isReleasedWhenClosed = false
        return win
    }

    // MARK: - Content view

    private static let contentWidth: CGFloat = 440

    private func makeContentView() -> NSView {
        let header = makeHeader()

        let axCard = PermissionCardView(
            name: NSLocalizedString("アクセシビリティ", comment: "Permission name: accessibility"),
            benefit: NSLocalizedString("切替キーの捕捉と、選んだウィンドウの前面化に使います。", comment: "Accessibility permission benefit"),
            target: self,
            action: #selector(grantAccessibility)
        )
        accessibilityCard = axCard

        let srCard = PermissionCardView(
            name: NSLocalizedString("画面収録", comment: "Permission name: screen recording"),
            benefit: NSLocalizedString(
                "ウィンドウ名の取得と、プレビュー表示に使います。録画やファイルへの保存はしません。",
                comment: "Screen recording permission benefit"),
            target: self,
            action: #selector(grantScreenRecording)
        )
        screenRecordingCard = srCard

        let footer = makeFooter()

        let stack = NSStackView(views: [header, axCard, srCard, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(28, after: header)
        stack.setCustomSpacing(24, after: srCard)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // NSWindow manages its contentView's frame directly (autoresizing),
        // so the container must keep translatesAutoresizingMaskIntoConstraints
        // enabled; only the inner stack uses Auto Layout.
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            axCard.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            srCard.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            footer.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])

        return container
    }

    private func makeHeader() -> NSView {
        // The shipped icon itself (see AppIconImage), not a hand-drawn look-alike:
        // the tile this used to draw had its own corner radius, flat accent-colour
        // background and larger glyph, so the first screen the user ever sees
        // showed an icon that did not match the app's real one.
        let iconView = NSImageView(image: AppIconImage.bundled)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])

        let title = NSTextField(labelWithString: "ShakaPachi")
        title.font = .boldSystemFont(ofSize: 26)

        let subtitle = NSTextField(
            labelWithString: NSLocalizedString(
                "ウィンドウを切り替えるには 2 つの権限が必要です。", comment: "Onboarding subtitle: two permissions required"))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let header = NSStackView(views: [iconView, textStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        return header
    }

    private func makeFooter() -> NSView {
        let helper = NSTextField(
            wrappingLabelWithString:
                NSLocalizedString(
                    "「設定を開く」を押して ShakaPachi をオンにしてください。この画面は自動で更新されます。画面収録は再起動後に反映されます。",
                    comment: "Onboarding footer helper text"))
        helper.font = .systemFont(ofSize: 11)
        helper.textColor = .secondaryLabelColor
        helper.preferredMaxLayoutWidth = 240
        helper.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let restartButton = NSButton(
            title: NSLocalizedString("再起動", comment: "Button: restart app"), target: self, action: #selector(relaunch))
        restartButton.bezelStyle = .rounded
        restartButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [helper, restartButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        // Right-align the buttons: .fill lets the low-hugging helper label
        // stretch, pushing the buttons to the trailing edge.
        footer.distribution = .fill
        return footer
    }

    // MARK: - Button actions

    @objc private func grantAccessibility() {
        // Register the app in the Accessibility list (system prompt), then
        // open the pane so the user only has to flip the toggle.
        permissionManager.requestAccessibility()
        permissionManager.openAccessibilitySettings()
    }

    @objc private func grantScreenRecording() {
        permissionManager.requestScreenRecording()
        permissionManager.openScreenRecordingSettings()
    }

    @objc private func relaunch() {
        permissionManager.relaunchApp()
    }
}

// MARK: - Permission card

/// One rounded card per permission: status icon, name + benefit copy, and a
/// single action button that becomes a disabled "Granted" (「許可済み」) once granted.
@MainActor
private final class PermissionCardView: NSView {

    private let statusIconView = NSImageView()
    private let actionButton: NSButton
    private var granted = false

    init(name: String, benefit: String, target: AnyObject, action: Selector) {
        actionButton = NSButton(
            title: NSLocalizedString("設定を開く", comment: "Button: open system settings"), target: target, action: action)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10

        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusIconView.widthAnchor.constraint(equalToConstant: 28),
            statusIconView.heightAnchor.constraint(equalToConstant: 28),
        ])

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .boldSystemFont(ofSize: 15)

        let benefitLabel = NSTextField(wrappingLabelWithString: benefit)
        benefitLabel.font = .systemFont(ofSize: 12)
        benefitLabel.textColor = .secondaryLabelColor
        benefitLabel.preferredMaxLayoutWidth = 240

        let textStack = NSStackView(views: [nameLabel, benefitLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        actionButton.bezelStyle = .rounded

        let row = NSStackView(views: [statusIconView, textStack, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        // .fill (not the default .gravityAreas, which packs everything to the
        // leading edge) so the low-hugging text stack absorbs leftover width
        // and the action button sits flush right.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        // Explicit inset constants instead of NSStackView.edgeInsets so the
        // card padding is unambiguous.
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])

        setGranted(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func setGranted(_ newValue: Bool) {
        // Called every poll tick; skip the UI churn when nothing changed
        // (except the first call, which must populate the initial state).
        if statusIconView.image != nil && granted == newValue { return }
        granted = newValue

        if newValue {
            statusIconView.image = NSImage(
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: NSLocalizedString("許可済み", comment: "Permission status: granted")
            )?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
            statusIconView.contentTintColor = .systemGreen
            actionButton.title = NSLocalizedString("許可済み", comment: "Button title: already granted")
            actionButton.isEnabled = false
        } else {
            statusIconView.image = NSImage(
                systemSymbolName: "circle.dashed",
                accessibilityDescription: NSLocalizedString("未許可", comment: "Permission status: not granted")
            )?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
            statusIconView.contentTintColor = .tertiaryLabelColor
            actionButton.title = NSLocalizedString("設定を開く", comment: "Button: open system settings")
            actionButton.isEnabled = true
        }
    }

    // Card fill uses a dynamic color resolved in updateLayer so it adapts
    // when the system appearance changes (layers don't do this on their own).
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.06).cgColor
    }
}
