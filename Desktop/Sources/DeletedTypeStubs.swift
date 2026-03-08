// MARK: - Stubs for deleted types
// These are minimal stub implementations to satisfy compilation after removing ~170 files.
// They provide empty/no-op implementations so the remaining code compiles.

import SwiftUI
import Combine
import CoreBluetooth
import AVFoundation

// MARK: - Audio & Transcription

/// Speaker segment for diarized transcription
struct SpeakerSegment: Identifiable {
    var id: String { "\(speaker)-\(start)" }
    var speaker: Int
    var text: String
    var start: Double
    var end: Double
}

/// Result of finalizing a conversation
enum FinishConversationResult {
    case saved
    case discarded
    case error(String)
}

enum AudioSource: String {
    case microphone
    case bleDevice
}

enum ConversationSource: String {
    case desktop
    case omi
    case phone

    static func from(deviceType: String) -> ConversationSource { .omi }
}

// AudioCaptureService — real implementation in AudioCaptureService.swift

@MainActor
class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()
    @Published var microphoneLevel: Float = 0
    @Published var systemLevel: Float = 0
    func updateMicrophoneLevel(_ level: Float) { microphoneLevel = level }
    func updateSystemLevel(_ level: Float) { systemLevel = level }
    func reset() { microphoneLevel = 0; systemLevel = 0 }
}

class AudioMixer {
    func start(onMixed: @escaping (Data) -> Void) {}
    func setMicAudio(_ data: Data) {}
    func setSystemAudio(_ data: Data) {}
    func stop() {}
}

class SystemAudioCaptureService {
    func startCapture(onAudioChunk: @escaping (Data) -> Void, onAudioLevel: ((Float) -> Void)? = nil) async throws {}
    func stopCapture() {}
}

class VADGateService {
    struct Output {
        var audioToSend: Data = Data()
        var shouldFinalize: Bool = false
        var isComplete: Bool = false
        var audioBuffer: Data?
        var speechStartWallTime: Double = 0
    }
    var modelAvailable: Bool { false }
    func processAudio(_ data: Data) -> Output { Output() }
    func processAudioBatch(_ data: Data) -> Output { Output() }
    func needsKeepalive() -> Bool { false }
    func flushBatchBuffer() -> Output? { nil }
    func remapTimestamp(start: Double, end: Double) -> (Double, Double) { (start, end) }
}

// TranscriptionService — real implementation in TranscriptionService.swift

@MainActor
class RecordingTimer: ObservableObject {
    static let shared = RecordingTimer()
    @Published var duration: TimeInterval = 0
    func start() {}
    func stop() { duration = 0 }
    func restart() { duration = 0 }
}

@MainActor
class LiveTranscriptMonitor: ObservableObject {
    static let shared = LiveTranscriptMonitor()
    @Published var segments: [SpeakerSegment] = []
    func clear() { segments = [] }
    func updateSegments(_ segs: [SpeakerSegment]) { segments = segs }
}

@MainActor
class LiveNotesMonitor: ObservableObject {
    static let shared = LiveNotesMonitor()
    @Published var notes: [String] = []
    @Published var wordBufferCount: Int = 0
    @Published var existingNotesContextCount: Int = 0
    func startSession(sessionId: Int64) {}
    func endSession() {}
    func clear() {}
}

// MARK: - Storage

actor TranscriptionStorage {
    static let shared = TranscriptionStorage()
    func startSession(source: String, language: String, timezone: String, inputDeviceName: String?) async throws -> Int64 { 0 }
    func finishSession(id: Int64) async throws {}
    func markSessionUploading(id: Int64) async throws {}
    func markSessionCompleted(id: Int64, backendId: String) async throws {}
    func markSessionFailed(id: Int64, error: String) async throws {}
    func deleteSession(id: Int64) async throws {}
    struct DBSegment {
        var speaker: Int
        var text: String
        var startTime: Double
        var endTime: Double
    }
    func getSegments(sessionId: Int64) async throws -> [DBSegment] { [] }
    func appendSegment(sessionId: Int64, speaker: Int, text: String, startTime: Double, endTime: Double) async throws {}
    func getLocalConversations(limit: Int, starredOnly: Bool, folderId: String?) async throws -> [ServerConversation] { [] }
    func getLocalConversationsCount(starredOnly: Bool) async throws -> Int { 0 }
    func syncServerConversation(_ conversation: ServerConversation) async throws {}
    func updateFolderByBackendId(_ id: String, folderId: String?) async throws {}
}

// MARK: - Server Models

struct ServerConversation: Identifiable, Equatable, Codable {
    var id: String
    var structured: Structured
    var createdAt: Date
    var status: Status
    var discarded: Bool
    var starred: Bool

    struct Structured: Codable, Equatable {
        var title: String
        var overview: String
    }

    enum Status: String, Codable {
        case completed
        case processing
        case inProgress = "in_progress"
    }

    init(id: String = UUID().uuidString, title: String = "", overview: String = "", createdAt: Date = Date(), starred: Bool = false) {
        self.id = id
        self.structured = Structured(title: title, overview: overview)
        self.createdAt = createdAt
        self.status = .completed
        self.discarded = false
        self.starred = starred
    }
}

struct Folder: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var description: String?
    var color: String?
}

struct Person: Identifiable, Codable, Equatable {
    var id: String
    var name: String
}

struct ServerMemory: Identifiable, Codable, Equatable {
    var id: String
    var content: String
}

enum GoalType: String, Codable {
    case boolean
    case numeric
    case percentage
}

struct Goal: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var description: String?
    var isActive: Bool = true
    var goalType: GoalType = .boolean
    var currentValue: Double = 0
    var targetValue: Double = 1
    var unit: String?
}

struct TaskActionItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var description: String
    var completed: Bool = false
    var deleted: Bool? = false
    var priority: String?
    var category: String?
    var dueAt: Date?
}

// MARK: - InstalledApp Model (Chat apps)

struct InstalledApp: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var image: String
    var description: String
    var author: String
}

// MARK: - API Client

// AuthError moved to AuthService.swift

struct ChatMessageResponse: Codable {
    var id: String
    var text: String
    var sender: String
    var created_at: Date?
    var createdAt: Date? { created_at }
    var rating: Int?
}

/// Type alias so both names work — ChatProvider uses ChatMessageDB, stubs return the same type
typealias ChatMessageDB = ChatMessageResponse

struct InitialMessageResponse {
    var message: String
    var messageId: String
}

struct SessionTitleResponse {
    var title: String
}

struct SaveMessageResponse {
    var id: String
}

@MainActor
class APIClient {
    static let shared = APIClient()

    struct TranscriptSegmentRequest {
        var text: String
        var speaker: String
        var speakerId: Int
        var isUser: Bool
        var personId: String?
        var start: Double
        var end: Double
    }

    struct CreateConversationResponse {
        var id: String
        var status: String
        var discarded: Bool
    }

    struct AppInfo: Codable, Identifiable {
        var id: String
        var name: String
    }

    func getConversations(limit: Int, offset: Int, statuses: [ServerConversation.Status] = [], includeDiscarded: Bool = false, startDate: Date? = nil, endDate: Date? = nil, folderId: String? = nil, starred: Bool? = nil) async throws -> [ServerConversation] { [] }
    func getConversationsCount(includeDiscarded: Bool = false) async throws -> Int { 0 }
    func getConversation(id: String) async throws -> ServerConversation { ServerConversation() }
    func createConversationFromSegments(segments: [TranscriptSegmentRequest], startedAt: Date, finishedAt: Date, source: ConversationSource, inputDeviceName: String?) async throws -> CreateConversationResponse {
        CreateConversationResponse(id: UUID().uuidString, status: "completed", discarded: false)
    }
    func getFolders() async throws -> [Folder] { [] }
    func createFolder(name: String, description: String?, color: String?) async throws -> Folder { Folder(id: UUID().uuidString, name: name) }
    func deleteFolder(id: String, moveToFolderId: String?) async throws {}
    func updateFolder(id: String, name: String?, description: String?, color: String?) async throws -> Folder { Folder(id: id, name: name ?? "") }
    func moveConversationToFolder(conversationId: String, folderId: String?) async throws {}
    func getPeople() async throws -> [Person] { [] }
    func createPerson(name: String) async throws -> Person { Person(id: UUID().uuidString, name: name) }
    func assignSegmentsBulk(conversationId: String, segmentIds: [String], isUser: Bool, personId: String?) async throws {}

    // Chat API — signatures match ChatProvider calling patterns
    func getChatSessions(appId: String? = nil, starred: Bool? = nil) async throws -> [ChatSession] { [] }
    func createChatSession(title: String? = nil, appId: String? = nil) async throws -> ChatSession { ChatSession() }
    func updateChatSession(sessionId: String, title: String? = nil, starred: Bool? = nil) async throws -> ChatSession { ChatSession() }
    func deleteChatSession(sessionId: String) async throws {}
    func generateSessionTitle(sessionId: String, messages: [(text: String, sender: String)] = []) async throws -> SessionTitleResponse { SessionTitleResponse(title: "Chat") }
    func getMessages(sessionId: String, limit: Int = 100, offset: Int = 0) async throws -> [ChatMessageDB] { [] }
    func getMessages(appId: String?, limit: Int = 100, offset: Int = 0) async throws -> [ChatMessageDB] { [] }
    func getChatMessageCount(sessionId: String? = nil) async throws -> Int { 0 }
    func saveMessage(text: String, sender: String, appId: String? = nil, sessionId: String? = nil, metadata: String? = nil) async throws -> SaveMessageResponse {
        SaveMessageResponse(id: UUID().uuidString)
    }
    func deleteMessages(sessionId: String? = nil, messageIds: [String] = [], appId: String? = nil) async throws {}
    func rateMessage(messageId: String, rating: Int?) async throws {}
    func getInitialMessage(sessionId: String, appId: String? = nil) async throws -> InitialMessageResponse {
        InitialMessageResponse(message: "Hello!", messageId: UUID().uuidString)
    }
    func recordLlmUsage(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, totalTokens: Int = 0, costUsd: Double = 0, account: String = "") async {}
    func fetchTotalOmiAICost() async -> Double? { 0.0 }

    // Knowledge Graph
    func getKnowledgeGraph() async throws -> KnowledgeGraphResponse { KnowledgeGraphResponse(nodes: [], edges: []) }
    func rebuildKnowledgeGraph() async throws -> Bool { false }

    // Search
    func searchApps(query: String = "", installedOnly: Bool = false) async throws -> [AppInfo] { [] }

    // Goals
    func getGoals() async throws -> [Goal] { [] }

    // Settings API
    func setRecordingPermission(enabled: Bool) async throws {}
    func getRecordingPermission() async throws -> (enabled: Bool, Void) { (enabled: false, ()) }
    func setPrivateCloudSync(enabled: Bool) async throws {}
    func getPrivateCloudSync() async throws -> (enabled: Bool, Void) { (enabled: false, ()) }
    func updateTranscriptionPreferences(language: String? = nil, autoDetect: Bool? = nil, vocabulary: [String]? = nil, singleLanguageMode: Bool? = nil) async throws {}
    func getTranscriptionPreferences() async throws -> (singleLanguageMode: Bool, vocabulary: [String]) { (singleLanguageMode: false, vocabulary: []) }
    func updateUserLanguage(_ language: String) async throws {}
    func getUserLanguage() async throws -> (language: String, Void) { (language: "en", ()) }
    func updateNotificationSettings(focus: Bool? = nil, task: Bool? = nil, memory: Bool? = nil, advice: Bool? = nil, enabled: Bool? = nil, frequency: Int? = nil) async throws {}
    func getNotificationSettings() async throws -> (enabled: Bool, frequency: Int) { (enabled: false, frequency: 0) }
    func getDailySummarySettings() async throws -> DailySummarySettings { DailySummarySettings() }
    func updateDailySummarySettings(enabled: Bool? = nil, time: String? = nil, hour: Int? = nil) async throws {}

    struct DailySummarySettings: Codable {
        var enabled: Bool = false
        var time: String = "09:00"
        var hour: Int = 9
        init() {}
    }
}

// MARK: - Auth & Services

// AuthService moved to AuthService.swift

class ScreenCaptureService {
    static func checkPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    static func openScreenRecordingPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    static func requestAllScreenCapturePermissions() {
        CGRequestScreenCaptureAccess()
    }
    @available(macOS 14.0, *)
    static func testScreenCaptureKitPermission() async -> Bool { true }
    static func ensureLaunchServicesRegistration() {
        DispatchQueue.global(qos: .utility).async {
            ensureLaunchServicesRegistrationSync()
        }
    }
    static func ensureLaunchServicesRegistrationSync() {
        let appPath = Bundle.main.bundlePath
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = ["-f", appPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
    static func resetScreenCapturePermission() -> Bool {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.fazm.app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleId]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    static func resetScreenCapturePermissionAndRestart() {
        _ = resetScreenCapturePermission()
    }
}

// MARK: - Bluetooth & Device

class BluetoothManager: ObservableObject {
    static let shared = BluetoothManager()
    @Published var bluetoothState: CBManagerState = .unknown
    var bluetoothStateDescription: String { "unknown" }
    var authorizationDescription: String { "unknown" }
    func triggerPermissionPrompt() {}
}

@MainActor
class DeviceProvider: ObservableObject {
    static let shared = DeviceProvider()
    struct Device {
        var type: String
        var displayName: String
    }
    struct Connection {
        var device: Device
    }
    @Published var isConnected: Bool = false
    @Published var batteryLevel: Int = -1
    var connectedDevice: Device? { nil }
    var pairedDevice: Device? { nil }
    var activeConnection: Connection? { nil }
    func initializeBluetoothBindingsIfNeeded() {}
    func getButtonStream() -> AsyncThrowingStream<[UInt8], Error>? { nil }
}

class BleAudioService {
    static let shared = BleAudioService()
    var audioLevel: Float = 0
    func startProcessing(from connection: DeviceProvider.Connection, transcriptionService: TranscriptionService, audioDataHandler: @escaping (Data) -> Void) async {}
    func stopProcessing() {}
}

// MARK: - Proactive Assistants & Settings

@MainActor
class AssistantSettings: ObservableObject {
    static let shared = AssistantSettings()
    @Published var transcriptionEnabled: Bool = false
    @Published var transcriptionLanguage: String = "en"
    @Published var transcriptionAutoDetect: Bool = false
    @Published var batchTranscriptionEnabled: Bool = false
    @Published var vadGateEnabled: Bool = false
    @Published var screenAnalysisEnabled: Bool = false
    @Published var transcriptionVocabulary: [String] = UserDefaults.standard.stringArray(forKey: "transcription_vocabulary") ?? ["fazm"] {
        didSet {
            UserDefaults.standard.set(transcriptionVocabulary, forKey: "transcription_vocabulary")
        }
    }
    @Published var analysisDelay: Int = 3
    @Published var glowOverlayEnabled: Bool = false
    var effectiveTranscriptionLanguage: String { transcriptionLanguage }
    var effectiveVocabulary: [String] { transcriptionVocabulary }

    static var supportedLanguages: [(code: String, name: String)] {
        [("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
         ("it", "Italian"), ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"),
         ("zh", "Chinese"), ("ru", "Russian"), ("ar", "Arabic"), ("hi", "Hindi")]
    }
    static func supportsAutoDetect(_ language: String) -> Bool { true }
}

struct AssistantSettingsResponse: Codable {
    var shared: SharedAssistantSettingsResponse?
    var focus: FocusSettingsResponse?
    var task: TaskSettingsResponse?
    var memory: MemorySettingsResponse?
    var advice: AdviceSettingsResponse?

    init(shared: SharedAssistantSettingsResponse? = nil,
         focus: FocusSettingsResponse? = nil,
         task: TaskSettingsResponse? = nil,
         memory: MemorySettingsResponse? = nil,
         advice: AdviceSettingsResponse? = nil) {
        self.shared = shared
        self.focus = focus
        self.task = task
        self.memory = memory
        self.advice = advice
    }
}

struct SharedAssistantSettingsResponse: Codable {
    var analysisDelay: Int?
    var glowOverlayEnabled: Bool?
    init(analysisDelay: Int? = nil, glowOverlayEnabled: Bool? = nil) {
        self.analysisDelay = analysisDelay
        self.glowOverlayEnabled = glowOverlayEnabled
    }
}
struct FocusSettingsResponse: Codable {
    var enabled: Bool?
    var notificationsEnabled: Bool?
    var cooldownInterval: Int?
    init(enabled: Bool? = nil, notificationsEnabled: Bool? = nil, cooldownInterval: Int? = nil) {
        self.enabled = enabled
        self.notificationsEnabled = notificationsEnabled
        self.cooldownInterval = cooldownInterval
    }
}
struct TaskSettingsResponse: Codable {
    var enabled: Bool?
    var notificationsEnabled: Bool?
    var extractionInterval: Int?
    var minConfidence: Double?
    init(enabled: Bool? = nil, notificationsEnabled: Bool? = nil, extractionInterval: Int? = nil, minConfidence: Double? = nil) {
        self.enabled = enabled
        self.notificationsEnabled = notificationsEnabled
        self.extractionInterval = extractionInterval
        self.minConfidence = minConfidence
    }
}
struct MemorySettingsResponse: Codable {
    var enabled: Bool?
    var extractionInterval: Int?
    var minConfidence: Double?
    var notificationsEnabled: Bool?
    init(enabled: Bool? = nil, extractionInterval: Int? = nil, minConfidence: Double? = nil, notificationsEnabled: Bool? = nil) {
        self.enabled = enabled
        self.extractionInterval = extractionInterval
        self.minConfidence = minConfidence
        self.notificationsEnabled = notificationsEnabled
    }
}
struct AdviceSettingsResponse: Codable {
    var enabled: Bool?
    var extractionInterval: Int?
    var minConfidence: Double?
    var notificationsEnabled: Bool?
    init(enabled: Bool? = nil, extractionInterval: Int? = nil, minConfidence: Double? = nil, notificationsEnabled: Bool? = nil) {
        self.enabled = enabled
        self.extractionInterval = extractionInterval
        self.minConfidence = minConfidence
        self.notificationsEnabled = notificationsEnabled
    }
}

@MainActor
class FocusAssistantSettings: ObservableObject {
    static let shared = FocusAssistantSettings()
    @Published var enabled: Bool = false
    @Published var isEnabled: Bool = false
    @Published var cooldownInterval: Int = 5
    @Published var analysisDelay: Int = 3
    @Published var glowOverlayEnabled: Bool = false
    @Published var notificationsEnabled: Bool = true
    @Published var excludedApps: Set<String> = []

    func includeApp(_ appName: String) { excludedApps.remove(appName) }
    func excludeApp(_ appName: String) { excludedApps.insert(appName) }
}

@MainActor
class TaskAssistantSettings: ObservableObject {
    static let shared = TaskAssistantSettings()
    @Published var enabled: Bool = false
    @Published var isEnabled: Bool = false
    @Published var extractionInterval: Int = 5
    @Published var minConfidence: Double = 0.7
    @Published var notificationsEnabled: Bool = true
    @Published var allowedApps: Set<String> = []
    @Published var browserKeywords: [String] = []
    static var builtInExcludedApps: Set<String> { [] }
    static var defaultAllowedApps: Set<String> { [] }

    func allowApp(_ appName: String) { allowedApps.insert(appName) }
    func disallowApp(_ appName: String) { allowedApps.remove(appName) }
    func addBrowserKeyword(_ keyword: String) { browserKeywords.append(keyword) }
    func removeBrowserKeyword(_ keyword: String) { browserKeywords.removeAll { $0 == keyword } }
    static func isBrowser(_ appName: String) -> Bool { false }
}

@MainActor
class MemoryAssistantSettings: ObservableObject {
    static let shared = MemoryAssistantSettings()
    @Published var enabled: Bool = false
    @Published var isEnabled: Bool = false
    @Published var extractionInterval: Int = 5
    @Published var minConfidence: Double = 0.7
    @Published var notificationsEnabled: Bool = true
    @Published var excludedApps: Set<String> = []

    func includeApp(_ appName: String) { excludedApps.remove(appName) }
    func excludeApp(_ appName: String) { excludedApps.insert(appName) }
}

@MainActor
class AdviceAssistantSettings: ObservableObject {
    static let shared = AdviceAssistantSettings()
    @Published var enabled: Bool = false
    @Published var isEnabled: Bool = false
    @Published var extractionInterval: Int = 5
    @Published var minConfidence: Double = 0.7
    @Published var notificationsEnabled: Bool = true
    @Published var excludedApps: Set<String> = []

    func includeApp(_ appName: String) { excludedApps.remove(appName) }
    func excludeApp(_ appName: String) { excludedApps.insert(appName) }
}

@MainActor
class ProactiveAssistantsPlugin {
    static let shared = ProactiveAssistantsPlugin()
    var isMonitoring: Bool = false
    var hasScreenRecordingPermission: Bool = false
    var isProcessingRewindFrame: Bool = false
    var droppedFrameCount: Int = 0
    var currentFocusAssistant: FocusAssistantActor? = nil
    func startMonitoring(completion: @escaping (Bool, String?) -> Void) { completion(true, nil) }
    func stopMonitoring() {}
    func refreshScreenRecordingPermission() {}
    func openScreenRecordingPreferences() {
        ScreenCaptureService.openScreenRecordingPreferences()
    }
    static func repairNotificationRegistration() {}
}

/// Stub actor for focus assistant to satisfy async member access
actor FocusAssistantActor {
    var pendingTasksCount: Int { 0 }
    var analysisHistoryCount: Int { 0 }
    func clearPendingWork() {}
}

@MainActor
class AssistantCoordinator {
    static let shared = AssistantCoordinator()
    func refreshSettings() async {}
    func clearAllPendingWork() {}
}

class SettingsSyncManager {
    static let shared = SettingsSyncManager()
    func syncToServer() async {}
    func syncFromServer() async {}
    func pushPartialUpdate(_ settings: AssistantSettingsResponse) {}
    func pushPartialUpdate(key: String, value: Any) async {}
}

// MARK: - Services

class AgentSyncService {
    static let shared = AgentSyncService()
    func stop() async {}
    func pause() async {}
    func resume() async {}
}

class AgentVMService {
    static let shared = AgentVMService()
    func startPipeline() async {}
    func ensureProvisioned() async {}
}

class NotificationService {
    static let shared = NotificationService()
    func sendNotification(title: String, body: String, identifier: String? = nil) {}
    func sendNotification(title: String, message: String, identifier: String? = nil) {}
}

class OverlayService {
    static let shared = OverlayService()
    func showGlow(around frame: CGRect, colorMode: GlowColorMode, isPreview: Bool = false) {}
}

enum GlowColorMode: String {
    case focused
    case distracted
}

// FileIndexerService moved to FileIndexing/FileIndexerService.swift

@MainActor
class CrispManager: ObservableObject {
    static let shared = CrispManager()
    @Published var unreadCount: Int = 0
    func start() {}
    func markAsRead() { unreadCount = 0 }
}

@MainActor
class TierManager: ObservableObject {
    static let shared = TierManager()
    @Published var currentTier: Int = 0
    func userDidSetTier(_ tier: Int) {}
    func checkTierIfNeeded() async {}
}

class ScreenActivitySyncService {
    static let shared = ScreenActivitySyncService()
    func start() async {}
}

class VideoChunkEncoder {
    static let shared = VideoChunkEncoder()
    var currentChunkPath: String? { nil }
    func initialize() {}
    func initialize(videosDirectory: URL) async throws {}
    func flushCurrentChunk() async {}
    func getBufferStatus() -> VideoBufferStatus { VideoBufferStatus() }
}

struct VideoBufferStatus {
    var frameCount: Int = 0
    var oldestFrameAge: Double? = nil
}

@MainActor
class GoalsAIService {
    static let shared = GoalsAIService()
    func extractProgressFromAllGoals(text: String) async {}
}

@MainActor
class GoalGenerationService: ObservableObject {
    static let shared = GoalGenerationService()
    @Published var isAutoGenerationEnabled: Bool = false
    func onConversationCreated() {}
}

class TaskPrioritizationService {
    static let shared = TaskPrioritizationService()
    func forceFullRescore() async {}
}

class TaskAgentManager {
    static let shared = TaskAgentManager()
    func restoreSessionsFromDatabase() async {}
}

class OCREmbeddingService {
    static let shared = OCREmbeddingService()
    struct SearchResult {
        var screenshotId: Int64
        var similarity: Float
    }
    func searchSimilar(query: String, startDate: Date, endDate: Date, appFilter: String? = nil, topK: Int = 20) async throws -> [SearchResult] { [] }
}

class RewindIndexer {
    static let shared = RewindIndexer()
    struct Stats {
        var totalFrames: Int = 0
        var totalSize: Int64 = 0
        var total: Int = 0
        var indexed: Int = 0
        var storageSize: Int64 = 0
    }
    func getStats() async -> Stats { Stats() }
}

// AIUserProfileService moved to FileIndexing/AIUserProfileService.swift
// KnowledgeGraphStorage moved to FileIndexing/KnowledgeGraphStorage.swift

// MARK: - Storage Actors

actor ActionItemStorage {
    static let shared = ActionItemStorage()
    func getLocalActionItems(limit: Int = 50, completed: Bool? = nil, filter: String? = nil) async throws -> [TaskActionItem] { [] }
    func getLocalActionItem(id: String) async -> TaskActionItem? { nil }
    func getLocalActionItem(byBackendId id: String) async throws -> TaskActionItem? { nil }
    func actionItemExists(id: String) async -> Bool { false }
    func actionItemExists(description: String) async -> Bool { false }
    struct FilterCounts {
        var all: Int = 0
        var today: Int = 0
        var upcoming: Int = 0
        var completed: Int = 0
        var todo: Int = 0
        var done: Int = 0
        var deleted: Int = 0
    }
    func getFilterCounts() async -> FilterCounts { FilterCounts() }
}

@MainActor
class AdviceStorage: ObservableObject {
    static let shared = AdviceStorage()
    @Published var unreadCount: Int = 0
}

enum FocusStatus: String {
    case focused
    case distracted
}

@MainActor
class FocusStorage: ObservableObject {
    static let shared = FocusStorage()
    @Published var currentStatus: FocusStatus? = nil
}

actor GoalStorage {
    static let shared = GoalStorage()
    func getLocalGoals(activeOnly: Bool = false) async throws -> [Goal] { [] }
}

actor MemoryStorage {
    static let shared = MemoryStorage()
    func getLocalMemories(limit: Int) async throws -> [ServerMemory] { [] }
    struct Stats {
        var total: Int = 0
    }
    func getStats() async -> Stats { Stats() }
}

actor ProactiveStorage {
    static let shared = ProactiveStorage()
    func getTotalFocusSessionCount() async -> Int { 0 }
}

// MARK: - ViewModels

@MainActor
class DashboardViewModel: ObservableObject {
    func loadDashboardData() async {}
}

@MainActor
class TasksViewModel: ObservableObject {
    var chatCoordinator: TaskChatCoordinator?
}

@MainActor
class TasksStore: ObservableObject {
    static let shared = TasksStore()
    var isActive: Bool = false
    func loadTasks() async {}
    func toggleTask(_ task: TaskActionItem) async {}
    func deleteTask(_ task: TaskActionItem) async {}
    func createTask(description: String, dueAt: Date? = nil, priority: String? = nil) async {}
    func retryUnsyncedItems(includeRecent: Bool = false) async {}
    func reloadFromLocalCache() async {}
}

@MainActor
class MemoriesViewModel: ObservableObject {
    var isActive: Bool = false
    func loadMemories() async {}
}

@MainActor
class TaskChatCoordinator: ObservableObject {
    init(chatProvider: ChatProvider) {}
}

@MainActor
class AppProvider: ObservableObject {
    @Published var chatApps: [InstalledApp] = []
    func fetchApps() async {}
}

// MARK: - Views (Deleted Pages)

// SignInView moved to SignInView.swift

struct DashboardPage: View {
    var viewModel: DashboardViewModel
    var appState: AppState
    @Binding var selectedIndex: Int
    var body: some View {
        Text("Dashboard")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationDetailView: View {
    var conversation: ServerConversation? = nil
    var onBack: (() -> Void)? = nil
    var body: some View { EmptyView() }
}

struct MemoriesPage: View {
    var viewModel: MemoriesViewModel
    var body: some View {
        Text("Memories")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TasksPage: View {
    var viewModel: TasksViewModel
    var chatCoordinator: TaskChatCoordinator
    var chatProvider: ChatProvider
    var body: some View {
        Text("Tasks")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FocusPage: View {
    var body: some View {
        Text("Focus")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AdvicePage: View {
    var body: some View {
        Text("Advice")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RewindPage: View {
    var appState: AppState
    var body: some View {
        Text("Rewind")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppsPage: View {
    var appProvider: AppProvider
    var body: some View {
        Text("Apps")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DeviceSettingsPage: View {
    var body: some View {
        Text("Device Settings")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HelpPage: View {
    var body: some View {
        Text("Help")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GoalCelebrationView: View {
    var body: some View { EmptyView() }
}

struct AppIconView: View {
    var appName: String = ""
    var size: CGFloat = 24
    var body: some View { EmptyView() }
}

struct DismissButton: View {
    var action: (() -> Void)? = nil
    var showBackground: Bool = true
    var body: some View { EmptyView() }
}

// MARK: - Task Agent Settings

class TaskAgentSettings {
    static var shared = TaskAgentSettings()
    var maxParallelAgents: Int = 4
    var enabledTools: Set<String> = []
    var isChatEnabled: Bool = false
    var workingDirectory: String = ""
}

struct TaskAgentSettingsView: View {
    var body: some View { EmptyView() }
}

// MARK: - Window Stubs

// FeedbackWindow: moved to FeedbackView.swift

class GlowDemoWindow {
    var frame: CGRect { .zero }
    @discardableResult
    static func show() -> GlowDemoWindow { GlowDemoWindow() }
    static func close() {}
    static func setPhase(_ phase: GlowColorMode) {}
}

class PromptEditorWindow {
    static func show() {}
}

class FocusTestRunnerWindow {
    static func show() {}
}

class TaskTestRunnerWindow {
    static func show() {}
}

class MemoryPromptEditorWindow {
    static func show() {}
}

class AdvicePromptEditorWindow {
    static func show() {}
}

class AdviceTestRunnerWindow {
    static func show() {}
}

class TaskPromptEditorWindow {
    static func show() {}
}

// MARK: - OCR Models

struct OCRResult: Codable, Equatable {
    var fullText: String = ""
    var blocks: [OCRTextBlock]
    var processedAt: Date? = nil

    init(fullText: String = "", blocks: [OCRTextBlock] = [], processedAt: Date? = nil) {
        self.fullText = fullText
        self.blocks = blocks
        self.processedAt = processedAt
    }

    func blocksContaining(_ query: String) -> [OCRTextBlock] {
        blocks.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }
    func contextSnippet(for query: String) -> String? {
        guard let block = blocks.first(where: { $0.text.localizedCaseInsensitiveContains(query) }) else { return nil }
        return block.text
    }
}

struct OCRTextBlock: Codable, Equatable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var confidence: Float = 1.0
}

// LocalKGNodeRecord and LocalKGEdgeRecord moved to FileIndexing/KnowledgeGraphRecord.swift

// MARK: - Knowledge Graph API Models

enum KnowledgeGraphNodeType: String, Codable {
    case person
    case place
    case organization
    case thing
    case concept
}

struct KnowledgeGraphNode: Identifiable, Codable {
    var id: String
    var label: String
    var nodeType: KnowledgeGraphNodeType
    var aliases: [String]
    var memoryIds: [String]
    var createdAt: Date
    var updatedAt: Date
}

struct KnowledgeGraphEdge: Identifiable, Codable {
    var id: String
    var sourceId: String
    var targetId: String
    var label: String
    var memoryIds: [String]
    var createdAt: Date
}

struct KnowledgeGraphResponse {
    var nodes: [KnowledgeGraphNode]
    var edges: [KnowledgeGraphEdge]
}

// MARK: - ToolCall Model

struct ToolCall {
    var name: String
    var arguments: [String: Any]
    var thoughtSignature: String?

    init(name: String, arguments: [String: Any], thoughtSignature: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
    }
}

// MARK: - TableDocumented Protocol

protocol TableDocumented {
    static var tableDescription: String { get }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Notification.Name Extensions

extension Notification.Name {
    static let userDidSignOut = Notification.Name("userDidSignOut")
    static let assistantMonitoringStateDidChange = Notification.Name("assistantMonitoringStateDidChange")
}

// MARK: - UserStats for SettingsPage

struct UserStats {
    var conversations: Int = 0
    var appsInstalled: Int = 0
    var screenshotsTotal: Int = 0
    var focusSessions: Int = 0
    var tasksTodo: Int = 0
    var tasksDone: Int = 0
    var tasksDeleted: Int = 0
    var goalsCount: Int = 0
    var memoriesTotal: Int = 0
}

// LaunchAtLoginManager is defined in LaunchAtLoginManager.swift
