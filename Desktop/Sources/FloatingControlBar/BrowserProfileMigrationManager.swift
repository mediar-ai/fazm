import Combine
import Foundation
import SwiftUI

/// Manages the one-time browser profile extraction flow for existing users
/// who completed onboarding before the feature was introduced.
///
/// Pattern mirrors `TutorialChatGuide`: injects a system prompt suffix,
/// observes AI responses for a completion marker, then cleans up.
@MainActor
class BrowserProfileMigrationManager {
    static let shared = BrowserProfileMigrationManager()

    private let userDefaultsKey = "hasCompletedBrowserProfileExtraction"
    private var cancellables = Set<AnyCancellable>()
    private var doneMarkerSeen = false

    private init() {}

    // MARK: - Public

    /// Check if migration is needed and start the flow if so.
    func startIfNeeded(barState: FloatingControlBarState) {
        guard needsMigration() else {
            log("BrowserProfileMigration: startIfNeeded — not needed")
            return
        }
        // Don't overlap with tutorial
        guard !barState.isTutorialChatActive else {
            log("BrowserProfileMigration: startIfNeeded — skipped, tutorial active")
            return
        }
        guard !barState.isBrowserMigrationActive else {
            log("BrowserProfileMigration: startIfNeeded — already active")
            return
        }

        log("BrowserProfileMigration: Starting migration flow")
        barState.isBrowserMigrationActive = true
        barState.browserMigrationSystemPromptSuffix = ChatPrompts.browserProfileMigration

        // Inject an initial AI message to kick off the conversation
        let kickoff = ChatMessage(
            text: "Hey! I have a quick new feature to show you — I can now learn about you from your browser data (saved logins, autofill, bookmarks). Everything stays on your device.\n\nWant me to scan your browsers?",
            sender: .ai
        )
        injectMessage(kickoff, barState: barState)

        // Observe responses for the done marker
        observeResponses(barState: barState)
    }

    /// Mark migration as skipped (user dismissed the conversation).
    func skip() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        cancellables.removeAll()
        doneMarkerSeen = false
        log("BrowserProfileMigration: Skipped by user")
    }

    /// Called on app launch to pre-set the flag for users who already have browser profile data.
    func markCompleteIfAlreadyExtracted() {
        guard !UserDefaults.standard.bool(forKey: userDefaultsKey) else { return }
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }

        let memoriesDb = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ai-browser-profile/memories.db")
        if FileManager.default.fileExists(atPath: memoriesDb.path) {
            UserDefaults.standard.set(true, forKey: userDefaultsKey)
            log("BrowserProfileMigration: memories.db already exists, marking complete")
        }
    }

    // MARK: - Private

    private func needsMigration() -> Bool {
        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let alreadyDone = UserDefaults.standard.bool(forKey: userDefaultsKey)
        guard hasOnboarded && !alreadyDone else {
            log("BrowserProfileMigration: needsMigration=false (onboarded=\(hasOnboarded), alreadyDone=\(alreadyDone))")
            return false
        }

        let memoriesDb = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ai-browser-profile/memories.db")
        let exists = FileManager.default.fileExists(atPath: memoriesDb.path)
        log("BrowserProfileMigration: needsMigration=\(!exists) (memories.db exists=\(exists))")
        return !exists
    }

    private func observeResponses(barState: FloatingControlBarState) {
        cancellables.removeAll()

        barState.$currentAIMessage
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak barState] message in
                guard let self, let barState, barState.isBrowserMigrationActive else { return }
                let marker = "[[BROWSER_MIGRATION_DONE]]"

                // Strip marker so it never shows
                if message.text.contains(marker) {
                    barState.currentAIMessage?.text = message.text
                        .replacingOccurrences(of: marker, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.doneMarkerSeen = true
                }

                // Wait for streaming to complete before finishing
                guard !message.isStreaming, self.doneMarkerSeen else { return }
                self.completeMigration(barState: barState)
            }
            .store(in: &cancellables)
    }

    private func completeMigration(barState: FloatingControlBarState) {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        barState.isBrowserMigrationActive = false
        barState.browserMigrationSystemPromptSuffix = nil
        cancellables.removeAll()
        doneMarkerSeen = false

        // Reset the browser-migration ACP session to free context
        Task {
            if let provider = FloatingControlBarManager.shared.chatProvider {
                await provider.resetSession(key: "browser-migration")
                log("BrowserProfileMigration: Reset session to clear migration context")
            }
        }

        log("BrowserProfileMigration: Completed successfully")
    }

    private func injectMessage(_ message: ChatMessage, barState: FloatingControlBarState) {
        barState.displayedQuery = ""
        barState.currentAIMessage = message
        barState.isAILoading = false

        if !barState.showingAIResponse {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                barState.showingAIResponse = true
            }
        }

        // Expand the floating bar window to show the conversation and resize
        FloatingControlBarManager.shared.showAIConversationAndResize()
    }
}
