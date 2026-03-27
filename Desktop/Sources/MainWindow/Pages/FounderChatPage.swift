import SwiftUI
import MarkdownUI

/// Chat with Founder page — reuses the onboarding chat bubble style
struct FounderChatPage: View {
    @ObservedObject private var chatService = FounderChatService.shared
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if chatService.messages.isEmpty && !chatService.isSending {
                emptyState
            } else {
                messageList
            }

            Divider()
                .background(FazmColors.backgroundTertiary)

            inputBar
        }
        .onAppear {
            chatService.startPolling()
            Task { await chatService.markFounderMessagesAsRead() }
        }
        .onDisappear {
            chatService.stopPolling()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            if let logoURL = Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png"),
               let logoImage = NSImage(contentsOf: logoURL) {
                Image(nsImage: logoImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .foregroundColor(FazmColors.textTertiary)
            }

            Text("Chat with the Fazm team")
                .scaledFont(size: 20, weight: .semibold)
                .foregroundColor(FazmColors.textPrimary)

            Text("Ask questions, share feedback, or just say hi.\nWe'll reply as soon as we can.")
                .scaledFont(size: 14)
                .foregroundColor(FazmColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(chatService.messages) { message in
                        FounderChatBubble(message: message)
                            .id(message.id)
                    }

                    if chatService.isSending {
                        TypingIndicator()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 44)
                            .id("typing")
                    }
                }
                .padding(24)
            }
            .onChange(of: chatService.messages.count) { _, _ in
                withAnimation {
                    if let last = chatService.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let last = chatService.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Send a message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .scaledFont(size: 14)
                .foregroundColor(FazmColors.textPrimary)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit {
                    sendMessage()
                }

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? FazmColors.textTertiary
                                    : FazmColors.purplePrimary)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatService.isSending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(FazmColors.backgroundPrimary.opacity(0.5))
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task { await chatService.sendMessage(text) }
    }
}

// MARK: - Chat Bubble (reuses onboarding style)

struct FounderChatBubble: View {
    let message: FounderChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.sender == .founder {
                // Fazm logo for founder messages
                if let logoURL = Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png"),
                   let logoImage = NSImage(contentsOf: logoURL) {
                    Image(nsImage: logoImage)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(FazmColors.backgroundTertiary)
                        .clipShape(Circle())
                }
            }

            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 4) {
                if message.sender == .founder, let name = message.senderName, !name.isEmpty {
                    Text(name)
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundColor(FazmColors.textTertiary)
                }

                Markdown(message.text)
                    .markdownTheme(message.sender == .user ? .userMessage() : .aiMessage())
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.sender == .user ? FazmColors.purplePrimary : FazmColors.backgroundSecondary)
                    .cornerRadius(18)

                Text(timeString(message.createdAt))
                    .scaledFont(size: 10)
                    .foregroundColor(FazmColors.textTertiary)
            }

            if message.sender == .user {
                // User avatar
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(FazmColors.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(FazmColors.backgroundTertiary)
                    .clipShape(Circle())
            }
        }
        .frame(maxWidth: .infinity, alignment: message.sender == .user ? .trailing : .leading)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday' h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        return formatter.string(from: date)
    }
}
