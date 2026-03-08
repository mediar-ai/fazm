import SwiftUI

/// Main floating control bar SwiftUI view composing all sub-views.
struct FloatingControlBarView: View {
    @EnvironmentObject var state: FloatingControlBarState
    @ObservedObject private var shortcutSettings = ShortcutSettings.shared
    weak var window: NSWindow?
    var onPlayPause: () -> Void
    var onAskAI: () -> Void
    var onHide: () -> Void
    var onSendQuery: (String) -> Void
    var onCloseAI: () -> Void
    var onNewChat: () -> Void
    var onInterruptAndFollowUp: ((String) -> Void)?
    var onStopAgent: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // AI conversation view - conditionally visible (expands upward above the bar)
            if state.showingAIConversation {
                Group {
                    if state.showingAIResponse {
                        aiResponseView
                    } else {
                        aiInputView
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            // Main control bar - always visible at the bottom
            controlBarView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if state.showingAIConversation {
                Button {
                    onCloseAI()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                        Text("esc")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isHovering && !state.isVoiceListening {
                Button {
                    openFloatingBarSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if state.showingAIConversation {
                ZStack {
                    ResizeHandleView(targetWindow: window)
                        .frame(width: 20, height: 20)
                    ResizeGripShape()
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 14, height: 14)
                        .allowsHitTesting(false)
                }
                .padding(4)
            }
        }
        .clipped()
        .onHover { hovering in
            // Resize window BEFORE updating SwiftUI state on expand so the expanded
            // content never renders in a too-small window (which causes overflow).
            if hovering {
                (window as? FloatingControlBarWindow)?.resizeForHover(expanded: true)
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
            if !hovering {
                (window as? FloatingControlBarWindow)?.resizeForHover(expanded: false)
            }
        }
        .background(DraggableAreaView(targetWindow: window))
        .floatingBackground(cornerRadius: isHovering || state.showingAIConversation || state.isVoiceListening ? 20 : 5)
    }

    private func openFloatingBarSettings() {
        // Bring main window to front and navigate to floating bar settings
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title.hasPrefix("Fazm") {
            window.makeKeyAndOrderFront(nil)
            break
        }
        NotificationCenter.default.post(name: .navigateToFloatingBarSettings, object: nil)
    }

    private var controlBarView: some View {
        Group {
            if state.isVoiceListening && !state.isVoiceFollowUp {
                voiceListeningView
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(height: 50)
                    .transition(.opacity)
            } else if isHovering || state.showingAIConversation {
                HStack(spacing: 6) {
                    compactButton(title: "Push to talk", keys: [shortcutSettings.pttKey.symbol]) {
                        onAskAI()
                    }
                    if state.hasLastConversation && !state.showingAIConversation {
                        compactButton(title: "New chat", keys: ["⌘", "N"], action: onNewChat)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(height: 50)
                .transition(.opacity)
            } else {
                compactCircleView
                    .transition(.opacity)
            }
        }
    }

    /// Minimal thin bar shown when not hovering
    private var compactCircleView: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(0.5))
            .frame(width: 28, height: 4)
    }

    private func compactToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(spacing: 3) {
                Text(title)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundColor(.white)
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn.wrappedValue ? Color.white.opacity(0.3) : Color.white.opacity(0.1))
                    .frame(width: 26, height: 15)
                    .overlay(alignment: isOn.wrappedValue ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 11, height: 11)
                            .padding(2)
                    }
                    .animation(.easeInOut(duration: 0.15), value: isOn.wrappedValue)
            }
        }
        .buttonStyle(.plain)
    }

    private func compactButton(title: String, keys: [String], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            compactLabel(title, keys: keys)
        }
        .buttonStyle(.plain)
    }

    private func compactLabel(_ title: String, keys: [String]) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .scaledFont(size: 11, weight: .medium)
                .foregroundColor(.white)
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .scaledFont(size: 9)
                    .foregroundColor(.white)
                    .frame(minWidth: 15, minHeight: 15)
                    .padding(.horizontal, 3)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(3)
            }
        }
    }

    private var voiceListeningView: some View {
        HStack(spacing: 8) {
            if state.isVoiceFinalizing {
                // Transcribing loading indicator
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                // Animated audio level bars
                AudioLevelBarsView(
                    level: state.voiceAudioLevel,
                    barCount: 5,
                    barWidth: 3,
                    spacing: 2,
                    maxHeight: 20,
                    minHeight: 3,
                    color: .white
                )
            }

            if state.isVoiceLocked && !state.isVoiceFinalizing {
                Text("LOCKED")
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }

            if state.isVoiceFinalizing {
                Text("Transcribing...")
                    .scaledFont(size: 13)
                    .foregroundColor(.white.opacity(0.8))
            } else if !state.voiceTranscript.isEmpty {
                Text(state.voiceTranscript)
                    .scaledFont(size: 13)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text(state.isVoiceLocked ? "Tap \(shortcutSettings.pttKey.symbol) to send" : "Release \(shortcutSettings.pttKey.symbol) to send")
                    .scaledFont(size: 13)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private var aiInputView: some View {
        VStack(spacing: 0) {
            AskAIInputView(
                userInput: Binding(
                    get: { state.aiInputText },
                    set: { state.aiInputText = $0 }
                ),
                onSend: { message in
                    state.displayedQuery = message
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        state.showingAIResponse = true
                        state.isAILoading = true
                        state.currentAIMessage = nil
                    }
                    onSendQuery(message)
                },
                onCancel: onCloseAI,
                onHeightChange: { [weak state] height in
                    guard let state = state else { return }
                    // 106 = controlBarView(50) + Group top padding(8) + AskAIInputView top bar(24) + input vertical padding(24)
                    let totalHeight = height + 106
                    state.inputViewHeight = totalHeight
                }
            )

            if !state.chatHistory.isEmpty || state.showingAIResponse {
                Button(action: onNewChat) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                        Text("New chat")
                            .scaledFont(size: 11)
                        Text("⌘N")
                            .scaledFont(size: 9)
                            .padding(.horizontal, 3)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(3)
                    }
                    .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.95).combined(with: .opacity),
                removal: .scale(scale: 0.95).combined(with: .opacity)
            ))
    }

    private var aiResponseView: some View {
        AIResponseView(
            isLoading: Binding(
                get: { state.isAILoading },
                set: { state.isAILoading = $0 }
            ),
            currentMessage: state.currentAIMessage,
            userInput: state.displayedQuery,
            chatHistory: state.chatHistory,
            isVoiceFollowUp: Binding(
                get: { state.isVoiceFollowUp },
                set: { state.isVoiceFollowUp = $0 }
            ),
            voiceFollowUpTranscript: Binding(
                get: { state.voiceFollowUpTranscript },
                set: { state.voiceFollowUpTranscript = $0 }
            ),
            suggestedReplies: Binding(
                get: { state.suggestedReplies },
                set: { state.suggestedReplies = $0 }
            ),
            onClose: onCloseAI,
            onNewChat: onNewChat,
            onSendFollowUp: { message in
                state.suggestedReplies = []
                let isStillGenerating = state.isAILoading || state.currentAIMessage?.isStreaming == true
                if isStillGenerating {
                    // AI is still working — archive partial exchange and interrupt
                    let currentQuery = state.displayedQuery
                    if let currentMessage = state.currentAIMessage, !currentQuery.isEmpty {
                        state.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: currentMessage))
                    }
                    state.displayedQuery = message
                    state.isAILoading = true
                    state.currentAIMessage = nil
                    onInterruptAndFollowUp?(message)
                } else {
                    // Archive current exchange to chat history
                    let currentQuery = state.displayedQuery
                    if let currentMessage = state.currentAIMessage, !currentQuery.isEmpty, !currentMessage.text.isEmpty {
                        state.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: currentMessage))
                    }

                    state.displayedQuery = message
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        state.isAILoading = true
                        state.currentAIMessage = nil
                    }
                    onSendQuery(message)
                }
            },
            onStopAgent: onStopAgent
        )
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.95).combined(with: .opacity),
                removal: .scale(scale: 0.95).combined(with: .opacity)
            ))
    }


}
