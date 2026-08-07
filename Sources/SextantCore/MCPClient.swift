import Foundation

/// An MCP client and where it keeps its server list.
///
/// Producing the JSON is the easy half. The hard half is everything the existing `.mcp.json` path
/// already does and that has to hold for every client: merge instead of clobbering, refuse to
/// guess at a file that does not parse, treat "already registered" as a fact rather than an error,
/// and write an absolute path to the binary — a client that cannot find it cannot start the server.
public struct MCPClient: Sendable, Equatable {
    public let name: String
    /// Where the server list lives. Project-relative for a per-project client, absolute for a
    /// per-user one — resolved rather than hard-coded, because it differs by OS and by client.
    public let configuration: Configuration
    /// The key the servers live under: most use `mcpServers`, and the difference matters more
    /// than it looks — writing ours under the wrong one produces a file the client ignores.
    public let serversKey: String
    /// Extra fields a client expects on each entry.
    public let entryExtras: [String: String]

    public enum Configuration: Sendable, Equatable {
        /// Inside the project, at this relative path.
        case project(String)
        /// Per user, under the home directory.
        case home(String)
    }

    public func configurationURL(projectRoot: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch configuration {
        case .project(let path):
            return URL(fileURLWithPath: projectRoot, isDirectory: true).appendingPathComponent(path)
        case .home(let path):
            return home.appendingPathComponent(path)
        }
    }

    // MARK: - The clients that are actually supported

    /// Claude Code: a file in the project, which is why it is the default — a registration that
    /// travels with the checkout rather than with the machine.
    public static let claudeCode = MCPClient(
        name: "claude-code", configuration: .project(".mcp.json"),
        serversKey: "mcpServers", entryExtras: [:]
    )

    /// Claude Desktop: one list for the whole machine, so the project has to be named in the args.
    public static let claudeDesktop = MCPClient(
        name: "claude-desktop",
        configuration: .home("Library/Application Support/Claude/claude_desktop_config.json"),
        serversKey: "mcpServers", entryExtras: [:]
    )

    /// Only clients whose configuration has been written and launched are listed here.
    ///
    /// Others — VS Code, Cursor, Windsurf, Zed — differ in more than the path: the servers key and
    /// the entry shape are not the same, and a config written from documentation and never
    /// launched is worse than no support at all, because it fails silently and the user blames the
    /// tool. Adding one means verifying it against the running client, not reading its docs.
    public static let supported: [MCPClient] = [claudeCode, claudeDesktop]

    public static func named(_ name: String) -> MCPClient? {
        supported.first { $0.name == name }
    }
}

/// Writing a server into a client's configuration without destroying what is already there.
public enum MCPRegistration {
    public enum Outcome: Sendable, Equatable {
        case written(String)
        /// The file exists and does not parse, or the servers key is not an object. Left alone:
        /// overwriting a config the user hand-edited is not a repair.
        case refused(String)
        case alreadyRegistered(String)
    }

    /// Merges sextant into the servers of an existing configuration.
    ///
    /// `existing` is the parsed file, or nil when there is none. Returns the new file and what
    /// happened, or a refusal — never a silently rewritten config.
    public static func merge(existing: [String: Any]?, client: MCPClient, binary: String,
                             projectRoot: String, force: Bool) -> (json: [String: Any], outcome: Outcome) {
        var root = existing ?? [:]
        var servers: [String: Any] = [:]

        if let present = root[client.serversKey] {
            guard let object = present as? [String: Any] else {
                return ([:], .refused("\(client.serversKey) is not an object — leaving the file alone, fix it by hand"))
            }
            servers = object
        }
        if servers["sextant"] != nil, !force {
            return (root, .alreadyRegistered("· sextant is already registered for \(client.name) (--force to overwrite)"))
        }

        var entry: [String: Any] = ["command": binary, "args": ["mcp", "--project", projectRoot]]
        for (key, value) in client.entryExtras { entry[key] = value }
        servers["sextant"] = entry
        root[client.serversKey] = servers
        return (root, .written("✅ registered for \(client.name)"))
    }
}
