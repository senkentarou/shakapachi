// IconCache.swift
// Cache app icons, resized once at store-time so draw() never pays for
// scaling at runtime.
//
// Note: the original spec called for 20×20 icons for 28pt rows. The design
// uses a horizontal tile layout with 76pt tiles and 60pt icons
// (SwitcherLayout.iconSize), so icons are cached at 60×60 instead — the stored
// image matches the drawn size exactly.

import AppKit
import Foundation
import UniformTypeIdentifiers

final class IconCache {

    // Cache key is bundleID when available; falls back to "pid:<pid>" for
    // processes that have no bundle (e.g. command-line tools).
    private var cache: [String: NSImage] = [:]

    // MARK: - Lifecycle

    init() {
        // Evict entries when an app terminates so stale icons don't accumulate.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Public API

    /// Return a cached, pre-scaled icon for the given process.
    ///
    /// - Parameters:
    ///   - pid: The process identifier of the running application.
    ///   - bundleID: The bundle identifier, if available.  Used as the cache key.
    /// - Returns: A 60×60 NSImage.  Never nil — falls back to the generic
    ///   application bundle icon when the process icon cannot be retrieved.
    func icon(for pid: pid_t, bundleID: String?) -> NSImage {
        let key = cacheKey(pid: pid, bundleID: bundleID)
        if let cached = cache[key] {
            return cached
        }
        let image = resolveIcon(for: pid)
        let sized = resize(image, to: IconCache.targetSize)
        cache[key] = sized
        return sized
    }

    // MARK: - Private helpers

    /// The target edge length for cached icons, matching SwitcherLayout.iconSize.
    static let targetSize: CGFloat = 60

    private func cacheKey(pid: pid_t, bundleID: String?) -> String {
        bundleID ?? "pid:\(pid)"
    }

    /// Retrieve the icon for the given process, preferring a direct read of
    /// the bundled .icns over `NSRunningApplication.icon`. The latter is
    /// served from macOS's IconServices cache, which keeps returning a stale
    /// icon after the bundled icns changes (until the system icon cache is
    /// cleared), so a rebuilt icon would not show here. Reading the file
    /// directly always reflects the shipped icon.
    private func resolveIcon(for pid: pid_t) -> NSImage {
        let app = NSRunningApplication(processIdentifier: pid)
        if let bundleURL = app?.bundleURL,
            let iconURL = IconCache.bundledIconURL(forBundleAt: bundleURL),
            let image = NSImage(contentsOf: iconURL)
        {
            return image
        }
        // Fallback: apps that ship their icon only inside an asset catalog
        // (no .icns file under Contents/Resources) have nothing for
        // `bundledIconURL` to find; `NSRunningApplication.icon` is the only
        // source available for those, stale-cache risk notwithstanding.
        if let icon = app?.icon {
            return icon
        }
        // Fallback: generic app icon that NSWorkspace provides for any .app bundle.
        return NSWorkspace.shared.icon(for: .application)
    }

    /// Resolve the .icns file inside an application bundle, or nil when the
    /// bundle ships its icon only inside an asset catalog.
    ///
    /// `CFBundleIconFile` in Info.plist may or may not include the `.icns`
    /// extension (in practice it's usually omitted, e.g. "AppIcon"), so the
    /// extension is appended when missing. When Info.plist has no
    /// `CFBundleIconFile` key at all, "AppIcon.icns" — the common convention
    /// — is tried as a last-resort candidate. Either way, the candidate is
    /// only returned once its existence on disk is confirmed.
    static func bundledIconURL(forBundleAt bundleURL: URL) -> URL? {
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources")
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")

        var candidateName: String?
        if let data = try? Data(contentsOf: infoPlistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let iconFile = plist["CFBundleIconFile"] as? String
        {
            candidateName = iconFile
        }

        let name = candidateName ?? "AppIcon"
        let fileName = name.hasSuffix(".icns") ? name : name + ".icns"
        let iconURL = resourcesURL.appendingPathComponent(fileName)

        return FileManager.default.fileExists(atPath: iconURL.path) ? iconURL : nil
    }

    /// Draw `source` into a new `size × size` bitmap, returning the result.
    /// This is done once at cache-fill time; subsequent draws are a plain blit.
    private func resize(_ source: NSImage, to edge: CGFloat) -> NSImage {
        let targetSize = NSSize(width: edge, height: edge)
        return NSImage(size: targetSize, flipped: false) { bounds in
            source.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            return true
        }
    }

    // MARK: - Eviction

    @objc private func appDidTerminate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        // Remove by bundleID if present, and also by pid-keyed entry.
        if let bid = app.bundleIdentifier {
            cache.removeValue(forKey: bid)
        }
        cache.removeValue(forKey: "pid:\(app.processIdentifier)")
    }
}
