import Foundation
import AppKit

/// Single-instance lock for production "Fazm" (bundle id `com.fazm.app`).
///
/// Why this exists: macOS will happily launch a second copy of the same app if
/// the user double-clicks two different `.app` bundles (e.g. the one in
/// `/Applications` AND a copy in `~/Downloads`), AND `LSMultipleInstancesProhibited`
/// in Info.plist is unreliable across paths. Two prod instances stomp on the
/// same SQLite db, ACP bridge, Stripe device id, and listen for the same global
/// hotkey. So before we do any other init we check for a running peer and, if
/// one is alive, hand off focus and exit.
///
/// Dev builds (`com.fazm.desktop-dev`) intentionally skip this so multiple dev
/// instances can coexist for testing. The check is a no-op anywhere outside
/// of the prod bundle.
enum InstanceLock {

    /// Production bundle id; only this build is gated.
    private static let prodBundleId = "com.fazm.app"

    /// PID file path inside the prod app's Application Support directory.
    /// We deliberately do NOT use `~/tmp` because tmp is wiped on reboot and we
    /// want the file to be a tombstone the kernel can clean up via `kill -0`
    /// even after a crash; if we restart fast enough the dead PID is reused
    /// and we risk a false positive. Combining PID + bundle id mtime check
    /// would solve that — for now we accept the rare race because a stale
    /// PID file is harmless: kill -0 returns ENOENT and we overwrite it.
    private static var lockFileURL: URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else { return nil }
        let dir = support.appendingPathComponent("com.fazm.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".instance.pid")
    }

    /// Cached so we don't have to recompute in `release()`.
    private static var heldLockURL: URL?

    /// Acquire the lock or hand off to a running peer. Call this from
    /// `applicationWillFinishLaunching` (BEFORE any heavy init) so a
    /// duplicate launch terminates fast and clean, before we wire up
    /// hotkey monitors / Firebase / SQLite / the ACP bridge.
    ///
    /// Behavior:
    /// - Dev build: no-op, returns true.
    /// - No existing lock: writes our PID, returns true.
    /// - Existing lock pointing at an alive PID: activates that peer
    ///   via NSRunningApplication, then `exit(0)`. Never returns.
    /// - Existing lock pointing at a dead PID: overwrites with our PID,
    ///   returns true. (Crash recovery — previous instance died without
    ///   releasing.)
    @discardableResult
    static func acquireOrHandoff() -> Bool {
        guard Bundle.main.bundleIdentifier == prodBundleId else {
            // Dev or unsigned build, skip entirely.
            return true
        }

        guard let url = lockFileURL else {
            // Couldn't find Application Support directory; fail open
            // because it's better to launch than to refuse. Worst case:
            // two prods can run, which is the existing behavior.
            NSLog("InstanceLock: could not derive lock file URL; proceeding without lock")
            return true
        }

        // If a lock file exists, see if its PID is alive.
        if let data = try? Data(contentsOf: url),
           let raw = String(data: data, encoding: .utf8) {
            let pidStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .first ?? ""
            if let peerPid = Int32(pidStr), peerPid > 0, peerPid != getpid() {
                // `kill(pid, 0)` succeeds only if the process exists and we
                // can signal it. ESRCH = no such process (dead/stale).
                let alive = (kill(peerPid, 0) == 0) || (errno == EPERM)
                if alive {
                    // Confirm the peer is actually Fazm and not a recycled PID.
                    if let peer = NSRunningApplication(processIdentifier: peerPid),
                       peer.bundleIdentifier == prodBundleId {
                        NSLog("InstanceLock: peer Fazm running (pid=\(peerPid)); activating and exiting")
                        peer.activate(options: [.activateAllWindows])
                        // Give AppKit a tick to deliver the activation
                        // request before we tear down. 200ms is enough on
                        // every Mac I've tested; the delay only matters in
                        // the corner case where the user double-clicked
                        // the app icon twice in <1s.
                        Thread.sleep(forTimeInterval: 0.2)
                        exit(0)
                    } else {
                        NSLog("InstanceLock: pid=\(peerPid) alive but not Fazm — recycled, overwriting")
                    }
                } else {
                    NSLog("InstanceLock: stale lock pid=\(peerPid) dead, overwriting")
                }
            }
        }

        // Write our PID. We want this to survive an unclean exit (kernel
        // panic, SIGKILL) so we tolerate stale-on-next-launch via the
        // kill -0 check above, rather than relying on flock or unlink
        // hooks that don't fire on hard kills.
        let pidStr = "\(getpid())\n"
        do {
            try pidStr.data(using: .utf8)?.write(to: url, options: .atomic)
            heldLockURL = url
            // Register signal handlers so a SIGTERM (e.g. `killall Fazm`)
            // still releases the lock — applicationWillTerminate doesn't
            // fire for SIGKILL but does for SIGTERM via AppKit.
            installSignalCleanup()
            NSLog("InstanceLock: acquired pid=\(getpid()) at \(url.path)")
            return true
        } catch {
            NSLog("InstanceLock: failed to write lock: \(error.localizedDescription) — proceeding without lock")
            return true
        }
    }

    /// Release the lock. Call from `applicationWillTerminate`. Safe to
    /// call multiple times.
    static func release() {
        guard let url = heldLockURL else { return }
        // Only delete if the file still references our PID — defends
        // against the case where a peer raced past us and overwrote.
        if let data = try? Data(contentsOf: url),
           let raw = String(data: data, encoding: .utf8) {
            let pidStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .first ?? ""
            if let pid = Int32(pidStr), pid == getpid() {
                try? FileManager.default.removeItem(at: url)
                NSLog("InstanceLock: released pid=\(getpid())")
            } else {
                NSLog("InstanceLock: lock file owned by pid=\(pidStr); not removing")
            }
        }
        heldLockURL = nil
    }

    // MARK: - Signal handling

    private static var signalHandlersInstalled = false

    /// Path stored as a C string in heap memory for the signal handler.
    /// Swift @convention(c) closures can't capture context, so we stash the
    /// path in a global the handler can reach without capturing.
    private static var lockPathCString: UnsafeMutablePointer<CChar>?

    private static func installSignalCleanup() {
        guard !signalHandlersInstalled else { return }
        guard let url = heldLockURL else { return }
        signalHandlersInstalled = true

        // Stash an async-signal-safe copy of the path.
        let path = url.path
        lockPathCString = strdup(path)

        // SIGTERM = `kill <pid>` (default), SIGINT = Ctrl+C in dev.
        // SIGKILL can't be caught — for that we rely on the kill -0
        // staleness check on next launch.
        let action: @convention(c) (Int32) -> Void = { sig in
            // Best-effort cleanup; signal-handler-safe via unlink().
            if let p = InstanceLock.lockPathCString {
                _ = unlink(p)
            }
            // Re-raise the signal with the default handler so the OS still
            // tears us down (and the exit code reflects the signal).
            signal(sig, SIG_DFL)
            raise(sig)
        }
        signal(SIGTERM, action)
        signal(SIGINT, action)
        signal(SIGHUP, action)
    }
}
