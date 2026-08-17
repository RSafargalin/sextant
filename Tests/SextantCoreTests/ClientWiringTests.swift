import Foundation
import Testing
@testable import SextantCore

/// The setup a check-up used to skip entirely: what the client was told to run.
///
/// Every check `doctor` made was about this process — sources parse, store opens, library found —
/// and all of them passed for ten days while the hook sat in no settings file at all and the
/// snippet offered for pasting named a binary that did not exist. A green check-up that says
/// nothing about reachability is the same failure shape as an empty answer with no warning.
@Suite("Client wiring")
struct ClientWiringTests {

    private func project(_ build: (URL) throws -> Void) rethrows -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-wiring-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"),
                                                 withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ object: [String: Any], to url: URL) {
        let data = try? JSONSerialization.data(withJSONObject: object)
        try? data?.write(to: url)
    }

    @Test("A registration that names a missing binary is not a registration that works")
    func missingBinaryIsVisible() throws {
        let root = project { root in
            write(["mcpServers": ["sextant": ["command": "/nowhere/sextant", "args": ["mcp"]]]],
                  to: root.appendingPathComponent(".mcp.json"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let registration = try #require(ClientWiring.mcpRegistration(projectRoot: root.path))
        #expect(registration.binary == "/nowhere/sextant")
        #expect(!registration.binaryExists)

        // And a real one is recognised as real, or the check above would pass on everything.
        let real = project { root in
            write(["mcpServers": ["sextant": ["command": "/bin/ls", "args": ["mcp"]]]],
                  to: root.appendingPathComponent(".mcp.json"))
        }
        defer { try? FileManager.default.removeItem(at: real) }
        #expect(ClientWiring.mcpRegistration(projectRoot: real.path)?.binaryExists == true)
    }

    @Test("The hook is found where a client actually keeps it, and only when it is ours")
    func findsOurHook() throws {
        let root = project { root in
            write(["hooks": ["PreToolUse": [
                ["matcher": "Bash", "hooks": [["type": "command", "command": "somebody-elses-tool --check"]]],
                ["matcher": "*", "hooks": [["type": "command", "command": "/opt/bin/sextant hook"]]]
            ]]], to: root.appendingPathComponent(".claude/settings.json"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = [root.appendingPathComponent(".claude/settings.json")]
        let hook = try #require(ClientWiring.hookRegistration(projectRoot: root.path, in: settings))
        #expect(hook.binary == "/opt/bin/sextant")
        #expect(hook.source.hasSuffix("settings.json"))
    }

    /// The user's own `~/.claude/settings.json` is searched on purpose: a hook registered there
    /// runs for every project, and looking only at the project would call it missing.
    @Test("The search reaches the user's settings, not only the project's")
    func searchesTheUsersSettings() {
        let files = ClientWiring.settingsFiles(projectRoot: "/tmp/whatever")
        #expect(files.contains { $0.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path) })
        #expect(files.contains { $0.path.hasPrefix("/tmp/whatever") })
    }

    @Test("Someone else's hooks are left alone, and an absent hook is absent, not broken")
    func ignoresForeignHooks() throws {
        let root = project { root in
            write(["hooks": ["PreToolUse": [
                ["matcher": "*", "hooks": [["type": "command", "command": "prettier --write"]]]
            ]]], to: root.appendingPathComponent(".claude/settings.json"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = [root.appendingPathComponent(".claude/settings.json")]
        #expect(ClientWiring.hookRegistration(projectRoot: root.path, in: settings) == nil)

        // A command that mentions the tool without running the hook is not our hook either.
        #expect(ClientWiring.sextantHookBinary(inCommand: "echo sextant is nice") == nil)
        #expect(ClientWiring.sextantHookBinary(inCommand: "/usr/local/bin/sextant hook") == "/usr/local/bin/sextant")
        #expect(ClientWiring.sextantHookBinary(inCommand: "sextant hook") == "sextant")
    }
}
