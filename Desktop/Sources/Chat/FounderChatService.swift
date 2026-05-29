import Foundation

/// An attachment (image/file) on a founder chat message. The bytes live in
/// Firebase Storage; the message doc only carries these lightweight references.
struct FounderChatAttachment: Identifiable, Equatable {
    /// Tokenized Firebase Storage download URL (used for rendering and by the
    /// founder-chat agent to fetch the file).
    let url: String
    let name: String
    let mimeType: String
    /// Object path in the Storage bucket, e.g.
    /// `founder_chat_attachments/{uid}/{messageId}/{filename}`. Lets the
    /// admin-SDK pipeline fetch the file without the tokenized URL.
    let storagePath: String
    /// Local file path, set only on the optimistic just-sent message so the
    /// bubble can render instantly from disk before the upload round-trips.
    var localPath: String?

    var id: String { storagePath.isEmpty ? (localPath ?? url) : storagePath }
    var isImage: Bool { mimeType.hasPrefix("image/") }

    /// Firestore REST `mapValue` encoding for the message doc's `attachments` array.
    var firestoreValue: [String: Any] {
        ["mapValue": ["fields": [
            "url": ["stringValue": url],
            "name": ["stringValue": name],
            "mime_type": ["stringValue": mimeType],
            "storage_path": ["stringValue": storagePath],
        ]]]
    }

    /// Identity ignores `localPath` (a transient render hint) so the polled
    /// remote copy compares equal to the optimistic local one and doesn't
    /// trigger a needless replace.
    static func == (lhs: FounderChatAttachment, rhs: FounderChatAttachment) -> Bool {
        lhs.url == rhs.url && lhs.name == rhs.name
            && lhs.mimeType == rhs.mimeType && lhs.storagePath == rhs.storagePath
    }
}

/// Message in a founder chat conversation
struct FounderChatMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let sender: FounderChatSender
    let senderName: String?
    let createdAt: Date
    var read: Bool
    var attachments: [FounderChatAttachment] = []

    static func == (lhs: FounderChatMessage, rhs: FounderChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.read == rhs.read
            && lhs.attachments == rhs.attachments
    }
}

enum FounderChatSender: String {
    case user
    case founder
}

/// Service for reading/writing founder chat messages via Firestore REST API.
/// Collection structure:
///   founder_chats/{user_uid}          — metadata doc (unread counts, last message)
///   founder_chats/{user_uid}/messages — individual messages
@MainActor
class FounderChatService: ObservableObject {
    static let shared = FounderChatService()

    @Published var messages: [FounderChatMessage] = []
    @Published var unreadCount: Int = 0
    @Published var isSending: Bool = false

    private static let firestoreProjectId = "fazm-prod"
    private static let baseUrl = "https://firestore.googleapis.com/v1/projects/\(firestoreProjectId)/databases/(default)/documents"

    /// Firebase Storage bucket (matches STORAGE_BUCKET in GoogleService-Info.plist).
    private static let storageBucket = "fazm-prod.firebasestorage.app"
    /// Max attachment size accepted for upload (10 MB).
    private static let maxAttachmentBytes = 10 * 1024 * 1024
    /// Characters left unescaped when percent-encoding a Storage object path.
    /// Everything else (including `/`) is encoded, which is how Firebase
    /// Storage represents an object's full name in both the upload `name`
    /// query param and the download URL path segment.
    private static let storagePathAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    private var pollingTask: Task<Void, Never>?
    private var lastPollTime: Date?

    private init() {
        setupTestNotificationListener()
    }

    // MARK: - Programmatic Test Hook

    /// Listen for distributed notification to send a test message from the terminal:
    /// ```
    /// xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.founderChat"), object: nil, userInfo: ["text": "Hello from terminal!"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
    /// ```
    /// Simulate receiving a founder message:
    /// ```
    /// xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.founderChat"), object: nil, userInfo: ["text": "Reply from founder", "sender": "founder", "senderName": "Matt"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
    /// ```
    /// Bundle-scoped form (target dev or prod individually): replace
    /// `com.fazm.founderChat` with `com.fazm.desktop-dev.founderChat` (dev)
    /// or `com.fazm.app.founderChat` (prod).
    private func setupTestNotificationListener() {
        DistributedNotificationCenter.default().addFazmObserver(
            "founderChat"
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let text = userInfo["text"] as? String else { return }
            let sender = userInfo["sender"] as? String ?? "user"
            let senderName = userInfo["senderName"] as? String

            log("FounderChatService: Test notification received — sender=\(sender), text=\(text)")

            Task { @MainActor [weak self] in
                if sender == "founder" {
                    // Simulate receiving a founder message (write to Firestore as founder)
                    await self?.simulateFounderMessage(text: text, senderName: senderName ?? "Matt")
                } else {
                    // Send as user message
                    await self?.sendMessage(text)
                }
            }
        }
    }

    /// Write a founder message to Firestore (for testing the receive path)
    private func simulateFounderMessage(text: String, senderName: String) async {
        guard let uid = AuthService.shared.userId,
              let idToken = try? await AuthService.shared.getIdToken() else {
            log("FounderChatService: simulateFounderMessage — not signed in")
            return
        }

        let messageId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        let msgDocPath = "\(Self.baseUrl)/founder_chats/\(uid)/messages/\(messageId)?updateMask.fieldPaths=text&updateMask.fieldPaths=sender&updateMask.fieldPaths=sender_name&updateMask.fieldPaths=created_at&updateMask.fieldPaths=read"
        let msgFields: [String: Any] = [
            "text": ["stringValue": text],
            "sender": ["stringValue": "founder"],
            "sender_name": ["stringValue": senderName],
            "created_at": ["timestampValue": now],
            "read": ["booleanValue": false],
        ]

        var request = URLRequest(url: URL(string: msgDocPath)!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fields": msgFields])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                log("FounderChatService: simulateFounderMessage success")
                // Update metadata to increment unread_by_user
                let commitUrl = "https://firestore.googleapis.com/v1/projects/\(Self.firestoreProjectId)/databases/(default)/documents:commit"
                let docPath = "projects/\(Self.firestoreProjectId)/databases/(default)/documents/founder_chats/\(uid)"
                let writes: [[String: Any]] = [
                    [
                        "update": [
                            "name": docPath,
                            "fields": [
                                "last_message_text": ["stringValue": String(text.prefix(100))],
                                "last_message_at": ["timestampValue": now],
                                "last_message_sender": ["stringValue": "founder"],
                            ],
                        ] as [String: Any],
                        "updateMask": ["fieldPaths": ["last_message_text", "last_message_at", "last_message_sender"]],
                    ],
                    [
                        "transform": [
                            "document": docPath,
                            "fieldTransforms": [
                                ["fieldPath": "unread_by_user", "increment": ["integerValue": "1"]],
                            ],
                        ] as [String: Any],
                    ],
                ]
                let body: [String: Any] = ["writes": writes]
                var metaReq = URLRequest(url: URL(string: commitUrl)!)
                metaReq.httpMethod = "POST"
                metaReq.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
                metaReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                metaReq.httpBody = try? JSONSerialization.data(withJSONObject: body)
                _ = try? await URLSession.shared.data(for: metaReq)

                // Trigger immediate poll to show the message
                await fetchMessages()
                await fetchUnreadCount()
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                log("FounderChatService: simulateFounderMessage failed (status \(code))")
            }
        } catch {
            log("FounderChatService: simulateFounderMessage failed: \(error)")
        }
    }

    // MARK: - Lifecycle

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchMessages()
                await self?.fetchUnreadCount()
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Send Message

    func sendMessage(_ text: String, attachments: [ChatAttachment] = []) async {
        // Allow attachment-only messages (e.g. a screenshot with no caption).
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        guard let uid = AuthService.shared.userId,
              let idToken = try? await AuthService.shared.getIdToken() else {
            log("FounderChatService: Cannot send — not signed in")
            return
        }

        isSending = true
        defer { isSending = false }

        let messageId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let userEmail = AuthService.shared.userEmail ?? ""
        let userName = AuthService.shared.displayName

        // Upload attachments to Firebase Storage first (failed ones are dropped + logged).
        var uploaded: [FounderChatAttachment] = []
        for att in attachments {
            if let up = await uploadAttachment(att, uid: uid, idToken: idToken, messageId: messageId) {
                uploaded.append(up)
            }
        }

        // Write message document
        let msgDocPath = "\(Self.baseUrl)/founder_chats/\(uid)/messages/\(messageId)"
        var msgFields: [String: Any] = [
            "text": ["stringValue": text],
            "sender": ["stringValue": "user"],
            "sender_name": ["stringValue": userName],
            "created_at": ["timestampValue": now],
            "read": ["booleanValue": false],
        ]
        var maskFields = ["text", "sender", "sender_name", "created_at", "read"]
        if !uploaded.isEmpty {
            msgFields["attachments"] = ["arrayValue": ["values": uploaded.map { $0.firestoreValue }]]
            maskFields.append("attachments")
        }
        let maskQuery = maskFields.map { "updateMask.fieldPaths=\($0)" }.joined(separator: "&")

        var request = URLRequest(url: URL(string: "\(msgDocPath)?\(maskQuery)")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fields": msgFields])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                log("FounderChatService: Message sent successfully (\(uploaded.count) attachment(s))")

                // Optimistically add to local messages
                let msg = FounderChatMessage(
                    id: messageId,
                    text: text,
                    sender: .user,
                    senderName: userName,
                    createdAt: Date(),
                    read: true, // user's own message is always read
                    attachments: uploaded
                )
                messages.append(msg)

                // Update metadata doc (last message, unread for founder). Use an
                // emoji preview when there's no caption so the chat-list preview
                // and Matt's report aren't blank for attachment-only messages.
                let preview = text.isEmpty ? attachmentPreview(uploaded) : text
                await updateMetadata(uid: uid, idToken: idToken, lastMessageText: preview, userEmail: userEmail, userName: userName)
            } else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                log("FounderChatService: Send failed (status \(statusCode)): \(body.prefix(500))")
            }
        } catch {
            log("FounderChatService: Send failed: \(error.localizedDescription)")
        }
    }

    /// Short text preview for an attachment-only message.
    private func attachmentPreview(_ uploaded: [FounderChatAttachment]) -> String {
        guard let first = uploaded.first else { return "📎 Attachment" }
        if first.isImage { return uploaded.count > 1 ? "📷 \(uploaded.count) images" : "📷 Screenshot" }
        return uploaded.count > 1 ? "📎 \(uploaded.count) files" : "📎 \(first.name)"
    }

    /// Upload one attachment's bytes to Firebase Storage via the REST API,
    /// authed by the user's Firebase ID token. Returns a reference with a
    /// tokenized download URL, or nil on failure / oversize.
    private func uploadAttachment(_ att: ChatAttachment, uid: String, idToken: String, messageId: String) async -> FounderChatAttachment? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: att.path)) else {
            log("FounderChatService: uploadAttachment — cannot read \(att.path)")
            return nil
        }
        if data.count > Self.maxAttachmentBytes {
            log("FounderChatService: uploadAttachment — \(att.name) too large (\(data.count) bytes), skipping")
            return nil
        }

        let objectPath = "founder_chat_attachments/\(uid)/\(messageId)/\(att.name)"
        guard let encodedPath = objectPath.addingPercentEncoding(withAllowedCharacters: Self.storagePathAllowed),
              let uploadURL = URL(string: "https://firebasestorage.googleapis.com/v0/b/\(Self.storageBucket)/o?uploadType=media&name=\(encodedPath)") else {
            log("FounderChatService: uploadAttachment — could not build URL for \(att.name)")
            return nil
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue(att.mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        do {
            let (respData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: respData, encoding: .utf8) ?? ""
                log("FounderChatService: uploadAttachment failed (status \(code)): \(body.prefix(300))")
                return nil
            }
            let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any]
            let token = (json?["downloadTokens"] as? String) ?? ""
            let downloadURL = "https://firebasestorage.googleapis.com/v0/b/\(Self.storageBucket)/o/\(encodedPath)?alt=media&token=\(token)"
            return FounderChatAttachment(url: downloadURL, name: att.name, mimeType: att.mimeType, storagePath: objectPath, localPath: att.path)
        } catch {
            log("FounderChatService: uploadAttachment failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Mark Messages as Read

    func markFounderMessagesAsRead() async {
        guard let uid = AuthService.shared.userId,
              let idToken = try? await AuthService.shared.getIdToken() else { return }

        let unreadMessages = messages.filter { $0.sender == .founder && !$0.read }
        guard !unreadMessages.isEmpty else { return }

        for msg in unreadMessages {
            let docPath = "\(Self.baseUrl)/founder_chats/\(uid)/messages/\(msg.id)?updateMask.fieldPaths=read"
            let fields: [String: Any] = ["fields": ["read": ["booleanValue": true]]]
            var request = URLRequest(url: URL(string: docPath)!)
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: fields)
            _ = try? await URLSession.shared.data(for: request)
        }

        // Update local state
        for i in messages.indices {
            if messages[i].sender == .founder {
                messages[i].read = true
            }
        }

        // Reset unread count on metadata doc
        await resetUnreadForUser(uid: uid, idToken: idToken)
        unreadCount = 0
    }

    // MARK: - Fetch Messages

    func fetchMessages() async {
        guard let uid = AuthService.shared.userId,
              let idToken = try? await AuthService.shared.getIdToken() else { return }

        let parent = "\(Self.baseUrl)/founder_chats/\(uid)"
        let queryUrl = "\(parent):runQuery"

        let query: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": "messages"]],
                "orderBy": [["field": ["fieldPath": "created_at"], "direction": "ASCENDING"]],
                "limit": 200,
            ]
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: query)
            var request = URLRequest(url: URL(string: queryUrl)!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                log("FounderChatService: fetchMessages failed (status \(code)): \(body.prefix(500))")
                return
            }

            guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("FounderChatService: fetchMessages — could not parse response")
                return
            }

            var fetched: [FounderChatMessage] = []
            for entry in results {
                guard let doc = entry["document"] as? [String: Any],
                      let fields = doc["fields"] as? [String: Any],
                      let name = doc["name"] as? String else { continue }

                let docId = name.split(separator: "/").last.map(String.init) ?? UUID().uuidString
                let text = (fields["text"] as? [String: Any])?["stringValue"] as? String ?? ""
                let senderStr = (fields["sender"] as? [String: Any])?["stringValue"] as? String ?? "user"
                let senderName = (fields["sender_name"] as? [String: Any])?["stringValue"] as? String
                let read = (fields["read"] as? [String: Any])?["booleanValue"] as? Bool ?? false
                let timestampStr = (fields["created_at"] as? [String: Any])?["timestampValue"] as? String

                let createdAt: Date
                if let ts = timestampStr {
                    createdAt = ISO8601DateFormatter().date(from: ts) ?? Date()
                } else {
                    createdAt = Date()
                }

                var attachments: [FounderChatAttachment] = []
                if let values = ((fields["attachments"] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [[String: Any]] {
                    for v in values {
                        guard let mv = (v["mapValue"] as? [String: Any])?["fields"] as? [String: Any] else { continue }
                        func str(_ key: String) -> String { (mv[key] as? [String: Any])?["stringValue"] as? String ?? "" }
                        attachments.append(FounderChatAttachment(
                            url: str("url"),
                            name: str("name").isEmpty ? "file" : str("name"),
                            mimeType: str("mime_type").isEmpty ? "application/octet-stream" : str("mime_type"),
                            storagePath: str("storage_path"),
                            localPath: nil
                        ))
                    }
                }

                fetched.append(FounderChatMessage(
                    id: docId,
                    text: text,
                    sender: FounderChatSender(rawValue: senderStr) ?? .user,
                    senderName: senderName,
                    createdAt: createdAt,
                    read: read,
                    attachments: attachments
                ))
            }

            if fetched != messages {
                messages = fetched
            }
        } catch {
            log("FounderChatService: fetchMessages failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Unread Count

    private func fetchUnreadCount() async {
        let count = messages.filter { $0.sender == .founder && !$0.read }.count
        if count != unreadCount {
            unreadCount = count
        }
    }

    // MARK: - Metadata Helpers

    private func updateMetadata(uid: String, idToken: String, lastMessageText: String, userEmail: String, userName: String) async {
        let metaDocPath = "\(Self.baseUrl)/founder_chats/\(uid)"
        let now = ISO8601DateFormatter().string(from: Date())

        // Use commit with transforms to atomically increment unread_by_founder
        let commitUrl = "https://firestore.googleapis.com/v1/projects/\(Self.firestoreProjectId)/databases/(default)/documents:commit"

        let docPath = "projects/\(Self.firestoreProjectId)/databases/(default)/documents/founder_chats/\(uid)"

        let writes: [[String: Any]] = [
            // Set metadata fields
            [
                "update": [
                    "name": docPath,
                    "fields": [
                        "last_message_text": ["stringValue": String(lastMessageText.prefix(100))],
                        "last_message_at": ["timestampValue": now],
                        "last_message_sender": ["stringValue": "user"],
                        "user_email": ["stringValue": userEmail],
                        "user_name": ["stringValue": userName],
                        "user_uid": ["stringValue": uid],
                    ],
                ] as [String: Any],
                "updateMask": ["fieldPaths": ["last_message_text", "last_message_at", "last_message_sender", "user_email", "user_name", "user_uid"]],
            ],
            // Increment unread_by_founder
            [
                "transform": [
                    "document": docPath,
                    "fieldTransforms": [
                        ["fieldPath": "unread_by_founder", "increment": ["integerValue": "1"]],
                    ],
                ] as [String: Any],
            ],
        ]

        let body: [String: Any] = ["writes": writes]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            var request = URLRequest(url: URL(string: commitUrl)!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            _ = try await URLSession.shared.data(for: request)
        } catch {
            log("FounderChatService: updateMetadata failed: \(error.localizedDescription)")
        }
    }

    private func resetUnreadForUser(uid: String, idToken: String) async {
        let metaDocPath = "\(Self.baseUrl)/founder_chats/\(uid)?updateMask.fieldPaths=unread_by_user"
        let fields: [String: Any] = [
            "fields": [
                "unread_by_user": ["integerValue": "0"],
            ]
        ]

        var request = URLRequest(url: URL(string: metaDocPath)!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: fields)
        _ = try? await URLSession.shared.data(for: request)
    }
}
