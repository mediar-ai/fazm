import Cocoa
import GRDB
import PostHog
import SwiftUI

/// NSPanel subclass that can become key (required for buttons to work in a borderless floating panel).
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Manages a separate floating window for the Gemini analysis overlay
/// (shown when session recording analysis detects a task).
@MainActor
class AnalysisOverlayWindow {
    static let shared = AnalysisOverlayWindow()

    private var window: NSWindow?
    private var autoDismissWork: DispatchWorkItem?
    private static let overlayWidth: CGFloat = 340
    private static let autoDismissDelay: TimeInterval = 15

    /// Lock — only one overlay at a time.
    var isShowing: Bool { window != nil }

    /// Show the analysis overlay positioned above the given bar window frame.
    func show(below barFrame: NSRect, task: String, description: String? = nil, document: String? = nil, activityId: Int64) {
        // Only one overlay at a time
        guard !isShowing else {
            log("AnalysisOverlay: already showing, skipping")
            return
        }

        let hostingView = NSHostingView(
            rootView: AnalysisOverlayView(
                task: task,
                onDiscuss: { [weak self] in
                    log("AnalysisOverlay: Discuss tapped (activityId=\(activityId))")
                    PostHogSDK.shared.capture("discovered_task_overlay_discuss", properties: [
                        "task_title": String(task.prefix(100)),
                        "activity_id": activityId,
                    ])
                    self?.dismiss()

                    // Update DB status
                    Task {
                        await AnalysisOverlayWindow.updateActivityStatus(activityId: activityId, status: "acted", response: "discuss")
                    }

                    // Inject message into existing floating bar session
                    AnalysisOverlayWindow.sendDiscussMessage(task: task, description: description, document: document)
                },
                onHide: { [weak self] in
                    log("AnalysisOverlay: Hide tapped (activityId=\(activityId))")
                    PostHogSDK.shared.capture("discovered_task_overlay_dismissed", properties: [
                        "task_title": String(task.prefix(100)),
                        "activity_id": activityId,
                    ])
                    self?.dismiss()
                    Task {
                        await AnalysisOverlayWindow.updateActivityStatus(activityId: activityId, status: "dismissed", response: "hide")
                    }
                }
            )
            .frame(width: Self.overlayWidth)
        )

        let fittingSize = hostingView.fittingSize
        let overlayHeight = max(fittingSize.height, 80)
        let overlaySize = NSSize(width: Self.overlayWidth, height: overlayHeight)

        let x = barFrame.midX - overlaySize.width / 2
        let y = barFrame.maxY + 8

        let panel = KeyablePanel(
            contentRect: NSRect(origin: NSPoint(x: x, y: y), size: overlaySize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false

        hostingView.frame = NSRect(origin: .zero, size: overlaySize)
        panel.contentView = hostingView

        panel.makeKeyAndOrderFront(nil)
        self.window = panel

        PostHogSDK.shared.capture("discovered_task_overlay_shown", properties: [
            "task_title": String(task.prefix(100)),
            "activity_id": activityId,
        ])

        // Auto-dismiss after 15 seconds
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isShowing else { return }
                log("AnalysisOverlay: auto-dismissed after \(Int(Self.autoDismissDelay))s")
                self.dismiss()
            }
        }
        autoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissDelay, execute: work)
    }

    func dismiss() {
        autoDismissWork?.cancel()
        autoDismissWork = nil
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Discuss Action

    /// Send the analysis context as a user message into the existing floating bar session.
    static func sendDiscussMessage(task: String, description: String?, document: String?) {
        // Build the message that gets sent as if the user typed it
        var message = """
        The screen observer analyzed my last ~60 minutes of screen activity and identified a task that could be done by AI:

        **Task:** \(task)
        """

        if let description, !description.isEmpty {
            message += "\n\n**What was observed:** \(description)"
        }

        if let document, !document.isEmpty {
            message += "\n\n---\n\n\(document)"
        }

        message += """


        I'd like to discuss this. Before taking action, please ask me:
        1. Is this task still relevant — do I still need it done?
        2. Is it something I'd trust AI to handle, or does it need my judgment?
        3. Is it repetitive enough to be worth automating as a reusable skill?
        """

        // Use the testQuery notification to inject into the floating bar session
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.fazm.testQuery"),
            object: nil,
            userInfo: ["text": message],
            deliverImmediately: true
        )
    }

    // MARK: - DB

    /// Update observer_activity row status.
    static func updateActivityStatus(activityId: Int64, status: String, response: String) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE observer_activity SET status = ?, userResponse = ?, actedAt = datetime('now') WHERE id = ?",
                    arguments: [status, response, activityId]
                )
            }
        } catch {
            log("AnalysisOverlay: failed to update activity \(activityId): \(error)")
        }
    }
}
