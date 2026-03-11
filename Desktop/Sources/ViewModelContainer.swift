import SwiftUI

/// Central container that holds ChatProvider and manages database initialization
@MainActor
class ViewModelContainer: ObservableObject {
    let chatProvider: ChatProvider

    init() {
        chatProvider = ChatProvider()
    }

    // Loading state
    @Published var isInitialLoadComplete = false
    @Published var isLoading = false
    @Published var databaseInitFailed = false

    /// Initialize database and chat provider at app launch
    func loadAllData() async {
        guard !isLoading else { return }
        isLoading = true

        let startupStart = CFAbsoluteTimeGetCurrent()
        logPerf("DATA LOAD: Starting data load", cpu: true)

        // Configure database for the current user before initialization
        let userId = UserDefaults.standard.string(forKey: "auth_tokenUserId")
        await AppDatabase.shared.configure(userId: userId)

        // Pre-initialize database
        do {
            try await AppDatabase.shared.initialize()
            databaseInitFailed = false
        } catch {
            logError("ViewModelContainer: Database init failed", error: error)
            databaseInitFailed = true
        }


        // Database is ready — dismiss loading
        isInitialLoadComplete = true
        let timeToInteractive = CFAbsoluteTimeGetCurrent() - startupStart
        logPerf("DATA LOAD: time-to-interactive \(String(format: "%.1f", timeToInteractive * 1000))ms")

        // Initialize chat provider
        await chatProvider.initialize()
        await chatProvider.warmupBridge()

        isLoading = false
        logPerf("DATA LOAD: Complete", cpu: true)
    }
}
