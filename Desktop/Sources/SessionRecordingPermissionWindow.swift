import SwiftUI
import AppKit

/// Observable state shared between the view and window controller.
@MainActor
class SessionRecordingPermissionState: ObservableObject {
    @Published var hasClickedGrant = false
    @Published var isGranted = false
}

/// Compact overlay shown when screen recording permission is needed.
/// Shows the same tutorial GIF as the permissions page with a single button.
struct SessionRecordingPermissionSheet: View {
    let onGrantPermission: () -> Void
    let onDismiss: () -> Void
    @ObservedObject var state: SessionRecordingPermissionState

    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Fazm"

    var body: some View {
        VStack(spacing: 16) {
            if state.isGranted {
                // Success state
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                Text("Done")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(FazmColors.textPrimary)
                Text("Screen recording is now enabled.")
                    .font(.system(size: 13))
                    .foregroundColor(FazmColors.textSecondary)
                Spacer()
                Button(action: onDismiss) {
                    Text("OK")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(FazmColors.purplePrimary)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            } else {
                // Header with close button
                HStack {
                    Image(systemName: "record.circle")
                        .scaledFont(size: 16)
                        .foregroundColor(FazmColors.purplePrimary)
                    Text("Enable Screen Recording")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundColor(FazmColors.textPrimary)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundColor(FazmColors.textTertiary)
                            .frame(width: 24, height: 24)
                            .background(FazmColors.backgroundTertiary.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // Brief explanation
                Text("Fazm needs screen recording to see what's on your screen and help you.")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)

                // Tutorial GIF — same as permissions page
                AnimatedGIFView(gifName: "permissions")
                    .frame(maxWidth: 280, maxHeight: 180)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(FazmColors.backgroundQuaternary, lineWidth: 1)
                    )
                    .padding(.horizontal, 20)

                if state.hasClickedGrant {
                    // Waiting state
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Waiting for permission...")
                            .scaledFont(size: 11)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                }

                // Button
                Button(action: {
                    state.hasClickedGrant = true
                    onGrantPermission()
                }) {
                    Text(state.hasClickedGrant ? "Open Settings Again" : "Open Settings")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(FazmColors.purplePrimary)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 340, height: 400)
        .animation(.easeInOut(duration: 0.3), value: state.isGranted)
        .background(FazmColors.backgroundPrimary)
    }
}

// MARK: - Window Controller

@MainActor
final class SessionRecordingPermissionWindowController {
    static let shared = SessionRecordingPermissionWindowController()
    private var window: NSWindow?
    private var permissionCheckTimer: Timer?
    private var state = SessionRecordingPermissionState()
    /// Prevent showing the prompt more than once per app session
    private var hasShownThisSession = false

    private let windowWidth: CGFloat = 340
    private let windowHeight: CGFloat = 400

    /// Show the prompt for testing — bypasses the once-per-session guard.
    func showForTesting() {
        log("SessionRecordingPermission: triggered via test notification")
        hasShownThisSession = false
        show(onPermissionGranted: {
            log("SessionRecordingPermission: permission granted (test trigger)")
            SessionRecordingManager.shared.checkFlagAndUpdate()
        })
    }

    /// Show the prompt from the sidebar widget — always opens (user-initiated).
    func showFromSidebar(onPermissionGranted: @escaping () -> Void) {
        log("SessionRecordingPermission: triggered from sidebar")
        // If already visible, just bring to front
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // User-initiated — bypass the once-per-session guard
        showWindow(onPermissionGranted: onPermissionGranted)
    }

    func show(onPermissionGranted: @escaping () -> Void) {
        guard !hasShownThisSession else {
            log("SessionRecordingPermission: already shown this session, skipping")
            return
        }
        hasShownThisSession = true

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        showWindow(onPermissionGranted: onPermissionGranted)
    }

    private func showWindow(onPermissionGranted: @escaping () -> Void) {
        // Reset state for new prompt
        state = SessionRecordingPermissionState()

        let controller = self
        let content = SessionRecordingPermissionSheet(
            onGrantPermission: {
                // Open System Settings first
                ScreenCaptureService.openScreenRecordingPreferences()
                // Trigger the permission prompt so the app appears in the list
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    ScreenCaptureService.requestAllScreenCapturePermissions()
                }
                // Start polling for permission grant
                controller.startPermissionPolling(onGranted: onPermissionGranted)
            },
            onDismiss: {
                controller.close()
            },
            state: state
        )

        let hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.setFrameSize(NSSize(width: windowWidth, height: windowHeight))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: windowWidth, height: windowHeight)),
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

        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = mouseScreen {
            let x = screen.frame.midX - windowWidth / 2
            let y = screen.frame.midY - windowHeight / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        log("SessionRecordingPermission: showing permission prompt")
    }

    func close() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        window?.orderOut(nil)
        window = nil
        log("SessionRecordingPermission: dismissed")
    }

    private func startPermissionPolling(onGranted: @escaping () -> Void) {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if ScreenCaptureService.checkPermission() {
                self.permissionCheckTimer?.invalidate()
                self.permissionCheckTimer = nil
                log("SessionRecordingPermission: permission granted!")

                // Show "Done" state — user clicks OK to dismiss
                self.state.isGranted = true
                onGranted()
            }
        }
    }
}
