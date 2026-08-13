import Foundation

/// A single renderer for semantic answers, shared by the CLI and MCP. The histogram, the
/// degradation notice and the symbol summary used to be written twice and drifted apart; now the
/// surfaces differ only in style (indentation, columns, wording of hints), and the logic is one.
public enum SymbolReport {
    /// Presentation per surface: the CLI prints with rules and columns, MCP prints compactly.
    public struct Style: Sendable {
        public var headerPrefix: String
        public var level1: String
        public var level2: String
        public var showsColumns: Bool
        public var compact: Bool
        public var referenceLimit: Int
        public var fullHint: String?
        public var separatesHits: Bool
        /// Command and tool names used by the "a type has no callers" hint.
        public var referencesCommand: String
        public var contextCommand: String

        public init(
            headerPrefix: String,
            level1: String,
            level2: String,
            showsColumns: Bool,
            compact: Bool,
            referenceLimit: Int,
            fullHint: String?,
            separatesHits: Bool,
            referencesCommand: String,
            contextCommand: String
        ) {
            self.headerPrefix = headerPrefix
            self.level1 = level1
            self.level2 = level2
            self.showsColumns = showsColumns
            self.compact = compact
            self.referenceLimit = referenceLimit
            self.fullHint = fullHint
            self.separatesHits = separatesHits
            self.referencesCommand = referencesCommand
            self.contextCommand = contextCommand
        }

        public static func cli(compact: Bool, referenceLimit: Int) -> Style {
            Style(
                headerPrefix: "── ", level1: "   ", level2: "     ",
                showsColumns: true, compact: compact, referenceLimit: referenceLimit,
                fullHint: compact ? "(--full — line by line, with snippets)" : nil,
                separatesHits: true, referencesCommand: "refs", contextCommand: "context"
            )
        }

        public static let mcp = Style(
            headerPrefix: "", level1: "  ", level2: "    ",
            showsColumns: false, compact: true, referenceLimit: .max,
            fullHint: nil, separatesHits: false,
            referencesCommand: "find_references", contextCommand: "context"
        )
    }

    /// Rendering result. `advisory` is a hint that is not part of the answer itself: the CLI sends
    /// it to stderr to keep stdout clean; MCP appends it to the text the agent reads.
    public struct Rendering: Sendable {
        public let lines: [String]
        public let advisory: String?
    }

    /// The refs/defs/callers answer: a definition, a histogram, or a line-by-line list.
    public static func lookup(
        symbol: String,
        hits: [SymbolHit],
        query: SymbolQuery,
        style: Style,
        path: (String) -> String,
        snippet: (SourceLocation) -> String?
    ) -> Rendering {
        // A location whose file is gone is not a fact about the code — it is the index describing
        // a state that no longer exists. Deleting a file makes nothing "newer", so the freshness
        // signal cannot see it; the answer itself is the only place where it shows.
        var vanished: Set<String> = []
        func located(_ location: SourceLocation) -> String {
            if !FileManager.default.fileExists(atPath: location.path) { vanished.insert(path(location.path)) }
            let position = style.showsColumns ? "\(location.line):\(location.column)" : "\(location.line)"
            let text = snippet(location).map { "  \($0)" } ?? ""
            return "\(path(location.path)):\(position)\(text)"
        }

        // The index layer caps how many occurrences it collects. Printing the cap as the count
        // answers "how many are there" with "how many I looked at".
        func counted(_ hit: SymbolHit) -> String {
            hit.totalReferences > hit.references.count
                ? "\(hit.references.count) of \(hit.totalReferences) (internal cap)"
                : "\(hit.references.count)"
        }

        var lines: [String] = []
        for hit in hits {
            lines.append("\(style.headerPrefix)\(hit.name)  [\(hit.kind)]")
            if query == .definitions {
                let locations = hit.references.isEmpty ? [hit.definition].compactMap { $0 } : hit.references
                if locations.isEmpty {
                    lines.append("\(style.level1)definition not in the index (an external symbol?) — try `\(style.referencesCommand) \(symbol)`")
                }
                locations.forEach { lines.append("\(style.level1)• \(located($0))") }
            } else {
                if let definition = hit.definition { lines.append("\(style.level1)def: \(located(definition))") }
                let label = query == .callers ? "calls" : "usages"
                if style.compact {
                    // A histogram by file without snippets — exact, every occurrence is grouped.
                    let histogram = ReferenceHistogram.byFile(hit.references) { path($0.path) }
                    lines.append("\(style.level1)\(label): \(counted(hit)) in \(histogram.count) file(s)")
                    for entry in histogram {
                        lines.append("\(style.level2)\(entry.file): \(entry.lines.map(String.init).joined(separator: ", "))")
                    }
                    if let hint = style.fullHint { lines.append("\(style.level2)\(hint)") }
                } else {
                    lines.append("\(style.level1)\(label): \(counted(hit))")
                    for reference in hit.references.prefix(style.referenceLimit) {
                        lines.append("\(style.level2)• \(located(reference))")
                    }
                    if hit.references.count > style.referenceLimit {
                        lines.append("\(style.level2)… \(hit.references.count - style.referenceLimit) more")
                    }
                }
            }
            if style.separatesHits { lines.append("") }
        }

        // Types have no callers — point at usages, or an empty answer reads as "nobody uses this".
        let typesOnly = !hits.isEmpty && hits.allSatisfy { isTypeKind($0.kind) } && hits.allSatisfy { $0.references.isEmpty }
        var advisories: [String] = []
        if !vanished.isEmpty {
            // The provenance line above is computed before the query and reports timestamps, which
            // a deletion never moves. Saying so here keeps the two from contradicting each other.
            advisories.append("""
                ⚠ the index is out of date despite the marker above — \(vanished.count) file(s) in \
                this answer no longer exist: \(vanished.sorted().joined(separator: ", ")). \
                Deleting a file cannot make an index look stale by time; rebuild the project or \
                run `sextant index`.
                """)
        }
        if query == .callers && typesOnly {
            advisories.append("ℹ '\(symbol)' is a type: types have no call sites. Use `\(style.referencesCommand) \(symbol)` or `\(style.contextCommand) \(symbol)`.")
        }
        return Rendering(lines: lines, advisory: advisories.isEmpty ? nil : advisories.joined(separator: "\n"))
    }

    /// Everything about one symbol (`context`).
    public static func context(
        _ context: SymbolContext,
        sampleLimit: Int,
        style: Style,
        path: (String) -> String,
        snippet: (SourceLocation) -> String?
    ) -> [String] {
        func located(_ location: SourceLocation) -> String {
            let text = snippet(location).map { "  \($0)" } ?? ""
            return "\(path(location.path)):\(location.line)\(text)"
        }

        var lines = ["\(style.headerPrefix)\(context.name)  [\(context.kinds.joined(separator: ", "))]"]
        context.definitions.forEach { lines.append("\(style.level1)def: \(located($0))") }
        if context.referenceCount > 0 {
            lines.append("\(style.level1)usages: \(context.referenceCount)")
            context.references.forEach { lines.append("\(style.level2)• \(located($0))") }
        }
        if context.callerCount > 0 {
            lines.append("\(style.level1)callers: \(context.callerCount)")
            context.callers.forEach { lines.append("\(style.level2)• \(located($0))") }
        }
        if !context.callees.isEmpty {
            lines.append("\(style.level1)calls: \(context.callees.count)")
            for callee in context.callees.prefix(sampleLimit) {
                lines.append("\(style.level2)→ \(callee.name) [\(callee.kind)]  \(path(callee.location.path)):\(callee.location.line)")
            }
        }
        if !context.implementations.isEmpty {
            lines.append("\(style.level1)implementations: " + context.implementations.map { $0.name }.joined(separator: ", "))
        }
        if !context.supertypes.isEmpty {
            lines.append("\(style.level1)bases and protocols: " + context.supertypes.map { $0.name }.joined(separator: ", "))
        }
        return lines
    }

    /// Degradation to textual occurrences when semantics find nothing. It is marked explicitly as
    /// NOT semantics, or the grep equivalent gets read as a list of references.
    public static func textual(
        symbol: String,
        matches: [IdentifierScan.Match],
        truncated: Bool,
        style: Style,
        path: (String) -> String
    ) -> [String] {
        var lines = ["⚠ \(symbol): 0 semantic hits → textual occurrences (grep equivalent, NOT calls or references; \(matches.count)\(truncated ? "+" : "")):"]
        for match in matches {
            // The marker is per line, not per answer: in a file with several branches only some
            // of the occurrences are outside the built configuration, and which ones matters.
            let marker = match.conditional ? "  [#if — outside the built configuration]" : ""
            lines.append("\(style.level2)\(path(match.path)):\(match.line)  \(match.text)\(marker)")
        }
        return lines
    }

    /// A container kind (a type), which never has call sites.
    public static func isTypeKind(_ kind: String) -> Bool {
        ["struct", "class", "enum", "protocol", "actor", "extension"].contains(kind)
    }
}
