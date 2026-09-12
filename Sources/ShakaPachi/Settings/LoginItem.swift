// LoginItem.swift
// Register/unregister the app as a Login Item via SMAppService (macOS 13+).
// SMAppService is used deliberately rather than a hand-written LaunchAgent plist
// — the system manages the registration lifecycle and handles permission changes.
//
// SMAppService.mainApp.status is the authoritative source of truth for whether
// the app launches at login — the Settings bool is only a cached mirror for the
// UI. Always read status() for the real state.

import Foundation
import ServiceManagement

enum LoginItemManager {

    /// Whether the app is currently registered to launch at login.
    /// Reads the live SMAppService status rather than the cached Settings bool.
    @MainActor
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the main app as a login item.
    /// Throws if the system rejects the request (e.g. the app is not in a
    /// launchable location or the registration is denied by the user).
    @MainActor
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            // register() is idempotent-ish but throws if already registered in
            // some states; guard on status to avoid a spurious throw.
            if service.status != .enabled {
                try service.register()
            }
        } else {
            if service.status == .enabled {
                try service.unregister()
            }
        }
    }
}
