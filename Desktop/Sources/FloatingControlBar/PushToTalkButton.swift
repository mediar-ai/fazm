import SwiftUI

/// A press-and-hold microphone button that triggers PushToTalkManager.
/// Uses an NSView overlay to reliably capture mouseDown/mouseUp events.
/// Passes the owning view's FloatingControlBarState so transcript syncs
/// to the correct window (floating bar or detached chat).
struct PushToTalkButton: View {
    @EnvironmentObject var state: FloatingControlBarState
    var isListening: Bool
    var iconSize: CGFloat = 18
    var frameSize: CGFloat = 28

    /// Spins continuously while finalizing transcription.
    @State private var isSpinning = false

    var body: some View {
        ZStack {
            if state.isVoiceFinalizing {
                // Spinning arc to indicate transcription is processing
                Circle()
                    .trim(from: 0, to: 0.65)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: frameSize - 4, height: frameSize - 4)
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .onAppear { isSpinning = true }
                    .onDisappear { isSpinning = false }
                    .animation(
                        .linear(duration: 0.8).repeatForever(autoreverses: false),
                        value: isSpinning
                    )

                Image(systemName: "mic.fill")
                    .scaledFont(size: iconSize * 0.75)
                    .foregroundColor(.accentColor)
            } else {
                Image(systemName: isListening ? "mic.fill" : "mic")
                    .scaledFont(size: iconSize)
                    .foregroundColor(isListening ? .red : .secondary)
                    .scaleEffect(isListening ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: isListening)
            }
        }
        .frame(width: frameSize, height: frameSize)
        .contentShape(Rectangle())
        .overlay(PushToTalkMouseHandler(targetState: state))
        .help(state.isVoiceFinalizing ? "Processing voice…" : "Hold to talk")
    }
}

/// NSViewRepresentable that captures mouseDown/mouseUp for press-and-hold PTT.
private struct PushToTalkMouseHandler: NSViewRepresentable {
    let targetState: FloatingControlBarState

    func makeNSView(context: Context) -> PushToTalkMouseView {
        let view = PushToTalkMouseView()
        view.targetState = targetState
        return view
    }

    func updateNSView(_ nsView: PushToTalkMouseView, context: Context) {
        nsView.targetState = targetState
    }
}

/// Custom NSView that forwards mouse press/release to PushToTalkManager.
final class PushToTalkMouseView: NSView {
    var targetState: FloatingControlBarState?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let state = targetState
        Task { @MainActor in
            PushToTalkManager.shared.startUIListening(targetState: state)
        }
    }

    override func mouseUp(with event: NSEvent) {
        Task { @MainActor in
            PushToTalkManager.shared.finalizeUIListening()
        }
    }
}
