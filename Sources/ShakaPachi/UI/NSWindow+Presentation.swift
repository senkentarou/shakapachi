// NSWindow+Presentation.swift
// Shared window presentation helpers used by SettingsWindow and OnboardingWindow.
// Extracted to eliminate duplicate raiseToFront implementations and centralize
// the macOS 14+ NSApp.activate() API branch.

import AppKit

// MARK: - NSWindow convenience

extension NSWindow {

    /// Bring this window to the absolute front on the active Space.
    /// Handles the deprecated activate(ignoringOtherApps:) on macOS < 14.
    func raiseToFront() {
        NSApp.activateFocused()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}

// MARK: - NSApplication convenience

extension NSApplication {

    /// Activate the application, using the non-deprecated API on macOS 14+.
    func activateFocused() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Open-window counter (activation policy coordinator)

/// Tracks how many presentation-managed windows are currently open.
/// The activation policy reverts to .accessory only when this counter reaches zero,
/// which fixes the asymmetry bug where closing one window while another is open
/// would incorrectly revert .regular → .accessory.
///
/// Side effects (setActivationPolicy / activate) are injected via closures so that
/// tests can drive a real instance without touching NSApp. The shared singleton uses
/// the live NSApp closures; tests supply recording stubs.
@MainActor
final class WindowPresentationCoordinator {

    /// Live singleton: delegates both side effects to NSApp.
    static let shared = WindowPresentationCoordinator(
        setPolicy: { NSApp.setActivationPolicy($0) },
        activate: { NSApp.activateFocused() }
    )

    private var openCount = 0
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private let activate: () -> Void

    init(
        setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void,
        activate: @escaping () -> Void
    ) {
        self.setPolicy = setPolicy
        self.activate = activate
    }

    /// Call when a managed window opens.
    func windowDidOpen() {
        openCount += 1
        if openCount == 1 {
            // First window: switch to regular so the window can come to front.
            setPolicy(.regular)
            activate()
        }
    }

    /// Call when a managed window closes.
    /// Reverts the activation policy to .accessory only after the last window closes.
    func windowDidClose() {
        openCount = max(0, openCount - 1)
        if openCount == 0 {
            setPolicy(.accessory)
        }
    }
}
