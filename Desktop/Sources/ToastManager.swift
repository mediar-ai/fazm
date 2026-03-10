import SwiftUI
import AppKit

/// Displays a brief in-app toast notification in the top-center of the screen.
@MainActor
final class ToastManager {
    static let shared = ToastManager()
    private init() {}

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, duration: TimeInterval = 4) {
        dismissTask?.cancel()
        panel?.close()

        let hosting = NSHostingView(rootView: ToastView(message: message))
        hosting.sizingOptions = .minSize

        let size = hosting.fittingSize

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height - 16
        )

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.ignoresMouseEvents = true
        p.contentView = hosting
        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 1
        }

        self.panel = p

        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run { self.dismiss() }
        }
    }

    private func dismiss() {
        guard let p = panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.close()
        })
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.2.circlepath")
                .font(.system(size: 12, weight: .medium))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.75), in: Capsule())
        .padding(4)
    }
}
