import Foundation

/// Message in a founder chat conversation
struct FounderChatMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let sender: FounderChatSender
    let senderName: String?
    let createdAt: Date
    var read: Bool

    static func == (lhs: FounderChatMessage, rhs: FounderChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.read == rhs.read
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

    func sendMessage(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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

        // Write message document
        let msgDocPath = "\(Self.baseUrl)/founder_chats/\(uid)/messages/\(messageId)"
        let msgFields: [String: Any] = [
            "text": ["stringValue": text],
            "sender": ["stringValue": "user"],
            "sender_name": ["stringValue": userName],
            "created_at": ["timestampValue": now],
            "read": ["booleanValue": false],
        ]

        var request = URLRequest(url: URL(string: "\(msgDocPath)?updateMask.fieldPaths=text&updateMask.fieldPaths=sender&updateMask.fieldPaths=sender_name&updateMask.fieldPaths=created_at&updateMask.fieldPaths=read")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fields": msgFields])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                log("FounderChatService: Message sent successfully")

                // Optimistically add to local messages
                let msg = FounderChatMessage(
                    id: messageId,
                    text: text,
                    sender: .user,
                    senderName: userName,
                    createdAt: Date(),
                    read: true // user's own message is always read
                )
                messages.append(msg)

                // Update metadata doc (last message, unread for founder)
                await updateMetadata(uid: uid, idToken: idToken, lastMessageText: text, userEmail: userEmail, userName: userName)
            } else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                log("FounderChatService: Send failed (status \(statusCode)): \(body.prefix(500))")
            }
        } catch {
            log("FounderChatService: Send failed: \(error.localizedDescription)")
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

                fetched.append(FounderChatMessage(
                    id: docId,
                    text: text,
                    sender: FounderChatSender(rawValue: senderStr) ?? .user,
                    senderName: senderName,
                    createdAt: createdAt,
                    read: read
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
