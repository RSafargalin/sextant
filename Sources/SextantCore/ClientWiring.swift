import Foundation

/// What the client was told to run, and whether that thing exists.
///
/// A check-up that only inspects the parts it owns will pass while the tool is unreachable: the
/// index opens, the sources parse, and no client is wired to any of it. That is not hypothetical —
/// the `PreToolUse` hook shipped, went into no settings file for ten days, and the snippet offered
/// for pasting named a binary that did not exist. Nothing in a self-check noticed, because every
/// check was about this process rather than about the wiring around it.
public enum ClientWiring {

    public struct Registration: Sendable, Equatable {
        /// The file the entry was read from, for a message that says where to go and fix it.
        public let source: String
        /// The command as written, exactly.
        public let command: String
        /// The binary the command names, once the arguments are stripped off.
        public let binary: String
        public var binaryExists: Bool {
            FileManager.default.isExecutableFile(atPath: binary)
        }
    }

    /// The MCP server entry for sextant in the project's `.mcp.json`.
    public static func mcpRegistration(projectRoot: String) -> Registration? {
        let file = URL(fileURLWithPath: projectRoot, isDirectory: true).appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers["sextant"] as? [String: Any],
              let command = entry["command"] as? String else { return nil }
        let arguments = (entry["args"] as? [String]) ?? []
        return Registration(source: ".mcp.json",
                            command: ([command] + arguments).joined(separator: " "),
                            binary: command)
    }

    /// Where a client keeps its hooks, nearest first. A project setting overrides the user's, so
    /// the first hit is the one that runs.
    public static func settingsFiles(projectRoot: String) -> [URL] {
        let project = URL(fileURLWithPath: projectRoot, isDirectory: true)
        return [
            project.appendingPathComponent(".claude/settings.local.json"),
            project.appendingPathComponent(".claude/settings.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        ]
    }

    /// The `PreToolUse` hook that runs `sextant hook`, wherever a client keeps it.
    ///
    /// The files are a parameter because the search reaches into the user's home by design — a
    /// hook registered there runs for every project, including this one — and a check that reads
    /// the real home cannot be tested without depending on the machine it runs on.
    public static func hookRegistration(projectRoot: String, in files: [URL]? = nil) -> Registration? {
        for file in files ?? settingsFiles(projectRoot: projectRoot) {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = root["hooks"] as? [String: Any],
                  let events = hooks["PreToolUse"] as? [[String: Any]] else { continue }
            for matcher in events {
                for entry in (matcher["hooks"] as? [[String: Any]]) ?? [] {
                    guard let command = entry["command"] as? String,
                          let binary = sextantHookBinary(inCommand: command) else { continue }
                    return Registration(source: shortHome(file.path), command: command, binary: binary)
                }
            }
        }
        return nil
    }

    /// The binary a hook command runs, when that command is ours: a word whose last path component
    /// is `sextant`, followed later by `hook`. Anything else in the file belongs to someone else
    /// and is left alone.
    static func sextantHookBinary(inCommand command: String) -> String? {
        let words = ShellWords.split(command)
        guard let index = words.firstIndex(where: {
            ($0.split(separator: "/").last.map(String.init) ?? $0) == "sextant"
        }), words.dropFirst(index + 1).contains("hook") else { return nil }
        return words[index]
    }

    private static func shortHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
