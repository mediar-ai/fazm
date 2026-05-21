import Foundation

/// Resolved directory names and URLs that depend on the running bundle.
/// Dev (`com.fazm.desktop-dev`) uses a separate parent so it never shares
/// `~/Library/Application Support/Fazm/` with prod, preventing the
/// migration logic from confusing one build's user dir for another.
enum AppPaths {
    /// "Fazm" for prod, "Fazm-Dev" for the dev bundle. Defaults to "Fazm"
    /// for any unknown/missing bundle ID so prod is the safe fallback.
    static var supportDirName: String {
        Bundle.main.bundleIdentifier == "com.fazm.desktop-dev" ? "Fazm-Dev" : "Fazm"
    }

    /// `~/Library/Application Support/<Fazm or Fazm-Dev>/`
    static var supportRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent(supportDirName, isDirectory: true)
    }

    /// Short suffix identifying this build for distributed notification names
    /// and `/tmp` output files. "app" for prod (`com.fazm.app`), "desktop-dev"
    /// for the dev bundle (`com.fazm.desktop-dev`). Used so dev and prod can
    /// receive programmatic commands independently when both are running.
    static var bundleScope: String {
        let id = Bundle.main.bundleIdentifier ?? "com.fazm.app"
        if let dot = id.lastIndex(of: ".") {
            return String(id[id.index(after: dot)...])
        }
        return id
    }

    /// Path to a `/tmp/fazm-<name>-<scope>.<ext>` file, used for programmatic
    /// state dumps that must not be overwritten by a sibling build running
    /// at the same time. Pass e.g. `controlStateTmpPath("control-state", ext: "json")`.
    static func scopedTmpPath(_ name: String, ext: String) -> String {
        "/tmp/fazm-\(name)-\(bundleScope).\(ext)"
    }
}

extension DistributedNotificationCenter {
    /// Register an observer that fires for both:
    ///
    /// 1. The legacy unscoped name `com.fazm.<suffix>` (e.g. `com.fazm.testQuery`),
    ///    which broadcasts to every running Fazm build (dev + prod). Kept so older
    ///    debug commands and docs continue to work.
    /// 2. The bundle-scoped name `com.fazm.<bundleScope>.<suffix>` (e.g.
    ///    `com.fazm.desktop-dev.testQuery`), which fires only on this specific
    ///    build. Use this form when both dev and prod are running side-by-side
    ///    and you want to target one without nuking the other.
    func addFazmObserver(
        _ suffix: String,
        queue: OperationQueue? = .main,
        using block: @escaping (Notification) -> Void
    ) {
        let legacy = NSNotification.Name("com.fazm.\(suffix)")
        let scoped = NSNotification.Name("com.fazm.\(AppPaths.bundleScope).\(suffix)")
        addObserver(forName: legacy, object: nil, queue: queue, using: block)
        addObserver(forName: scoped, object: nil, queue: queue, using: block)
    }
}
