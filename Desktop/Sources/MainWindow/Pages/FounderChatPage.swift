import SwiftUI
import MarkdownUI
import UniformTypeIdentifiers

/// Chat with Founder page — reuses the onboarding chat bubble style
struct FounderChatPage: View {
    @ObservedObject private var chatService = FounderChatService.shared
    @State private var inputText: String = ""
    @State private var inputHeight: CGFloat = 34
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var isDragOver: Bool = false

    private let inputMinHeight: CGFloat = 34
    private let inputMaxHeight: CGFloat = 160

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if chatService.messages.isEmpty && !chatService.isSending {
                    emptyState
                } else {
                    messageList
                }

                if isDragOver {
                    ChatDragOverlay()
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $isDragOver) { providers in
                handleDrop(providers)
            }

            Divider()
                .background(FazmColors.backgroundTertiary)

            inputBar
        }
        .onAppear {
            chatService.startPolling()
            Task { await chatService.markFounderMessagesAsRead() }
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

            Text("Chat with the founder")
                .scaledFont(size: 20, weight: .semibold)
                .foregroundColor(FazmColors.textPrimary)

            Text("Ask questions, share feedback, or just say hi.\nWe'll reply as soon as we can.")
                .scaledFont(size: 14)
                .foregroundColor(FazmColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(spacing: 0) {
            if !pendingAttachments.isEmpty {
                ChatAttachmentStrip(attachments: $pendingAttachments)
            }

            HStack(alignment: .bottom, spacing: 12) {
                ChatAttachmentButton {
                    ChatAttachmentHelper.openFilePicker { urls in
                        appendFiles(urls)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("Send a message...")
                            .scaledFont(size: 14)
                            .foregroundColor(FazmColors.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    FazmTextEditor(
                        text: $inputText,
                        fontSize: 14,
                        textColor: NSColor(FazmColors.textPrimary),
                        lineFragmentPadding: 8,
                        onSubmit: { sendMessage() },
                        focusOnAppear: false,
                        onPasteFiles: { urls in appendFiles(urls) },
                        onPasteImageData: { data in appendPastedImage(data) },
                        minHeight: inputMinHeight,
                        maxHeight: inputMaxHeight,
                        onHeightChange: { newHeight in
                            if abs(inputHeight - newHeight) > 1 {
                                inputHeight = newHeight
                            }
                        }
                    )
                }
                .frame(height: inputHeight)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .scaledFont(size: 24)
                        .foregroundColor(canSend ? FazmColors.purplePrimary : FazmColors.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend || chatService.isSending)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(FazmColors.backgroundPrimary.opacity(0.5))
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = pendingAttachments
        guard !text.isEmpty || !attachmentsToSend.isEmpty else { return }
        guard !chatService.isSending else { return }
        inputText = ""
        pendingAttachments = []
        Task { await chatService.sendMessage(text, attachments: attachmentsToSend) }
    }

    /// Append picked/pasted file URLs to the pending strip. Uses a local copy so
    /// we never take `inout` of @State from an escaping closure.
    private func appendFiles(_ urls: [URL]) {
        var atts = pendingAttachments
        ChatAttachmentHelper.addFiles(from: urls, to: &atts)
        pendingAttachments = atts
    }

    private func appendPastedImage(_ data: Data) {
        var atts = pendingAttachments
        ChatAttachmentHelper.addPastedImage(data, to: &atts)
        pendingAttachments = atts
    }

    /// Drag-and-drop handler — mirrors the floating bar's resolution of fileURL
    /// (URL or Data) and image providers.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let resolvedURL: URL?
                    if let url = item as? URL {
                        resolvedURL = url
                    } else if let data = item as? Data,
                              let urlStr = String(data: data, encoding: .utf8),
                              let url = URL(string: urlStr) {
                        resolvedURL = url
                    } else {
                        resolvedURL = nil
                    }
                    guard let url = resolvedURL else { return }
                    DispatchQueue.main.async { appendFiles([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.png.identifier, options: nil) { item, _ in
                    let imageData: Data?
                    if let data = item as? Data {
                        imageData = data
                    } else if let url = item as? URL, let data = try? Data(contentsOf: url) {
                        imageData = data
                    } else {
                        imageData = nil
                    }
                    guard let data = imageData else { return }
                    DispatchQueue.main.async { appendPastedImage(data) }
                }
            }
        }
        return true
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

                ForEach(message.attachments) { attachment in
                    FounderChatAttachmentView(attachment: attachment)
                }

                if !message.text.isEmpty {
                    Markdown(message.text)
                        .markdownTheme(message.sender == .user ? .userMessage() : .aiMessage())
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(message.sender == .user ? FazmColors.purplePrimary : FazmColors.backgroundSecondary)
                        .cornerRadius(18)
                }

                Text(timeString(message.createdAt))
                    .scaledFont(size: 10)
                    .foregroundColor(FazmColors.textTertiary)
            }

            if message.sender == .user {
                // User avatar
                Image(systemName: "person.fill")
                    .scaledFont(size: 14)
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

// MARK: - Attachment Rendering

/// Renders a founder-chat attachment: an inline image (loaded from the local
/// file when available, else the Storage download URL) or a tappable file chip.
struct FounderChatAttachmentView: View {
    let attachment: FounderChatAttachment

    @State private var loadedImage: NSImage?
    @State private var didFail = false

    private let maxDimension: CGFloat = 240

    var body: some View {
        Group {
            if attachment.isImage {
                imageView
            } else {
                fileChip
            }
        }
        .onTapGesture { open() }
        .help(attachment.name)
    }

    @ViewBuilder
    private var imageView: some View {
        if let image = loadedImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxDimension, maxHeight: maxDimension)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(FazmColors.overlayForeground.opacity(0.12), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(FazmColors.backgroundSecondary)
                .frame(width: 160, height: 120)
                .overlay {
                    if didFail {
                        Image(systemName: "photo")
                            .scaledFont(size: 22)
                            .foregroundColor(FazmColors.textTertiary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .task(id: attachment.id) { await load() }
        }
    }

    private var fileChip: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.mimeType == "application/pdf" ? "doc.fill" : "doc.text.fill")
                .scaledFont(size: 16)
                .foregroundColor(FazmColors.textSecondary)
            Text(attachment.name)
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: maxDimension, alignment: .leading)
        .background(FazmColors.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(FazmColors.overlayForeground.opacity(0.12), lineWidth: 1)
        )
    }

    /// Load the image — prefer the local file (instant for a just-sent message),
    /// else fetch the Storage download URL.
    private func load() async {
        if let localPath = attachment.localPath,
           FileManager.default.fileExists(atPath: localPath),
           let image = NSImage(contentsOfFile: localPath) {
            loadedImage = image
            return
        }
        guard let url = URL(string: attachment.url),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else {
            didFail = true
            return
        }
        loadedImage = image
    }

    /// Open the attachment full-size: the local file in its default app, or the
    /// remote download URL in the browser.
    private func open() {
        if let localPath = attachment.localPath, FileManager.default.fileExists(atPath: localPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: localPath))
        } else if let url = URL(string: attachment.url) {
            NSWorkspace.shared.open(url)
        }
    }
}
