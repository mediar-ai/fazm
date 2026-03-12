import SwiftUI
import GRDB

/// Home tab — the default landing page showing how to use Fazm, toggle, stats, and recent activity.
struct HomeSection: View {
    @ObservedObject var shortcutSettings = ShortcutSettings.shared
    @State private var showAskFazmBar: Bool = FloatingControlBarManager.shared.isVisible

    // Stats
    @State private var messagesToday: Int = 0
    @State private var totalMessages: Int = 0
    @State private var filesIndexed: Int = 0

    // Recent activity
    @State private var recentQueries: [(question: String, answer: String, date: Date)] = []

    var body: some View {
        VStack(spacing: 20) {
            howToUseCard
            fazmToggleCard
            statsRow
            recentActivityCard
        }
        .onAppear {
            showAskFazmBar = FloatingControlBarManager.shared.isVisible
            Task { await loadStats() }
        }
    }

    // MARK: - How to Use Fazm

    private var howToUseCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                // Row 1: Talk to Fazm
                HStack(spacing: 16) {
                    shortcutBadge(keys: [shortcutSettings.pttKey.symbol])
                        .frame(width: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Talk to Fazm")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        (Text("Hold ") + Text(shortcutSettings.pttKey.symbol).bold() + Text(" to speak, release to send"))
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textSecondary)
                    }

                    Spacer()
                }

                Divider()
                    .background(FazmColors.backgroundQuaternary)

                // Row 2: Hands-free mode
                if shortcutSettings.doubleTapForLock {
                    HStack(spacing: 16) {
                        shortcutBadge(keys: [shortcutSettings.pttKey.symbol, "\u{00D7}2"])
                            .frame(width: 48)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hands-free mode")
                                .scaledFont(size: 15, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)

                            (Text("Double-tap ") + Text(shortcutSettings.pttKey.symbol).bold() + Text(" to lock, tap again when done"))
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textSecondary)
                        }

                        Spacer()
                    }

                    Divider()
                        .background(FazmColors.backgroundQuaternary)
                }

                // Row 3: Toggle floating bar
                HStack(spacing: 16) {
                    shortcutBadge(keys: ["\u{2318}", "\\"])
                        .frame(width: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Toggle floating bar")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Text("Show or hide the Ask Fazm bar")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textSecondary)
                    }

                    Spacer()
                }
            }
            .padding(20)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(FazmColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Fazm Toggle

    private var fazmToggleCard: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(showAskFazmBar ? FazmColors.success : FazmColors.textTertiary.opacity(0.3))
                .frame(width: 12, height: 12)
                .shadow(color: showAskFazmBar ? FazmColors.success.opacity(0.5) : .clear, radius: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text("Ask Fazm")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)

                Text(showAskFazmBar ? "Floating bar is active" : "Floating bar is hidden")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textTertiary)
            }

            Spacer()

            Toggle("", isOn: $showAskFazmBar)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: showAskFazmBar) { _, newValue in
                    if newValue {
                        FloatingControlBarManager.shared.show()
                    } else {
                        FloatingControlBarManager.shared.hide()
                    }
                }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(FazmColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 12) {
            statCard(title: "Today", value: "\(messagesToday)", icon: "bubble.left.fill")
            statCard(title: "Total messages", value: "\(totalMessages)", icon: "text.bubble.fill")
            statCard(title: "Files indexed", value: "\(filesIndexed)", icon: "doc.fill")
        }
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.purplePrimary)

                Text(title)
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textTertiary)
            }

            Text(value)
                .scaledFont(size: 24, weight: .bold)
                .foregroundColor(FazmColors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(FazmColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Recent Activity

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recent activity")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundColor(FazmColors.textPrimary)

            if recentQueries.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .scaledFont(size: 24)
                            .foregroundColor(FazmColors.textQuaternary)
                        Text("No conversations yet")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textQuaternary)
                        Text("Hold \(shortcutSettings.pttKey.symbol) to ask Fazm something")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(recentQueries.enumerated()), id: \.offset) { _, query in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.fill")
                                    .scaledFont(size: 10)
                                    .foregroundColor(FazmColors.purplePrimary)

                                Text(query.question)
                                    .scaledFont(size: 13, weight: .medium)
                                    .foregroundColor(FazmColors.textPrimary)
                                    .lineLimit(1)

                                Spacer()

                                Text(timeAgo(query.date))
                                    .scaledFont(size: 11)
                                    .foregroundColor(FazmColors.textQuaternary)
                            }

                            Text(query.answer)
                                .scaledFont(size: 12)
                                .foregroundColor(FazmColors.textTertiary)
                                .lineLimit(2)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(FazmColors.backgroundTertiary.opacity(0.3))
                        )
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(FazmColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers

    private func shortcutBadge(keys: [String]) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(FazmColors.backgroundQuaternary)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(FazmColors.border, lineWidth: 1)
                )
        )
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    private func loadStats() async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }

        do {
            let stats = try await dbQueue.read { db -> (today: Int, total: Int, files: Int) in
                let calendar = Calendar.current
                let startOfDay = calendar.startOfDay(for: Date())

                let today = try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM chat_messages WHERE sender = 'user' AND createdAt >= ?",
                    arguments: [startOfDay]
                ) ?? 0

                let total = try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM chat_messages WHERE sender = 'user'"
                ) ?? 0

                let files = try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM indexed_files"
                ) ?? 0

                return (today, total, files)
            }

            await MainActor.run {
                messagesToday = stats.today
                totalMessages = stats.total
                filesIndexed = stats.files
            }

            // Load recent queries (last 5 user messages paired with AI responses)
            let recent = try await dbQueue.read { db -> [(question: String, answer: String, date: Date)] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m1.messageText AS question, m1.createdAt AS date,
                           COALESCE(
                               (SELECT m2.messageText FROM chat_messages m2
                                WHERE m2.sender = 'ai' AND m2.createdAt > m1.createdAt
                                AND m2.taskId = m1.taskId
                                ORDER BY m2.createdAt ASC LIMIT 1),
                               ''
                           ) AS answer
                    FROM chat_messages m1
                    WHERE m1.sender = 'user'
                    ORDER BY m1.createdAt DESC
                    LIMIT 5
                """)

                return rows.map { row in
                    (
                        question: (row["question"] as String?) ?? "",
                        answer: (row["answer"] as String?) ?? "",
                        date: (row["date"] as Date?) ?? Date()
                    )
                }
            }

            await MainActor.run {
                recentQueries = recent
            }
        } catch {
            logError("HomeSection: Failed to load stats", error: error)
        }
    }
}
