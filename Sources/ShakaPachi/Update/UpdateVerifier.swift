// UpdateVerifier.swift
// Extracts and cryptographically verifies the downloaded update bundle.
//
// Security model:
//   The download channel (HTTPS + GitHub API) is NOT fully trusted on its own.
//   A compromised CDN, DNS hijack, or man-in-the-middle could substitute a
//   different zip. We therefore PIN to our Developer ID Team ID (U2H8U2TN85)
//   using the Security framework's static code-signing API. Any bundle that is
//   not signed by that specific Developer ID — regardless of how it arrived —
//   is rejected before it can touch the app location.
//
//   Why-not: we do not rely on the GitHub API's TLS certificate alone because
//   it would only protect the transport, not the identity of the code being
//   delivered. Team ID pinning proves the signer, not just the channel.

import Foundation
import Security

struct UpdateVerifier {

    // MARK: - Extraction

    /// Extracts the zip archive at `zipAt` into `destDir` using `/usr/bin/ditto`
    /// and returns the URL of the extracted `ShakaPachi.app` bundle.
    /// Throws `UpdateError.installFailed` if ditto fails or the .app is not found.
    static func extract(zipAt: URL, to destDir: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipAt.path, destDir.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed("ditto failed to launch: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "(unknown)"
            throw UpdateError.installFailed("ditto exited \(process.terminationStatus): \(errMsg)")
        }

        // Locate the extracted ShakaPachi.app.
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: destDir.path)) ?? []
        guard let appEntry = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.installFailed("No .app bundle found after extraction in \(destDir.path)")
        }

        return destDir.appendingPathComponent(appEntry)
    }

    // MARK: - Signature verification

    /// Verifies that the bundle at `appURL` is:
    ///   1. Validly signed by a Developer ID certificate issued to Team U2H8U2TN85.
    ///   2. Reports the expected version in its Info.plist.
    ///
    /// Throws `UpdateError.verifyFailed` on any violation.
    static func verify(appAt appURL: URL, expectedVersion: SemanticVersion) throws {
        // Build a static code reference for the bundle.
        var staticCodeOpt: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(),
            &staticCodeOpt
        )
        guard createStatus == errSecSuccess, let staticCode = staticCodeOpt else {
            throw UpdateError.verifyFailed(
                "SecStaticCodeCreateWithPath failed: \(createStatus)"
            )
        }

        // Pin to our Developer ID Team ID.
        // Why-not: we don't accept "anchor apple generic" alone because that
        // would allow any Developer ID signer. We pin to the specific OU so
        // only certificates issued to OUR team can pass.
        let requirementString =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(UpdateConfig.teamID)\""
        var reqOpt: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(
            requirementString as CFString,
            SecCSFlags(),
            &reqOpt
        )
        guard reqStatus == errSecSuccess, let requirement = reqOpt else {
            throw UpdateError.verifyFailed(
                "SecRequirementCreateWithString failed: \(reqStatus)"
            )
        }

        // Validate the bundle against the pinned requirement.
        // .checkAllArchitectures ensures both arm64 and x86_64 slices are validated.
        // .checkNestedCode ensures frameworks and helpers inside the bundle are also checked.
        var cfError: Unmanaged<CFError>?
        let checkStatus = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            SecCSFlags(rawValue:
                kSecCSCheckAllArchitectures |
                kSecCSCheckNestedCode
            ),
            requirement,
            &cfError
        )
        if checkStatus != errSecSuccess {
            let detail = cfError?.takeRetainedValue().localizedDescription ?? "status \(checkStatus)"
            throw UpdateError.verifyFailed("Signature check failed: \(detail)")
        }

        // Cross-check that the bundle's declared version matches what the API told us.
        // This catches any mismatch between the tag and the actual binary, which could
        // indicate a packaging error or a confused update flow.
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let infoPlistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: infoPlistData, format: nil)
                  as? [String: Any],
              let bundleVersionString = plist["CFBundleShortVersionString"] as? String
        else {
            throw UpdateError.verifyFailed("Cannot read CFBundleShortVersionString from extracted bundle")
        }

        guard let bundleVersion = SemanticVersion(bundleVersionString) else {
            throw UpdateError.verifyFailed(
                "Cannot parse CFBundleShortVersionString '\(bundleVersionString)' as SemanticVersion"
            )
        }

        guard bundleVersion == expectedVersion else {
            throw UpdateError.verifyFailed(
                "Version mismatch: expected \(expectedVersion), bundle says \(bundleVersion)"
            )
        }
    }
}
