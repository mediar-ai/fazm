import SwiftUI

/// "Ask a question..." input panel for the floating control bar.
struct AskAIInputView: View {
    @EnvironmentObject var state: FloatingControlBarState
    @Binding var userInput: String
    @State private var localInput: String = ""
    @State private var textHeight: CGFloat = 40

    var onSend: ((String) -> Void)?
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

            HStack(spacing: 6) {
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
                            let trimmed = localInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            state.showSendButtonHint = false
                            onSend?(trimmed)
                        },
                        focusOnAppear: true,
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

    private var hasInput: Bool {
        !localInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var micButton: some View {
        PushToTalkButton(isListening: state.isVoiceListening, iconSize: 18, frameSize: 28)
    }

    private var sendButton: some View {
        VStack(spacing: 2) {
            Button(action: {
                guard hasInput else { return }
                state.showSendButtonHint = false
                onSend?(localInput.trimmingCharacters(in: .whitespacesAndNewlines))
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .symbolRenderingMode(.palette)
                    .scaledFont(size: 24)
                    .foregroundStyle(
                        hasInput ? FazmColors.backgroundPrimary : Color.secondary.opacity(0.5),
                        hasInput ? FazmColors.overlayForeground : Color.secondary.opacity(0.3)
                    )
                    .shadow(
                        color: state.showSendButtonHint && hasInput
                            ? FazmColors.purplePrimary.opacity(sendPulse ? 0.8 : 0.3)
                            : .clear,
                        radius: sendPulse ? 10 : 4
                    )
                    .scaleEffect(state.showSendButtonHint && hasInput && sendPulse ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: sendPulse)
            }
            .disabled(!hasInput)
            .buttonStyle(.plain)

            if state.showSendButtonHint && hasInput {
                Text("⏎")
                    .font(.system(size: 10))
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
