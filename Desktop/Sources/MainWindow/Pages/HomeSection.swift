import SwiftUI
import GRDB

/// Home tab — the default landing page showing how to use Fazm, stats, and recent messages.
struct HomeSection: View {
    @ObservedObject var shortcutSettings = ShortcutSettings.shared

    // Stats
    @State private var totalMessages: Int = 0

    // Recent messages
    @State private var recentMessages: [(text: String, date: Date)] = []

    var body: some View {
        VStack(spacing: 20) {
            howToUseCard
            statsCard
            recentMessagesCard
        }
        .onAppear {
            loadData()
        }
    }

    // MARK: - How to Use Fazm

    private var howToUseCard: some View {
        HStack(spacing: 16) {
            shortcutBadge(keys: [shortcutSettings.pttKey.symbol])

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

    // MARK: - Stats

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.purplePrimary)

                Text("Total messages")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textTertiary)
            }

            Text("\(totalMessages)")
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

    // MARK: - Recent Messages

    private var recentMessagesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recent messages")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundColor(FazmColors.textPrimary)

            if recentMessages.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .scaledFont(size: 24)
                            .foregroundColor(FazmColors.textQuaternary)
                        Text("No messages yet")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textQuaternary)
                        (Text("Hold ") + Text(shortcutSettings.pttKey.symbol).bold() + Text(" to ask Fazm something"))
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(recentMessages.enumerated()), id: \.offset) { _, message in
                        HStack(spacing: 8) {
                            Image(systemName: "person.fill")
                                .scaledFont(size: 10)
                                .foregroundColor(FazmColors.purplePrimary)

                            Text(message.text)
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundColor(FazmColors.textPrimary)
                                .lineLimit(1)

                            Spacer()

                            Text(timeAgo(message.date))
                                .scaledFont(size: 11)
                                .foregroundColor(FazmColors.textQuaternary)
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

    private func loadData() {
        Task {
            // Retry a few times if DB isn't ready yet (can happen on first launch)
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { continue }

                do {
                    let total = try await dbQueue.read { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages") ?? 0
                    }

                    let recent = try await dbQueue.read { db -> [(text: String, date: Date)] in
                        let rows = try Row.fetchAll(db, sql: """
                            SELECT messageText, createdAt
                            FROM chat_messages
                            WHERE sender = 'user'
                            ORDER BY createdAt DESC
                            LIMIT 5
                        """)
                        return rows.map { row in
                            (
                                text: (row["messageText"] as String?) ?? "",
                                date: (row["createdAt"] as Date?) ?? Date()
                            )
                        }
                    }

                    await MainActor.run {
                        totalMessages = total
                        recentMessages = recent
                    }
                    return // success
                } catch {
                    log("HomeSection: DB read attempt \(attempt) failed: \(error)")
                }
            }
        }
    }
}
