import SwiftUI
import AppKit

/// Modal shown when the user kicks off Codex (ChatGPT subscription) OAuth.
/// Surfaces the authorize URL so the user can pick their browser instead of
/// being forced into Chrome — copy the URL, open in Chrome, or hand it to the
/// system default browser.
struct CodexAuthSheet: View {
    let url: String
    let onOpenChrome: () -> Void
    let onOpenDefault: () -> Void
    let onCancel: () -> Void
    let loginInProgress: Bool
    let loginError: String?

    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect ChatGPT subscription")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundColor(FazmColors.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(FazmColors.backgroundTertiary.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().foregroundColor(FazmColors.border)

            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "person.badge.key")
                    .scaledFont(size: 36)
                    .foregroundColor(Color(red: 0.063, green: 0.639, blue: 0.498))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                Text("Sign in to OpenAI to authorize Fazm to use your ChatGPT subscription. After signing in, return to Fazm.")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Authorization URL")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundColor(FazmColors.textTertiary)
                    HStack(spacing: 8) {
                        Text(url)
                            .scaledFont(size: 11)
                            .foregroundColor(FazmColors.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: copyUrl) {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .scaledFont(size: 11)
                                Text(copied ? "Copied" : "Copy")
                                    .scaledFont(size: 11, weight: .medium)
                            }
                            .foregroundColor(copied ? .green : FazmColors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(FazmColors.backgroundTertiary.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(FazmColors.backgroundQuaternary.opacity(0.4)))
                }

                if loginInProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for sign-in to complete…")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let err = loginError {
                    Text("Sign-in failed: \(err)")
                        .scaledFont(size: 12)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Spacer()

            VStack(spacing: 8) {
                Button(action: onOpenChrome) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                            .scaledFont(size: 13)
                        Text("Open in Chrome")
                            .scaledFont(size: 14, weight: .semibold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.063, green: 0.639, blue: 0.498))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: onOpenDefault) {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                            .scaledFont(size: 13)
                        Text("Open in default browser")
                            .scaledFont(size: 14, weight: .medium)
                    }
                    .foregroundColor(FazmColors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(FazmColors.backgroundTertiary.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 420, height: 460)
        .background(FazmColors.backgroundPrimary)
        .cornerRadius(12)
    }

    private func copyUrl() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { copied = false }
        }
    }
}

// MARK: - Window Controller

/// Wrapper that observes CodexBackendManager so loginInProgress / loginError
/// updates re-render the sheet without callers having to thread state.
private struct CodexAuthWindowContent: View {
    @ObservedObject var codexBackend: CodexBackendManager
    let url: String
    let onOpenChrome: () -> Void
    let onOpenDefault: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CodexAuthSheet(
            url: url,
            onOpenChrome: onOpenChrome,
            onOpenDefault: onOpenDefault,
            onCancel: {
                onCancel()
                onDismiss()
            },
            loginInProgress: codexBackend.loginInProgress,
            loginError: codexBackend.loginError
        )
        .onChange(of: codexBackend.authMode) { _, newValue in
            // Auto-close once auth.json lands and the next probe reports chatgpt.
            if newValue == "chatgpt" { onDismiss() }
        }
    }
}

/// Manages a single floating window for the Codex OAuth flow.
@MainActor
final class CodexAuthWindowController {
    static let shared = CodexAuthWindowController()
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    func show(
        url: String,
        onOpenChrome: @escaping () -> Void,
        onOpenDefault: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = self
        let content = CodexAuthWindowContent(
            codexBackend: CodexBackendManager.shared,
            url: url,
            onOpenChrome: onOpenChrome,
            onOpenDefault: onOpenDefault,
            onCancel: onCancel,
            onDismiss: { controller.close() }
        )

        let hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.setFrameSize(NSSize(width: 420, height: 460))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 420, height: 460)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.applyCrashWorkarounds()

        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = mouseScreen {
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - 420) / 2
            let y = sf.origin.y + (sf.height - 460) / 2
            window.setFrame(NSRect(x: x, y: y, width: 420, height: 460), display: true)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.hostingView = hostingView
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }
}
