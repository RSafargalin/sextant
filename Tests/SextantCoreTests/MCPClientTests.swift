import Foundation
import Testing
@testable import SextantCore

/// Producing the JSON is the easy half of registering a server. These cover the other half — the
/// carefulness the `.mcp.json` path already had, which has to hold for every client added.
@Suite("MCP client registration")
struct MCPClientTests {
    private let binary = "/usr/local/bin/sextant"

    @Test("Someone else's servers survive")
    func mergesRatherThanClobbers() throws {
        let existing: [String: Any] = ["mcpServers": ["other": ["command": "/opt/other"]]]
        let (json, outcome) = MCPRegistration.merge(existing: existing, client: .claudeCode,
                                                    binary: binary, projectRoot: "/p", force: false)
        #expect(outcome == .written("✅ registered for claude-code"))
        let servers = try #require(json["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)                    // untouched
        let entry = try #require(servers["sextant"] as? [String: Any])
        #expect(entry["command"] as? String == binary)      // absolute: a client cannot resolve PATH for us
        #expect(entry["args"] as? [String] == ["mcp", "--project", "/p"])
    }

    @Test("A servers key that is not an object is left alone")
    func refusesToGuess() {
        // The file is the user's, and it parses — it simply is not shaped the way we expect.
        // Overwriting it would be destroying a config someone edited by hand.
        let (_, outcome) = MCPRegistration.merge(existing: ["mcpServers": "nonsense"], client: .claudeCode,
                                                 binary: binary, projectRoot: "/p", force: false)
        #expect(outcome == .refused("mcpServers is not an object — leaving the file alone, fix it by hand"))
    }

    @Test("Already registered is a fact, not an error")
    func alreadyRegistered() throws {
        let existing: [String: Any] = ["mcpServers": ["sextant": ["command": "/old/sextant"]]]
        let (json, outcome) = MCPRegistration.merge(existing: existing, client: .claudeCode,
                                                    binary: binary, projectRoot: "/p", force: false)
        if case .alreadyRegistered = outcome {} else { Issue.record("expected alreadyRegistered, got \(outcome)") }
        // And the old entry is kept as it was, rather than half-updated.
        let servers = try #require(json["mcpServers"] as? [String: Any])
        #expect((servers["sextant"] as? [String: Any])?["command"] as? String == "/old/sextant")

        let (forced, forcedOutcome) = MCPRegistration.merge(existing: existing, client: .claudeCode,
                                                            binary: binary, projectRoot: "/p", force: true)
        if case .written = forcedOutcome {} else { Issue.record("--force should rewrite") }
        let updated = try #require(forced["mcpServers"] as? [String: Any])
        #expect((updated["sextant"] as? [String: Any])?["command"] as? String == binary)
    }

    @Test("Each client is written where that client reads")
    func configurationLocations() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(MCPClient.claudeCode.configurationURL(projectRoot: "/p", home: home).path == "/p/.mcp.json")
        // Claude Desktop keeps one list per machine, so the project has to be named in the args —
        // which is why the entry carries `--project` rather than relying on the working directory.
        #expect(MCPClient.claudeDesktop.configurationURL(projectRoot: "/p", home: home).path
                == "/Users/someone/Library/Application Support/Claude/claude_desktop_config.json")
    }

    @Test("Only clients that were verified against the running application are offered")
    func supportedClients() {
        #expect(MCPClient.named("claude-code") != nil)
        #expect(MCPClient.named("claude-desktop") != nil)
        // Not guessed from documentation: VS Code, Cursor and the rest differ in the servers key
        // and the entry shape, and an unlaunched config fails silently.
        #expect(MCPClient.named("cursor") == nil)
        #expect(MCPClient.named("vscode") == nil)
    }
}
