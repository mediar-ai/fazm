import AppKit
import CryptoKit
import Foundation

struct InstallResult {
    let appURL: URL
    let fallback: InstallFallback
}

enum InstallFallback {
    case none                   // Installed to /Applications successfully
    case userApplications       // Fell back to ~/Applications
    case manualDrag(appURL: URL) // Both failed, app extracted for manual drag
}

enum InstallManager {

    static func verifySHA256(fileURL: URL, expected: String) throws {
        let data = try Data(contentsOf: fileURL)
        let hash = SHA256.hash(data: data)
        let hexString = hash.compactMap { String(format: "%02x", $0) }.joined()

        if hexString.lowercased() != expected.lowercased() {
            throw InstallerError.sha256Mismatch
        }
    }

    static func install(zipURL: URL) throws -> InstallResult {
        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory.appendingPathComponent("FazmExtract-\(UUID().uuidString)")

        // Extract ZIP using ditto (preserves code signatures, resource forks, etc.)
        let extractProcess = Process()
        extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extractProcess.arguments = ["-xk", zipURL.path, extractDir.path]
        try extractProcess.run()
        extractProcess.waitUntilExit()

        guard extractProcess.terminationStatus == 0 else {
            throw InstallerError.extractionFailed
        }

        // Find Fazm.app in extracted contents
        let appName = "Fazm.app"
        guard let sourceApp = findApp(named: appName, in: extractDir) else {
            throw InstallerError.appNotFound
        }

        // Try /Applications first
        let systemAppsDir = URL(fileURLWithPath: "/Applications")
        do {
            let result = try installTo(directory: systemAppsDir, sourceApp: sourceApp, appName: appName, fallback: .none)
            cleanup(zipURL: zipURL, extractDir: extractDir)
            return result
        } catch {}

        // Fall back to ~/Applications
        let userAppsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        try? fm.createDirectory(at: userAppsDir, withIntermediateDirectories: true)
        do {
            let result = try installTo(directory: userAppsDir, sourceApp: sourceApp, appName: appName, fallback: .userApplications)
            cleanup(zipURL: zipURL, extractDir: extractDir)
            return result
        } catch {}

        // Both failed: copy app to Desktop for manual drag
        let desktopApp = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").appendingPathComponent(appName)
        try? fm.removeItem(at: desktopApp)
        copyWithDitto(from: sourceApp.path, to: desktopApp.path)

        let finalApp: URL
        if fm.fileExists(atPath: desktopApp.path) {
            finalApp = desktopApp
            cleanup(zipURL: zipURL, extractDir: extractDir)
        } else {
            // Last resort: use the extracted app directly
            finalApp = sourceApp
            try? fm.removeItem(at: zipURL)
        }

        return InstallResult(appURL: finalApp, fallback: .manualDrag(appURL: finalApp))
    }

    private static func cleanup(zipURL: URL, extractDir: URL) {
        try? FileManager.default.removeItem(at: zipURL)
        try? FileManager.default.removeItem(at: extractDir)
    }

    private static func copyWithDitto(from source: String, to destination: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source, destination]
        try? process.run()
        process.waitUntilExit()
    }

    private static func installTo(
        directory: URL,
        sourceApp: URL,
        appName: String,
        fallback: InstallFallback
    ) throws -> InstallResult {
        let fm = FileManager.default
        let targetApp = directory.appendingPathComponent(appName)

        // Remove existing
        if fm.fileExists(atPath: targetApp.path) {
            try fm.removeItem(at: targetApp)
        }

        // Remove legacy Omi installations
        for legacy in ["Omi.app", "omi.app"] {
            let legacyPath = directory.appendingPathComponent(legacy)
            if fm.fileExists(atPath: legacyPath.path) {
                try? fm.removeItem(at: legacyPath)
            }
        }

        // Copy using ditto (preserves code signatures)
        let installProcess = Process()
        installProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        installProcess.arguments = [sourceApp.path, targetApp.path]
        try installProcess.run()
        installProcess.waitUntilExit()

        guard installProcess.terminationStatus == 0 else {
            throw InstallerError.installFailed("Failed to copy app to \(directory.path)")
        }

        return InstallResult(appURL: targetApp, fallback: fallback)
    }

    static func launch(appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error = error {
                print("Failed to launch app: \(error)")
            }
        }
    }

    static func revealInFinderWithApplications(appURL: URL) {
        // Open /Applications in one Finder window, and select the app
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
        // Also open /Applications so user can drag
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "/Applications")
    }

    // Recursively find the .app bundle
    private static func findApp(named name: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        let directPath = directory.appendingPathComponent(name)
        if fm.fileExists(atPath: directPath.path) {
            return directPath
        }

        // Search one level deep (ZIP might have a top-level folder)
        if let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for item in contents {
                let nested = item.appendingPathComponent(name)
                if fm.fileExists(atPath: nested.path) {
                    return nested
                }
            }
        }
        return nil
    }
}
