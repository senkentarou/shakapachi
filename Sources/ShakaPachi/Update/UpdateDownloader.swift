// UpdateDownloader.swift
// Downloads a release asset (zip) to a temporary directory and reports progress.

import Foundation

struct UpdateDownloader {

    /// Downloads the zip for the given release to a system temp directory.
    /// Calls `progress` repeatedly with values in [0.0, 1.0].
    /// Returns the local URL of the downloaded zip on success.
    func download(_ release: ReleaseInfo, progress: @escaping (Double) -> Void) async throws -> URL {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShakaPachi-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destURL = destDir.appendingPathComponent(release.assetName)

        var request = URLRequest(url: release.downloadURL)
        request.setValue("ShakaPachi", forHTTPHeaderField: "User-Agent")

        // Use the async bytes API for streaming progress tracking.
        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw UpdateError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.httpError(http.statusCode)
        }

        // Expected total from Content-Length header, falling back to assetSize from the API.
        let expectedBytes: Int64
        if let http = response as? HTTPURLResponse,
           let lengthString = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(lengthString) {
            expectedBytes = length
        } else {
            expectedBytes = release.assetSize > 0 ? release.assetSize : 0
        }

        // Stream response bytes into a file handle for memory efficiency.
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: destURL.path) else {
            throw UpdateError.installFailed("Cannot open temp file for writing at \(destURL.path)")
        }
        defer { try? fileHandle.close() }

        var receivedBytes: Int64 = 0
        var buffer = Data(capacity: 65_536)

        for try await byte in asyncBytes {
            buffer.append(byte)
            receivedBytes += 1

            if buffer.count >= 65_536 {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if expectedBytes > 0 {
                    progress(min(Double(receivedBytes) / Double(expectedBytes), 1.0))
                }
            }
        }
        // Flush remaining bytes.
        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }

        progress(1.0)

        // Best-effort: warn if received size doesn't match the declared asset size.
        if release.assetSize > 0, receivedBytes != release.assetSize {
            NSLog(
                "[ShakaPachi] UpdateDownloader: size mismatch — expected %lld bytes, got %lld",
                release.assetSize, receivedBytes)
        }

        return destURL
    }
}
