import Foundation

/// Ensures the bundled Node.js binary can be executed safely.
///
/// On macOS 26+ (Tahoe), Sparkle auto-updates can silently corrupt the code signing
/// seal of the bundled node binary. The kernel's Code Signing Monitor (CSM) then
/// kills the process with SIGKILL on launch. The binary passes `codesign --verify`
/// but still gets killed — a seal-level corruption invisible to userspace tools.
///
/// This helper:
/// 1. Copies the bundled node to a temp location outside the app bundle seal
/// 2. Verifies the copy can actually execute (`node --version`)
/// 3. Tracks when the bundled path fails but the external copy works (Sparkle corruption)
enum NodeBinaryHelper {
    private static var cachedPath: String?
    private(set) static var bundledNodeWasBroken = false

    /// Returns a path to the node binary that can be safely executed.
    /// Copies from the app bundle to a temp dir and verifies it works.
    ///
    /// The temp path is scoped by bundle ID (`fazm-node-app` for prod,
    /// `fazm-node-desktop-dev` for dev) so that dev and prod builds running on
    /// the same user account never clobber each other's copy. Pre-2026-06-02
    /// both used the unscoped `fazm-node` path; a dev `./run.sh` could replace
    /// the running prod app's temp node, and if the dev cert was unhealthy
    /// (e.g. XProtect-blocked team), the next prod ACP-bridge spawn got
    /// SIGKILL'd and the chat hung forever.
    static func externalNodePath(from bundledPath: String) -> String {
        if let cached = cachedPath,
           FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }

        let tmpNode = NSTemporaryDirectory() + "fazm-node-" + AppPaths.bundleScope
        // Best-effort cleanup of the pre-2026-06-02 shared path so it can't
        // keep getting flagged by XProtect after upgrade. Ignored if absent
        // or in use by another build's still-running bridge.
        let legacyTmpNode = NSTemporaryDirectory() + "fazm-node"
        if FileManager.default.fileExists(atPath: legacyTmpNode) {
            try? FileManager.default.removeItem(atPath: legacyTmpNode)
        }
        do {
            if FileManager.default.fileExists(atPath: tmpNode) {
                try FileManager.default.removeItem(atPath: tmpNode)
            }
            try FileManager.default.copyItem(atPath: bundledPath, toPath: tmpNode)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpNode)
        } catch {
            log("NodeBinaryHelper: Failed to copy node to temp dir (\(error)), using bundled path")
            return bundledPath
        }

        // Verify the external copy actually runs
        if verify(path: tmpNode) {
            cachedPath = tmpNode
            // Check if the original bundled path was broken (Sparkle corruption)
            if !verify(path: bundledPath) {
                bundledNodeWasBroken = true
                log("NodeBinaryHelper: ⚠️ Bundled node binary is broken (SIGKILL), using temp copy at \(tmpNode). Likely Sparkle update corruption.")
            } else {
                log("NodeBinaryHelper: Copied bundled node to \(tmpNode)")
            }
            return tmpNode
        } else {
            // External copy also broken — fall back to bundled path as last resort
            log("NodeBinaryHelper: External copy also failed to verify, falling back to bundled path")
            return bundledPath
        }
    }

    /// Test that a node binary can actually execute by running `node --version`.
    /// Returns true if it exits successfully (code 0) within 5 seconds.
    static func verify(path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return false
        }
        // Wait with timeout — if the process hangs or gets killed immediately, don't block
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return false
        }
        return proc.terminationStatus == 0
    }
}
