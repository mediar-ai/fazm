#!/usr/bin/env xcrun swift
//
// check_settings_search.swift
//
// Ensures every setting visible in the Settings UI has a corresponding
// entry in SettingsSearchItem.allSearchableItems, that subtitles are
// populated, and that ALL visible text in settings is searchable.
//
// THREE CHECKS:
//   1. Title coverage: every settingRow/settingsCard title has a search item
//   2. Subtitle coverage: every search item has a non-empty subtitle
//   3. Text coverage: every Text("...") string in settings files is findable
//      via some search item's name, subtitle, or keywords
//
// RUN:
//   xcrun swift scripts/check_settings_search.swift
//
// Wired into release.sh to catch missing search entries before release.

import Foundation

// MARK: - Configuration

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root

let settingsPagePath = repoRoot
    .appendingPathComponent("Desktop/Sources/MainWindow/Pages/SettingsPage.swift").path
let shortcutsPath = repoRoot
    .appendingPathComponent("Desktop/Sources/MainWindow/Pages/ShortcutsSettingsSection.swift").path
let sidebarPath = repoRoot
    .appendingPathComponent("Desktop/Sources/MainWindow/SettingsSidebar.swift").path

/// Titles that match our patterns but are NOT searchable settings.
/// These are display-only labels, dynamic text, or structural elements.
let ignoredTitles: Set<String> = [
    "Omi",                      // App name in About header
    "Progress",                 // Section label in Feature Tiers
    "Keyboard Shortcuts",       // Reference card header (read-only)
]

/// Text strings that appear in settings but are structural/generic UI labels,
/// not something a user would search for. Keep this list minimal and documented.
let ignoredTextLabels: Set<String> = [
    // Structural / layout
    "Omi",                          // App name in About header
    "Progress",                     // Section label in Feature Tiers
    "Keyboard Shortcuts",           // Reference card header (read-only)
    "General",                      // Section headers (not searchable settings)
    "Advanced",
    "About",
    "Settings",

    // Status indicators (not actionable settings)
    "Connected",                    // Browser extension status label
    "Not Connected",

    // Generic button labels too common to be useful search terms
    "OK",
    "Done",
    "Close",
    "Cancel",
    "Save",
    "Delete",
    "Add",
    "Remove",
    "Browse...",                     // File/folder picker button
    "Clear",                        // Reset/clear button

    // Dynamic/contextual labels that contain runtime values
    "browser",                      // Lowercase label for browser app type in allowed apps

    // Display-only / informational text
    "The quick brown fox jumps over the lazy dog",  // Font size preview string
    "Loading...",                    // Loading state indicator
    "Connecting... (click to cancel)", // Codex login transient state
    "Coming Soon",                  // Feature not yet available label
    "Automatically detects and transcribes:",  // Transcription info label

    // Data retention option labels (values, not searchable settings)
    "3 days",
    "7 days",
    "14 days",
    "30 days",

    // Language list (display-only, not a setting)
    "English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, Dutch",

    // Keyboard shortcut reference labels (display-only)
    "Ask omi",
    "Toggle floating bar",
    "Push to talk",
    "Locked listening",

    // Appearance option values (not actionable settings)
    "System Default",
    "Choose light, dark, or match your system setting.",

    // Voice speed slider labels (values, not settings)
    "0.5×",
    "2.0×",

    // Action buttons in context (not searchable settings)
    "Disconnect",
    "Edit",
    "Open Settings",

    // Informational / error messages (not settings)
    "Backend API, auth, and sync logic are read-only",
    "Could not toggle automatically.",
    "You will be signed out of Fazm.",

    // Tool Timeout card sub-labels (card itself is searchable as "Tool Timeout")
    "Seconds:",
    "0 for smart defaults",

    // Referral card stat headers (card itself is searchable under Subscription)
    "Your code",
    "Completed",
]

// MARK: - Extraction

func readFile(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
        print("ERROR: Cannot read \(path)")
        exit(2)
    }
    return content
}

/// Extract setting titles and subtitles from a Swift source file.
func extractSettingTitles(from source: String, filePath: String) -> [(title: String, subtitle: String?, line: Int)] {
    var results: [(String, String?, Int)] = []
    let lines = source.components(separatedBy: "\n")

    let settingRowRegex = try! NSRegularExpression(
        pattern: #"settingRow\(title:\s*"([^"]+)",\s*subtitle:\s*"([^"]+)""#
    )
    let settingRowNoSubRegex = try! NSRegularExpression(pattern: #"settingRow\(title:\s*"([^"]+)""#)
    let textRegex = try! NSRegularExpression(pattern: #"Text\("([^"\\]+)"\)"#)
    let fontRegex = try! NSRegularExpression(
        pattern: #"\.scaledFont\(size:\s*1[56],\s*weight:\s*\.(medium|semibold)\)"#
    )

    for (i, line) in lines.enumerated() {
        let range = NSRange(line.startIndex..., in: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }

        var matchedSettingRow = false
        for match in settingRowRegex.matches(in: line, range: range) {
            if let titleRange = Range(match.range(at: 1), in: line),
               let subtitleRange = Range(match.range(at: 2), in: line) {
                results.append((String(line[titleRange]), String(line[subtitleRange]), i + 1))
                matchedSettingRow = true
            }
        }

        if !matchedSettingRow {
            for match in settingRowNoSubRegex.matches(in: line, range: range) {
                if let titleRange = Range(match.range(at: 1), in: line) {
                    results.append((String(line[titleRange]), nil, i + 1))
                }
            }
        }

        for match in textRegex.matches(in: line, range: range) {
            if let titleRange = Range(match.range(at: 1), in: line) {
                let title = String(line[titleRange])
                if title.contains("\\(") || title.contains("?") { continue }
                let lookAhead = min(i + 3, lines.count)
                var hasFont = false
                for j in (i + 1)..<lookAhead {
                    let nextLine = lines[j]
                    let nextRange = NSRange(nextLine.startIndex..., in: nextLine)
                    if !fontRegex.matches(in: nextLine, range: nextRange).isEmpty {
                        hasFont = true
                        break
                    }
                }
                if hasFont {
                    results.append((title, nil, i + 1))
                }
            }
        }
    }

    return results
}

/// Extract ALL visible text strings from a Swift source file.
/// Captures both Text("...") and Button("...") labels — any hardcoded
/// string literal that appears in the UI and a user might search for.
func extractAllTextStrings(from source: String) -> [(text: String, line: Int)] {
    var results: [(String, Int)] = []
    let lines = source.components(separatedBy: "\n")

    // Match Text("...") and Button("...") — the two main patterns for visible strings
    let textRegex = try! NSRegularExpression(pattern: #"(?:Text|Button)\("([^"\\]+)"\)"#)

    for (i, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }

        let range = NSRange(line.startIndex..., in: line)
        for match in textRegex.matches(in: line, range: range) {
            if let textRange = Range(match.range(at: 1), in: line) {
                let text = String(line[textRange])
                // Skip single characters, numbers-only, and interpolated strings
                if text.count <= 1 { continue }
                if text.allSatisfy({ $0.isNumber || $0 == "." }) { continue }
                results.append((text, i + 1))
            }
        }
    }

    return results
}

/// Extract all search items (name, subtitle, keywords) from SettingsSidebar.swift
struct SearchItemData {
    let name: String
    let subtitle: String
    let keywords: [String]
}

func extractSearchItems(from source: String) -> [SearchItemData] {
    var items: [SearchItemData] = []

    // Match: SettingsSearchItem(name: "...", subtitle: "...", keywords: ["...", "..."],
    let regex = try! NSRegularExpression(
        pattern: #"SettingsSearchItem\(name:\s*"([^"]+)",\s*subtitle:\s*"([^"]*)",\s*keywords:\s*\[([^\]]*)\]"#
    )
    let range = NSRange(source.startIndex..., in: source)

    let kwRegex = try! NSRegularExpression(pattern: #""([^"]+)""#)

    for match in regex.matches(in: source, range: range) {
        guard let nameRange = Range(match.range(at: 1), in: source),
              let subtitleRange = Range(match.range(at: 2), in: source),
              let kwRange = Range(match.range(at: 3), in: source) else { continue }

        let name = String(source[nameRange])
        let subtitle = String(source[subtitleRange])

        // Extract individual keywords from the array
        let kwString = String(source[kwRange])
        let kwNSRange = NSRange(kwString.startIndex..., in: kwString)
        var keywords: [String] = []
        for kwMatch in kwRegex.matches(in: kwString, range: kwNSRange) {
            if let r = Range(kwMatch.range(at: 1), in: kwString) {
                keywords.append(String(kwString[r]))
            }
        }

        items.append(SearchItemData(name: name, subtitle: subtitle, keywords: keywords))
    }

    return items
}

/// Check if a text string is findable in any search item
func isTextFindable(_ text: String, in items: [SearchItemData]) -> Bool {
    let lower = text.lowercased()
    return items.contains { item in
        let nameLower = item.name.lowercased()
        let subtitleLower = item.subtitle.lowercased()
        let keywordsLower = item.keywords.map { $0.lowercased() }

        // The text itself (or its words) must appear in name, subtitle, or keywords
        return nameLower.contains(lower) ||
               lower.contains(nameLower) ||
               subtitleLower.contains(lower) ||
               keywordsLower.contains(where: { $0.contains(lower) || lower.contains($0) })
    }
}

// MARK: - Main

let settingsSource = readFile(settingsPagePath)
let shortcutsSource = readFile(shortcutsPath)
let sidebarSource = readFile(sidebarPath)

// Extract data
var uiSettings: [(title: String, subtitle: String?, file: String, line: Int)] = []
for (title, subtitle, line) in extractSettingTitles(from: settingsSource, filePath: settingsPagePath) {
    uiSettings.append((title, subtitle, "SettingsPage.swift", line))
}
for (title, subtitle, line) in extractSettingTitles(from: shortcutsSource, filePath: shortcutsPath) {
    uiSettings.append((title, subtitle, "ShortcutsSettingsSection.swift", line))
}

let searchItems = extractSearchItems(from: sidebarSource)
let searchNames = Set(searchItems.map { $0.name })

// Deduplicate
var seen: Set<String> = []
var uniqueSettings: [(title: String, subtitle: String?, file: String, line: Int)] = []
for s in uiSettings {
    if !seen.contains(s.title) {
        seen.insert(s.title)
        uniqueSettings.append(s)
    }
}

var failed = false

// ── Check 1: Title coverage ──
var missing: [(title: String, file: String, line: Int)] = []
for setting in uniqueSettings {
    if ignoredTitles.contains(setting.title) { continue }
    let found = searchNames.contains(where: { name in
        name == setting.title || name.contains(setting.title) || setting.title.contains(name)
    })
    if !found {
        missing.append((setting.title, setting.file, setting.line))
    }
}

// ── Check 2: Subtitle coverage ──
let emptySubtitles = searchItems.filter { $0.subtitle.isEmpty }

// ── Check 3: Text coverage ──
// Extract ALL Text("...") from settings files and verify each is findable
var allTextStrings: [(text: String, file: String, line: Int)] = []
for (text, line) in extractAllTextStrings(from: settingsSource) {
    allTextStrings.append((text, "SettingsPage.swift", line))
}
for (text, line) in extractAllTextStrings(from: shortcutsSource) {
    allTextStrings.append((text, "ShortcutsSettingsSection.swift", line))
}

// Deduplicate text strings
var seenTexts: Set<String> = []
var uniqueTexts: [(text: String, file: String, line: Int)] = []
for t in allTextStrings {
    let lower = t.text.lowercased()
    if !seenTexts.contains(lower) {
        seenTexts.insert(lower)
        uniqueTexts.append(t)
    }
}

var unfindableTexts: [(text: String, file: String, line: Int)] = []
for t in uniqueTexts {
    if ignoredTextLabels.contains(t.text) { continue }
    if !isTextFindable(t.text, in: searchItems) {
        unfindableTexts.append(t)
    }
}

// ── Report ──
print("Settings Search Coverage Check")
print("==============================")
print("UI settings found: \(uniqueSettings.count)")
print("Search items found: \(searchItems.count)")
print("Text strings found: \(uniqueTexts.count)")
print("Ignored titles: \(ignoredTitles.count)")
print("Ignored text labels: \(ignoredTextLabels.count)")
print("")

// Check 1 report
print("Check 1: Setting titles → search items")
if missing.isEmpty {
    print("  ✅ All settings are covered in search!")
} else {
    failed = true
    print("  ❌ \(missing.count) setting(s) missing from search:\n")
    for m in missing {
        print("    • \"\(m.title)\" — \(m.file):\(m.line)")
    }
    print("\n  → Add these to SettingsSearchItem.allSearchableItems in SettingsSidebar.swift")
}
print("")

// Check 2 report
print("Check 2: Search item subtitles")
if emptySubtitles.isEmpty {
    print("  ✅ All search items have subtitles!")
} else {
    failed = true
    print("  ❌ \(emptySubtitles.count) search item(s) have empty subtitles:\n")
    for item in emptySubtitles {
        print("    • \"\(item.name)\"")
    }
    print("\n  → Add subtitles to these items in SettingsSidebar.swift")
}
print("")

// Check 3 report
print("Check 3: Text strings → searchable")
if unfindableTexts.isEmpty {
    print("  ✅ All visible text is searchable!")
} else {
    failed = true
    print("  ❌ \(unfindableTexts.count) text string(s) not findable via search:\n")
    for t in unfindableTexts {
        print("    • \"\(t.text)\" — \(t.file):\(t.line)")
    }
    print("\n  → Add these as keywords to the relevant search item in SettingsSidebar.swift,")
    print("    or add to ignoredTextLabels if they are structural/non-searchable.")
}

print("")
if failed {
    print("❌ Some checks failed!")
    exit(1)
} else {
    print("✅ All checks passed!")
    exit(0)
}
