import Foundation

/// What a flag takes after it. Every value-taking flag is checked against its kind before a
/// command runs, so a value the command would not understand is refused instead of being
/// replaced by the default.
public enum FlagValue: Sendable, Equatable {
    /// A switch: the flag takes no value.
    case none
    /// Any non-empty text.
    case text
    /// A file-system path, read relative to the working directory of the process that was invoked.
    case path
    /// A whole number no smaller than `minimum`.
    case integer(minimum: Int)
    /// One of a fixed set of words.
    case choice([String])

    /// What the value has to be, in words, for an error message.
    public var expectation: String {
        switch self {
        case .none: return "no value"
        case .text: return "a value"
        case .path: return "a path"
        case .integer(let minimum) where minimum == 1: return "a positive integer"
        case .integer(let minimum) where minimum == 0: return "a non-negative integer"
        case .integer(let minimum): return "an integer of at least \(minimum)"
        case .choice(let words): return "one of: \(words.joined(separator: ", "))"
        }
    }

    /// Why `value` is not acceptable, or nil when it is.
    public func problem(with value: String) -> String? {
        guard !value.isEmpty else { return "is empty; expected \(expectation)" }
        switch self {
        case .none, .text, .path:
            return nil
        case .integer(let minimum):
            guard let number = Int(value) else { return "is not an integer; expected \(expectation)" }
            return number < minimum ? "is out of range; expected \(expectation)" : nil
        case .choice(let words):
            return words.contains(value) ? nil : "is not recognised; expected \(expectation)"
        }
    }
}

/// A command flag: either value-taking (`--project <path>`) or a switch (`--json`).
public struct FlagSpec: Sendable, Equatable {
    public let name: String
    /// What the flag takes after it.
    public let value: FlagValue
    public let summary: String

    public var takesValue: Bool { value != .none }
    /// The value is a file-system path, read relative to the working directory of the process
    /// that was invoked.
    public var takesPath: Bool { value == .path }

    public init(_ name: String, value: FlagValue, _ summary: String) {
        self.name = name
        self.value = value
        self.summary = summary
    }

    public init(_ name: String, takesValue: Bool = false, takesPath: Bool = false, _ summary: String) {
        self.init(name, value: takesPath ? .path : takesValue ? .text : .none, summary)
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
    /// A running `sextant serve` may answer this command for a client. Only read-only queries
    /// about the code qualify: the daemon answers from its own process, so a command that reads
    /// stdin, writes into the project, builds, or serves something itself must run where it was
    /// invoked. Off unless a command says otherwise.
    public let servedByDaemon: Bool

    public init(name: String, argument: String? = nil, summary: String, group: String, flags: [FlagSpec] = [],
                details: [String] = [], servedByDaemon: Bool = false) {
        self.name = name
        self.argument = argument
        self.summary = summary
        self.group = group
        self.flags = flags
        self.details = details
        self.servedByDaemon = servedByDaemon
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
    // MARK: Groups

    static let navigationGroup = "Navigation (syntax, no build required)"
    static let semanticsGroup = "Semantics (index store)"

    /// Commands that answer a question about the code — what an adoption share counts as navigation
    /// through sextant. Setup, help, measurement, building the index and linting are not: `lint`
    /// judges the code rather than finding anything in it.
    public static let navigationCommands: Set<String> = Set(
        commands.filter { [navigationGroup, semanticsGroup].contains($0.group) && !["index", "lint"].contains($0.name) }
            .map(\.name)
    )

    // MARK: Shared flag sets

    static let project = FlagSpec("--project", takesPath: true, "project root (otherwise CLAUDE_PROJECT_DIR or the current directory)")
    static let json = FlagSpec("--json", "structured output instead of text")
    static let scope = FlagSpec("--scope", takesValue: true, "narrow the area to a subdirectory")
    static let maxFiles = FlagSpec("--max-files", value: .integer(minimum: 1),
                                   "how many files to read (default 4000); the answer names what it left out")
    static let apiBudget = FlagSpec("--budget", value: .integer(minimum: 1), "token budget for the surface (unbounded by default)")
    static let exclude = FlagSpec("--exclude", takesValue: true, "glob to leave out; repeatable, replaces the config list")
    static let includeTests = FlagSpec("--include-tests", "include test files")
    static let limit = FlagSpec("--limit", value: .integer(minimum: 1), "how many entries to show")
    /// For refs, defs and callers, where `0` lists no positions and keeps the counts.
    static let referenceLimit = FlagSpec("--limit", value: .integer(minimum: 0),
                                         "how many positions to list per symbol (default 40; 0 lists none, counts stay)")
    static let symbols = FlagSpec("--symbols", value: .integer(minimum: 1),
                                  "how many symbols sharing the name to show (default 10; the rest are counted)")
    static let contextLines = FlagSpec("--context-lines", value: .integer(minimum: 0),
                                       "lines of surrounding source around the declaration (default 0)")
    static let fullPaths = FlagSpec("--full-paths", "full paths instead of shortened ones")
    static let full = FlagSpec("--full", "line by line, with snippets")
    static let compact = FlagSpec("--compact", "compact: a histogram by file")
    static let verify = FlagSpec("--verify", "cross-check semantics against the textual occurrence count")
    static let reindex = FlagSpec("--reindex", "rebuild the index before the query")
    static let indexStore = FlagSpec("--index-store", takesPath: true, "path to an index store")
    static let indexLib = FlagSpec("--index-lib", takesPath: true, "path to libIndexStore.dylib")
    static let derivedData = FlagSpec("--derived-data", takesPath: true,
                                      "Xcode DerivedData directory (default: ~/Library/Developer/Xcode/DerivedData)")
    static let storePolicyFlag = FlagSpec("--store-policy", value: .choice(StorePolicy.allCases.map(\.rawValue)),
                                          "for this command only: \(StorePolicy.known) (see `sextant store`)")

    static var semanticFlags: [FlagSpec] {
        [project, indexStore, indexLib, storePolicyFlag, derivedData, reindex, referenceLimit, symbols, fullPaths, full, compact, verify, json]
    }

    // MARK: Commands

    public static let commands: [CommandSpec] = [
        CommandSpec(
            name: "map", summary: "repository map under a token budget",
            group: navigationGroup,
            flags: [project, FlagSpec("--budget", value: .integer(minimum: 1), "token budget for the map (default 6000)"),
                    FlagSpec("--semantic", "types by usage count (needs an index)"),
                    FlagSpec("--pagerank", "files by centrality (needs an index)"),
                    includeTests, scope, maxFiles, exclude, json],
            details: ["Defaults are taken from .sextant.json."],
            servedByDaemon: true
        ),
        CommandSpec(
            name: "api", summary: "public surface of a package, subdirectory, or type",
            group: navigationGroup,
            flags: [project, FlagSpec("--package", takesValue: true, "package name"),
                    FlagSpec("--type", takesValue: true, "type name — only that type"),
                    apiBudget, scope, maxFiles, exclude, json],
            details: ["A replacement for reading sources: signatures and doc summaries in one call.",
                      "The surface is unbounded by default — a contract cut in silence is not one.",
                      "`--budget <tokens>` bounds it, and the header then says what was left out."],
            servedByDaemon: true
        ),
        CommandSpec(
            name: "search", argument: "<pattern>", summary: "structural search over the AST (a grep replacement)",
            group: navigationGroup,
            flags: [project, scope, maxFiles, exclude, includeTests, limit, json],
            details: ["Metavariables: $X (an expression), variadic $$$. For example 'try? $X.save()'."],
            servedByDaemon: true
        ),
        CommandSpec(
            name: "lint", summary: "structural code-hygiene rules",
            group: navigationGroup,
            flags: [project, FlagSpec("--rules", takesPath: true, "JSON rules file (otherwise the built-in set)"),
                    scope, maxFiles, exclude, includeTests, json],
            servedByDaemon: true
        ),
        CommandSpec(
            name: "changed", summary: "symbol-level git diff: added, removed, or changed signature",
            group: navigationGroup,
            flags: [project, FlagSpec("--from", takesValue: true, "baseline revision (default HEAD)"),
                    FlagSpec("--to", takesValue: true, "second revision; omit to use the working tree"), json],
            details: ["Compares SYMBOLS, not lines: body edits and reformatting do not add noise.",
                      "Swift only. Changed C, C++ and Objective-C files are listed as not compared, never dropped."],
            servedByDaemon: true
        ),

        CommandSpec(
            name: "index", summary: "build an index store (SPM or an app target)",
            group: semanticsGroup,
            flags: [project, FlagSpec("--app", "app target via xcodebuild (covers an xcodeproj)"),
                    FlagSpec("--scheme", takesValue: true, "Xcode scheme (otherwise auto-detected)"),
                    FlagSpec("--destination", takesValue: true, "xcodebuild destination"),
                    FlagSpec("--no-tests", "skip the test targets (a faster build, and their usages go missing)"),
                    FlagSpec("--no-build", "only locate an existing index, do not build")],
            details: [BuildTrust.summary,
                      "A package is built in a tree of its own, `.build/sextant-index`, always with the index",
                      "store on: a second build tree on disk, and a full build the first time.",
                      "Test targets are built into the index. Measured on Alamofire: without them the",
                      "store covers 43 of 98 files and `refs Session` answers 25 instead of 504."]
        ),
        CommandSpec(name: "refs", argument: "<symbol>", summary: "every usage of a symbol",
                    group: semanticsGroup, flags: semanticFlags,
                    details: ["Default when piped (an agent) is a histogram by file; TTY or --full gives line by line."], servedByDaemon: true),
        CommandSpec(name: "defs", argument: "<symbol>", summary: "where a symbol is defined",
                    group: semanticsGroup, flags: semanticFlags, servedByDaemon: true),
        CommandSpec(name: "callers", argument: "<symbol>", summary: "call sites, accounting for protocol dispatch",
                    group: semanticsGroup, flags: semanticFlags,
                    details: ["Types have no call sites — use refs, context, or blast for those."], servedByDaemon: true),
        CommandSpec(name: "callees", argument: "<symbol>", summary: "what a symbol calls (best effort)",
                    group: semanticsGroup, flags: [project, indexStore, indexLib, storePolicyFlag, derivedData, reindex, limit, json], servedByDaemon: true),
        CommandSpec(name: "impls", argument: "<type>", summary: "implementations and subtypes of a protocol or class",
                    group: semanticsGroup, flags: [project, indexStore, indexLib, storePolicyFlag, derivedData, reindex, limit, json], servedByDaemon: true),
        CommandSpec(name: "supertypes", argument: "<type>", summary: "bases and protocols of a type",
                    group: semanticsGroup, flags: [project, indexStore, indexLib, storePolicyFlag, derivedData, reindex, limit, json], servedByDaemon: true),
        CommandSpec(
            name: "hierarchy", argument: "<symbol>", summary: "transitive call graph, as a tree",
            group: semanticsGroup,
            flags: [project, FlagSpec("--callees", "down the call graph (default)"), FlagSpec("--callers", "up to the callers"),
                    FlagSpec("--depth", value: .integer(minimum: 1), "traversal depth (default 3)"), indexStore, indexLib, storePolicyFlag, derivedData, reindex, json],
            servedByDaemon: true
        ),
        CommandSpec(name: "context", argument: "<symbol>", summary: "everything about one symbol in a single query",
                    group: semanticsGroup, flags: [project, indexStore, indexLib, storePolicyFlag, derivedData, reindex, limit, json],
                    details: ["Definition, usages, callers, callees, hierarchy — instead of a series of greps."], servedByDaemon: true),
        CommandSpec(name: "blast", argument: "<symbol>", summary: "impact analysis: what a change would touch",
                    group: semanticsGroup, flags: [project, indexStore, indexLib, storePolicyFlag, derivedData, reindex, json], servedByDaemon: true),
        CommandSpec(name: "body", argument: "<symbol>", summary: "full text of a declaration (signature and body)",
                    group: semanticsGroup,
                    flags: [project, indexStore, indexLib, storePolicyFlag, derivedData, reindex, limit, contextLines, json],
                    details: ["`--context-lines N` adds N lines on each side, marked apart from the declaration."], servedByDaemon: true),
        CommandSpec(name: "construct", argument: "<type>", summary: "construction and injection sites of a type",
                    group: semanticsGroup, flags: [project, indexStore, indexLib, storePolicyFlag, derivedData, reindex, limit, json],
                    details: ["A `Type(` heuristic over usages — not exact semantics."], servedByDaemon: true),

        CommandSpec(name: "mcp", summary: "MCP server (stdio) for an agent",
                    group: "Integration and setup", flags: [project, indexStore, indexLib, storePolicyFlag, derivedData],
                    details: ["Tools: " + MCPTools.names.joined(separator: ", ") + "."]),
        CommandSpec(name: "init", summary: "set up a project: .sextant.json, MCP registration, and a check",
                    group: "Integration and setup",
                    flags: [project, FlagSpec("--force", "overwrite existing files"),
                            FlagSpec("--client", value: .choice(MCPClient.supported.map(\.name)), "MCP client to register with (default claude-code)")],
                    details: ["clients: " + MCPClient.supported.map { $0.name }.joined(separator: ", ") + ".",
                              "Only clients verified against the running application are listed: a config written",
                              "from documentation and never launched fails silently, and the user blames the tool."]),
        CommandSpec(name: "serve", summary: "daemon with a warm index: removes the cold CLI start",
                    group: "Integration and setup", flags: [project, indexStore, indexLib, storePolicyFlag, derivedData],
                    details: ["Clients use it automatically; with no daemon they take the normal path.",
                              "SEXTANT_NO_DAEMON=1 disables any use of the daemon.",
                              "The daemon never builds or sets up (index/init/doctor) — queries only."]),
        CommandSpec(name: "store", argument: "[show | use <policy>]",
                    summary: "index stores in reach, and the policy that decides between them",
                    group: "Integration and setup",
                    flags: [project, indexStore, indexLib, storePolicyFlag, derivedData],
                    details: ["With several usable stores the answer depends on which is read, so the",
                              "choice is a person's: `store use recency` or `store use union`, recorded",
                              "in .sextant.json. Until it is made, semantic commands refuse rather than guess.",
                              "`store` prints what each policy gives, what it does not, and its risk."]),
        CommandSpec(name: "doctor", summary: "self-check of the setup",
                    group: "Integration and setup",
                    flags: [project, FlagSpec("--fix", "build the index if missing or stale"),
                            FlagSpec("--app", "with --fix: build the app target"),
                            FlagSpec("--scheme", takesValue: true, "Xcode scheme for --fix"), indexStore, indexLib, storePolicyFlag, derivedData]),

        CommandSpec(name: "golden", summary: "semantic regression check against a spec",
                    group: "Trust and measurability",
                    flags: [project, FlagSpec("--spec", takesPath: true, "JSON spec of assertions"), indexStore, indexLib, storePolicyFlag, derivedData, json]),
        CommandSpec(name: "bench", summary: "latency (p50/p95), payload proxy, peak RSS",
                    group: "Trust and measurability",
                    flags: [project, FlagSpec("--symbols", takesValue: true, "symbols, comma separated"),
                            FlagSpec("--iterations", value: .integer(minimum: 1), "number of iterations (default 20)"), indexStore, indexLib, storePolicyFlag, derivedData, json],
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
    ///
    /// Single-dash spellings count too. `sextant search -json 'print($$$)'` used to take `-json`
    /// as the pattern and drop the real one, answering "No matches." about the flag's own name —
    /// a confident negative produced by a typo.
    public static func unknownFlags(in arguments: [String], for spec: CommandSpec) -> [String] {
        let known = Set(spec.flags.map(\.name)).union(["--help", "-h"])
        return arguments.filter { argument in
            guard argument.hasPrefix("-"), argument != "-", !known.contains(argument) else { return false }
            // A negative number is a value, not a flag.
            return argument.hasPrefix("--") || Double(argument) == nil
        }
    }

    /// The environment variable that sets the store policy when `--store-policy` is not given.
    public static let storePolicyVariable = "SEXTANT_STORE_POLICY"

    /// Every value a command would not understand, as sentences naming the flag and the value:
    /// a value-taking flag given last or followed by another flag, a value of the wrong kind, and,
    /// for a command that reads index stores, an unknown store policy in the environment. Empty
    /// when the command may run. Checked before a command runs or is forwarded to a daemon, so
    /// a value is refused the same way wherever the command would have been answered.
    ///
    /// An empty `SEXTANT_STORE_POLICY` reads as unset. An unknown one is refused rather than
    /// warned about: the store would otherwise be chosen without the policy its author meant,
    /// and a warning on stderr never reaches an agent reading the answer.
    public static func usageProblems(in arguments: [String], for spec: CommandSpec,
                                     environment: (String) -> String? = { CallerContext.environmentValue($0) }) -> [String] {
        let kinds = Dictionary(spec.flags.filter(\.takesValue).map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        var problems: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard let kind = kinds[argument] else {
                index += 1
                continue
            }
            let next = index + 1 < arguments.endIndex ? arguments[index + 1] : nil
            guard let value = next, !value.hasPrefix("--") else {
                problems.append("\(argument) expects \(kind.expectation), and none was given.")
                index += 1
                continue
            }
            if let problem = kind.problem(with: value) {
                problems.append("\(argument) '\(value)' \(problem).")
            }
            index += 2
        }
        if let policyFlag = spec.flags.first(where: { $0.name == "--store-policy" }), !arguments.contains(policyFlag.name),
           let raw = environment(storePolicyVariable), !raw.isEmpty, let problem = policyFlag.value.problem(with: raw) {
            problems.append("\(storePolicyVariable) '\(raw)' \(problem). Unset it or correct it: "
                            + "no store is read under a policy that was not understood.")
        }
        return problems
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
