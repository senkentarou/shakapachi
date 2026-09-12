// UpdateModels.swift
// Core data types and constants for the in-app update pipeline.

import Foundation

// MARK: - SemanticVersion

/// A parsed semantic version (major.minor.patch) that supports comparison and
/// display. Used for both the running app version and the fetched release version.
struct SemanticVersion: Comparable, CustomStringConvertible, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    /// Parses a string of the form "1.2.3" or "v1.2.3".
    /// Returns nil for any string that does not match that pattern.
    init?(_ string: String) {
        // Strip a leading "v" that GitHub conventionally prepends to tag names.
        let raw = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let maj = Int(parts[0]),
              let min = Int(parts[1]),
              let pat = Int(parts[2]),
              maj >= 0, min >= 0, pat >= 0
        else { return nil }
        major = maj
        minor = min
        patch = pat
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

// MARK: - ReleaseInfo

/// All metadata about a single GitHub release that the update pipeline needs.
struct ReleaseInfo: Equatable {
    let version: SemanticVersion
    let tagName: String         // e.g. "v1.1.0"
    let name: String?           // release title — may be nil or empty
    let notes: String           // release body markdown/plain text (may be "")
    let htmlURL: URL            // the GitHub release page URL
    let downloadURL: URL        // browser_download_url for the ShakaPachi-*.zip asset
    let assetName: String       // e.g. "ShakaPachi-1.1.0.zip"
    let assetSize: Int64
    let publishedAt: Date?
}

// MARK: - UpdateConfig

/// Centralised constants so every module that needs the GitHub coordinates
/// pulls them from one place instead of repeating literal strings.
enum UpdateConfig {
    static let repoOwner = "senkentarou"
    static let repoName  = "shakapachi"
    /// Team ID of the Developer ID certificate used to sign and notarize releases.
    static let teamID    = "U2H8U2TN85"
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/senkentarou/shakapachi/releases/latest"
    )!
}
