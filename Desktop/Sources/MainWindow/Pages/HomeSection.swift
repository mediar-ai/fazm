import SwiftUI
import GRDB

/// Home tab — the default landing page showing how to use Fazm, stats, and recent messages.
struct HomeSection: View {
    @ObservedObject var shortcutSettings = ShortcutSettings.shared
    var appState: AppState? = nil

    // Stats
    @State private var totalMessages: Int = 0

    // Recent messages
    @State private var recentMessages: [(text: String, date: Date)] = []

    // Onboarding skipped state
    @AppStorage("onboardingWasSkipped") private var onboardingWasSkipped = false

    // Timer to refresh data periodically
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            if onboardingWasSkipped {
                completeSetupBanner
            }
            howToUseCard
            exploreCards
            subscriptionCard
            statsCard
            recentMessagesCard
        }
        .onAppear {
            loadData()
        }
        .onReceive(refreshTimer) { _ in
            loadData()
        }
    }

    // MARK: - Complete Setup Banner

    private var completeSetupBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle.fill")
                .scaledFont(size: 20)
                .foregroundColor(FazmColors.purplePrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Setup incomplete")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Text("Finish setting up Fazm to get the full experience.")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textSecondary)
            }

            Spacer()

            Button(action: {
                appState?.restartOnboarding()
            }) {
                Text("Complete Setup")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(FazmColors.purplePrimary)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.purplePrimary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(FazmColors.purplePrimary.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - How to Use Fazm

    private var howToUseCard: some View {
        VStack(spacing: 14) {
            Text("Talk to Fazm")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundColor(FazmColors.textPrimary)

            HomeKeyboardView(pttKey: shortcutSettings.pttKey)

            (Text("Hold ") + Text(shortcutSettings.pttKey.rawValue).bold() + Text(" to speak, release to send"))
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
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

    // MARK: - Explore Fazm

    private var exploreCards: some View {
        let cards: [(icon: String, title: String, subtitle: String, url: String)] = [
            ("play.rectangle.fill", "Watch Demos", "See Fazm in action", "https://fazm.ai#use-cases"),
            ("lock.shield.fill", "Safety & Privacy", "How your data stays safe", "https://fazm.ai/safety"),
            ("sparkles", "Use Cases", "Ideas and inspiration", "https://fazm.ai/blog"),
            ("arrow.left.arrow.right", "Compare Features", "See how Fazm stacks up", "https://fazm.ai/compare"),
        ]

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                Button(action: {
                    PostHogManager.shared.track("resource_card_clicked", properties: ["card": card.title])
                    if let url = URL(string: card.url) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: card.icon)
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.purplePrimary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title)
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)
                            Text(card.subtitle)
                                .scaledFont(size: 11)
                                .foregroundColor(FazmColors.textTertiary)
                        }

                        Spacer()

                        Image(systemName: "arrow.up.right")
                            .scaledFont(size: 10)
                            .foregroundColor(FazmColors.textQuaternary)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(FazmColors.backgroundTertiary.opacity(0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(FazmColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Stats

    // MARK: - Subscription Status

    private var subscriptionCard: some View {
        let sub = SubscriptionService.shared
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: sub.isActive ? "checkmark.seal.fill" : "clock.fill")
                    .scaledFont(size: 13)
                    .foregroundColor(sub.isActive ? FazmColors.success : FazmColors.purplePrimary)

                Text(sub.isActive ? "Fazm Pro" : (sub.isTrialExpired ? "Free Plan" : "Free Trial"))
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)

                Spacer()

                if !sub.isActive {
                    Button(action: {
                        Task { try? await sub.openCheckout() }
                    }) {
                        Text("Upgrade")
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(FazmColors.purplePrimary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            if sub.isActive {
                if let end = sub.currentPeriodEnd {
                    Text("Renews \(end.formatted(date: .abbreviated, time: .omitted))")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)
                }
            } else if !sub.isTrialExpired {
                let daysLeft = max(0, 30 - (Calendar.current.dateComponents([.day], from: sub.firstLaunchDate, to: Date()).day ?? 0))
                Text("\(daysLeft) days remaining in free trial")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textTertiary)
            } else {
                Text("\(sub.freeMessagesPerDay) free messages per day")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(sub.isActive ? FazmColors.success.opacity(0.3) : FazmColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                )
        )
    }

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
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(recentMessages.enumerated()), id: \.offset) { _, message in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "person.fill")
                                    .scaledFont(size: 10)
                                    .foregroundColor(FazmColors.purplePrimary)
                                    .padding(.top, 3)

                                Text(message.text)
                                    .scaledFont(size: 13, weight: .medium)
                                    .foregroundColor(FazmColors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer()

                                HStack(spacing: 8) {
                                    Text(timeAgo(message.date))
                                        .scaledFont(size: 11)
                                        .foregroundColor(FazmColors.textQuaternary)

                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(message.text, forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .scaledFont(size: 11)
                                            .foregroundColor(FazmColors.textQuaternary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy to clipboard")
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(FazmColors.backgroundTertiary.opacity(0.3))
                            )
                        }
                    }
                }
                .frame(maxHeight: 400)
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
                            LIMIT 100
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

// MARK: - HomeKeyboardView

/// Full Mac keyboard visualization for the homepage, highlighting the active PTT key.
struct HomeKeyboardView: View {
    let pttKey: ShortcutSettings.PTTKey

    @State private var isPressed = false

    private let kh: CGFloat = 28
    private let khSmall: CGFloat = 14
    private let gap: CGFloat = 2
    private let keyColor = Color(nsColor: NSColor(white: 0.15, alpha: 1.0))
    private let keyBorder = Color(nsColor: NSColor(white: 0.28, alpha: 1.0))

    var body: some View {
        VStack(spacing: gap) {
            // Row 1: Esc + F-keys
            HStack(spacing: gap) {
                key("esc", w: 30)
                Spacer().frame(width: 8)
                key("F1", w: 30); key("F2", w: 30); key("F3", w: 30); key("F4", w: 30)
                Spacer().frame(width: 4)
                key("F5", w: 30); key("F6", w: 30); key("F7", w: 30); key("F8", w: 30)
                Spacer().frame(width: 4)
                key("F9", w: 30); key("F10", w: 28); key("F11", w: 28); key("F12", w: 28)
            }

            // Row 2: Number row
            HStack(spacing: gap) {
                key("`", w: 28)
                key("1", w: 28); key("2", w: 28); key("3", w: 28); key("4", w: 28); key("5", w: 28)
                key("6", w: 28); key("7", w: 28); key("8", w: 28); key("9", w: 28); key("0", w: 28)
                key("-", w: 28); key("=", w: 28)
                key("⌫", w: 42)
            }

            // Row 3: QWERTY
            HStack(spacing: gap) {
                key("⇥", w: 38)
                key("Q", w: 28); key("W", w: 28); key("E", w: 28); key("R", w: 28); key("T", w: 28)
                key("Y", w: 28); key("U", w: 28); key("I", w: 28); key("O", w: 28); key("P", w: 28)
                key("[", w: 28); key("]", w: 28)
                key("\\", w: 38)
            }

            // Row 4: ASDF
            HStack(spacing: gap) {
                key("⇪", w: 46)
                key("A", w: 28); key("S", w: 28); key("D", w: 28); key("F", w: 28); key("G", w: 28)
                key("H", w: 28); key("J", w: 28); key("K", w: 28); key("L", w: 28)
                key(";", w: 28); key("'", w: 28)
                key("⏎", w: 50)
            }

            // Row 5: ZXCV
            HStack(spacing: gap) {
                key("⇧", w: 62)
                key("Z", w: 28); key("X", w: 28); key("C", w: 28); key("V", w: 28); key("B", w: 28)
                key("N", w: 28); key("M", w: 28); key(",", w: 28); key(".", w: 28); key("/", w: 28)
                key("⇧", w: 62)
            }

            // Row 6: Bottom modifier row
            HStack(spacing: gap) {
                highlightableKey("fn", w: 28, for: .fn)
                highlightableKey("⌃", w: 28, for: .leftControl)
                highlightableKey("⌥", w: 34, for: .option)
                highlightableKey("⌘", w: 38, for: .leftCommand)
                key("", w: 130) // space bar
                highlightableKey("⌘", w: 38, for: .rightCommand)
                key("⌥", w: 34)
                // Arrow cluster
                HStack(spacing: 1) {
                    key("◀", w: 20)
                    VStack(spacing: 1) {
                        key("▲", w: 20, h: khSmall)
                        key("▼", w: 20, h: khSmall)
                    }
                    key("▶", w: 20)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: NSColor(white: 0.08, alpha: 1.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .onAppear { startPressAnimation() }
    }

    private func highlightableKey(_ label: String, w: CGFloat, for pttOption: ShortcutSettings.PTTKey) -> some View {
        let isHighlighted = pttOption == pttKey
        return Text(label)
            .font(.system(size: 12, weight: isHighlighted ? .semibold : .medium))
            .foregroundColor(isHighlighted ? .white : Color.white.opacity(0.4))
            .frame(width: w, height: kh)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHighlighted ? FazmColors.purplePrimary.opacity(isPressed ? 0.6 : 0.25) : keyColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isHighlighted ? FazmColors.purplePrimary.opacity(isPressed ? 1.0 : 0.7) : keyBorder, lineWidth: isHighlighted ? 1.5 : 0.5)
            )
            .shadow(color: isHighlighted ? FazmColors.purplePrimary.opacity(isPressed ? 0.8 : 0.4) : .clear, radius: isPressed ? 12 : 5, x: 0, y: 0)
            .scaleEffect(isHighlighted && isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isPressed)
    }

    private func key(_ label: String, w: CGFloat, h: CGFloat? = nil) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(Color.white.opacity(0.4))
            .frame(width: w, height: h ?? kh)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(keyColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(keyBorder, lineWidth: 0.5)
            )
    }

    private func startPressAnimation() {
        withAnimation(.easeIn(duration: 0.15)) { isPressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.15)) { isPressed = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { startPressAnimation() }
        }
    }
}
