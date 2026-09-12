// UpdateInstaller.swift
// Installs a verified replacement bundle by writing a detached shell helper that
// waits for the running process to exit, then swaps the bundles and relaunches.
//
// Why a shell helper instead of in-process copy:
//   A running .app cannot overwrite itself on macOS — the OS holds the bundle
//   directory open. We therefore write a small sh script to a temp path, launch
//   it detached (so it keeps running after this process exits), and then let the
//   caller terminate the app. The script polls until the old PID is gone, swaps
//   the bundles with ditto, and relaunches the new version.

import Foundation
import AppKit

struct UpdateInstaller {

    // MARK: - Helper script

    /// Writes a shell helper to a temp path, marks it executable, and launches it
    /// detached with the current process PID so it can wait for us to exit before
    /// swapping the bundle.
    ///
    /// The caller MUST call `NSApp.terminate(nil)` immediately after this returns
    /// so the helper's PID-wait loop can proceed.
    static func makeAndLaunchHelper(newApp: URL, destApp: URL) throws {
        let needAdmin = !FileManager.default.isWritableFile(
            atPath: destApp.deletingLastPathComponent().path
        )

        // Build the helper script text. The script:
        //   1. Waits until the old process exits (kill -0 returns non-zero).
        //   2. Replaces the bundle using ditto (preserving xattrs / resource forks).
        //   3. Relaunches the new bundle as the current user.
        //   If admin rights are required it wraps the swap in an osascript prompt.
        //   If authorization is cancelled it reveals the verified .app for manual install
        //   rather than silently failing — the user still gets their update.
        let scriptContent = """
        #!/bin/sh
        OLD_PID="$1"; NEW_APP="$2"; DEST="$3"; NEED_ADMIN="$4"
        while kill -0 "$OLD_PID" 2>/dev/null; do sleep 0.2; done
        if [ "$NEED_ADMIN" = "1" ]; then
          if ! osascript -e "do shell script \\"rm -rf '$DEST' && /usr/bin/ditto '$NEW_APP' '$DEST' && chown -R $(id -un) '$DEST'\\" with administrator privileges"; then
            open -R "$NEW_APP"
            exit 1
          fi
        else
          rm -rf "$DEST" && /usr/bin/ditto "$NEW_APP" "$DEST" || { open -R "$NEW_APP"; exit 1; }
        fi
        open "$DEST"
        """

        let helperDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShakaPachi-Helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        let helperScript = helperDir.appendingPathComponent("update_helper.sh")

        try scriptContent.write(to: helperScript, atomically: true, encoding: .utf8)

        // chmod +x
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperScript.path
        )

        let pid = ProcessInfo.processInfo.processIdentifier

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            helperScript.path,
            String(pid),
            newApp.path,
            destApp.path,
            needAdmin ? "1" : "0"
        ]

        // Launch detached — do NOT wait. The helper keeps running after we exit.
        do {
            try helper.run()
        } catch {
            throw UpdateError.installFailed("Failed to launch update helper: \(error.localizedDescription)")
        }
    }
}
