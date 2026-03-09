import Foundation

/// Installs bundled skills from the app's Resources/BundledSkills to ~/.claude/skills/
/// Skills are only installed if they don't already exist (never overwrites user data).
enum SkillInstaller {

    /// All bundled skill names and their user-facing descriptions
    static let bundledSkills: [(name: String, description: String, category: String)] = [
        // Documents
        ("pdf", "Read, merge, split, OCR, and create PDF files", "Documents"),
        ("docx", "Create and edit Word documents", "Documents"),
        ("xlsx", "Create and edit spreadsheets", "Documents"),
        ("pptx", "Create and edit presentations", "Documents"),
        // Creation
        ("video-edit", "Edit long videos into short, story-driven clips", "Creation"),
        ("frontend-design", "Build web pages, components, and UI", "Creation"),
        ("canvas-design", "Create posters, visual art, and diagrams", "Creation"),
        ("doc-coauthoring", "Co-write docs, proposals, and specs step by step", "Creation"),
        // Research & Planning
        ("deep-research", "Multi-source research reports with citations", "Research & Planning"),
        ("travel-planner", "Trip planning, itineraries, and budgets", "Research & Planning"),
        ("web-scraping", "Extract content from websites locally", "Research & Planning"),
        // Google Workspace
        ("gws-gmail", "Read, search, and send Gmail", "Google Workspace"),
        ("gws-calendar", "Google Calendar events and scheduling", "Google Workspace"),
        ("gws-docs", "Read Google Docs", "Google Workspace"),
        ("gws-docs-write", "Create and edit Google Docs", "Google Workspace"),
        ("gws-sheets", "Read and write Google Sheets", "Google Workspace"),
        ("gws-drive", "Google Drive file management", "Google Workspace"),
        // Social Media
        ("social-autoposter", "Automate social media posting across Reddit, X, LinkedIn, and Moltbook", "Social Media"),
        ("social-autoposter-setup", "Set up social-autoposter: accounts, database, and scheduled automation", "Social Media"),
        // Discovery
        ("find-skills", "Discover and install new skills from skillhu.bz and skills.sh", "Discovery"),
    ]

    /// Install specified skills (by name). Returns a summary of what was done.
    /// - Parameter names: skill names to install. If empty, installs all.
    /// - Returns: Human-readable result string
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
            toInstall = bundledSkills.map { $0.name }
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

    /// Returns a JSON-formatted list of bundled skills grouped by category, for the AI to present.
    static func listBundledSkills() -> String {
        var categories: [String: [(name: String, description: String)]] = [:]
        for skill in bundledSkills {
            categories[skill.category, default: []].append((name: skill.name, description: skill.description))
        }

        let order = ["Documents", "Creation", "Research & Planning", "Google Workspace", "Social Media", "Discovery"]
        var lines: [String] = []
        for cat in order {
            guard let skills = categories[cat] else { continue }
            lines.append("\(cat):")
            for s in skills {
                // Check if already installed
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let exists = FileManager.default.fileExists(atPath: "\(home)/.claude/skills/\(s.name)/SKILL.md")
                let status = exists ? " [already installed]" : ""
                lines.append("  - \(s.name): \(s.description)\(status)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
