import Foundation

/// Installs bundled skills from the app's Resources/BundledSkills to ~/.claude/skills/
/// Skills are only installed if they don't already exist (never overwrites user data).
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

    /// Auto-discovered skill names from all *.skill.md files in the app bundle.
    static var bundledSkillNames: [String] {
        guard let bundleURL = Bundle.resourceBundle.resourceURL else { return [] }
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
        guard let url = Bundle.resourceBundle.url(forResource: "\(name).skill", withExtension: "md"),
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

    /// Install specified skills (by name). Returns a summary of what was done.
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
        var skipped: [String] = []
        var failed: [String] = []

        for name in toInstall {
            let destDir = "\(skillsDir)/\(name)"
            let destFile = "\(destDir)/SKILL.md"

            // Never overwrite existing skills
            if fm.fileExists(atPath: destFile) {
                skipped.append(name)
                continue
            }

            // Find the bundled skill file (stored as {name}.skill.md, flattened by SPM)
            guard let bundledURL = Bundle.resourceBundle.url(
                forResource: "\(name).skill",
                withExtension: "md"
            ) else {
                failed.append(name)
                continue
            }

            do {
                try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
                try fm.copyItem(atPath: bundledURL.path, toPath: destFile)
                installed.append(name)
            } catch {
                failed.append(name)
            }
        }

        var parts: [String] = []
        if !installed.isEmpty {
            parts.append("Installed \(installed.count) skills: \(installed.joined(separator: ", "))")
        }
        if !skipped.isEmpty {
            parts.append("Skipped \(skipped.count) (already exist): \(skipped.joined(separator: ", "))")
        }
        if !failed.isEmpty {
            parts.append("Failed \(failed.count): \(failed.joined(separator: ", "))")
        }

        log("SkillInstaller: \(parts.joined(separator: ". "))")
        return parts.isEmpty ? "No skills to install." : parts.joined(separator: ". ")
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
