import Foundation

/// A command flag: either value-taking (`--project <path>`) or a switch (`--json`).
public struct FlagSpec: Sendable, Equatable {
    public let name: String
    public let takesValue: Bool
    public let summary: String

    public init(_ name: String, takesValue: Bool = false, _ summary: String) {
        self.name = name
        self.takesValue = takesValue
        self.summary = summary
    }
}

/// Description of a CLI command.
public struct CommandSpec: Sendable {
    public let name: String
    public let argument: String?
    public let summary: String
    public let group: String
    public let flags: [FlagSpec]
    public let details: [String]

    public init(name: String, argument: String? = nil, summary: String, group: String, flags: [FlagSpec] = [], details: [String] = []) {
        self.name = name
        self.argument = argument
        self.summary = summary
        self.group = group
        self.flags = flags
        self.details = details
    }

    public var invocation: String {
        argument.map { "\(name) \($0)" } ?? name
    }
}

/// The single source of truth about commands and their flags: the general help, the
/// per-command help, and flag validation are all built from it. The list of value-taking
/// flags used to be maintained by hand — a forgotten flag turned its own value into a
/// positional argument, and the error surfaced as "symbol not found".
public enum CommandCatalog {
    // MARK: Shared flag sets

    static let project = FlagSpec("--project", takesValue: true, "project root (otherwise CLAUDE_PROJECT_DIR or the current directory)")
    static let json = FlagSpec("--json", "structured output instead of text")
    static let scope = FlagSpec("--scope", takesValue: true, "narrow the area to a subdirectory")
    static let maxFiles = FlagSpec("--max-files", takesValue: true, "limit on Swift files (default 4000)")
    static let exclude = FlagSpec("--exclude", takesValue: true, "glob to leave out; repeatable, replaces the config list")
    static let includeTests = FlagSpec("--include-tests", "include test files")
    static let limit = FlagSpec("--limit", takesValue: true, "how many entries to show")
    static let fullPaths = FlagSpec("--full-paths", "full paths instead of shortened ones")
    static let full = FlagSpec("--full", "line by line, with snippets")
    static let compact = FlagSpec("--compact", "compact: a histogram by file")
    static let verify = FlagSpec("--verify", "cross-check semantics against the textual occurrence count")
    static let reindex = FlagSpec("--reindex", "rebuild the index before the query")
    static let indexStore = FlagSpec("--index-store", takesValue: true, "path to an index store")
    static let indexLib = FlagSpec("--index-lib", takesValue: true, "path to libIndexStore.dylib")

    static var semanticFlags: [FlagSpec] {
        [project, indexStore, indexLib, reindex, limit, fullPaths, full, compact, verify, json]
    }

    // MARK: Commands

    public static let commands: [CommandSpec] = [
        CommandSpec(
            name: "map", summary: "repository map under a token budget",
            group: "Navigation (syntax, no build required)",
            flags: [project, FlagSpec("--budget", takesValue: true, "token budget for the map (default 6000)"),
                    FlagSpec("--semantic", "types by usage count (needs an index)"),
                    FlagSpec("--pagerank", "files by centrality (needs an index)"),
                    includeTests, scope, maxFiles, exclude, json],
            details: ["Defaults are taken from .sextant.json."]
        ),
        CommandSpec(
            name: "api", summary: "public surface of a package, subdirectory, or type",
            group: "Navigation (syntax, no build required)",
            flags: [project, FlagSpec("--package", takesValue: true, "package name"),
                    FlagSpec("--type", takesValue: true, "type name — only that type"),
                    scope, maxFiles, exclude, json],
            details: ["A replacement for reading sources: signatures and doc summaries in one call."]
        ),
        CommandSpec(
            name: "search", argument: "<pattern>", summary: "structural search over the AST (a grep replacement)",
            group: "Navigation (syntax, no build required)",
            flags: [project, scope, maxFiles, exclude, includeTests, limit, json],
            details: ["Metavariables: $X (an expression), variadic $$$. For example 'try? $X.save()'."]
        ),
        CommandSpec(
            name: "lint", summary: "structural code-hygiene rules",
            group: "Navigation (syntax, no build required)",
            flags: [project, FlagSpec("--rules", takesValue: true, "JSON rules file (otherwise the built-in set)"),
                    scope, maxFiles, exclude, includeTests, json]
        ),
        CommandSpec(
            name: "changed", summary: "symbol-level git diff: added, removed, or changed signature",
            group: "Navigation (syntax, no build required)",
            flags: [project, FlagSpec("--from", takesValue: true, "baseline revision (default HEAD)"),
                    FlagSpec("--to", takesValue: true, "second revision; omit to use the working tree"), json],
            details: ["Compares SYMBOLS, not lines: body edits and reformatting do not add noise.",
                      "Swift only. Changed C, C++ and Objective-C files are listed as not compared, never dropped."]
        ),

        CommandSpec(
            name: "index", summary: "build an index store (SPM or an app target)",
            group: "Semantics (index store)",
            flags: [project, FlagSpec("--app", "app target via xcodebuild (covers an xcodeproj)"),
                    FlagSpec("--scheme", takesValue: true, "Xcode scheme (otherwise auto-detected)"),
                    FlagSpec("--destination", takesValue: true, "xcodebuild destination"),
                    FlagSpec("--no-build", "only locate an existing index, do not build")],
            details: ["index EXECUTES the project's manifest and build — run it only on code you trust."]
        ),
        CommandSpec(name: "refs", argument: "<symbol>", summary: "every usage of a symbol",
                    group: "Semantics (index store)", flags: semanticFlags,
                    details: ["Default when piped (an agent) is a histogram by file; TTY or --full gives line by line."]),
        CommandSpec(name: "defs", argument: "<symbol>", summary: "where a symbol is defined",
                    group: "Semantics (index store)", flags: semanticFlags),
        CommandSpec(name: "callers", argument: "<symbol>", summary: "call sites, accounting for protocol dispatch",
                    group: "Semantics (index store)", flags: semanticFlags,
                    details: ["Types have no call sites — use refs, context, or blast for those."]),
        CommandSpec(name: "callees", argument: "<symbol>", summary: "what a symbol calls (best effort)",
                    group: "Semantics (index store)", flags: [project, indexStore, indexLib, reindex, limit, json]),
        CommandSpec(name: "impls", argument: "<type>", summary: "implementations and subtypes of a protocol or class",
                    group: "Semantics (index store)", flags: [project, indexStore, indexLib, reindex, limit, json]),
        CommandSpec(name: "supertypes", argument: "<type>", summary: "bases and protocols of a type",
                    group: "Semantics (index store)", flags: [project, indexStore, indexLib, reindex, limit, json]),
        CommandSpec(
            name: "hierarchy", argument: "<symbol>", summary: "transitive call graph, as a tree",
            group: "Semantics (index store)",
            flags: [project, FlagSpec("--callees", "down the call graph (default)"), FlagSpec("--callers", "up to the callers"),
                    FlagSpec("--depth", takesValue: true, "traversal depth (default 3)"), indexStore, indexLib, reindex, json]
        ),
        CommandSpec(name: "context", argument: "<symbol>", summary: "everything about one symbol in a single query",
                    group: "Semantics (index store)", flags: [project, indexStore, indexLib, reindex, limit, json],
                    details: ["Definition, usages, callers, callees, hierarchy — instead of a series of greps."]),
        CommandSpec(name: "blast", argument: "<symbol>", summary: "impact analysis: what a change would touch",
                    group: "Semantics (index store)", flags: [project, indexStore, indexLib, reindex, json]),
        CommandSpec(name: "body", argument: "<symbol>", summary: "full text of a declaration (signature and body)",
                    group: "Semantics (index store)", flags: [project, indexStore, indexLib, reindex, limit, json]),
        CommandSpec(name: "construct", argument: "<type>", summary: "construction and injection sites of a type",
                    group: "Semantics (index store)", flags: [project, indexStore, indexLib, reindex, limit, json],
                    details: ["A `Type(` heuristic over usages — not exact semantics."]),

        CommandSpec(name: "mcp", summary: "MCP server (stdio) for an agent",
                    group: "Integration and setup", flags: [project, indexStore, indexLib],
                    details: ["Tools: " + MCPTools.names.joined(separator: ", ") + "."]),
        CommandSpec(name: "init", summary: "set up a project: .sextant.json, MCP registration, and a check",
                    group: "Integration and setup",
                    flags: [project, FlagSpec("--force", "overwrite existing files"),
                            FlagSpec("--client", takesValue: true, "MCP client to register with (default claude-code)")],
                    details: ["clients: " + MCPClient.supported.map { $0.name }.joined(separator: ", ") + ".",
                              "Only clients verified against the running application are listed: a config written",
                              "from documentation and never launched fails silently, and the user blames the tool."]),
        CommandSpec(name: "serve", summary: "daemon with a warm index: removes the cold CLI start",
                    group: "Integration and setup", flags: [project, indexStore, indexLib],
                    details: ["Clients use it automatically; with no daemon they take the normal path.",
                              "SEXTANT_NO_DAEMON=1 disables any use of the daemon.",
                              "The daemon never builds or sets up (index/init/doctor) — queries only."]),
        CommandSpec(name: "doctor", summary: "self-check of the setup",
                    group: "Integration and setup",
                    flags: [project, FlagSpec("--fix", "build the index if missing or stale"),
                            FlagSpec("--app", "with --fix: build the app target"),
                            FlagSpec("--scheme", takesValue: true, "Xcode scheme for --fix"), indexStore, indexLib]),

        CommandSpec(name: "golden", summary: "semantic regression check against a spec",
                    group: "Trust and measurability",
                    flags: [project, FlagSpec("--spec", takesValue: true, "JSON spec of assertions"), indexStore, indexLib, json]),
        CommandSpec(name: "bench", summary: "latency (p50/p95), payload proxy, peak RSS",
                    group: "Trust and measurability",
                    flags: [project, FlagSpec("--symbols", takesValue: true, "symbols, comma separated"),
                            FlagSpec("--iterations", takesValue: true, "number of iterations (default 20)"), indexStore, indexLib, json],
                    details: ["payload is compact JSON as a RELATIVE proxy for volume, NOT tokens."]),
        CommandSpec(name: "adoption", summary: "how much code navigation went through sextant, not grep",
                    group: "Trust and measurability",
                    flags: [project, json,
                            FlagSpec("--show-queries", "print the search patterns themselves (they stay local)")],
                    details: ["reads this project's session transcripts; only the tool name and its query are looked at.",
                              "queries are reduced to a shape (identifier, phrase, …) and NOT stored or printed",
                              "unless --show-queries is given. Nothing is sent anywhere."]),
        CommandSpec(name: "completion", argument: "<shell>",
                    summary: "print a shell completion script (zsh or bash)",
                    group: "Integration and setup",
                    details: ["generated from this catalog, so a new command cannot fall out of completion.",
                              "zsh:  sextant completion zsh > \"${fpath[1]}/_sextant\"",
                              "bash: sextant completion bash > /usr/local/etc/bash_completion.d/sextant"]),
        CommandSpec(name: "hook", summary: "record one tool-use event (for a client's PreToolUse hook)",
                    group: "Trust and measurability",
                    flags: [project, FlagSpec("--install", "print how to install it, and what it writes")],
                    details: ["reads the event on stdin; writes an act and a query SHAPE, never the query,",
                              "the command, the path or the project. Silent and exit 0 on anything unexpected."])
    ]

    public static func command(named name: String) -> CommandSpec? {
        commands.first { $0.name == name }
    }

    /// Every flag that consumes the next token as its value — derived from the catalog rather
    /// than maintained by hand.
    public static var valueFlags: Set<String> {
        Set(commands.flatMap { $0.flags }.filter(\.takesValue).map(\.name))
    }

    /// Flags a command does not declare. `--help` and `-h` are accepted everywhere.
    public static func unknownFlags(in arguments: [String], for spec: CommandSpec) -> [String] {
        let known = Set(spec.flags.map(\.name)).union(["--help", "-h"])
        return arguments.filter { $0.hasPrefix("--") && !known.contains($0) }
    }

    /// The closest known flag by spelling — used to suggest a correction for a typo.
    public static func closestFlag(to flag: String, in spec: CommandSpec) -> String? {
        spec.flags.map(\.name)
            .map { (name: $0, distance: editDistance($0, flag)) }
            .filter { $0.distance <= 3 }
            .min { $0.distance < $1.distance }?.name
    }

    /// Help for a single command.
    public static func help(for spec: CommandSpec) -> String {
        var lines = ["sextant \(spec.invocation) — \(spec.summary)"]
        if !spec.details.isEmpty {
            lines.append("")
            spec.details.forEach { lines.append("  \($0)") }
        }
        if !spec.flags.isEmpty {
            lines.append("")
            lines.append("Flags:")
            let width = spec.flags.map { $0.name.count + ($0.takesValue ? 6 : 0) }.max() ?? 0
            for flag in spec.flags {
                let invocation = flag.name + (flag.takesValue ? " <val>" : "")
                lines.append("  \(invocation.padding(toLength: max(width, invocation.count), withPad: " ", startingAt: 0))  \(flag.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// General help: commands grouped by section.
    public static func overview() -> String {
        var lines: [String] = []
        var seenGroups: [String] = []
        for spec in commands where !seenGroups.contains(spec.group) { seenGroups.append(spec.group) }

        let width = commands.map { $0.invocation.count }.max() ?? 0
        for group in seenGroups {
            lines.append("")
            lines.append("\(group):")
            for spec in commands where spec.group == group {
                let invocation = spec.invocation.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("  \(invocation)  \(spec.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Levenshtein distance — for the "did you mean" suggestion.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs), right = Array(rhs)
        var previous = Array(0...right.count)
        for i in 1...max(left.count, 1) where !left.isEmpty {
            var current = [i] + Array(repeating: 0, count: right.count)
            for j in 1...max(right.count, 1) where !right.isEmpty {
                current[j] = left[i - 1] == right[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            previous = current
        }
        return previous[right.count]
    }
}
