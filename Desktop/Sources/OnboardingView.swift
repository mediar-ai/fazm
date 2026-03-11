import SwiftUI
import AppKit
import AVKit
import SceneKit

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var chatProvider: ChatProvider
    var onComplete: (() -> Void)? = nil
    @StateObject private var graphViewModel = MemoryGraphViewModel()
    @State private var graphHasData = false
    @State private var showGraphHints = false
    @State private var hintsHovered = false

    var body: some View {
        ZStack {
            // Full dark background
            FazmColors.backgroundPrimary
                .ignoresSafeArea()

            Group {
                if appState.hasCompletedOnboarding {
                    Color.clear
                        .onAppear {
                            log("OnboardingView: hasCompletedOnboarding=true, starting monitoring")
                            if !ProactiveAssistantsPlugin.shared.isMonitoring {
                                ProactiveAssistantsPlugin.shared.startMonitoring { _, _ in }
                            }
                            if let onComplete = onComplete {
                                log("OnboardingView: Calling onComplete handler")
                                onComplete()
                            } else {
                                log("OnboardingView: No onComplete handler, view will transition via DesktopHomeView")
                            }
                        }
                } else {
                    onboardingContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await chatProvider.warmupBridge()
        }
    }

    private var onboardingContent: some View {
        // Interactive AI Chat + Live Knowledge Graph
        HStack(spacing: 0) {
                    OnboardingChatView(
                        appState: appState,
                        chatProvider: chatProvider,
                        graphViewModel: graphViewModel,
                        onComplete: {
                            AnalyticsManager.shared.onboardingStepCompleted(step: 0, stepName: "Chat")
                            if let onComplete = onComplete {
                                onComplete()
                            }
                        },
                        onSkip: {
                            handleSkip()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Right pane: Knowledge graph (dark background, graph appears when data arrives)
                    ZStack {
                        FazmColors.backgroundSecondary.ignoresSafeArea()

                        if graphHasData {
                            MemoryGraphSceneView(viewModel: graphViewModel)
                                .ignoresSafeArea()
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Use .overlay so hints composite above the NSViewRepresentable SCNView
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 20) {
                            graphHintItem(icon: "arrow.triangle.2.circlepath", label: "Drag to rotate")
                            graphHintItem(icon: "magnifyingglass", label: "Scroll to zoom")
                            graphHintItem(icon: "hand.draw", label: "Two-finger to pan")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [Color.black.opacity(0), Color.black.opacity(0.5)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .onHover { hovering in
                            hintsHovered = hovering
                        }
                        .opacity(graphHasData && (showGraphHints || hintsHovered) ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: showGraphHints)
                        .animation(.easeInOut(duration: 0.3), value: hintsHovered)
                        .animation(.easeInOut(duration: 0.3), value: graphHasData)
                    }
                    .onAppear {
                        // Handle case where graph already has data on appear
                        if !graphViewModel.isEmpty && !graphHasData {
                            withAnimation(.easeIn(duration: 0.5)) {
                                graphHasData = true
                            }
                            flashGraphHints()
                        }
                    }
                    .onChange(of: graphViewModel.isEmpty) { _, isEmpty in
                        if !isEmpty && !graphHasData {
                            withAnimation(.easeIn(duration: 0.5)) {
                                graphHasData = true
                            }
                            flashGraphHints()
                        }
                    }
                }
    }

    private func graphHintItem(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundColor(.white.opacity(0.5))
    }

    private func flashGraphHints() {
        showGraphHints = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            showGraphHints = false
        }
    }

    /// Skip onboarding — complete with minimal setup
    private func handleSkip() {
        log("OnboardingView: User skipped onboarding chat")
        AnalyticsManager.shared.onboardingStepCompleted(step: 0, stepName: "Chat_Skipped")
        AnalyticsManager.shared.onboardingCompleted()

        // Stop the AI if it's still running
        chatProvider.stopAgent()

        // Navigate to Chat page after transition (not Dashboard)
        UserDefaults.standard.set(true, forKey: "onboardingJustCompleted")

        appState.hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedFileIndexing")

        // Start essential services
        Task {
            await AgentVMService.shared.startPipeline()
        }
        if LaunchAtLoginManager.shared.setEnabled(true) {
            AnalyticsManager.shared.launchAtLoginChanged(enabled: true, source: "onboarding_skip")
        }
        ProactiveAssistantsPlugin.shared.startMonitoring { _, _ in }
        appState.startTranscription()

        // Clean up onboarding state and persisted chat data
        chatProvider.isOnboarding = false
        OnboardingChatPersistence.clear()

        if let onComplete = onComplete {
            onComplete()
        }
    }
}

// MARK: - Onboarding Video View

struct OnboardingVideoView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        if let url = Bundle.resourceBundle.url(forResource: "fazm-demo", withExtension: "mp4") {
            let player = AVPlayer(url: url)
            playerView.player = player
            playerView.controlsStyle = .none
            playerView.showsFullScreenToggleButton = false
            playerView.showsSharingServiceButton = false
            player.play()

            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.playerDidFinishPlaying(_:)),
                name: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem
            )
            context.coordinator.player = player
        }
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    class Coordinator: NSObject {
        var player: AVPlayer?

        @objc func playerDidFinishPlaying(_ notification: Notification) {
            player?.seek(to: .zero)
            player?.play()
        }
    }
}

// MARK: - Animated GIF View

struct AnimatedGIFView: NSViewRepresentable {
    let gifName: String

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.animates = true
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        if let url = Bundle.resourceBundle.url(forResource: gifName, withExtension: "gif"),
           let image = NSImage(contentsOf: url) {
            imageView.image = image
        }

        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.animates = true
    }
}

// MARK: - Onboarding Privacy Sheet

struct OnboardingPrivacySheet: View {
    @Binding var isPresented: Bool
    var showSessionRecordingSection: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .scaledFont(size: 16)
                    .foregroundColor(FazmColors.purplePrimary)

                Text("Privacy Policy")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 18)
                        .foregroundColor(FazmColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Introduction
                    Text("Fazm is committed to protecting your privacy. This policy explains what data we collect, how we use it, and the choices you have.")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // 1. Local-First Architecture
                    privacyCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Local-First Architecture", systemImage: "desktopcomputer")
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)

                            Text("Fazm runs primarily on your machine. Transcripts, conversations, memories, and indexed files are stored locally in a SQLite database on your device. We do not upload or store your personal content on our servers unless you explicitly use a cloud feature.")
                                .scaledFont(size: 11)
                                .foregroundColor(FazmColors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // 2. Encryption & Security
                    privacyCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Encryption & Security", systemImage: "lock.shield")
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)

                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .scaledFont(size: 11)
                                    .foregroundColor(.green)
                                Text("Server-side encryption")
                                    .scaledFont(size: 12)
                                    .foregroundColor(FazmColors.textSecondary)
                                Text("Active")
                                    .scaledFont(size: 10, weight: .semibold)
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.15))
                                    .cornerRadius(3)
                            }

                            Text("All data transmitted to our servers is encrypted in transit (TLS) and at rest using Google Cloud infrastructure. Authentication is handled via Google Sign-In and Firebase — we never see or store your Google password.")
                                .scaledFont(size: 11)
                                .foregroundColor(FazmColors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // 3. Analytics & Telemetry
                    privacyCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Analytics & Telemetry", systemImage: "chart.bar")
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)

                            Text("We collect anonymized usage events to understand how the app is used and to fix bugs. These events do not contain the content of your conversations, files, or personal data.")
                                .scaledFont(size: 11)
                                .foregroundColor(FazmColors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 4) {
                                sheetTrackingItem("Onboarding steps completed")
                                sheetTrackingItem("Settings changes")
                                sheetTrackingItem("Feature usage (chat, focus sessions, memories)")
                                sheetTrackingItem("App open/close and session duration")
                                sheetTrackingItem("Error and crash reports")
                            }
                        }
                    }

                    // 4. Beta Program — Extended Analytics (only shown to enrolled users)
                    if showSessionRecordingSection {
                    privacyCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Label("Beta Program", systemImage: "testtube.2")
                                    .scaledFont(size: 13, weight: .semibold)
                                    .foregroundColor(FazmColors.textPrimary)

                                Text("Beta")
                                    .scaledFont(size: 10, weight: .semibold)
                                    .foregroundColor(FazmColors.purplePrimary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(FazmColors.purplePrimary.opacity(0.15))
                                    .cornerRadius(4)
                            }

                            Text("As a beta user, you agree that we may collect extended analytics to help us build the best possible experience. This includes:")
                                .scaledFont(size: 11)
                                .foregroundColor(FazmColors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 4) {
                                sheetTrackingItem("Session recordings of app usage (screen capture)")
                                sheetTrackingItem("Detailed interaction patterns and navigation flows")
                                sheetTrackingItem("Performance metrics and resource usage")
                                sheetTrackingItem("Feature adoption and workflow analytics")
                            }

                            Text("Session recordings are encrypted, stored securely on Google Cloud, and automatically deleted after 30 days. They are only used internally by the Fazm team to identify UX issues and improve the product. Recordings are never shared with third parties.")
                                .scaledFont(size: 11)
                                .foregroundColor(FazmColors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("You may opt out of the beta channel at any time in Settings, which will stop extended data collection.")
                                .scaledFont(size: 11, weight: .medium)
                                .foregroundColor(FazmColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    } // end if showSessionRecordingSection

                    // 5. Data Sharing
                    privacyCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Data Sharing", systemImage: "person.2.slash")
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)

                            Text("We do not sell, rent, or share your personal data with third parties. Analytics data is processed by PostHog (our analytics provider) and Sentry (error tracking). These services receive only anonymized event data, not your personal content.")
                                .scaledFont(size: 11)
                                .foregroundColor(FazmColors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // 6. Your Rights & Choices
                    privacyCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Your Rights & Choices", systemImage: "hand.raised.fill")
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)

                            VStack(alignment: .leading, spacing: 5) {
                                sheetBullet("Fully open source — verify everything on GitHub")
                                sheetBullet("Local-first: your data stays on your machine")
                                sheetBullet("Delete your account and all associated data at any time")
                                sheetBullet("Switch from beta to stable to stop extended analytics")
                                sheetBullet("Data is never sold or shared with third parties")
                                sheetBullet("Contact us at support@fazm.ai for any privacy questions")
                            }
                        }
                    }

                    // 7. Open Source
                    privacyCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Open Source Transparency", systemImage: "chevron.left.forwardslash.chevron.right")
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)

                            Text("Fazm is fully open source. You can inspect exactly what data is collected and how it is processed by reviewing our source code on GitHub.")
                                .scaledFont(size: 11)
                                .foregroundColor(FazmColors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button(action: {
                                if let url = URL(string: "https://github.com/m13v/fazm") {
                                    NSWorkspace.shared.open(url)
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.right.square")
                                        .scaledFont(size: 10)
                                    Text("View on GitHub")
                                        .scaledFont(size: 11, weight: .medium)
                                }
                                .foregroundColor(FazmColors.purplePrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Footer
                    Text("Last updated: March 2026")
                        .scaledFont(size: 10)
                        .foregroundColor(FazmColors.textQuaternary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 600)
        .background(FazmColors.backgroundSecondary)
    }

    private func privacyCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(FazmColors.backgroundTertiary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(FazmColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                    )
            )
    }

    private func sheetTrackingItem(_ text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(FazmColors.textTertiary.opacity(0.5))
                .frame(width: 3, height: 3)
            Text(text)
                .scaledFont(size: 11)
                .foregroundColor(FazmColors.textTertiary)
        }
    }

    private func sheetBullet(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .scaledFont(size: 8, weight: .bold)
                .foregroundColor(.green)
            Text(text)
                .scaledFont(size: 11)
                .foregroundColor(FazmColors.textSecondary)
        }
    }
}
