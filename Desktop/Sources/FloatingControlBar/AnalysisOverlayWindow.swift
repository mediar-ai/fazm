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
    /// `category` is "automate" (default) or "heal" — the heal variant uses a stethoscope
    /// icon, a different accent color, and frames the discuss message as a Mac Doctor diagnostic.
    func show(below barFrame: NSRect, task: String, category: String = "automate", description: String? = nil, document: String? = nil, activityId: Int64) {
        // Only one overlay at a time
        guard !isShowing else {
            log("AnalysisOverlay: already showing, skipping")
            return
        }

        let hostingView = NSHostingView(
            rootView: AnalysisOverlayView(
                task: task,
                category: category,
                onDiscuss: { [weak self] in
                    log("AnalysisOverlay: Discuss tapped (activityId=\(activityId), category=\(category))")
                    PostHogSDK.shared.capture("discovered_task_overlay_discuss", properties: [
                        "task_title": String(task.prefix(100)),
                        "activity_id": activityId,
                        "category": category,
                        "source": "popup_overlay",
                    ])
                    self?.dismiss()

                    // Update DB status
                    Task {
                        await AnalysisOverlayWindow.updateActivityStatus(activityId: activityId, status: "acted", response: "discuss")
                    }

                    // Inject message into existing floating bar session
                    AnalysisOverlayWindow.sendDiscussMessage(task: task, category: category, description: description, document: document)
                },
                onHide: { [weak self] in
                    log("AnalysisOverlay: Hide tapped (activityId=\(activityId), category=\(category))")
                    PostHogSDK.shared.capture("discovered_task_overlay_dismissed", properties: [
                        "task_title": String(task.prefix(100)),
                        "activity_id": activityId,
                        "category": category,
                        "source": "popup_overlay",
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
        panel.applyCrashWorkarounds()  // FAZM-20: disable auto touch bar / tabbing

        hostingView.frame = NSRect(origin: .zero, size: overlaySize)
        panel.contentView = hostingView

        panel.makeKeyAndOrderFront(nil)
        self.window = panel

        PostHogSDK.shared.capture("discovered_task_overlay_shown", properties: [
            "task_title": String(task.prefix(100)),
            "activity_id": activityId,
            "category": category,
            "auto_dismiss_delay_seconds": Int(Self.autoDismissDelay),
        ])

        // Auto-dismiss after 15 seconds
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isShowing else { return }
                log("AnalysisOverlay: auto-dismissed after \(Int(Self.autoDismissDelay))s")
                // Distinct from explicit "Hide" — measures passive ignore vs. active dismiss.
                // Status stays "pending" since the user never engaged; the card remains
                // in the Discovered Tasks tab until they act on it there.
                PostHogSDK.shared.capture("discovered_task_overlay_auto_dismissed", properties: [
                    "task_title": String(task.prefix(100)),
                    "activity_id": activityId,
                    "category": category,
                    "auto_dismiss_delay_seconds": Int(Self.autoDismissDelay),
                ])
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
    /// The framing differs by category: automate cards prime "is this worth automating?",
    /// heal cards prime "Mac Doctor — read-only diagnostics first, no destructive actions".
    static func sendDiscussMessage(task: String, category: String = "automate", description: String?, document: String?) {
        var message: String
        if category == "heal" {
            message = """
            Fazm's screen observer (or system-health monitor) detected a Mac health signal that may need attention:

            **Symptom:** \(task)
            """

            if let description, !description.isEmpty {
                message += "\n\n**What was observed:** \(description)"
            }

            if let document, !document.isEmpty {
                message += "\n\n---\n\n\(document)"
            }

            message += """


            Act as **Mac Doctor**: a careful macOS sysadmin. Strict rules:
            1. **Read-only first.** Run only safe, read-only diagnostics (`top`, `vm_stat`, `pmset -g`, `log show`, `cat` of report files, `brctl status`, `zprint`, etc). Never `sudo`, `rm`, `kextunload`, `killall`, or anything destructive without my explicit approval.
            2. **Diagnose, then explain in plain English.** Tell me what the symptom likely means, ranked by probability, and why.
            3. **Propose fixes ranked by reversibility** (safe & reversible first, irreversible last). For each fix, tell me exactly what command would run and what it does.
            4. **Wait for my OK before any fix.** Do not run any command that changes system state until I confirm.

            Start by asking me one clarifying question if anything is ambiguous, otherwise proceed with read-only diagnostics.
            """
        } else {
            message = """
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
        }

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
