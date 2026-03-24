import SwiftUI
import AppKit

/// Manages a standalone centered window for the App Management permission setup guide.
final class AppManagementSetupWindowController {
    static let shared = AppManagementSetupWindowController()
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    /// Show the guide in its initial "steps" state.
    func show(version: String, onDone: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        showView(version: version, startGranted: false, onDone: onDone, onDismiss: onDismiss)
    }

    /// Show the guide in its "done" state (permission already granted, e.g. after relaunch).
    func showDone(version: String, onDone: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        showView(version: version, startGranted: true, onDone: onDone, onDismiss: onDismiss)
    }

    private func showView(version: String, startGranted: Bool, onDone: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        // If already showing, just bring to front
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let controller = self
        let setupView = AppManagementSetupView(
            version: version,
            startGranted: startGranted,
            onDone: {
                onDone()
                controller.close()
            },
            onDismiss: {
                onDismiss()
                controller.close()
            }
        )

        let hostingView = NSHostingView(rootView: AnyView(setupView))
        hostingView.setFrameSize(hostingView.fittingSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
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
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.hostingView = hostingView
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }
}

/// Step-by-step guide for granting App Management permission so Sparkle can install updates.
struct AppManagementSetupView: View {
    let version: String
    let startGranted: Bool
    var onDone: () -> Void
    var onDismiss: () -> Void

    @State private var settingsOpened = false
    @State private var permissionGranted = false
    @State private var appBecameActiveObserver: NSObjectProtocol?

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Fazm"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: dismiss button
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundColor(FazmColors.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(FazmColors.textTertiary.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            if permissionGranted {
                doneView
            } else {
                stepsView
            }

            Spacer()

            // Bottom buttons
            VStack(spacing: 8) {
                if permissionGranted {
                    Button(action: {
                        log("AppManagementSetup: User clicked Install Update")
                        PostHogManager.shared.track("app_management_install_clicked", properties: ["version": version])
                        onDone()
                    }) {
                        Text("Install Update")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button(action: {
                        log("AppManagementSetup: User clicked Open System Settings")
                        PostHogManager.shared.track("app_management_open_settings_clicked", properties: ["version": version])
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement") {
                            NSWorkspace.shared.open(url)
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settingsOpened = true
                        }
                        startListeningForReturn()
                    }) {
                        Text(settingsOpened ? "Open Settings Again" : "Open System Settings")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: {
                        log("AppManagementSetup: User clicked Not Now")
                        PostHogManager.shared.track("app_management_dismissed", properties: ["version": version, "settings_opened": settingsOpened])
                        onDismiss()
                    }) {
                        Text("Not Now")
                            .scaledFont(size: 13)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(width: 460, height: permissionGranted ? 380 : 480)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(FazmColors.backgroundSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(FazmColors.backgroundTertiary.opacity(0.5), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.3), value: permissionGranted)
        .onAppear {
            if startGranted {
                permissionGranted = true
                log("AppManagementSetup: Opened in done state (permission already granted)")
                PostHogManager.shared.track("app_management_guide_shown", properties: ["version": version, "state": "done"])
            } else {
                log("AppManagementSetup: Opened in steps state (permission needed)")
                PostHogManager.shared.track("app_management_guide_shown", properties: ["version": version, "state": "steps"])
            }
        }
        .onDisappear {
            if let observer = appBecameActiveObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    // MARK: - Steps View

    private var stepsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.app")
                .scaledFont(size: 44)
                .foregroundColor(FazmColors.purplePrimary)

            Text("Update v\(version) is ready")
                .scaledFont(size: 20, weight: .semibold)
                .foregroundColor(FazmColors.textPrimary)

            Text("macOS requires a one-time permission before \(appName) can install updates.")
                .scaledFont(size: 14)
                .foregroundColor(FazmColors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                stepRow(number: "1", text: "Click \"Open System Settings\" below", done: settingsOpened)
                stepRow(number: "2", text: "Find \(appName) in the App Management list", done: false, dimmed: !settingsOpened)
                stepRow(number: "3", text: "Toggle it on", done: false, dimmed: !settingsOpened)
                stepRow(number: "4", text: "macOS will ask to \"Quit & Reopen\" — allow it", done: false, dimmed: !settingsOpened)
            }
            .padding(.horizontal, 44)
            .padding(.top, 8)

            if settingsOpened {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for permission to be granted...")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Done View

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 48)
                .foregroundColor(.green)

            Text("Permission granted!")
                .scaledFont(size: 20, weight: .semibold)
                .foregroundColor(FazmColors.textPrimary)

            Text("\(appName) can now install updates automatically. Click below to install v\(version).")
                .scaledFont(size: 14)
                .foregroundColor(FazmColors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Helpers

    private func stepRow(number: String, text: String, done: Bool, dimmed: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.green))
                } else {
                    Text(number)
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(dimmed ? FazmColors.textTertiary.opacity(0.2) : FazmColors.textTertiary.opacity(0.5)))
                }
            }

            Text(text)
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(dimmed ? FazmColors.textTertiary.opacity(0.4) : done ? FazmColors.textTertiary : FazmColors.textPrimary)
        }
    }

    /// Listen for the app becoming active (user returned from System Settings) and probe permission.
    private func startListeningForReturn() {
        // Remove any existing observer
        if let observer = appBecameActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        appBecameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            probeAppManagementPermission()
        }
    }

    /// Attempt a harmless write inside the app bundle to test if App Management is granted.
    /// If we can write + delete a temp file in Contents/, permission is active.
    private func probeAppManagementPermission() {
        let testPath = Bundle.main.bundlePath + "/Contents/.fazm-permission-test"
        let fm = FileManager.default
        let canWrite = fm.createFile(atPath: testPath, contents: Data("test".utf8))
        if canWrite {
            try? fm.removeItem(atPath: testPath)
            log("AppManagementSetup: Permission probe succeeded — permission granted")
            PostHogManager.shared.track("app_management_permission_granted", properties: ["version": version])
            withAnimation(.easeInOut(duration: 0.3)) {
                permissionGranted = true
            }
            if let observer = appBecameActiveObserver {
                NotificationCenter.default.removeObserver(observer)
                appBecameActiveObserver = nil
            }
        } else {
            log("AppManagementSetup: Permission probe failed — still not granted")
        }
    }
}
