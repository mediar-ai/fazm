import Foundation
import CryptoKit

/// Installs bundled skills from the app's Resources/BundledSkills to ~/.claude/skills/
/// Skills are installed on first run and updated whenever the bundled content changes (checksum comparison).
/// User-edited skills that differ from the bundled version will be overwritten if the bundle was updated.
///
/// To add or remove a bundled skill: add/remove the *.skill.md file in
/// Desktop/Sources/Resources/BundledSkills/ — no code change required.
/// To assign a category for onboarding display, update categoryMap below.
enum SkillInstaller {

    /// Category grouping for the onboarding display. UI config only — not stored in skill files.
    private static let categoryMap: [String: String] = [
        "pdf": "Documents", "docx": "Documents", "xlsx": "Documents", "pptx": "Documents",
        "video-edit": "Creation", "frontend-design": "Creation", "canvas-design": "Creation", "doc-coauthoring": "Creation",
        "deep-research": "Research & Planning", "travel-planner": "Research & Planning", "web-scraping": "Research & Planning",
        "gws-gmail": "Google Workspace", "gws-calendar": "Google Workspace", "gws-docs": "Google Workspace",
        "gws-docs-write": "Google Workspace", "gws-sheets": "Google Workspace", "gws-drive": "Google Workspace",
        "gws-setup": "Google Workspace",
        "social-autoposter": "Social Media", "social-autoposter-setup": "Social Media",
        "find-skills": "Discovery",
    ]

    private static let categoryOrder = [
        "Documents", "Creation", "Research & Planning", "Google Workspace", "Social Media", "Discovery"
    ]

    /// Auto-discovered skill names from all *.skill.md files in the app bundle's BundledSkills directory.
    static var bundledSkillNames: [String] {
        guard let bundleURL = Bundle.resourceBundle.resourceURL?
            .appendingPathComponent("BundledSkills") else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: bundleURL, includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "md" && $0.deletingPathExtension().pathExtension == "skill" }
            .map { $0.deletingPathExtension().deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Parse the `description:` field from a skill's YAML frontmatter.
    private static func skillDescription(for name: String) -> String {
        guard let url = Bundle.resourceBundle.url(forResource: "\(name).skill", withExtension: "md", subdirectory: "BundledSkills"),
              let content = try? String(contentsOf: url) else { return name }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("description:") else { continue }
            return trimmed
                .dropFirst("description:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return name
    }

    /// SHA-256 hex digest of a file's contents, or nil if the file can't be read.
    private static func sha256(of path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Install specified skills (by name). Returns a summary of what was done.
    /// Installs missing skills and updates existing ones when the bundled content has changed.
    /// - Parameter names: skill names to install. If nil or empty, installs all bundled skills.
    static func install(names: [String]? = nil) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let skillsDir = "\(home)/.claude/skills"
        let fm = FileManager.default

        // Ensure ~/.claude/skills/ exists
        try? fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)

        let toInstall: [String]
        if let names = names, !names.isEmpty {
            toInstall = names
        } else {
            toInstall = bundledSkillNames
        }

        var installed: [String] = []
        var updated: [String] = []
        var skipped: [String] = []
        var failed: [String] = []

        for name in toInstall {
            let destDir = "\(skillsDir)/\(name)"
            let destFile = "\(destDir)/SKILL.md"

            // Find the bundled skill file in BundledSkills subdirectory
            guard let bundledURL = Bundle.resourceBundle.url(
                forResource: "\(name).skill",
                withExtension: "md",
                subdirectory: "BundledSkills"
            ) else {
                failed.append(name)
                continue
            }

            let alreadyExists = fm.fileExists(atPath: destFile)

            if alreadyExists {
                // Compare checksums — only overwrite if the bundled skill has changed
                let bundledHash = sha256(of: bundledURL.path)
                let installedHash = sha256(of: destFile)
                guard bundledHash != installedHash else {
                    skipped.append(name)
                    continue
                }
                // Bundled version differs — update
                do {
                    try fm.removeItem(atPath: destFile)
                    try fm.copyItem(atPath: bundledURL.path, toPath: destFile)
                    updated.append(name)
                } catch {
                    failed.append(name)
                }
            } else {
                // New skill — install it
                do {
                    try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
                    try fm.copyItem(atPath: bundledURL.path, toPath: destFile)
                    installed.append(name)
                } catch {
                    failed.append(name)
                }
            }
        }

        var parts: [String] = []
        if !installed.isEmpty {
            parts.append("Installed \(installed.count) skills: \(installed.joined(separator: ", "))")
        }
        if !updated.isEmpty {
            parts.append("Updated \(updated.count) skills: \(updated.joined(separator: ", "))")
        }
        if !skipped.isEmpty {
            parts.append("Skipped \(skipped.count) (up to date): \(skipped.joined(separator: ", "))")
        }
        if !failed.isEmpty {
            parts.append("Failed \(failed.count): \(failed.joined(separator: ", "))")
        }

        log("SkillInstaller: \(parts.joined(separator: ". "))")

        // Show a toast if any bundled skills were updated
        if !updated.isEmpty {
            let names = updated.joined(separator: ", ")
            let msg = updated.count == 1
                ? "Skill updated: \(names)"
                : "\(updated.count) skills updated: \(names)"
            DispatchQueue.main.async {
                ToastManager.shared.show(msg)
            }
        }

        return parts.isEmpty ? "No skills to install." : parts.joined(separator: ". ")
    }

    // MARK: - npm skill auto-update

    /// Registry of skills installed via npm. Maps skill name → (npm package name, install directory).
    private static let npmSkills: [(name: String, package: String, dir: String)] = [
        ("social-autoposter", "social-autoposter", "social-autoposter"),
    ]

    /// Check for npm skill updates and run `npx <package> update` if a newer version is available.
    /// Runs synchronously — call from a background queue.
    static func checkNpmSkillUpdates() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        for skill in npmSkills {
            let installDir = "\(home)/\(skill.dir)"
            let packageJson = "\(installDir)/package.json"

            // Only check skills that were installed via npm (have a package.json)
            guard FileManager.default.fileExists(atPath: packageJson) else {
                log("SkillInstaller: npm skip \(skill.name) — not installed at \(installDir)")
                continue
            }

            // Read local version
            guard let data = FileManager.default.contents(atPath: packageJson),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let localVersion = json["version"] as? String else {
                log("SkillInstaller: npm skip \(skill.name) — can't read local version")
                continue
            }

            // Check remote version via `npm view <package> version`
            let viewProcess = Process()
            let viewPipe = Pipe()
            viewProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            viewProcess.arguments = ["npm", "view", skill.package, "version"]
            viewProcess.standardOutput = viewPipe
            viewProcess.standardError = FileHandle.nullDevice
            do { try viewProcess.run() } catch {
                log("SkillInstaller: npm skip \(skill.name) — npm view failed: \(error)")
                continue
            }
            viewProcess.waitUntilExit()
            let remoteVersion = String(data: viewPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !remoteVersion.isEmpty, remoteVersion != localVersion else {
                log("SkillInstaller: npm \(skill.name) is up to date (v\(localVersion))")
                continue
            }

            log("SkillInstaller: npm \(skill.name) update available: v\(localVersion) → v\(remoteVersion)")

            // Run `npx <package> update`
            let updateProcess = Process()
            updateProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            updateProcess.arguments = ["npx", "--yes", skill.package, "update"]
            updateProcess.standardOutput = FileHandle.nullDevice
            updateProcess.standardError = FileHandle.nullDevice
            updateProcess.currentDirectoryURL = URL(fileURLWithPath: home)
            do { try updateProcess.run() } catch {
                log("SkillInstaller: npm \(skill.name) update failed: \(error)")
                continue
            }
            updateProcess.waitUntilExit()

            if updateProcess.terminationStatus == 0 {
                log("SkillInstaller: npm \(skill.name) updated to v\(remoteVersion)")
                DispatchQueue.main.async {
                    ToastManager.shared.show("\(skill.name) updated to v\(remoteVersion)")
                }
            } else {
                log("SkillInstaller: npm \(skill.name) update exited with \(updateProcess.terminationStatus)")
            }
        }
    }

    // MARK: - Analytics

    /// Returns analytics properties describing the current skill installation state.
    /// Intended for inclusion in the daily "All Settings State" PostHog report.
    static func analyticsProperties() -> [String: Any] {
        var props: [String: Any] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let skillsDir = "\(home)/.claude/skills"
        let fm = FileManager.default

        // Enumerate installed skills: dirs inside ~/.claude/skills/ that contain a SKILL.md
        let installedSkills: [String]
        if let contents = try? fm.contentsOfDirectory(atPath: skillsDir) {
            installedSkills = contents.filter { name in
                var isDir: ObjCBool = false
                let dirPath = "\(skillsDir)/\(name)"
                fm.fileExists(atPath: dirPath, isDirectory: &isDir)
                return isDir.boolValue && fm.fileExists(atPath: "\(dirPath)/SKILL.md")
            }.sorted()
        } else {
            installedSkills = []
        }

        props["installed_skills_count"] = installedSkills.count
        props["installed_skills"] = installedSkills.joined(separator: ",")
        props["bundled_skills_count"] = bundledSkillNames.count

        // npm skill versions (e.g. social-autoposter)
        for skill in npmSkills {
            let packageJson = "\(home)/\(skill.dir)/package.json"
            guard let data = fm.contents(atPath: packageJson),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String else { continue }
            props["npm_\(skill.name)_version"] = version
        }

        return props
    }

    /// Returns a formatted list of bundled skills grouped by category, for the AI to present during onboarding.
    static func listBundledSkills() -> String {
        var categories: [String: [(name: String, description: String)]] = [:]
        for name in bundledSkillNames {
            let category = categoryMap[name] ?? "Other"
            categories[category, default: []].append((name: name, description: skillDescription(for: name)))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var lines: [String] = []

        func appendSkills(_ skills: [(name: String, description: String)]) {
            for s in skills {
                let exists = FileManager.default.fileExists(atPath: "\(home)/.claude/skills/\(s.name)/SKILL.md")
                let status = exists ? " [already installed]" : ""
                lines.append("  - \(s.name): \(s.description)\(status)")
            }
        }

        for cat in categoryOrder {
            guard let skills = categories[cat] else { continue }
            lines.append("\(cat):")
            appendSkills(skills)
        }
        if let other = categories["Other"] {
            lines.append("Other:")
            appendSkills(other)
        }
        return lines.joined(separator: "\n")
    }
}
