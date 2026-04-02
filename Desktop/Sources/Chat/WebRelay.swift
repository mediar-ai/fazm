import Foundation

/// Runs a local WebSocket server (via Node.js subprocess) and a Cloudflare tunnel
/// so that a phone/web client can send chat queries to the desktop app remotely.
///
/// Flow:
/// 1. Launch a Node.js WS server (ws-relay.js) on a random port
/// 2. Launch `cloudflared tunnel --url http://localhost:<port>` to expose it
/// 3. Register the tunnel URL with the backend (`/api/relay/register`)
/// 4. Relay messages between phone and ChatProvider via stdin/stdout pipes
@MainActor
final class WebRelay: ObservableObject {

    // MARK: - State

    @Published private(set) var tunnelUrl: String?
    @Published private(set) var isPhoneConnected = false

    private var wsServerProcess: Process?
    private var cloudflaredProcess: Process?
    private var stdinPipe: Pipe?
    private var localPort: UInt16 = 0
    private var heartbeatTask: Task<Void, Never>?
    private var isStarted = false

    /// Dedup: last processed query text + timestamp to reject rapid duplicates
    private var lastQueryText: String?
    private var lastQueryTime: Date?

    /// Callback: a query arrived from the phone. Parameters: text, sessionKey
    var onQuery: ((String, String) async -> Void)?

    /// Callback: phone requested chat history
    var onHistoryRequest: (() async -> [[String: Any]])?

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else {
            log("WebRelay: already started, skipping duplicate start()")
            return
        }
        isStarted = true
        killOrphanedCloudflared()
        startWsServer()
    }

    func stop() {
        isStarted = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        unregisterTunnel()
        cloudflaredProcess?.terminationHandler = nil
        cloudflaredProcess?.terminate()
        cloudflaredProcess = nil
        wsServerProcess?.terminate()
        wsServerProcess = nil
        stdinPipe = nil
        tunnelUrl = nil
        isPhoneConnected = false
    }

    // MARK: - Orphan Cleanup

    /// Kill any cloudflared processes left over from previous app runs.
    /// These accumulate when the app is force-quit or crashes without calling stop().
    /// Runs on a background thread to avoid blocking the main thread
    /// (waitUntilExit pumps the run loop, which can cause SwiftUI re-entrancy crashes).
    private func killOrphanedCloudflared() {
        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["-f", "cloudflared tunnel --url"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else { return }

                let myPid = ProcessInfo.processInfo.processIdentifier
                for line in output.components(separatedBy: "\n") {
                    guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != myPid else { continue }
                    await MainActor.run { log("WebRelay: killing orphaned cloudflared (pid \(pid))") }
                    kill(pid, SIGTERM)
                }
            } catch {
                // pgrep not found or no matches — fine
            }
        }
    }

    // MARK: - Node.js WebSocket Server

    private func startWsServer() {
        // Find the Node binary and ws-relay.js script
        let bundle = Bundle.main
        guard let nodePath = findNode(in: bundle) else {
            log("WebRelay: Node.js binary not found, skipping")
            return
        }
        guard let scriptPath = findWsRelayScript(in: bundle) else {
            log("WebRelay: ws-relay.js not found, skipping")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [scriptPath]

        // Set NODE_PATH so ws module can be found
        var env = ProcessInfo.processInfo.environment
        if let bridgeDir = findAcpBridgeDir(in: bundle) {
            env["NODE_PATH"] = bridgeDir + "/node_modules"
        }
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdinPipe = stdin

        // Read stdout for PORT and MSG lines
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

            for line in output.components(separatedBy: "\n") where !line.isEmpty {
                if line.hasPrefix("PORT:") {
                    let portStr = String(line.dropFirst(5))
                    if let port = UInt16(portStr) {
                        Task { @MainActor in
                            self?.localPort = port
                            log("WebRelay: WS server listening on port \(port)")
                            self?.startCloudflared(port: port)
                        }
                    }
                } else if line.hasPrefix("MSG:") {
                    let jsonStr = String(line.dropFirst(4))
                    if let data = jsonStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let type = json["type"] as? String {
                        Task { @MainActor in
                            await self?.handleIncomingMessage(type: type, json: json)
                        }
                    }
                }
            }
        }

        // Read stderr for CLIENT_CONNECTED/DISCONNECTED
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

            for line in output.components(separatedBy: "\n") where !line.isEmpty {
                if line.contains("CLIENT_CONNECTED") {
                    Task { @MainActor in
                        self?.isPhoneConnected = true
                        log("WebRelay: phone connected")
                    }
                } else if line.contains("CLIENT_DISCONNECTED") {
                    Task { @MainActor in
                        self?.isPhoneConnected = false
                        log("WebRelay: phone disconnected")
                    }
                }
            }
        }

        do {
            try process.run()
            wsServerProcess = process
            log("WebRelay: WS server process started")
        } catch {
            logError("WebRelay: failed to start WS server", error: error)
        }
    }

    // MARK: - Find bundled paths

    private func findNode(in bundle: Bundle) -> String? {
        // Check bundle first, then system
        let bundlePaths = [
            bundle.resourcePath.map { $0 + "/Fazm_Fazm.bundle/node" },
            bundle.executablePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path + "/node" },
        ].compactMap { $0 }

        for path in bundlePaths {
            if FileManager.default.fileExists(atPath: path) {
                // Copy to temp dir to avoid macOS 26 CSM killing JIT-entitled binaries inside sealed bundles
                return NodeBinaryHelper.externalNodePath(from: path)
            }
        }

        // Fallback to system node
        let systemPaths = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        return systemPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func findWsRelayScript(in bundle: Bundle) -> String? {
        let bundlePaths = [
            bundle.resourcePath.map { $0 + "/acp-bridge/dist/ws-relay.js" },
        ].compactMap { $0 }

        for path in bundlePaths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }

        // Dev fallback: source tree
        let devPath = ProcessInfo.processInfo.environment["FAZM_SOURCE_DIR"]
            .map { $0 + "/acp-bridge/dist/ws-relay.js" }
        if let devPath, FileManager.default.fileExists(atPath: devPath) { return devPath }

        return nil
    }

    private func findAcpBridgeDir(in bundle: Bundle) -> String? {
        let bundlePaths = [
            bundle.resourcePath.map { $0 + "/acp-bridge" },
        ].compactMap { $0 }

        for path in bundlePaths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }

        let devPath = ProcessInfo.processInfo.environment["FAZM_SOURCE_DIR"]
            .map { $0 + "/acp-bridge" }
        if let devPath, FileManager.default.fileExists(atPath: devPath) { return devPath }

        return nil
    }

    // MARK: - Message handling

    private func handleIncomingMessage(type: String, json: [String: Any]) async {
        switch type {
        case "send_message":
            let text = json["text"] as? String ?? ""
            let sessionKey = json["sessionKey"] as? String ?? "main"
            guard !text.isEmpty else { return }

            // Dedup: reject identical messages within 5 seconds
            let now = Date()
            if let lastText = lastQueryText, lastText == text,
               let lastTime = lastQueryTime, now.timeIntervalSince(lastTime) < 5 {
                log("WebRelay: duplicate message rejected (\(text.prefix(50))...)")
                return
            }
            lastQueryText = text
            lastQueryTime = now

            // Notify the phone that query started
            sendToPhone(["type": "query_started"])

            // Process through ChatProvider
            await onQuery?(text, sessionKey)

        case "request_history":
            if let history = await onHistoryRequest?() {
                sendToPhone(["type": "chat_history", "messages": history])
            }

        default:
            log("WebRelay: unknown message type: \(type)")
        }
    }

    // MARK: - Send to phone

    func sendToPhone(_ json: [String: Any]) {
        guard let stdinPipe else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let jsonStr = String(data: data, encoding: .utf8) else { return }

        let line = jsonStr + "\n"
        stdinPipe.fileHandleForWriting.write(line.data(using: .utf8)!)
    }

    // MARK: - Cloudflared Tunnel

    private func findCloudflared(in bundle: Bundle) -> String? {
        // Check bundle first
        let bundlePaths = [
            bundle.resourcePath.map { $0 + "/Fazm_Fazm.bundle/cloudflared" },
        ].compactMap { $0 }

        for path in bundlePaths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }

        // Fallback to system
        let systemPaths = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
        return systemPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func startCloudflared(port: UInt16) {
        guard let binary = findCloudflared(in: Bundle.main) else {
            log("WebRelay: cloudflared not found, skipping tunnel")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["tunnel", "--url", "http://localhost:\(port)"]

        // Use a clean HOME so cloudflared doesn't pick up existing named tunnel credentials
        // that override the quick tunnel mode
        var env = ProcessInfo.processInfo.environment
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("cloudflared-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: tempHome, withIntermediateDirectories: true)
        env["HOME"] = tempHome
        process.environment = env

        let pipe = Pipe()
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

            if let range = output.range(of: "https://[a-z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) {
                let url = String(output[range])
                Task { @MainActor in
                    self?.tunnelUrl = url
                    log("WebRelay: tunnel URL = \(url)")
                    self?.registerTunnel(url: url)
                    self?.startHeartbeat()
                }
            }
        }

        // Auto-restart if cloudflared crashes or exits unexpectedly
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.cloudflaredProcess === proc else { return }
                self.cloudflaredProcess = nil
                self.tunnelUrl = nil
                let code = proc.terminationStatus
                log("WebRelay: cloudflared exited (status \(code)), restarting in 3s...")
                try? await Task.sleep(for: .seconds(3))
                guard self.wsServerProcess?.isRunning == true else { return }
                self.startCloudflared(port: self.localPort)
            }
        }

        do {
            try process.run()
            cloudflaredProcess = process
            log("WebRelay: cloudflared started")
        } catch {
            logError("WebRelay: failed to start cloudflared", error: error)
        }
    }

    // MARK: - Heartbeat

    /// Re-registers the tunnel URL every 60s so the backend's in-memory map
    /// survives Cloud Run instance restarts / deploys.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, let url = self.tunnelUrl else { break }
                log("WebRelay: heartbeat re-registering tunnel")
                self.registerTunnel(url: url)
            }
        }
    }

    // MARK: - Backend Registration

    private func registerTunnel(url: String) {
        guard let backendUrl = ProcessInfo.processInfo.environment["FAZM_BACKEND_URL"],
              let token = AuthService.shared.idToken else {
            log("WebRelay: missing backend URL or auth token, skipping registration")
            return
        }

        let endpoint = "\(backendUrl)/api/relay/register"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["tunnel_url": url]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                logError("WebRelay: register failed", error: error)
            } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                log("WebRelay: tunnel registered with backend")
            } else {
                log("WebRelay: register got status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
        }.resume()
    }

    private func unregisterTunnel() {
        guard let backendUrl = ProcessInfo.processInfo.environment["FAZM_BACKEND_URL"],
              let token = AuthService.shared.idToken else { return }

        let endpoint = "\(backendUrl)/api/relay/unregister"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
