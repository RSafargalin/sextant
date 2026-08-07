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

    /// Classifies one tool call. `command` is the shell command for `Bash`, the pattern for a
    /// search tool, the path for a read.
    public static func of(tool: String, command: String?) -> NavigationAct {
        if tool.hasPrefix("mcp__sextant") { return .sextant }
        switch tool {
        case "Grep", "Glob": return .textSearch
        case "Read": return isSource(command) ? .fileRead : .other
        case "Bash": return ofShell(command ?? "")
        default: return .other
        }
    }

    /// A shell command counts as a text search when it runs a search tool over the tree. `find`
    /// and `ls` are navigation of the file system, not of code, and stay out of the denominator:
    /// sextant does not replace them, so counting them would invent a gap it cannot close.
    private static func ofShell(_ command: String) -> NavigationAct {
        let searchTools = ["grep", "rg", "ag", "ack", "ripgrep"]
        for piece in command.split(whereSeparator: { " |;&\n".contains($0) }) {
            let word = piece.split(separator: "/").last.map(String.init) ?? String(piece)
            if searchTools.contains(word) { return .textSearch }
            if word == "sextant" { return .sextant }
        }
        return .other
    }

    /// The pattern a shell search was actually looking for.
    ///
    /// The shape of a query must be computed from the query, not from the command line carrying
    /// it: every shell command contains a slash somewhere, so classifying the whole line called
    /// every search a path and the metric said nothing about what was being looked for.
    public static func searchPattern(inShellCommand command: String) -> String? {
        let words = ShellWords.split(command)
        guard let start = words.firstIndex(where: { word in
            let name = word.split(separator: "/").last.map(String.init) ?? word
            return ["grep", "rg", "ag", "ack", "ripgrep"].contains(name)
        }) else { return nil }

        var index = words.index(after: start)
        while index < words.endIndex {
            let word = words[index]
            // `-e pattern` and `--regexp pattern` name the pattern explicitly.
            if word == "-e" || word == "--regexp" {
                return index + 1 < words.endIndex ? words[index + 1] : nil
            }
            // A flag that takes a value consumes it; a bare flag does not.
            if word.hasPrefix("-") {
                if ["--include", "--exclude", "-m", "--max-count", "-A", "-B", "-C", "--glob", "-g"].contains(word) {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            return word
        }
        return nil
    }

    private static func isSource(_ path: String?) -> Bool {
        guard let path else { return false }
        let sourceExtensions = Set(["swift"] + IndexDeclarations.clangExtensions)
        return sourceExtensions.contains((path as NSString).pathExtension)
    }
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
