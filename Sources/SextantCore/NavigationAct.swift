import Foundation

/// What an agent did when it went looking for code.
///
/// Adoption is a share, and a share needs a denominator this tool cannot see: the searches that
/// went somewhere else. Counting only its own calls would answer "how often was sextant used",
/// which rises just as well when the same question is asked five times.
public enum NavigationAct: String, Sendable, Codable {
    /// A question answered by sextant — the numerator.
    case sextant
    /// A text search over the sources: what sextant exists to replace.
    case textSearch
    /// Reading a source file whole, to find something in it.
    case fileRead
    /// Everything else — running a build, editing, listing a directory. Not navigation, and
    /// counting it would flatter the share.
    case other

    /// Classifies one tool call as a single act. `command` is the shell command for `Bash`, the
    /// pattern for a search tool, the path for a read. A shell line that ran several kinds of act is
    /// named by the weightiest — sextant, then a search, then a read; `events` lists them all.
    public static func of(tool: String, command: String?) -> NavigationAct {
        if isSextantTool(tool) { return tool.hasSuffix("__lint") ? .other : .sextant }
        switch tool {
        case "Grep", "Glob": return .textSearch
        case "Read": return isSource(command) ? .fileRead : .other
        case "Bash": return ofShell(command ?? "").act
        default: return .other
        }
    }

    /// The one field of a tool call's input that classification needs: the pattern of a search, the
    /// command of a shell call, the path of a read. Anything else in the input — file contents, an
    /// edit's replacement text, a prompt — is never read.
    public static func query(tool: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if isSextantTool(tool) { return input["pattern"] as? String }
        switch tool {
        case "Grep", "Glob": return input["pattern"] as? String
        case "Read": return input["file_path"] as? String
        case "Bash": return input["command"] as? String
        default: return nil
        }
    }

    /// The acts of one tool call, each kind at most once, in the order the call ran them; empty for
    /// a call that is not navigation. A shell line can run several: `sextant search X; grep -rn X
    /// Sources` asked us and searched past us, and both are counted — the answer in the numerator,
    /// the search in the denominator, and the answer marked `crossChecked`.
    ///
    /// Each act carries the shape of what was asked and, for a text search only, the text searched
    /// for, which the caller keeps or drops. A shell search is shaped by its pattern, not by the
    /// command line carrying it; a read is a path; a sextant answer is shaped by its pattern when an
    /// MCP tool takes one, and by nothing otherwise. A shell act names the directory it was about
    /// when the line moved it: by `cd` before it, and for sextant also by `--project` (the agent's
    /// shell sets no `CLAUDE_PROJECT_DIR`, so sextant answers for the directory it runs in). A
    /// relative path is relative to the directory the call was made from.
    ///
    /// The `Grep` and `Glob` tools are held to the rule their shell counterparts are: a search
    /// limited to files other than sources (`glob: "*.md"`, `path: "docs/a.md"`, `type: "md"`,
    /// `**/*.md`) is not a search of the sources.
    public static func events(tool: String, input: [String: Any]?) -> [NavigationEvent] {
        let query = query(tool: tool, input: input)
        if tool == "Bash" {
            let shell = ofShell(query ?? "")
            return shell.acts.map { act in
                switch act {
                case .sextant:
                    return NavigationEvent(act: act, shape: nil, searched: nil, channel: .cli,
                                           crossChecked: shell.acts.contains(.textSearch), project: shell.directories[act])
                case .textSearch:
                    let searched = shell.search.flatMap { parts(ofSearch: $0).pattern }
                    return NavigationEvent(act: act, shape: searched.map(QueryShape.of), searched: searched, channel: nil,
                                           project: shell.directories[act])
                case .fileRead, .other:
                    return NavigationEvent(act: act, shape: .path, searched: nil, channel: nil, project: shell.directories[act])
                }
            }
        }
        switch of(tool: tool, command: query) {
        case .sextant:
            return [NavigationEvent(act: .sextant, shape: query.map(QueryShape.of), searched: nil, channel: .mcp)]
        case .textSearch where searchToolSearchesSources(tool: tool, input: input):
            return [NavigationEvent(act: .textSearch, shape: query.map(QueryShape.of), searched: query, channel: nil)]
        case .fileRead:
            return [NavigationEvent(act: .fileRead, shape: .path, searched: nil, channel: nil)]
        case .textSearch, .other:
            return []
        }
    }

    /// The source-language types a `type` filter of a search can name.
    private static let sourceTypes: Set<String> = ["swift", "c", "cpp", "objc", "objcpp", "h"]

    private static func searchToolSearchesSources(tool: String, input: [String: Any]?) -> Bool {
        let input = input ?? [:]
        if tool == "Glob" { return (input["pattern"] as? String).map(mayNameSource) ?? true }
        if let type = input["type"] as? String { return sourceTypes.contains(type) }
        if let glob = input["glob"] as? String { return mayNameSource(glob) }
        if let path = input["path"] as? String { return mayNameSource(path) }
        return true
    }

    /// Which way a sextant answer was asked for. Meaningful only for `.sextant`.
    public static func channel(ofTool tool: String) -> NavigationChannel {
        isSextantTool(tool) ? .mcp : .cli
    }

    /// An MCP tool served by sextant: `mcp__sextant__<tool>` when the server is registered
    /// directly (as `sextant`, or `sextant-…` / `sextant_…`), `mcp__plugin_<plugin>_sextant__<tool>`
    /// when it comes bundled in a plugin.
    static func isSextantTool(_ tool: String) -> Bool {
        guard tool.hasPrefix("mcp__") else { return false }
        let qualified = tool.dropFirst("mcp__".count)
        guard let end = qualified.range(of: "__") else { return false }
        let server = qualified[..<end.lowerBound]
        return server == "sextant" || server.hasPrefix("sextant-") || server.hasPrefix("sextant_")
            || (server.hasPrefix("plugin_") && server.hasSuffix("_sextant"))
    }

    /// Shell tools that search file *contents* — what the `Grep` tool becomes when a client routes
    /// it through `Bash`.
    static let contentSearchTools = ["grep", "egrep", "fgrep", "rg", "ag", "ack", "ripgrep", "ugrep"]

    /// The shell tool that finds files *by name*. It is here for one reason: it is what the `Glob`
    /// tool becomes on native macOS and Linux builds, and `Glob` is counted above. The same act has
    /// to weigh the same whichever way the client delivers it, or the metric moves on its own every
    /// time a client changes how it runs a search — which is how this list came to be wrong.
    ///
    /// Bare `find` and `ls` stay out, as they always have: typed by hand they are as often about
    /// build output as about code, and sextant does not replace them.
    static let fileSearchTools = ["bfs"]

    /// A shell line counts by the commands it runs, never by words that merely appear in it.
    ///
    /// - sextant counts when it runs one of `CommandCatalog.navigationCommands`, and not for its
    ///   help; `--version`, `hook`, `init`, `index` and the like are not navigation. A path that
    ///   happens to contain `sextant` (`cd ~/Tools/sextant`) is not a call.
    /// - a search tool counts when it searches files: first in its pipeline, fed file names by
    ///   `xargs`, run by `find -exec`, or reading a pipe from a command that prints sources or lists
    ///   them (`cat A.swift | grep`, `git ls-files | grep`). Downstream of any other command it
    ///   filters that command's output — `swift build | grep error`, `sextant api | grep save` — and
    ///   that is not a search of the sources. `git grep` counts as a search.
    /// - a search whose every named target is a file other than a source — `grep -n X docs/a.md`,
    ///   `rg -g '*.md' X` — is not a search of the sources, the way a `Read` of a README is not a
    ///   read of one. A directory or no target at all is taken to be the sources. A target that is a
    ///   variable set earlier in the line (`L=run.log; grep x $L`, `for f in *.md; do grep x $f`) is
    ///   judged by its value.
    /// - a source file printed by `cat`, `head`, `tail`, `nl`, `bat` or `sed` (not `sed -i`) is a
    ///   read, the same act as the `Read` tool — first in its pipeline, like a search, and only when
    ///   the output comes back rather than going to a file (`cat > A.swift <<EOF` writes one).
    /// - each kind of act a line runs is one act of the call — `sextant refs X && grep -rn X .` is
    ///   an answer and a search. A search downstream of our answer (`sextant api | grep Y`) only
    ///   narrows it, by the rule above. A read whose output feeds a search (`cat A.swift | grep x`)
    ///   is that search, not a read as well.
    static func ofShell(_ line: String) -> ShellNavigation {
        var found: [(act: NavigationAct, command: Int, directory: String?)] = []
        var navigation = ShellNavigation()
        var upstream: Invocation?
        var variables: [String: [String]] = [:]
        var directory: String?
        for (position, command) in ShellCommand.commands(in: line).enumerated() {
            recordVariables(of: command.words, into: &variables)
            let invoked = invocation(of: command.words)
            let fedSources = command.readsPipe && upstream.map(printsSources) == true
            upstream = invoked
            guard let invoked else { continue }
            if invoked.name == "cd" {
                // `cd -` returns to a directory this line does not know; the line's place is left as it was.
                if invoked.arguments.first == "-" { continue }
                let target = invoked.arguments.first { !$0.hasPrefix("-") } ?? "~"
                directory = joined(directory, expanding(target, variables).first ?? target)
                continue
            }
            if invoked.name == "sextant" {
                if let subcommand = invoked.arguments.first, CommandCatalog.navigationCommands.contains(subcommand),
                   !invoked.arguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
                    let explicit = projectArgument(invoked.arguments).map { expanding($0, variables).first ?? $0 }
                    found.append((.sextant, position, explicit.map { joined(directory, $0) } ?? directory))
                }
                continue
            }
            if let words = searchWords(of: invoked, readsPipe: command.readsPipe && !fedSources),
               searchesSources(words, variables: variables) {
                if navigation.search == nil { navigation.search = words }
                if fedSources { found.removeAll { $0.act == .fileRead && $0.command == position - 1 } }
                found.append((.textSearch, position, directory))
            }
            if !command.readsPipe, !command.writesFile, readsSource(invoked) { found.append((.fileRead, position, directory)) }
        }
        for entry in found where !navigation.acts.contains(entry.act) {
            navigation.acts.append(entry.act)
            navigation.directories[entry.act] = entry.directory
        }
        return navigation
    }

    /// `path` taken from `base`: as it is when absolute or from home, or when there is no base.
    private static func joined(_ base: String?, _ path: String) -> String {
        guard let base, !path.hasPrefix("/"), !path.hasPrefix("~") else { return path }
        return base + "/" + path
    }

    /// The value of `--project` (`--project X` or `--project=X`), when given.
    private static func projectArgument(_ arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: "--project"), index + 1 < arguments.count { return arguments[index + 1] }
        return arguments.first { $0.hasPrefix("--project=") }.map { String($0.dropFirst("--project=".count)) }
    }

    /// Values a command gives to variables: a command of bare assignments (`L=run.log`), or the list
    /// of a `for` loop (`for f in a.md b.md`).
    private static func recordVariables(of words: [String], into variables: inout [String: [String]]) {
        if words.count >= 3, words[0] == "for", words[2] == "in" {
            variables[words[1]] = Array(words.dropFirst(3))
            return
        }
        guard !words.isEmpty, words.allSatisfy(isAssignment) else { return }
        for word in words {
            guard let equals = word.firstIndex(of: "=") else { continue }
            variables[String(word[..<equals])] = [String(word[word.index(after: equals)...])]
        }
    }

    /// A word with the variables set in the line put in: `$NAME` or `${NAME}` anywhere in it
    /// (`$SP/fixture`). A variable holding several values (a `for` list) gives a word for each when it
    /// is the whole word, and its first value inside a longer one. Unknown variables stay as written.
    private static func expanding(_ target: String, _ variables: [String: [String]]) -> [String] {
        guard target.contains("$") else { return [target] }
        var whole = target.dropFirst()
        if whole.hasPrefix("{"), whole.hasSuffix("}") { whole = whole.dropFirst().dropLast() }
        if target.hasPrefix("$"), let values = variables[String(whole)] { return values }

        var result = ""
        var rest = target[...]
        while let dollar = rest.firstIndex(of: "$") {
            result += rest[..<dollar]
            var cursor = rest.index(after: dollar)
            let braced = cursor < rest.endIndex && rest[cursor] == "{"
            if braced { cursor = rest.index(after: cursor) }
            let nameEnd = rest[cursor...].firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? rest.endIndex
            let name = String(rest[cursor..<nameEnd])
            var end = nameEnd
            if braced {
                guard end < rest.endIndex, rest[end] == "}" else { return [target] }
                end = rest.index(after: end)
            }
            guard !name.isEmpty, let value = variables[name]?.first else { return [target] }
            result += value
            rest = rest[end...]
        }
        return [result + rest]
    }

    /// Shell commands that print a file, as an agent reads one through `Bash`.
    static let fileReaders: Set<String> = ["cat", "head", "tail", "nl", "bat", "sed"]

    private static func readsSource(_ invoked: Invocation) -> Bool {
        guard fileReaders.contains(invoked.name) else { return false }
        if invoked.name == "sed", invoked.arguments.contains(where: { $0.hasPrefix("-i") || $0.hasPrefix("--in-place") }) {
            return false
        }
        return invoked.arguments.contains { !$0.hasPrefix("-") && isSource($0) }
    }

    /// A command whose output is the sources themselves or a list of them.
    private static func printsSources(_ invoked: Invocation) -> Bool {
        if readsSource(invoked) { return true }
        if invoked.name == "git" { return gitSubcommand(invoked.arguments).first == "ls-files" }
        return ["rg", "ripgrep"].contains(invoked.name) && invoked.arguments.contains("--files")
    }

    /// git's arguments from its subcommand on, past the options that precede it.
    private static func gitSubcommand(_ arguments: [String]) -> ArraySlice<String> {
        var rest = arguments[...]
        while let word = rest.first, word.hasPrefix("-") {
            rest = rest.dropFirst(["-C", "-c", "--git-dir", "--work-tree"].contains(word) ? 2 : 1)
        }
        return rest
    }

    /// The search tool and its arguments, when the command is a search of files.
    private static func searchWords(of invoked: Invocation, readsPipe: Bool) -> [String]? {
        guard !readsPipe || invoked.viaXargs else { return nil }
        if contentSearchTools.contains(invoked.name) || fileSearchTools.contains(invoked.name) {
            return [invoked.name] + invoked.arguments
        }
        if invoked.name == "git" {
            let rest = gitSubcommand(invoked.arguments)
            if rest.first == "grep" { return Array(rest) }
        }
        if invoked.name == "find",
           let exec = invoked.arguments.firstIndex(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }),
           exec + 1 < invoked.arguments.count {
            let tool = fileName(invoked.arguments[exec + 1])
            if contentSearchTools.contains(tool) {
                return [tool] + invoked.arguments[(exec + 2)...].prefix { $0 != ";" && $0 != "+" }
            }
        }
        return nil
    }

    private struct Invocation {
        let name: String
        let arguments: [String]
        let viaXargs: Bool
    }

    /// Commands that run the command named after them, with the flags that take a value and the
    /// operands they consume before it.
    private static let wrappers: [String: (valueFlags: Set<String>, operands: Int)] = [
        "env": (["-u"], 0),
        "command": ([], 0),
        "nohup": ([], 0),
        "time": ([], 0),
        "sudo": (["-u", "-g"], 0),
        "nice": (["-n"], 0),
        "timeout": (["-s", "-k"], 1),
        "xargs": (["-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a"], 0),
    ]

    /// Reserved words that open or continue a compound command; the command they introduce follows.
    private static let reservedWords: Set<String> = ["!", "{", "}", "do", "done", "then", "else", "elif", "fi",
                                                     "if", "while", "until"]

    /// The program a simple command runs, past reserved words, variable assignments and wrappers, by
    /// its file name. `command -v` looks a program up instead of running it.
    private static func invocation(of words: [String]) -> Invocation? {
        var rest = words[...]
        var viaXargs = false
        while let first = rest.first {
            if isAssignment(first) || reservedWords.contains(first) {
                rest = rest.dropFirst()
                continue
            }
            let name = fileName(first)
            guard let wrapper = wrappers[name] else {
                return Invocation(name: name, arguments: Array(rest.dropFirst()), viaXargs: viaXargs)
            }
            if name == "xargs" { viaXargs = true }
            rest = rest.dropFirst()
            if name == "command", let flag = rest.first, flag == "-v" || flag == "-V" { return nil }
            while let word = rest.first, word.hasPrefix("-") || (name == "env" && isAssignment(word)) {
                rest = rest.dropFirst(wrapper.valueFlags.contains(word) ? 2 : 1)
                if word == "--" { break }
            }
            rest = rest.dropFirst(wrapper.operands)
        }
        return nil
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.first.map { $0.isLetter || $0 == "_" } == true
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func fileName(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }

    /// Flags of a content search that take the next word as their value.
    private static let searchValueFlags: Set<String> = [
        "--include", "--exclude", "--exclude-dir", "--include-dir", "-m", "--max-count",
        "-A", "-B", "-C", "--after-context", "--before-context", "--context", "--glob", "-g", "--iglob",
        "-d", "--directories", "-D", "--devices", "--label", "--color", "--colour",
    ]

    /// Value-taking flags of ripgrep that other search tools spell differently — `-r` is
    /// `--replace` there and recursion in grep, `-E` an encoding there and extended regexps in grep.
    private static let ripgrepValueFlags: Set<String> = [
        "-t", "--type", "-T", "--type-not", "--type-add", "-j", "--threads", "--max-depth",
        "-r", "--replace", "-M", "--max-columns", "-E", "--encoding", "--sort", "--sortr",
        "--max-filesize", "--ignore-file", "--pre", "--colors", "--path-separator",
    ]

    /// The pattern a shell search was actually looking for.
    ///
    /// The shape of a query must be computed from the query, not from the command line carrying
    /// it: every shell command contains a slash somewhere, so classifying the whole line called
    /// every search a path and the metric said nothing about what was being looked for. A pattern
    /// read from a file (`-f`) is not known, and nil is returned.
    public static func searchPattern(inShellCommand command: String) -> String? {
        ofShell(command).search.flatMap { parts(ofSearch: $0).pattern }
    }

    /// A search's pattern, the files or directories it names, and the globs it is limited to.
    private static func parts(ofSearch words: [String]) -> (pattern: String?, targets: [String], globs: [String]) {
        guard let tool = words.first else { return (nil, [], []) }
        // A file search names its pattern in `-name`; its first bare word is the directory to walk,
        // which would otherwise be reported as the thing being looked for.
        if fileSearchTools.contains(tool) {
            guard let flag = words.firstIndex(where: { ["-name", "-iname", "-path", "-ipath", "-wholename"].contains($0) }),
                  flag + 1 < words.count else { return (nil, [], []) }
            return (words[flag + 1], [], [words[flag + 1]])
        }

        let valueFlags = ["rg", "ripgrep"].contains(tool) ? searchValueFlags.union(ripgrepValueFlags) : searchValueFlags
        var pattern: String?
        var patternKnown = true
        var targets: [String] = []
        var globs: [String] = []
        var index = 1
        var flagsEnded = false
        while index < words.count {
            let word = words[index]
            index += 1
            if !flagsEnded {
                if word == "--" {
                    flagsEnded = true
                    continue
                }
                // `-e pattern` and `--regexp pattern` name the pattern explicitly.
                if word.hasPrefix("--regexp=") {
                    if pattern == nil { pattern = String(word.dropFirst("--regexp=".count)) }
                    continue
                }
                if word == "-e" || word == "--regexp" {
                    if pattern == nil, index < words.count { pattern = words[index] }
                    index += 1
                    continue
                }
                if word == "-f" || word == "--file" {
                    patternKnown = false
                    index += 1
                    continue
                }
                if word.hasPrefix("--include=") || word.hasPrefix("--glob=") {
                    globs.append(String(word.drop { $0 != "=" }.dropFirst()))
                    continue
                }
                if word.hasPrefix("-") {
                    // A flag that takes a value consumes it; a bare flag does not.
                    if valueFlags.contains(word) {
                        if ["--include", "--glob", "-g", "--iglob"].contains(word), index < words.count { globs.append(words[index]) }
                        index += 1
                    }
                    continue
                }
            }
            if pattern == nil && patternKnown { pattern = word } else { targets.append(word) }
        }
        return (patternKnown ? pattern : nil, targets, globs)
    }

    /// Whether a search is over the sources. Globs it is limited to decide, when there are any: one
    /// that can match a source (`*.swift`, `*.{h,m}`, `*`) is enough. Otherwise the targets it names
    /// do: none at all, a source file, or a path with no extension (a directory, `.`) is enough.
    private static func searchesSources(_ words: [String], variables: [String: [String]] = [:]) -> Bool {
        let parts = parts(ofSearch: words)
        let globs = parts.globs.filter { !$0.hasPrefix("!") }
        if !globs.isEmpty { return globs.contains(where: mayNameSource) }
        let targets = parts.targets.flatMap { expanding($0, variables) }
        return targets.isEmpty || targets.contains(where: mayNameSource)
    }

    private static func mayNameSource(_ path: String) -> Bool {
        let pathExtension = (path as NSString).pathExtension
        if pathExtension.isEmpty || isSource(path) { return true }
        // `*.{h,m}`: one of the alternatives in braces.
        guard let open = pathExtension.firstIndex(of: "{"), let close = pathExtension.lastIndex(of: "}"), open < close
        else { return false }
        return pathExtension[pathExtension.index(after: open)..<close].split(separator: ",")
            .contains { sourceExtensions.contains(String($0)) }
    }

    private static let sourceExtensions = Set(["swift"] + IndexDeclarations.clangExtensions)

    private static func isSource(_ path: String?) -> Bool {
        guard let path else { return false }
        return sourceExtensions.contains((path as NSString).pathExtension)
    }
}

/// What a shell line did, as navigation.
struct ShellNavigation {
    /// Each kind of act the line ran, once, in the order it first ran.
    var acts: [NavigationAct] = []
    /// The first search of the sources: the tool and its arguments.
    var search: [String]?
    /// The directory each act was about, when the line moved it (`cd`, or `--project` for sextant):
    /// the first act of each kind.
    var directories: [NavigationAct: String] = [:]

    /// The weightiest act: sextant, then a search, then a read.
    var act: NavigationAct {
        [.sextant, .textSearch, .fileRead].first(where: acts.contains) ?? .other
    }
}

/// One act of a tool call, as the adoption metric sees it.
public struct NavigationEvent: Sendable, Equatable {
    public let act: NavigationAct
    public let shape: QueryShape?
    /// The text searched for — set for a text search only.
    public let searched: String?
    /// For a sextant answer: MCP or the command line.
    public let channel: NavigationChannel?
    /// For a sextant answer: the same call also searched the sources — the answer was checked, or
    /// was not enough.
    public let crossChecked: Bool
    /// For an act on the command line: the directory it was about when the line moved it — by `cd`,
    /// or `--project` for sextant — as written, relative to the directory the call was made from.
    public let project: String?

    public init(act: NavigationAct, shape: QueryShape?, searched: String?, channel: NavigationChannel?,
                crossChecked: Bool = false, project: String? = nil) {
        self.act = act
        self.shape = shape
        self.searched = searched
        self.channel = channel
        self.crossChecked = crossChecked
        self.project = project
    }
}

/// Which way a sextant answer was asked for: an MCP tool call, or the command line.
public enum NavigationChannel: String, Sendable, Codable {
    case mcp
    case cli
}

/// The shape of a query, without the query.
///
/// Fixing adoption needs to know *what kind* of question went past the tool: a bare identifier is
/// something `defs`/`refs` answer exactly, a phrase in prose is not. The shape says that much and
/// no more — the text itself never leaves the classifier, because a search pattern is as much the
/// user's business as the code it was run against.
public enum QueryShape: String, Sendable, Codable, CaseIterable {
    /// A single identifier — the case sextant answers best and should have been asked.
    case identifier
    /// A qualified name or member access (`Foo.bar`, `foo->bar`).
    case memberAccess
    /// A regular expression: alternation, classes, anchors.
    case pattern
    /// A path or a glob.
    case path
    /// Words with spaces — prose, a log line, a message.
    case phrase
    case unknown

    public static func of(_ query: String) -> QueryShape {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }
        if trimmed.contains("/") || trimmed.hasPrefix("*.") { return .path }
        if trimmed.contains(where: { "|[]()^$?+\\".contains($0) }) { return .pattern }
        if trimmed.contains(" ") { return .phrase }
        if trimmed.contains(".") || trimmed.contains("->") || trimmed.contains("::") { return .memberAccess }
        if isIdentifier(trimmed) { return .identifier }
        return .unknown
    }

    private static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
