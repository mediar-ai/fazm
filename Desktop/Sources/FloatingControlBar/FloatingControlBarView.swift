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
    var onEnqueueMessage: ((String) -> Void)?
    var onSendNowQueued: ((QueuedMessage) -> Void)?
    var onDeleteQueued: ((QueuedMessage) -> Void)?
    var onClearQueue: (() -> Void)?
    var onReorderQueue: ((IndexSet, Int) -> Void)?
    var onStopAgent: (() -> Void)?
    var onPopOut: (() -> Void)?
    var onConnectClaude: (() -> Void)?
    var onChatObserverCardAction: ((Int64, String) -> Void)?
    var onChangeWorkspace: (() -> Void)?

    @State private var isHovering = false
    @State private var updatePulse = false
    @State private var updateButtonPulse = false
    @ObservedObject private var updaterViewModel = UpdaterViewModel.shared

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
                .padding(.top, 12)
                .overlay(alignment: .topLeading) {
                    Button {
                        onCloseAI()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .scaledFont(size: 8)
                                .foregroundColor(.secondary)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(FazmColors.overlayForeground.opacity(0.2), lineWidth: 0.5))
                            Text("esc")
                                .scaledFont(size: 9)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                    .padding(.top, 4)
                    .transition(.opacity)
                }
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        ResizeHandleView(targetWindow: window)
                            .frame(width: 20, height: 20)
                        ResizeGripShape()
                            .foregroundStyle(FazmColors.overlayForeground.opacity(0.3))
                            .frame(width: 14, height: 14)
                            .allowsHitTesting(false)
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(FazmColors.overlayBorder.opacity(0.5), lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            // Main control bar - always visible at the bottom
            controlBarView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if isHovering && !state.isVoiceListening {
                Button {
                    openFloatingBarSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .scaledFont(size: 11)
                        .foregroundColor(FazmColors.overlayForeground.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(FazmColors.overlayForeground.opacity(0.12))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.opacity)
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
                HStack(spacing: 0) {
                    if updaterViewModel.updateAvailable {
                        updateButton
                            .padding(.leading, 4)
                    }
                    VStack(spacing: 4) {
                        compactButton(title: "Push to talk", keys: [shortcutSettings.pttKey.symbol]) {
                            onAskAI()
                        }
                        compactLabel("Open chat", keys: shortcutSettings.askFazmKey.hintKeys)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
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
            .fill(updaterViewModel.updateAvailable ? FazmColors.purplePrimary : FazmColors.overlayForeground.opacity(0.5))
            .frame(width: 28, height: 4)
            .shadow(
                color: updaterViewModel.updateAvailable
                    ? FazmColors.purplePrimary.opacity(updatePulse ? 0.9 : 0.2)
                    : .clear,
                radius: updatePulse ? 8 : 3
            )
            .onAppear {
                if updaterViewModel.updateAvailable {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        updatePulse = true
                    }
                }
            }
            .onChange(of: updaterViewModel.updateAvailable) { _, available in
                if available {
                    updatePulse = false
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        updatePulse = true
                    }
                } else {
                    updatePulse = false
                }
            }
    }

    private var updateButton: some View {
        Button {
            updaterViewModel.checkForUpdates()
        } label: {
            if updaterViewModel.updateSessionInProgress {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .scaledFont(size: 16)
                    .foregroundColor(FazmColors.purplePrimary)
                    .opacity(updateButtonPulse ? 1.0 : 0.4)
                    .scaleEffect(updateButtonPulse ? 1.15 : 0.9)
                    .shadow(color: FazmColors.purplePrimary.opacity(updateButtonPulse ? 0.9 : 0.0), radius: updateButtonPulse ? 8 : 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(updaterViewModel.updateSessionInProgress)
        .help(updaterViewModel.updateSessionInProgress ? "Updating..." : "Update available — v\(updaterViewModel.availableVersion)")
        .onAppear {
            updateButtonPulse = false
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                updateButtonPulse = true
            }
        }
    }

    private func compactToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(spacing: 3) {
                Text(title)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundColor(FazmColors.overlayForeground)
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn.wrappedValue ? FazmColors.overlayForeground.opacity(0.3) : FazmColors.overlayForeground.opacity(0.1))
                    .frame(width: 26, height: 15)
                    .overlay(alignment: isOn.wrappedValue ? .trailing : .leading) {
                        Circle()
                            .fill(FazmColors.overlayForeground)
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
                .foregroundColor(FazmColors.overlayForeground)
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .scaledFont(size: 9)
                    .foregroundColor(FazmColors.overlayForeground)
                    .frame(minWidth: 15, minHeight: 15)
                    .padding(.horizontal, 3)
                    .background(FazmColors.overlayForeground.opacity(0.1))
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
                    .tint(FazmColors.overlayForeground)
            } else {
                // Animated audio level bars — uses ObservedObject to avoid
                // re-rendering the conversation view on every level change.
                ObservedAudioLevelBarsView(
                    audioLevel: state.audioLevel,
                    barCount: 5,
                    barWidth: 3,
                    spacing: 2,
                    maxHeight: 20,
                    minHeight: 3,
                    color: FazmColors.overlayForeground
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

            ObservedTranscriptView(
                audioLevel: state.audioLevel,
                isVoiceFinalizing: state.isVoiceFinalizing,
                isVoiceLocked: state.isVoiceLocked,
                pttKeySymbol: shortcutSettings.pttKey.symbol
            )
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
                    state.aiInputText = ""
                    state.displayedQuery = message
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        state.showingAIResponse = true
                        state.isAILoading = true
                        state.currentAIMessage = nil
                    }
                    onSendQuery(message)
                    // Focus the follow-up input after the view transition settles
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        (window as? FloatingControlBarWindow)?.focusInputField()
                    }
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
                            .scaledFont(size: 10)
                        Text("New chat")
                            .scaledFont(size: 11)
                        Text("⌘N")
                            .scaledFont(size: 9)
                            .padding(.horizontal, 3)
                            .background(FazmColors.overlayForeground.opacity(0.1))
                            .cornerRadius(3)
                    }
                    .foregroundColor(FazmColors.overlayForeground.opacity(0.5))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
        .transition(.opacity)
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
            suggestedReplyQuestion: Binding(
                get: { state.suggestedReplyQuestion },
                set: { state.suggestedReplyQuestion = $0 }
            ),
            onClose: onCloseAI,
            onNewChat: onNewChat,
            onSendFollowUp: { message in
                state.suggestedReplies = []
                state.suggestedReplyQuestion = ""
                // Archive current exchange to chat history
                let currentQuery = state.displayedQuery
                if let currentMessage = state.currentAIMessage, !currentQuery.isEmpty, !currentMessage.text.isEmpty {
                    state.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: currentMessage))
                }
                state.flushPendingChatObserverExchanges()

                state.displayedQuery = message
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    state.isAILoading = true
                    state.currentAIMessage = nil
                }
                onSendQuery(message)
            },
            onEnqueueMessage: { message in
                guard state.messageQueue.count < FloatingControlBarState.maxQueueSize else { return }
                state.enqueue(message)
                onEnqueueMessage?(message)
                AnalyticsManager.shared.floatingBarMessageQueued(
                    queueSize: state.messageQueue.count,
                    messageLength: message.count
                )
            },
            onSendNow: { item in
                // Remove from queue
                state.dequeue(item.id)
                // Archive partial exchange and interrupt
                let currentQuery = state.displayedQuery
                if var currentMessage = state.currentAIMessage, !currentQuery.isEmpty {
                    currentMessage.contentBlocks = currentMessage.contentBlocks.map { block in
                        if case .toolCall(let id, let name, .running, let toolUseId, let input, let output) = block {
                            return .toolCall(id: id, name: name, status: .completed, toolUseId: toolUseId, input: input, output: output)
                        }
                        return block
                    }
                    state.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: currentMessage))
                }
                state.flushPendingChatObserverExchanges()
                state.displayedQuery = item.text
                state.isAILoading = true
                state.currentAIMessage = nil
                onSendNowQueued?(item)
            },
            onDeleteQueued: { item in
                state.dequeue(item.id)
                onDeleteQueued?(item)
            },
            onClearQueue: {
                state.clearQueue()
                onClearQueue?()
            },
            onReorderQueue: { source, dest in
                state.messageQueue.move(fromOffsets: source, toOffset: dest)
                onReorderQueue?(source, dest)
            },
            onStopAgent: onStopAgent,
            onPopOut: onPopOut,
            onConnectClaude: onConnectClaude,
            onChatObserverCardAction: onChatObserverCardAction,
            onChangeWorkspace: onChangeWorkspace
        )
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.95).combined(with: .opacity),
                removal: .scale(scale: 0.95).combined(with: .opacity)
            ))
    }


}
