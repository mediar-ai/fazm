import Foundation
import Combine

/// Manages user-defined MCP server configurations stored in ~/.fazm/mcp-servers.json
/// Format mirrors Claude Code's mcpServers: { "name": { "command": "...", "args": [...], "env": {...}, "enabled": true } }
final class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()

    @Published var servers: [MCPServerConfig] = []
    /// All MCP servers currently active in the bridge (built-in + user)
    @Published var activeServers: [ActiveServer] = []

    private let configURL: URL

    /// Represents an MCP server that is currently loaded in the ACP bridge
    struct ActiveServer: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var command: String
        var builtin: Bool
    }

    struct MCPServerConfig: Identifiable, Codable, Equatable, Hashable {
        var id: String { name }
        var name: String
        var command: String
        var args: [String]
        var env: [String: String]
        var enabled: Bool

        init(name: String, command: String, args: [String] = [], env: [String: String] = [:], enabled: Bool = true) {
            self.name = name
            self.command = command
            self.args = args
            self.env = env
            self.enabled = enabled
        }
    }

    private init() {
        let fazmDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fazm")
        self.configURL = fazmDir.appendingPathComponent("mcp-servers.json")
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            servers = []
            return
        }
        do {
            let data = try Data(contentsOf: configURL)
            let raw = try JSONDecoder().decode([String: RawServerConfig].self, from: data)
            servers = raw.map { (name, cfg) in
                MCPServerConfig(
                    name: name,
                    command: cfg.command,
                    args: cfg.args ?? [],
                    env: cfg.env ?? [:],
                    enabled: cfg.enabled ?? true
                )
            }.sorted(by: { $0.name < $1.name })
        } catch {
            print("[MCPServerManager] Failed to load: \(error)")
            servers = []
        }
    }

    func save() {
        let fazmDir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: fazmDir, withIntermediateDirectories: true)

        var dict: [String: RawServerConfig] = [:]
        for server in servers {
            dict[server.name] = RawServerConfig(
                command: server.command,
                args: server.args.isEmpty ? nil : server.args,
                env: server.env.isEmpty ? nil : server.env,
                enabled: server.enabled ? nil : false  // omit when true (default)
            )
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(dict)
            try data.write(to: configURL, options: .atomic)
        } catch {
            print("[MCPServerManager] Failed to save: \(error)")
        }
    }

    func addServer(_ server: MCPServerConfig) {
        servers.append(server)
        save()
    }

    func removeServer(named name: String) {
        servers.removeAll { $0.name == name }
        save()
    }

    func updateServer(_ server: MCPServerConfig) {
        if let idx = servers.firstIndex(where: { $0.name == server.name }) {
            servers[idx] = server
        }
        save()
    }

    func toggleServer(named name: String) {
        if let idx = servers.firstIndex(where: { $0.name == name }) {
            servers[idx].enabled.toggle()
        }
        save()
    }

    func updateActiveServers(_ servers: [ActiveServer]) {
        DispatchQueue.main.async {
            self.activeServers = servers
        }
    }

    /// JSON structure matching Claude Code's mcpServers format
    private struct RawServerConfig: Codable {
        var command: String
        var args: [String]?
        var env: [String: String]?
        var enabled: Bool?
    }
}
