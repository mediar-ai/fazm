import Foundation
import GRDB

// MARK: - Screenshot Model

/// Represents a captured screenshot stored in the database
struct Screenshot: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    /// Database row ID (auto-generated)
    var id: Int64?

    /// When the screenshot was captured
    var timestamp: Date

    /// Name of the application that was active
    var appName: String

    /// Title of the window (if available)
    var windowTitle: String?

    /// Relative path to the JPEG image file (legacy, nil for video storage)
    var imagePath: String?

    /// Relative path to the video chunk file (new video storage)
    var videoChunkPath: String?

    /// Frame index within the video chunk
    var frameOffset: Int?

    /// Extracted OCR text (nullable until indexed)
    var ocrText: String?

    /// JSON-encoded OCR data with bounding boxes
    var ocrDataJson: String?

    /// Whether OCR has been completed
    var isIndexed: Bool

    /// Focus status at capture time ("focused" | "distracted" | nil)
    var focusStatus: String?

    /// JSON-encoded array of extracted tasks
    var extractedTasksJson: String?

    /// JSON-encoded advice object
    var adviceJson: String?

    /// Whether OCR was skipped because the Mac was on battery (needs backfill when AC reconnects)
    var skippedForBattery: Bool

    static let databaseTableName = "screenshots"

    // MARK: - Storage Type

    /// Whether this screenshot uses video chunk storage (vs legacy JPEG)
    var usesVideoStorage: Bool {
        videoChunkPath != nil && frameOffset != nil
    }

    // MARK: - Initialization

    init(
        id: Int64? = nil,
        timestamp: Date = Date(),
        appName: String,
        windowTitle: String? = nil,
        imagePath: String? = nil,
        videoChunkPath: String? = nil,
        frameOffset: Int? = nil,
        ocrText: String? = nil,
        ocrDataJson: String? = nil,
        isIndexed: Bool = false,
        focusStatus: String? = nil,
        extractedTasksJson: String? = nil,
        adviceJson: String? = nil,
        skippedForBattery: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appName = appName
        self.windowTitle = windowTitle
        self.imagePath = imagePath
        self.videoChunkPath = videoChunkPath
        self.frameOffset = frameOffset
        self.ocrText = ocrText
        self.ocrDataJson = ocrDataJson
        self.isIndexed = isIndexed
        self.focusStatus = focusStatus
        self.extractedTasksJson = extractedTasksJson
        self.adviceJson = adviceJson
        self.skippedForBattery = skippedForBattery
    }

    // MARK: - Persistence Callbacks

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - OCR Data Access

    /// Decode the OCR result with bounding boxes
    var ocrResult: OCRResult? {
        guard let jsonString = ocrDataJson,
              let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(OCRResult.self, from: data)
    }

    /// Get text blocks that match a search query
    func matchingBlocks(for query: String) -> [OCRTextBlock] {
        return ocrResult?.blocksContaining(query) ?? []
    }

    /// Get a context snippet for a search query
    func contextSnippet(for query: String) -> String? {
        return ocrResult?.contextSnippet(for: query)
    }
}

// MARK: - Date Formatting Extensions

extension Screenshot {
    /// Formatted date string for display
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    /// Compact formatted date for bottom controls (shorter format)
    var formattedDateCompact: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: timestamp)
    }

    /// Time-only string for timeline display
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    /// Day string for grouping
    var dayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: timestamp)
    }
}

// MARK: - TableDocumented

extension Screenshot: TableDocumented {
    static var tableDescription: String { ChatPrompts.tableAnnotations["screenshots"]! }
    static var columnDescriptions: [String: String] { ChatPrompts.columnAnnotations["screenshots"] ?? [:] }
}

// MARK: - Search Result

/// A search result containing a screenshot and match information
struct ScreenshotSearchResult: Identifiable, Equatable {
    let screenshot: Screenshot
    let matchedText: String?
    let contextSnippet: String?
    let matchingBlocks: [OCRTextBlock]

    var id: Int64? { screenshot.id }

    init(screenshot: Screenshot, query: String? = nil) {
        self.screenshot = screenshot
        self.matchedText = query

        if let query = query, !query.isEmpty {
            self.contextSnippet = screenshot.contextSnippet(for: query)
            self.matchingBlocks = screenshot.matchingBlocks(for: query)
        } else {
            self.contextSnippet = nil
            self.matchingBlocks = []
        }
    }
}

// MARK: - Search Result Group

/// A group of search results from the same app/window context within a time window
struct SearchResultGroup: Identifiable, Equatable {
    let id: String
    let representativeScreenshot: Screenshot
    let screenshots: [Screenshot]

    var appName: String { representativeScreenshot.appName }
    var windowTitle: String? { representativeScreenshot.windowTitle }
    var count: Int { screenshots.count }

    var startTime: Date {
        screenshots.map { $0.timestamp }.min() ?? representativeScreenshot.timestamp
    }

    var endTime: Date {
        screenshots.map { $0.timestamp }.max() ?? representativeScreenshot.timestamp
    }

    var formattedTimeRange: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let start = formatter.string(from: startTime)

        let calendar = Calendar.current
        if calendar.isDate(startTime, equalTo: endTime, toGranularity: .minute) {
            return start
        }

        if calendar.isDate(startTime, inSameDayAs: endTime) {
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            return "\(start) - \(timeFormatter.string(from: endTime))"
        }

        return "\(start) - \(formatter.string(from: endTime))"
    }

    static func == (lhs: SearchResultGroup, rhs: SearchResultGroup) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Search Result Grouping

private struct ScreenshotSession {
    var screenshots: [Screenshot]
    var minTime: Date
    var maxTime: Date

    mutating func add(_ screenshot: Screenshot) {
        screenshots.append(screenshot)
        if screenshot.timestamp < minTime { minTime = screenshot.timestamp }
        if screenshot.timestamp > maxTime { maxTime = screenshot.timestamp }
    }

    func contains(timestamp: Date, within window: TimeInterval) -> Bool {
        let expandedMin = minTime.addingTimeInterval(-window)
        let expandedMax = maxTime.addingTimeInterval(window)
        return timestamp >= expandedMin && timestamp <= expandedMax
    }
}

extension Array where Element == Screenshot {
    func groupedByContext(timeWindowSeconds: TimeInterval = 30) -> [SearchResultGroup] {
        guard !isEmpty else { return [] }

        var contextSessions: [String: [ScreenshotSession]] = [:]
        var groupOrder: [(key: String, sessionIndex: Int)] = []

        for screenshot in self {
            let key = "\(screenshot.appName)|\(screenshot.windowTitle ?? "")"

            if contextSessions[key] == nil {
                let session = ScreenshotSession(
                    screenshots: [screenshot],
                    minTime: screenshot.timestamp,
                    maxTime: screenshot.timestamp
                )
                contextSessions[key] = [session]
                groupOrder.append((key: key, sessionIndex: 0))
            } else {
                var foundSession = false
                for i in 0..<contextSessions[key]!.count {
                    if contextSessions[key]![i].contains(timestamp: screenshot.timestamp, within: timeWindowSeconds) {
                        contextSessions[key]![i].add(screenshot)
                        foundSession = true
                        break
                    }
                }

                if !foundSession {
                    let session = ScreenshotSession(
                        screenshots: [screenshot],
                        minTime: screenshot.timestamp,
                        maxTime: screenshot.timestamp
                    )
                    let newIndex = contextSessions[key]!.count
                    contextSessions[key]!.append(session)
                    groupOrder.append((key: key, sessionIndex: newIndex))
                }
            }
        }

        return groupOrder.compactMap { order -> SearchResultGroup? in
            guard let session = contextSessions[order.key]?[order.sessionIndex] else { return nil }

            let sortedScreenshots = session.screenshots.sorted { $0.timestamp > $1.timestamp }
            guard let representative = sortedScreenshots.first else { return nil }

            return SearchResultGroup(
                id: "\(order.key)|\(order.sessionIndex)",
                representativeScreenshot: representative,
                screenshots: sortedScreenshots
            )
        }
    }
}

// MARK: - Error Types

enum RewindError: LocalizedError {
    case databaseNotInitialized
    case databaseCorrupted(message: String)
    case invalidImage
    case storageError(String)
    case ocrFailed(String)
    case screenshotNotFound
    case corruptedVideoChunk(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "Database is not initialized"
        case .databaseCorrupted(let message):
            return "Database corrupted: \(message)"
        case .invalidImage:
            return "Invalid image data"
        case .storageError(let message):
            return "Storage error: \(message)"
        case .ocrFailed(let message):
            return "OCR failed: \(message)"
        case .screenshotNotFound:
            return "Screenshot not found"
        case .corruptedVideoChunk(let path):
            return "Video chunk corrupted: \(path)"
        }
    }
}

// MARK: - Video Chunk Info

/// Info about a video chunk file for database rebuild
struct VideoChunkInfo {
    let filename: String
    let relativePath: String
    let fullPath: URL
}

// MARK: - Rewind Settings

/// Settings for the screen capture feature
class RewindSettings: ObservableObject {
    static let shared = RewindSettings()

    private let defaults = UserDefaults.standard

    /// Default apps that should be excluded from screen capture for privacy
    static let defaultExcludedApps: Set<String> = [
        "Fazm",
        "Fazm Dev",
        "Omi Computer",
        "Omi Beta",
        "Omi Dev",
        "Passwords",
        "1Password",
        "1Password 7",
        "Bitwarden",
        "LastPass",
        "Dashlane",
        "Keeper",
        "Enpass",
        "KeePassXC",
        "Keychain Access",
    ]

    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: "rewindRetentionDays") }
    }

    @Published var captureInterval: Double {
        didSet { defaults.set(captureInterval, forKey: "rewindCaptureInterval") }
    }

    @Published var ocrRecognitionFast: Bool {
        didSet { defaults.set(ocrRecognitionFast, forKey: "rewindOCRFast") }
    }

    @Published var pauseOCROnBattery: Bool {
        didSet { defaults.set(pauseOCROnBattery, forKey: "rewindPauseOCROnBattery") }
    }

    @Published var excludedApps: Set<String> {
        didSet { defaults.set(Array(excludedApps), forKey: "rewindExcludedApps") }
    }

    private var removedDefaults: Set<String> {
        didSet { defaults.set(Array(removedDefaults), forKey: "rewindRemovedDefaultApps") }
    }

    private init() {
        self.retentionDays = defaults.object(forKey: "rewindRetentionDays") as? Int ?? 7
        self.captureInterval = defaults.object(forKey: "rewindCaptureInterval") as? Double ?? 1.0
        self.ocrRecognitionFast = defaults.object(forKey: "rewindOCRFast") as? Bool ?? true
        self.pauseOCROnBattery = defaults.object(forKey: "rewindPauseOCROnBattery") as? Bool ?? true
        self.removedDefaults = Set(defaults.array(forKey: "rewindRemovedDefaultApps") as? [String] ?? [])

        if let savedApps = defaults.array(forKey: "rewindExcludedApps") as? [String] {
            var apps = Set(savedApps)
            let newDefaults = Self.defaultExcludedApps.subtracting(apps).subtracting(removedDefaults)
            apps.formUnion(newDefaults)
            self.excludedApps = apps
        } else {
            self.excludedApps = Self.defaultExcludedApps
        }
    }

    func isAppExcluded(_ appName: String) -> Bool { excludedApps.contains(appName) }

    func excludeApp(_ appName: String) {
        excludedApps.insert(appName)
        if Self.defaultExcludedApps.contains(appName) { removedDefaults.remove(appName) }
    }

    func includeApp(_ appName: String) {
        excludedApps.remove(appName)
        if Self.defaultExcludedApps.contains(appName) { removedDefaults.insert(appName) }
    }

    func resetToDefaults() {
        excludedApps = Self.defaultExcludedApps
        removedDefaults = []
    }
}
