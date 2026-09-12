// UpdateChecker.swift
// Fetches and parses the latest GitHub release metadata.
// Parsing is kept pure (no network I/O) so it can be unit-tested in isolation.

import Foundation

// MARK: - UpdateError

/// Errors the update pipeline can produce. errorDescription is English so it
/// can be passed through NSLocalizedString at call sites if needed.
enum UpdateError: LocalizedError {
    case networkError(Error)
    case httpError(Int)         // HTTP status code other than 2xx
    case noMatchingAsset        // no ShakaPachi-*.zip asset in the release
    case parseError(String)     // JSON shape was not what we expected
    case verifyFailed(String)   // code-signature verification rejected the bundle
    case installFailed(String)  // helper script or ditto failed
    case notWritable            // destination path is not writable and auth was cancelled

    var errorDescription: String? {
        switch self {
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .httpError(let code):
            return "GitHub API returned HTTP \(code)"
        case .noMatchingAsset:
            return "No ShakaPachi-*.zip asset found in the latest release"
        case .parseError(let detail):
            return "Failed to parse release data: \(detail)"
        case .verifyFailed(let detail):
            return "Code signature verification failed: \(detail)"
        case .installFailed(let detail):
            return "Installation failed: \(detail)"
        case .notWritable:
            return "Update cancelled: destination is not writable and authorization was denied"
        }
    }
}

// MARK: - UpdateChecker

/// Fetches the latest release from GitHub and parses the response.
/// `parseLatestRelease` is a pure function so tests can feed fixture JSON
/// without touching the network.
struct UpdateChecker {

    // MARK: - Pure JSON parsing

    /// Parse a GitHub `/releases/latest` response body and return a `ReleaseInfo`.
    /// Throws `UpdateError.parseError` or `UpdateError.noMatchingAsset` on failure.
    static func parseLatestRelease(from data: Data) throws -> ReleaseInfo {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.parseError("Response is not a JSON object")
        }

        // tag_name is mandatory — it carries the version.
        guard let tagName = root["tag_name"] as? String else {
            throw UpdateError.parseError("Missing 'tag_name' field")
        }
        guard let version = SemanticVersion(tagName) else {
            throw UpdateError.parseError("Cannot parse SemanticVersion from tag '\(tagName)'")
        }

        let releaseName = root["name"] as? String
        let notes = (root["body"] as? String) ?? ""

        guard let htmlURLString = root["html_url"] as? String,
              let htmlURL = URL(string: htmlURLString)
        else {
            throw UpdateError.parseError("Missing or invalid 'html_url'")
        }

        // Parse published_at as ISO 8601.
        var publishedAt: Date?
        if let dateString = root["published_at"] as? String {
            let formatter = ISO8601DateFormatter()
            publishedAt = formatter.date(from: dateString)
        }

        // Find the first asset whose name matches "ShakaPachi-*.zip".
        guard let assets = root["assets"] as? [[String: Any]] else {
            throw UpdateError.noMatchingAsset
        }
        guard let asset = assets.first(where: {
            guard let name = $0["name"] as? String else { return false }
            return name.hasPrefix("ShakaPachi-") && name.hasSuffix(".zip")
        }) else {
            throw UpdateError.noMatchingAsset
        }

        guard let assetName = asset["name"] as? String,
              let downloadURLString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString)
        else {
            throw UpdateError.parseError("Asset is missing 'name' or 'browser_download_url'")
        }

        let assetSize = (asset["size"] as? Int64) ?? ((asset["size"] as? Int).map(Int64.init) ?? 0)

        return ReleaseInfo(
            version: version,
            tagName: tagName,
            name: releaseName,
            notes: notes,
            htmlURL: htmlURL,
            downloadURL: downloadURL,
            assetName: assetName,
            assetSize: assetSize,
            publishedAt: publishedAt
        )
    }

    // MARK: - Network fetch

    /// Fetches the latest release metadata from the GitHub API.
    /// Throws on network failure, non-2xx HTTP status, or parse errors.
    func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: UpdateConfig.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ShakaPachi", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UpdateError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.httpError(http.statusCode)
        }

        return try UpdateChecker.parseLatestRelease(from: data)
    }
}
