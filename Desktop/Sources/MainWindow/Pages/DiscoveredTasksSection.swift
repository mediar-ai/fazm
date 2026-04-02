import SwiftUI
import GRDB
import PostHog

/// Discovered Tasks tab — shows tasks identified by the Gemini session analysis.
struct DiscoveredTasksSection: View {
    @State private var tasks: [DiscoveredTask] = []
    @State private var selectedTaskId: Int64?
    @State private var isLoading = true

    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if tasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .onAppear {
            loadTasks()
            PostHogSDK.shared.capture("discovered_tasks_tab_viewed")
        }
        .onReceive(refreshTimer) { _ in loadTasks() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .scaledFont(size: 32)
                .foregroundColor(FazmColors.textTertiary)

            Text("No tasks discovered yet")
                .scaledFont(size: 15, weight: .medium)
                .foregroundColor(FazmColors.textSecondary)

            Text("The screen observer analyzes your activity and identifies tasks that AI could help with. Tasks will appear here as they're discovered.")
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.3))
        )
    }

    // MARK: - Task List

    private var taskList: some View {
        VStack(spacing: 8) {
            ForEach(sortedTasks) { task in
                taskRow(task)
            }
        }
    }

    /// Pending (unread) tasks first, then by createdAt desc
    private var sortedTasks: [DiscoveredTask] {
        tasks.sorted { a, b in
            let aUnread = a.status == "pending"
            let bUnread = b.status == "pending"
            if aUnread != bUnread { return aUnread }
            return a.createdAt > b.createdAt
        }
    }

    private func taskRow(_ task: DiscoveredTask) -> some View {
        let isExpanded = selectedTaskId == task.id

        return VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        selectedTaskId = nil
                    } else {
                        selectedTaskId = task.id
                        markAsRead(task)
                        PostHogSDK.shared.capture("discovered_task_expanded", properties: [
                            "task_id": task.id,
                            "task_status": task.status,
                            "task_title": String(task.taskTitle.prefix(100)),
                        ])
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .scaledFont(size: 14)
                        .foregroundColor(.purple)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.taskTitle)
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundColor(FazmColors.textPrimary)
                            .lineLimit(isExpanded ? nil : 2)

                        HStack(spacing: 8) {
                            Text(task.timeAgo)
                                .scaledFont(size: 11)
                                .foregroundColor(FazmColors.textTertiary)

                            statusBadge(task.status)
                        }
                    }

                    Spacer()

                    // Unread indicator dot
                    if task.status == "pending" {
                        Circle()
                            .fill(Color.purple)
                            .frame(width: 8, height: 8)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 11)
                        .foregroundColor(FazmColors.textTertiary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let description = task.description, !description.isEmpty {
                        Text(description)
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let document = task.document, !document.isEmpty {
                        Text(document)
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textSecondary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(FazmColors.backgroundPrimary.opacity(0.5))
                            )
                    }

                    // Action buttons
                    HStack(spacing: 8) {
                        if task.status == "pending" || task.status == "read" {
                            Button {
                                discussTask(task)
                            } label: {
                                Text("Discuss")
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Color.purple.opacity(0.8))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            Button {
                                dismissTask(task)
                            } label: {
                                Text("Dismiss")
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundColor(FazmColors.textSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(FazmColors.backgroundTertiary.opacity(0.5))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(FazmColors.backgroundTertiary.opacity(0.3))
        )
    }

    private func statusBadge(_ status: String) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case "acted": return ("Discussed", .green)
            case "dismissed": return ("Dismissed", .gray)
            case "read": return ("Read", FazmColors.textTertiary)
            default: return ("New", .purple)
            }
        }()

        return Text(text)
            .scaledFont(size: 10, weight: .medium)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    // MARK: - Actions

    private func markAsRead(_ task: DiscoveredTask) {
        guard task.status == "pending" else { return }
        Task {
            await AnalysisOverlayWindow.updateActivityStatus(activityId: task.id, status: "read", response: "viewed")
            loadTasks()
        }
    }

    private func discussTask(_ task: DiscoveredTask) {
        PostHogSDK.shared.capture("discovered_task_discuss", properties: [
            "task_id": task.id,
            "task_title": String(task.taskTitle.prefix(100)),
        ])
        Task {
            await AnalysisOverlayWindow.updateActivityStatus(activityId: task.id, status: "acted", response: "discuss")
            AnalysisOverlayWindow.sendDiscussMessage(task: task.taskTitle, description: task.description, document: task.document)
            loadTasks()
        }
    }

    private func dismissTask(_ task: DiscoveredTask) {
        PostHogSDK.shared.capture("discovered_task_dismissed", properties: [
            "task_id": task.id,
            "task_title": String(task.taskTitle.prefix(100)),
        ])
        Task {
            await AnalysisOverlayWindow.updateActivityStatus(activityId: task.id, status: "dismissed", response: "hide")
            loadTasks()
        }
    }

    // MARK: - Data Loading

    private func loadTasks() {
        Task {
            guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else {
                await MainActor.run {
                    isLoading = false
                }
                return
            }
            do {
                let rows = try await dbQueue.read { db -> [DiscoveredTask] in
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT id, content, status, userResponse, createdAt, actedAt
                        FROM observer_activity
                        WHERE type = 'gemini_analysis'
                        ORDER BY createdAt DESC
                        LIMIT 50
                    """)
                    return rows.compactMap { row -> DiscoveredTask? in
                        guard let id = row["id"] as? Int64,
                              let content = row["content"] as? String,
                              let status = row["status"] as? String,
                              let createdAt = row["createdAt"] as? String else { return nil }

                        // Parse JSON content
                        var taskTitle = content
                        var description: String?
                        var document: String?
                        if let data = content.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            taskTitle = json["task"] as? String ?? content
                            description = json["description"] as? String
                            document = json["document"] as? String
                        }

                        return DiscoveredTask(
                            id: id,
                            taskTitle: taskTitle,
                            description: description,
                            document: document,
                            status: status,
                            createdAt: createdAt,
                            actedAt: row["actedAt"] as? String
                        )
                    }
                }
                await MainActor.run {
                    self.tasks = rows
                    self.isLoading = false
                }
            } catch {
                log("DiscoveredTasks: failed to load: \(error)")
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Unread Count (for sidebar badge)

enum DiscoveredTasksStore {
    /// Returns the number of unread (pending) discovered tasks.
    static func unreadCount() async -> Int {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return 0 }
        do {
            return try await dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM observer_activity WHERE type = 'gemini_analysis' AND status = 'pending'") ?? 0
            }
        } catch {
            return 0
        }
    }
}

// MARK: - Data Model

struct DiscoveredTask: Identifiable {
    let id: Int64
    let taskTitle: String
    let description: String?
    let document: String?
    let status: String
    let createdAt: String
    let actedAt: String?

    var timeAgo: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = formatter.date(from: createdAt) else { return createdAt }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
