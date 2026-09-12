// UpdateManager.swift
// Orchestrates the full update lifecycle: check → download → verify → install.
// The UI layer observes `status` and `onStatusChange` to drive its display.
// All public properties and the callback are always accessed on the main thread.

import AppKit
import Foundation

// MARK: - UpdateManager

@MainActor
final class UpdateManager {

    // MARK: - Status

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(Double)    // 0.0...1.0
        case verifying
        case installing
        case failed(String)         // user-facing localized message
    }

    // MARK: - Singleton

    static let shared = UpdateManager()

    // MARK: - Public state

    private(set) var status: Status = .idle {
        didSet { onStatusChange?(status) }
    }

    /// Called on the main thread whenever `status` changes.
    var onStatusChange: ((Status) -> Void)?

    /// The release available for installation (non-nil when status == .available).
    private(set) var availableRelease: ReleaseInfo?

    /// The most recently fetched release, set on every successful check
    /// regardless of whether it is newer than `currentVersion`. Used by
    /// `openReleasePage()` so the release page can be opened even when the
    /// app is already up to date.
    private(set) var latestRelease: ReleaseInfo?

    // MARK: - Current version

    /// The version of the running app bundle, parsed once at init.
    var currentVersion: SemanticVersion {
        if let cached = _currentVersion { return cached }
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let version = SemanticVersion(raw) ?? SemanticVersion("0.0.0")!
        _currentVersion = version
        return version
    }
    private var _currentVersion: SemanticVersion?

    // MARK: - Persistence keys

    private enum DefaultsKey {
        static let autoCheckEnabled = "update.autoCheckEnabled"
        static let lastCheck        = "update.lastCheck"
    }

    /// Whether the app should check for updates automatically.
    /// Persisted in UserDefaults. Defaults to true.
    var autoCheckEnabled: Bool {
        get {
            let stored = UserDefaults.standard.object(forKey: DefaultsKey.autoCheckEnabled)
            return stored as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.autoCheckEnabled)
        }
    }

    // MARK: - Private state

    private var autoCheckTimer: Timer?
    private var isChecking = false

    // MARK: - Init

    private init() {}

    // MARK: - Auto-check scheduling

    /// Schedules an initial check shortly after launch and repeats every 24 hours.
    /// Has no effect if `autoCheckEnabled` is false.
    func startAutoCheck() {
        guard autoCheckEnabled else { return }

        // Initial check: 10 seconds after launch so startup is not impacted.
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            checkForUpdates(userInitiated: false)
        }

        // Repeat every 24 hours.
        let interval: TimeInterval = 24 * 60 * 60
        autoCheckTimer?.invalidate()
        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForUpdates(userInitiated: false)
            }
        }
    }

    // MARK: - Check for updates

    /// Fetches the latest release. Updates `status` and `availableRelease`.
    /// If `userInitiated` is false and auto-check is disabled, returns immediately.
    func checkForUpdates(userInitiated: Bool) {
        guard userInitiated || autoCheckEnabled else { return }
        guard !isChecking else { return }
        isChecking = true
        status = .checking

        Task {
            defer { Task { @MainActor in self.isChecking = false } }
            do {
                let checker = UpdateChecker()
                let release = try await checker.fetchLatest()

                await MainActor.run {
                    UserDefaults.standard.set(Date(), forKey: DefaultsKey.lastCheck)
                    self.latestRelease = release

                    if release.version > self.currentVersion {
                        self.availableRelease = release
                        self.status = .available(release)
                    } else {
                        self.status = .upToDate
                    }
                }
            } catch {
                await MainActor.run {
                    self.status = .failed(
                        NSLocalizedString(
                            "update.error.checkFailed",
                            value: "Failed to check for updates: \(error.localizedDescription)",
                            comment: "Shown when the update check network request or parse fails"
                        )
                    )
                }
            }
        }
    }

    // MARK: - Download and install

    /// Runs the full pipeline: download → extract → verify → install helper → terminate.
    /// Drives status through .downloading / .verifying / .installing / .failed.
    func downloadAndInstall() {
        guard let release = availableRelease else {
            status = .failed(
                NSLocalizedString(
                    "update.error.noReleaseAvailable",
                    value: "No update is available to install.",
                    comment: "Shown when downloadAndInstall is called but availableRelease is nil"
                )
            )
            return
        }

        Task {
            do {
                // -- Download --
                let downloader = UpdateDownloader()
                let zipURL = try await downloader.download(release) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.status = .downloading(fraction)
                    }
                }

                // -- Extract --
                await MainActor.run { self.status = .verifying }
                let extractDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ShakaPachi-Extracted-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
                let extractedApp = try UpdateVerifier.extract(zipAt: zipURL, to: extractDir)

                // -- Verify --
                try UpdateVerifier.verify(appAt: extractedApp, expectedVersion: release.version)

                // -- Install --
                await MainActor.run { self.status = .installing }
                guard let bundlePath = Bundle.main.bundlePath as String? else {
                    throw UpdateError.installFailed("Cannot determine current bundle path")
                }
                let destApp = URL(fileURLWithPath: bundlePath)

                try UpdateInstaller.makeAndLaunchHelper(newApp: extractedApp, destApp: destApp)

                // Terminate so the helper can proceed with the swap.
                await MainActor.run { NSApp.terminate(nil) }

            } catch {
                await MainActor.run {
                    self.status = .failed(
                        NSLocalizedString(
                            "update.error.installFailed",
                            value: "Update failed: \(error.localizedDescription)",
                            comment: "Shown when the download, verify, or install step fails"
                        )
                    )
                }
            }
        }
    }

    // MARK: - Open release page

    /// Opens the GitHub release page in the default browser.
    func openReleasePage() {
        guard let release = latestRelease else { return }
        NSWorkspace.shared.open(release.htmlURL)
    }
}
