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
    /// A directory, read relative to the working directory of the process that was invoked.
    case directory
    /// A directory under the project root, read relative to that root.
    case subdirectory
    /// A whole number no smaller than `minimum`.
    case integer(minimum: Int)
    /// One of a fixed set of words.
    case choice([String])

    /// What the value has to be, in words, for an error message.
    public var expectation: String {
        switch self {
        case .none: return "no value"
        case .text: return "a value"
        case .path, .directory: return "a path"
        case .subdirectory: return "a value"
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
        case .none, .text, .path, .directory, .subdirectory:
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
    public var takesPath: Bool { value == .path || value == .directory }

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
    /// How many positional arguments the command takes: one for a `<name>` argument, none without
    /// an argument, unless the command says otherwise.
    public let positionals: ClosedRange<Int>
    /// Flags of which at most one may be given in a command line: each set contradicts itself.
    public let exclusive: [[String]]
    /// For a command whose first positional argument is a subcommand: how many positional
    /// arguments each subcommand takes after its own name. A subcommand not listed is the
    /// command's own to refuse.
    public let subcommands: [String: ClosedRange<Int>]
    /// The words each positional argument may be, by position — what completion offers there.
    /// Empty for a free argument (a symbol, a pattern), which is completed as a file name.
    public let words: [[String]]

    public init(name: String, argument: String? = nil, summary: String, group: String, flags: [FlagSpec] = [],
                details: [String] = [], servedByDaemon: Bool = false, positionals: ClosedRange<Int>? = nil,
                exclusive: [[String]] = [], subcommands: [String: ClosedRange<Int>] = [:], words: [[String]] = []) {
        self.name = name
        self.argument = argument
        self.summary = summary
        self.group = group
        self.flags = flags
        self.details = details
        self.servedByDaemon = servedByDaemon
        self.positionals = positionals ?? (argument == nil ? 0...0 : 1...1)
        self.exclusive = exclusive
        self.subcommands = subcommands
        self.words = words
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

    static let project = FlagSpec("--project", value: .directory, "project root (otherwise CLAUDE_PROJECT_DIR or the current directory)")
    static let json = FlagSpec("--json", "structured output instead of text")
    static let scope = FlagSpec("--scope", value: .subdirectory, "narrow the area to a subdirectory")
    static let maxFiles = FlagSpec("--max-files", value: .integer(minimum: 1),
                                   "how many files to read, Swift and Objective-C/C/C++ together (default 4000); the answer names what it left out")
    static let apiBudget = FlagSpec("--budget", value: .integer(minimum: 1), "token budget for the surface (unbounded by default; at most \(TokenBudget.maximum))")
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
    static let indexStore = FlagSpec("--index-store", value: .directory, "path to an index store")
    static let indexLib = FlagSpec("--index-lib", takesPath: true, "path to libIndexStore.dylib")
    static let derivedData = FlagSpec("--derived-data", value: .directory,
                                      "Xcode DerivedData directory, or one `xcodebuild -derivedDataPath` built into "
                                      + "(default: SEXTANT_DERIVED_DATA, else ~/Library/Developer/Xcode/DerivedData)")
    static let storePolicyFlag = FlagSpec("--store-policy", value: .choice(StorePolicy.allCases.map(\.rawValue)),
                                          "for this command only: \(StorePolicy.known) (see `sextant store`)")

    /// `--full` and `--compact` choose opposite renderings.
    static let outputModes = ["--full", "--compact"]

    static var semanticFlags: [FlagSpec] {
        [project, indexStore, indexLib, storePolicyFlag, derivedData, reindex, referenceLimit, symbols, fullPaths, full, compact, verify, json]
    }

    // MARK: Commands

    public static let commands: [CommandSpec] = [
        CommandSpec(
            name: "map", summary: "repository map under a token budget",
            group: navigationGroup,
            flags: [project, FlagSpec("--budget", value: .integer(minimum: 1), "token budget for the map (default 6000; at most \(TokenBudget.maximum))"),
                    FlagSpec("--semantic", "types by usage count (needs an index)"),
                    FlagSpec("--pagerank", "files by centrality (needs an index)"),
                    includeTests, scope, maxFiles, exclude, json],
            details: ["Defaults are taken from .sextant.json."],
            servedByDaemon: true, exclusive: [["--semantic", "--pagerank"]]
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
            details: ["Metavariables: $X (an expression, a type, a binding or declaration name, a parameter), "
                      + "variadic $$$. For example 'try? $X.save()', '$X as! $T', 'func $F($$$) { $$$ }'.",
                      "A declaration pattern constrains only what it states: modifiers, attributes, a generic, inheritance "
                      + "or where clause it leaves out may be there or not ('struct $S { $$$ }' finds every struct); those "
                      + "it writes must be there ('public final class $C { $$$ }').",
                      "A metavariable that cannot be bound (in a string literal, in a comment) and a pattern "
                      + "of several statements are refused rather than answered with no matches.",
                      SourceColumn.positionFormat],
            servedByDaemon: true
        ),
        CommandSpec(
            name: "lint", summary: "structural code-hygiene rules",
            group: navigationGroup,
            flags: [project, FlagSpec("--rules", takesPath: true, "JSON rules file (otherwise the built-in set)"),
                    scope, maxFiles, exclude, includeTests, json],
            details: ["A rule's pattern is read as `search` reads one: a declaration pattern constrains only what it states.",
                      SourceColumn.positionFormat],
            servedByDaemon: true
        ),
        CommandSpec(
            name: "changed", summary: "symbol-level git diff: added, removed, or changed signature",
            group: navigationGroup,
            flags: [project, FlagSpec("--from", takesValue: true, "baseline revision (default HEAD)"),
                    FlagSpec("--to", takesValue: true, "second revision; omit to use the working tree"), json],
            details: ["Compares SYMBOLS, not lines: body edits and reformatting do not add noise.",
                      "Covers Swift, Objective-C, C and C++; the last three need the compile flags from `sextant index`.",
                      "A changed file that could not be compared is listed with the reason, never dropped."],
            servedByDaemon: true
        ),

        CommandSpec(
            name: "index", summary: "build an index store (SPM or an app target)",
            group: semanticsGroup,
            flags: [project, FlagSpec("--app", "app target via xcodebuild (covers an xcodeproj)"),
                    FlagSpec("--scheme", takesValue: true, "Xcode scheme (otherwise auto-detected)"),
                    FlagSpec("--destination", takesValue: true, "xcodebuild destination"),
                    FlagSpec("--no-tests", "skip the test targets (a faster build, and their usages go missing)"),
                    FlagSpec("--no-build", "only locate an existing index, do not build"), derivedData],
            details: [BuildTrust.summary,
                      "With --app, xcodebuild builds into --derived-data (or SEXTANT_DERIVED_DATA) when one is",
                      "given — where the store is then looked for — and into Xcode's default location otherwise.",
                      "A package is built in a tree of its own, `.build/sextant-index`, always with the index",
                      "store on: a second build tree on disk, and a full build the first time.",
                      "Test targets are built into the index. Measured on Alamofire: without them the",
                      "store covers 43 of 98 files and `refs Session` answers 25 instead of 504."]
        ),
        CommandSpec(name: "refs", argument: "<symbol>", summary: "every usage of a symbol",
                    group: semanticsGroup, flags: semanticFlags,
                    details: ["Default when piped (an agent) is a histogram by file; TTY or --full gives line by line.",
                              SourceColumn.positionFormat], servedByDaemon: true, exclusive: [outputModes]),
        CommandSpec(name: "defs", argument: "<symbol>", summary: "where a symbol is defined",
                    group: semanticsGroup, flags: semanticFlags, details: [SourceColumn.positionFormat], servedByDaemon: true,
                    exclusive: [outputModes]),
        CommandSpec(name: "callers", argument: "<symbol>", summary: "call sites, accounting for protocol dispatch",
                    group: semanticsGroup, flags: semanticFlags,
                    details: ["Types have no call sites — use refs, context, or blast for those.",
                              SourceColumn.positionFormat], servedByDaemon: true, exclusive: [outputModes]),
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
            servedByDaemon: true, exclusive: [["--callees", "--callers"]]
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
        CommandSpec(name: "version", summary: "print the version", group: "Integration and setup"),
        CommandSpec(name: "store", argument: "[show | use <policy>]",
                    summary: "index stores in reach, and the policy that decides between them",
                    group: "Integration and setup",
                    flags: [project, indexStore, indexLib, storePolicyFlag, derivedData],
                    details: ["With several usable stores the answer depends on which is read, so the",
                              "choice is a person's: `store use recency` or `store use union`, recorded",
                              "in .sextant.json. Until it is made, semantic commands refuse rather than guess.",
                              "`store` prints what each policy gives, what it does not, and its risk."],
                    positionals: 0...2, subcommands: ["show": 0...0, "use": 1...1],
                    words: [["show", "use"], StorePolicy.allCases.map(\.rawValue)]),
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
                              "bash: sextant completion bash > /usr/local/etc/bash_completion.d/sextant"],
                    words: [CompletionScript.Shell.allCases.map(\.rawValue)]),
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
        // A positional argument the command does not take used to be dropped without a word, and
        // `refs a b` answered about `a` alone.
        let positionals = ArgumentParsing.positionals(arguments, valueFlags: Set(kinds.keys))
        if let subcommand = positionals.first, let arity = spec.subcommands[subcommand],
           positionals.count - 1 > arity.upperBound, 1 + arity.upperBound < spec.positionals.upperBound {
            let extra = positionals.dropFirst(1 + arity.upperBound).map { "'\($0)'" }.joined(separator: ", ")
            problems.append(arity.upperBound == 0
                ? "\(subcommand) takes no further argument; got \(extra)."
                : "\(subcommand) takes at most \(arity.upperBound) argument(s); \(extra) would be ignored.")
        } else if positionals.count > spec.positionals.upperBound {
            let extra = positionals.dropFirst(spec.positionals.upperBound).map { "'\($0)'" }.joined(separator: ", ")
            problems.append(spec.positionals.upperBound == 0
                ? "takes no positional argument; got \(extra)."
                : "takes at most \(spec.positionals.upperBound) positional argument(s) (\(spec.argument ?? "")); "
                  + "\(extra) would be ignored.")
        }
        for set in spec.exclusive {
            let given = set.filter(arguments.contains)
            if given.count > 1 { problems.append("\(given.joined(separator: " and ")) cannot be given together.") }
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
        lines.append("")
        lines.append(SourceColumn.positionFormat)
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
