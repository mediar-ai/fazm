import SwiftUI
import UniformTypeIdentifiers

/// "Ask a question..." input panel for the floating control bar.
struct AskAIInputView: View {
    @EnvironmentObject var state: FloatingControlBarState
    @Binding var userInput: String
    @State private var localInput: String = ""
    @State private var textHeight: CGFloat = 40
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var isDragOver: Bool = false

    var onSend: ((String, [ChatAttachment]) -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    @State private var sendPulse: Bool = false

    private let minHeight: CGFloat = 40
    private let maxHeight: CGFloat = 200

    /// Supported file types for attachments
    private static let supportedImageTypes: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp"]
    private static let supportedDocTypes: Set<String> = ["pdf"]
    private static let supportedTextTypes: Set<String> = [
        "txt", "md", "csv", "json", "xml", "html", "css", "js", "ts", "tsx", "jsx",
        "py", "rs", "swift", "go", "java", "c", "cpp", "h", "hpp", "rb", "sh", "yaml", "yml",
        "toml", "ini", "cfg", "log", "sql", "r", "m", "mm"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: escape hint
            HStack {
                Spacer()

                HStack(spacing: 4) {
                    Text("esc")
                        .scaledFont(size: 11)
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 16)
                        .background(FazmColors.overlayForeground.opacity(0.1))
                        .cornerRadius(4)
                    Text("to close")
                        .scaledFont(size: 11)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 16)

            // Attachment thumbnails strip
            if !pendingAttachments.isEmpty {
                attachmentStrip
            }

            HStack(spacing: 6) {
                attachButton

                ZStack(alignment: .topLeading) {
                    if localInput.isEmpty && !state.isVoiceListening {
                        Text("Ask a question...")
                            .scaledFont(size: 13)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    }

                    FazmTextEditor(
                        text: $localInput,
                        lineFragmentPadding: 8,
                        onSubmit: {
                            sendCurrentMessage()
                        },
                        focusOnAppear: true,
                        minHeight: minHeight,
                        maxHeight: maxHeight,
                        onHeightChange: { newHeight in
                            if abs(textHeight - newHeight) > 1 {
                                textHeight = newHeight
                                onHeightChange?(newHeight)
                            }
                        }
                    )
                    .onChange(of: localInput) { _, newValue in
                        userInput = newValue
                    }
                    .onAppear {
                        localInput = userInput
                    }
                    .onChange(of: userInput) { _, newValue in
                        // Sync external changes (e.g. PTT transcription) into local state
                        if newValue != localInput {
                            localInput = newValue
                        }
                    }
                }
                .padding(.horizontal, 4)
                .frame(height: textHeight)

                micButton
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .overlay(
            // Drag & drop overlay
            isDragOver ?
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(FazmColors.purplePrimary, lineWidth: 2, antialiased: true)
                    .background(FazmColors.purplePrimary.opacity(0.08))
                    .cornerRadius(12)
                : nil
        )
        .onDrop(of: [.fileURL, .image], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
            return true
        }
        .onExitCommand {
            onCancel?()
        }
    }

    // MARK: - Helpers

    private func sendCurrentMessage() {
        let trimmed = localInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingAttachments.isEmpty else { return }
        guard !state.isAILoading else { return }
        state.showSendButtonHint = false
        let attachmentsToSend = pendingAttachments
        pendingAttachments = []
        onSend?(trimmed, attachmentsToSend)
    }

    private var hasInput: Bool {
        !localInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    private var canSend: Bool {
        hasInput && !state.isAILoading
    }

    // MARK: - Attachment handling

    private func addFiles(from urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            let mimeType: String

            if Self.supportedImageTypes.contains(ext) {
                mimeType = mimeTypeForExtension(ext)
            } else if Self.supportedDocTypes.contains(ext) {
                mimeType = "application/pdf"
            } else if Self.supportedTextTypes.contains(ext) {
                mimeType = "text/plain"
            } else {
                // Try to detect: if small enough and looks like text, allow it
                if let data = try? Data(contentsOf: url), data.count < 1_000_000 {
                    if String(data: data, encoding: .utf8) != nil {
                        mimeType = "text/plain"
                    } else {
                        continue // Skip unsupported binary files
                    }
                } else {
                    continue
                }
            }

            // Generate thumbnail for images
            var thumbnailData: Data?
            if mimeType.hasPrefix("image/") {
                if let image = NSImage(contentsOf: url) {
                    thumbnailData = generateThumbnail(from: image, maxSize: 80)
                }
            }

            let attachment = ChatAttachment(
                path: url.path,
                name: name,
                mimeType: mimeType,
                thumbnailData: thumbnailData
            )
            pendingAttachments.append(attachment)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let data = data as? Data, let urlStr = String(data: data, encoding: .utf8),
                          let url = URL(string: urlStr) else { return }
                    DispatchQueue.main.async {
                        addFiles(from: [url])
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // Pasted/dropped image data (not a file)
                provider.loadItem(forTypeIdentifier: UTType.png.identifier, options: nil) { data, _ in
                    guard let data = data as? Data else { return }
                    // Save to temp file
                    let tempDir = FileManager.default.temporaryDirectory
                    let filename = "paste-\(UUID().uuidString.prefix(8)).png"
                    let tempURL = tempDir.appendingPathComponent(filename)
                    try? data.write(to: tempURL)
                    DispatchQueue.main.async {
                        var thumbnail: Data?
                        if let img = NSImage(data: data) {
                            thumbnail = generateThumbnail(from: img, maxSize: 80)
                        }
                        let att = ChatAttachment(
                            path: tempURL.path,
                            name: filename,
                            mimeType: "image/png",
                            thumbnailData: thumbnail
                        )
                        pendingAttachments.append(att)
                    }
                }
            }
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        // Build allowed types
        var types: [UTType] = []
        for ext in Self.supportedImageTypes {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        types.append(.pdf)
        for ext in Self.supportedTextTypes {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types

        panel.begin { response in
            if response == .OK {
                addFiles(from: panel.urls)
            }
        }
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    private func generateThumbnail(from image: NSImage, maxSize: CGFloat) -> Data? {
        let size = image.size
        let scale = min(maxSize / size.width, maxSize / size.height, 1.0)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        newImage.unlockFocus()
        guard let tiffData = newImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    // MARK: - Subviews

    private var attachButton: some View {
        Button(action: { openFilePicker() }) {
            Image(systemName: "plus.circle")
                .scaledFont(size: 18)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Attach files (images, PDFs, code)")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { attachment in
                    attachmentThumbnail(attachment)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func attachmentThumbnail(_ attachment: ChatAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbData = attachment.thumbnailData, let nsImage = NSImage(data: thumbData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipped()
                } else if attachment.isPDF {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.1))
                        Image(systemName: "doc.fill")
                            .scaledFont(size: 20)
                            .foregroundColor(.red)
                    }
                    .frame(width: 48, height: 48)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.1))
                        Image(systemName: "doc.text.fill")
                            .scaledFont(size: 20)
                            .foregroundColor(.blue)
                    }
                    .frame(width: 48, height: 48)
                }
            }
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(FazmColors.overlayForeground.opacity(0.15), lineWidth: 1)
            )

            // Remove button
            Button(action: {
                pendingAttachments.removeAll { $0.id == attachment.id }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 14)
                    .foregroundColor(.secondary)
                    .background(Circle().fill(FazmColors.backgroundPrimary).frame(width: 12, height: 12))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .help(attachment.name)
    }

    private var micButton: some View {
        PushToTalkButton(isListening: state.isVoiceListening, iconSize: 18, frameSize: 28)
    }

    private var sendButton: some View {
        VStack(spacing: 2) {
            Button(action: {
                guard hasInput, !state.isAILoading else { return }
                sendCurrentMessage()
            }) {
                ZStack {
                        Circle()
                            .fill(canSend ? FazmColors.overlayForeground : Color.secondary.opacity(0.15))
                            .frame(width: 24, height: 24)
                        Image(systemName: "arrow.up")
                            .scaledFont(size: 12, weight: .heavy)
                            .foregroundColor(canSend ? FazmColors.backgroundPrimary : Color.secondary.opacity(0.5))
                    }
                    .shadow(
                        color: state.showSendButtonHint && hasInput
                            ? FazmColors.purplePrimary.opacity(sendPulse ? 0.8 : 0.3)
                            : .clear,
                        radius: sendPulse ? 10 : 4
                    )
                    .scaleEffect(state.showSendButtonHint && hasInput && sendPulse ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: sendPulse)
            }
            .disabled(!hasInput || state.isAILoading)
            .buttonStyle(.plain)

            if state.showSendButtonHint && hasInput {
                Text("⏎")
                    .scaledFont(size: 10)
                    .foregroundColor(FazmColors.overlayForeground.opacity(0.6))
                    .frame(width: 20, height: 14)
                    .background(FazmColors.overlayForeground.opacity(0.1))
                    .cornerRadius(3)
                    .transition(.opacity)
            }
        }
        .onChange(of: state.showSendButtonHint) { _, show in
            if show {
                sendPulse = true
            } else {
                sendPulse = false
            }
        }
    }
}
