import Foundation
import Testing

/// The Claude Code plugin is three JSON files pointing at two shell scripts, and nothing in a
/// build reads any of them: a renamed script or a typo in a path produces a plugin that installs
/// cleanly and then does nothing, which is the failure this repository keeps coming back to.
///
/// So the manifests are checked here — that they parse, that they agree with each other, and that
/// every path they name is an executable file.
@Suite("Claude Code plugin manifests")
struct PluginManifestTests {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static var pluginRoot: URL { repositoryRoot.appendingPathComponent("plugins/sextant") }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try #require(try? Data(contentsOf: url), "missing file: \(url.path)")
        let object = try? JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any], "not a JSON object: \(url.path)")
    }

    /// The plugin root as the client resolves it, so a command written against
    /// `${CLAUDE_PLUGIN_ROOT}` can be checked against the working tree. Quotes are dropped the way
    /// a shell drops them.
    private func resolve(command: String) -> String {
        command
            .replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: Self.pluginRoot.path)
            .replacingOccurrences(of: "\"", with: "")
    }

    @Test("the marketplace names a plugin directory that holds a manifest")
    func marketplacePointsAtThePlugin() throws {
        let marketplace = try json(at: Self.repositoryRoot.appendingPathComponent(".claude-plugin/marketplace.json"))
        let plugins = try #require(marketplace["plugins"] as? [[String: Any]], "plugins must be an array")
        let entry = try #require(plugins.first { $0["name"] as? String == "sextant" },
                                 "the marketplace must list the sextant plugin")

        let source = try #require(entry["source"] as? String, "the source must be a relative path")
        #expect(source.hasPrefix("./"), "a relative source must start with ./ — \(source)")

        let directory = Self.repositoryRoot.appendingPathComponent(String(source.dropFirst(2)))
        let manifest = directory.appendingPathComponent(".claude-plugin/plugin.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path),
                "the source names \(directory.path), which holds no plugin manifest")

        // The name is public and, once published, permanent: an entry that disagrees with the
        // manifest installs under one name and namespaces its commands under another.
        let plugin = try json(at: manifest)
        #expect(plugin["name"] as? String == entry["name"] as? String)
    }

    @Test("the MCP server names an executable launcher")
    func mcpServerLauncherExists() throws {
        let mcp = try json(at: Self.pluginRoot.appendingPathComponent(".mcp.json"))
        let servers = try #require(mcp["mcpServers"] as? [String: Any])
        let sextant = try #require(servers["sextant"] as? [String: Any], "the server must be called sextant")
        let command = resolve(command: try #require(sextant["command"] as? String))

        #expect(FileManager.default.isExecutableFile(atPath: command),
                "the plugin starts \(command), which is not an executable file")
    }

    /// The adoption hook runs before every tool call and starts writing the moment it is
    /// registered, so it stays a decision the user makes with `hook --install` rather than one an
    /// install makes for them. A plugin that ships it would be making it.
    @Test("the plugin registers no hooks")
    func pluginShipsNoHooks() throws {
        let hooks = Self.pluginRoot.appendingPathComponent("hooks")
        #expect(!FileManager.default.fileExists(atPath: hooks.path),
                "the plugin must not register hooks — \(hooks.path) exists")

        let manifest = try json(at: Self.pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"))
        #expect(manifest["hooks"] == nil, "the manifest must declare no hooks")
    }

    /// A skill without front matter is not loaded, and the failure is silent — the agent simply
    /// never learns when to ask the index instead of grepping.
    @Test("the skill carries front matter with a name and a description")
    func skillHasFrontMatter() throws {
        let skill = Self.pluginRoot.appendingPathComponent("skills/code-navigation/SKILL.md")
        let text = try #require(try? String(contentsOf: skill, encoding: .utf8), "missing \(skill.path)")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.first == "---", "the file must open with front matter")
        let closing = try #require(lines.dropFirst().firstIndex(of: "---"), "the front matter is not closed")
        let header = lines[1..<closing]
        #expect(header.contains { $0.hasPrefix("name:") })
        #expect(header.contains { $0.hasPrefix("description:") })
    }
}
