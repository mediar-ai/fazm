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

    // Cloudflared restart governor: caps tight restart loops when the tunnel can't come up
    // (e.g. APAC IPs blocked from trycloudflare, corporate proxy, no network). Without this,
    // a doomed tunnel respawns every 3s forever, polluting the Sentry breadcrumb buffer.
    private var cloudflaredRestartCount = 0
    private var cloudflaredRestartWindowStart: Date?
    private var cloudflaredGaveUp = false
    private let maxCloudflaredRestartsInWindow = 5
    private let cloudflaredRestartWindow: TimeInterval = 300
    private let cloudflaredGiveUpCooldown: TimeInterval = 3600

    /// Dedup: last processed query text + timestamp to reject rapid duplicates
    private var lastQueryText: String?
    private var lastQueryTime: Date?

    /// Callback: a query arrived from the phone. Parameters: text, sessionKey
    var onQuery: ((String, String) async -> Void)?

    /// Callback: phone requested chat history. The (optional) sessionKey lets the
    /// caller filter by a specific pop-out (`detached-<uuid>`), the floating bar
    /// (`main`), etc. nil means "default" (legacy clients).
    var onHistoryRequest: ((String?) async -> [[String: Any]])?

    /// Callback: phone requested current desktop state. The desktop side (ChatProvider)
    /// fills this with `{model, modelLabel, workspace, availableModels, voiceEnabled, ...}`
    /// and we wrap it with `{type: "desktop_state"}` before sending.
    var onStateRequest: (() async -> [String: Any])?

    /// Callback: phone requested the open detached pop-out list. Returns one entry per
    /// open window with `{sessionKey, title, workspace, selectedModel, ...}`.
    var onPopOutsRequest: (() async -> [[String: Any]])?

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else {
            log("WebRelay: already started, skipping duplicate start()")
            return
        }
        isStarted = true
        killOrphanedCloudflared()
        // Resolve the node binary off the main thread — NodeBinaryHelper.verify()
        // busy-waits (Thread.sleep) spawning `node --version`, blocking for up to 10s (FAZM-9W).
        let bundle = Bundle.main
        Task.detached { [weak self] in
            let nodePath = await self?.resolveNodePath(in: bundle)
            await self?.startWsServer(nodePath: nodePath, bundle: bundle)
        }
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

    /// Resolve the node binary path off the main thread (blocking I/O).
    nonisolated func resolveNodePath(in bundle: Bundle) -> String? {
        return findNode(in: bundle)
    }

    private func startWsServer(nodePath: String?, bundle: Bundle) {
        guard let nodePath else {
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

    private nonisolated func findNode(in bundle: Bundle) -> String? {
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

            // If the web client picked a specific pop-out as its target, route the
            // message through DetachedChatWindowController so the pop-out's own
            // streaming UI lights up. Falls back to the main floating-bar flow when
            // the pop-out has gone away.
            if sessionKey.hasPrefix("detached-") {
                let sent = DetachedChatWindowController.shared.sendQuery(toSessionKey: sessionKey, message: text)
                log("WebRelay: routed send_message to popout sessionKey=\(sessionKey) sent=\(sent)")
                if !sent {
                    // Pop-out gone (closed in another tab, etc). Fall back to floating bar.
                    await onQuery?(text, "main")
                }
            } else {
                await onQuery?(text, sessionKey)
            }

        case "request_history":
            let sessionKey = json["sessionKey"] as? String
            if let history = await onHistoryRequest?(sessionKey) {
                var payload: [String: Any] = ["type": "chat_history", "messages": history]
                if let sessionKey { payload["sessionKey"] = sessionKey }
                sendToPhone(payload)
            }

        case "request_state":
            if let state = await onStateRequest?() {
                var payload: [String: Any] = ["type": "desktop_state"]
                for (k, v) in state { payload[k] = v }
                sendToPhone(payload)
            }

        case "request_popouts":
            if let popouts = await onPopOutsRequest?() {
                sendToPhone(["type": "popouts_list", "popouts": popouts])
            }

        case "control":
            // Bridge web -> existing distributed-notification control API. This lets
            // every command supported by the floating bar (newChat, newPopOutChat,
            // setModel, setWorkspace, stopAgent, popOut, ...) work from the web with
            // zero duplication of the dispatch logic on the desktop side.
            let command = json["command"] as? String ?? ""
            guard !command.isEmpty else { return }
            log("WebRelay: control command from web: \(command)")
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.fazm.control"),
                object: nil,
                userInfo: ["command": command],
                deliverImmediately: true
            )
            // Push fresh state back so the web UI reflects whatever the command
            // changed (model, workspace, popout list, etc). 200ms gives the desktop
            // side time to apply the change before we read it back.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                if let state = await self?.onStateRequest?() {
                    var payload: [String: Any] = ["type": "desktop_state"]
                    for (k, v) in state { payload[k] = v }
                    self?.sendToPhone(payload)
                }
                if let popouts = await self?.onPopOutsRequest?() {
                    self?.sendToPhone(["type": "popouts_list", "popouts": popouts])
                }
            }

        case "stop":
            // Web client interrupted streaming. Re-use the existing stopAgent path
            // by posting the control notification, so behaviour matches the floating
            // bar's "Stop" button exactly (clears in-flight query, releases the bridge).
            log("WebRelay: stop from web")
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.fazm.control"),
                object: nil,
                userInfo: ["command": "stopAgent"],
                deliverImmediately: true
            )

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
                    self?.cloudflaredRestartCount = 0
                    self?.cloudflaredRestartWindowStart = nil
                    log("WebRelay: tunnel URL = \(url)")
                    await self?.registerTunnel(url: url)
                    self?.startHeartbeat()
                }
            } else {
                // Capture non-URL stderr lines (errors, connection failures, region blocks)
                // so we can diagnose why cloudflared keeps dying for APAC/corporate users.
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    log("WebRelay: cloudflared stderr: \(trimmed.prefix(500))")
                }
            }
        }

        // Auto-restart if cloudflared crashes or exits unexpectedly, with a capped
        // 5-attempts-per-5min window and exponential backoff. Once the cap is hit we
        // emit one Sentry breadcrumb and sleep for an hour before resetting, so we
        // don't burn the breadcrumb buffer on doomed-tunnel networks.
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.cloudflaredProcess === proc else { return }
                self.cloudflaredProcess = nil
                self.tunnelUrl = nil
                let code = proc.terminationStatus
                guard self.wsServerProcess?.isRunning == true else {
                    log("WebRelay: cloudflared exited (status \(code)), ws-server not running, skipping restart")
                    return
                }

                let now = Date()
                if let windowStart = self.cloudflaredRestartWindowStart,
                   now.timeIntervalSince(windowStart) > self.cloudflaredRestartWindow {
                    self.cloudflaredRestartCount = 0
                    self.cloudflaredRestartWindowStart = nil
                }
                if self.cloudflaredRestartWindowStart == nil {
                    self.cloudflaredRestartWindowStart = now
                }
                self.cloudflaredRestartCount += 1

                if self.cloudflaredRestartCount > self.maxCloudflaredRestartsInWindow {
                    if !self.cloudflaredGaveUp {
                        self.cloudflaredGaveUp = true
                        log("WebRelay: cloudflared failing to start (\(self.maxCloudflaredRestartsInWindow) attempts in \(Int(self.cloudflaredRestartWindow))s, last status \(code)), pausing for \(Int(self.cloudflaredGiveUpCooldown))s. Remote chat disabled until tunnel recovers.")
                    }
                    try? await Task.sleep(for: .seconds(self.cloudflaredGiveUpCooldown))
                    guard self.wsServerProcess?.isRunning == true else { return }
                    self.cloudflaredRestartCount = 0
                    self.cloudflaredRestartWindowStart = nil
                    self.cloudflaredGaveUp = false
                    log("WebRelay: cloudflared cooldown elapsed, retrying")
                    self.startCloudflared(port: self.localPort)
                    return
                }

                // Exponential backoff: 3, 6, 12, 24, 48 (capped at 60s).
                let backoff = min(60.0, 3.0 * pow(2.0, Double(self.cloudflaredRestartCount - 1)))
                log("WebRelay: cloudflared exited (status \(code)), restart \(self.cloudflaredRestartCount)/\(self.maxCloudflaredRestartsInWindow) in \(Int(backoff))s")
                try? await Task.sleep(for: .seconds(backoff))
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
                guard !Task.isCancelled, let self else { break }
                // tunnelUrl can be temporarily nil during cloudflared restarts; skip this tick
                guard let url = self.tunnelUrl else { continue }
                log("WebRelay: heartbeat re-registering tunnel")
                await self.registerTunnel(url: url)
            }
        }
    }

    // MARK: - Backend Registration

    private func registerTunnel(url: String) async {
        guard let backendUrl = ProcessInfo.processInfo.environment["FAZM_BACKEND_URL"] else {
            log("WebRelay: missing backend URL, skipping registration")
            return
        }

        let token: String
        do {
            token = try await AuthService.shared.getIdToken()
        } catch {
            log("WebRelay: failed to get auth token for registration, skipping")
            return
        }

        let endpoint = "\(backendUrl)/api/relay/register"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["tunnel_url": url]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                log("WebRelay: tunnel registered with backend")
            } else {
                log("WebRelay: register got status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
        } catch {
            logError("WebRelay: register failed", error: error)
        }
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
