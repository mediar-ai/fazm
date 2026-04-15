import SwiftUI
import UniformTypeIdentifiers

/// "Ask a question..." input panel for the floating control bar.
struct AskAIInputView: View {
    @EnvironmentObject var state: FloatingControlBarState
    @Binding var userInput: String
    @State private var localInput: String = ""
    @State private var textHeight: CGFloat = 40

    var onSend: ((String, [ChatAttachment]) -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    @State private var sendPulse: Bool = false

    private let minHeight: CGFloat = 40
    private let maxHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: escape hint
            HStack {
                Spacer()

                HStack(spacing: 4) {
                    Text("esc")
                        .scaledFont(size: 11)
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 16)
                        .background(FazmColors.overlayForeground.opacity(0.1))
                        .cornerRadius(4)
                    Text("to close")
                        .scaledFont(size: 11)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 16)

            // Attachment thumbnails strip
            if !state.pendingAttachments.isEmpty {
                ChatAttachmentStrip(attachments: $state.pendingAttachments)
            }

            HStack(spacing: 6) {
                ChatAttachmentButton {
                    ChatAttachmentHelper.openFilePicker { urls in
                        ChatAttachmentHelper.addFiles(from: urls, to: &state.pendingAttachments)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if localInput.isEmpty && !state.isVoiceListening {
                        Text("Ask a question...")
                            .scaledFont(size: 13)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    }

                    FazmTextEditor(
                        text: $localInput,
                        lineFragmentPadding: 8,
                        onSubmit: {
                            sendCurrentMessage()
                        },
                        focusOnAppear: true,
                        onPasteFiles: { urls in
                            ChatAttachmentHelper.addFiles(from: urls, to: &state.pendingAttachments)
                        },
                        onPasteImageData: { data in
                            ChatAttachmentHelper.addPastedImage(data, to: &state.pendingAttachments)
                        },
                        minHeight: minHeight,
                        maxHeight: maxHeight,
                        onHeightChange: { newHeight in
                            if abs(textHeight - newHeight) > 1 {
                                textHeight = newHeight
                                onHeightChange?(newHeight)
                            }
                        }
                    )
                    .onChange(of: localInput) { _, newValue in
                        userInput = newValue
                    }
                    .onAppear {
                        localInput = userInput
                    }
                    .onChange(of: userInput) { _, newValue in
                        // Sync external changes (e.g. PTT transcription) into local state
                        if newValue != localInput {
                            localInput = newValue
                        }
                    }
                }
                .padding(.horizontal, 4)
                .frame(height: textHeight)

                micButton
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .onExitCommand {
            onCancel?()
        }
    }

    // MARK: - Helpers

    private func sendCurrentMessage() {
        let trimmed = localInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !state.pendingAttachments.isEmpty else { return }
        guard !state.isAILoading else { return }
        state.showSendButtonHint = false
        let attachmentsToSend = state.pendingAttachments
        state.pendingAttachments = []
        onSend?(trimmed, attachmentsToSend)
    }

    private var hasInput: Bool {
        !localInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.pendingAttachments.isEmpty
    }

    private var canSend: Bool {
        hasInput && !state.isAILoading
    }

    // MARK: - Subviews

    private var micButton: some View {
        PushToTalkButton(isListening: state.isVoiceListening, iconSize: 18, frameSize: 28)
    }

    private var sendButton: some View {
        VStack(spacing: 2) {
            Button(action: {
                guard hasInput, !state.isAILoading else { return }
                sendCurrentMessage()
            }) {
                ZStack {
                        Circle()
                            .fill(canSend ? FazmColors.overlayForeground : Color.secondary.opacity(0.15))
                            .frame(width: 24, height: 24)
                        Image(systemName: "arrow.up")
                            .scaledFont(size: 12, weight: .heavy)
                            .foregroundColor(canSend ? FazmColors.backgroundPrimary : Color.secondary.opacity(0.5))
                    }
                    .shadow(
                        color: state.showSendButtonHint && hasInput
                            ? FazmColors.purplePrimary.opacity(sendPulse ? 0.8 : 0.3)
                            : .clear,
                        radius: sendPulse ? 10 : 4
                    )
                    .scaleEffect(state.showSendButtonHint && hasInput && sendPulse ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: sendPulse)
            }
            .disabled(!hasInput || state.isAILoading)
            .buttonStyle(.plain)

            if state.showSendButtonHint && hasInput {
                Text("⏎")
                    .scaledFont(size: 10)
                    .foregroundColor(FazmColors.overlayForeground.opacity(0.6))
                    .frame(width: 20, height: 14)
                    .background(FazmColors.overlayForeground.opacity(0.1))
                    .cornerRadius(3)
                    .transition(.opacity)
            }
        }
        .onChange(of: state.showSendButtonHint) { _, show in
            if show {
                sendPulse = true
            } else {
                sendPulse = false
            }
        }
    }
}
