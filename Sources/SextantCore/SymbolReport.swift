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
        /// How many symbols sharing the queried name are printed. A bare name is not a symbol:
        /// `request` on Alamofire resolves to 337 of them, and printing all 337 answers "which one
        /// did you mean" with a bill for the context window. The rest are counted, never dropped
        /// in silence.
        public var symbolLimit: Int
        public var fullHint: String?
        /// How to get the symbols that were not printed, phrased for this surface.
        public var moreSymbolsHint: String?
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
            symbolLimit: Int = .max,
            fullHint: String?,
            moreSymbolsHint: String? = nil,
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
            self.symbolLimit = symbolLimit
            self.fullHint = fullHint
            self.moreSymbolsHint = moreSymbolsHint
            self.separatesHits = separatesHits
            self.referencesCommand = referencesCommand
            self.contextCommand = contextCommand
        }

        public static func cli(compact: Bool, referenceLimit: Int, symbolLimit: Int = 10) -> Style {
            Style(
                headerPrefix: "── ", level1: "   ", level2: "     ",
                showsColumns: true, compact: compact, referenceLimit: referenceLimit,
                symbolLimit: symbolLimit,
                fullHint: compact ? "(--full — line by line, with snippets)" : nil,
                moreSymbolsHint: "`--symbols N` shows more of them, `--json` prints them all",
                separatesHits: true, referencesCommand: "refs", contextCommand: "context"
            )
        }

        public static let mcp = Style(
            headerPrefix: "", level1: "  ", level2: "    ",
            showsColumns: false, compact: true, referenceLimit: .max,
            symbolLimit: 10,
            fullHint: nil,
            // No hint about narrowing: there is no way to name one of several symbols that share a
            // name, so a suggestion here would be an instruction the tool cannot carry out.
            moreSymbolsHint: nil,
            separatesHits: false,
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
        // Snippets are read from the file as it is now, at the line the index recorded. After an
        // edit that line holds someone else's code, and printing it would attribute text to a
        // symbol that is not there. The line number stays — it is what the index knows — and only
        // the text is withheld.
        var shifted = 0
        func located(_ location: SourceLocation, symbolName: String) -> String {
            if !FileManager.default.fileExists(atPath: location.path) { vanished.insert(path(location.path)) }
            let position = style.showsColumns ? "\(location.line):\(location.column)" : "\(location.line)"
            var text = ""
            if let line = snippet(location) {
                if WordBoundary.contains(baseName(symbolName), in: line) {
                    text = "  \(line)"
                } else {
                    shifted += 1
                }
            }
            return "\(path(location.path)):\(position)\(text)"
        }

        // `save(_:)` and `save:` are written `save(` and `save:` in source, so the part before the
        // first separator is what a line can be checked against.
        func baseName(_ name: String) -> String {
            String(name.prefix { $0 != "(" && $0 != ":" })
        }

        // The index layer caps how many occurrences it collects. Printing the cap as the count
        // answers "how many are there" with "how many I looked at".
        func counted(_ hit: SymbolHit) -> String {
            hit.totalReferences > hit.references.count
                ? "\(hit.references.count) of \(hit.totalReferences) (internal cap)"
                : "\(hit.references.count)"
        }

        var lines: [String] = []
        // The hits arrive sorted by how many usages each has, so a cut keeps the ones a reader is
        // most likely to have meant. What is cut is stated with its count: an answer that shows
        // ten of 337 symbols and says nothing is a wrong answer, not a short one.
        let shown = style.symbolLimit >= hits.count ? hits : Array(hits.prefix(max(1, style.symbolLimit)))
        for hit in shown {
            lines.append("\(style.headerPrefix)\(hit.name)  [\(hit.kind)]")
            if query == .definitions {
                let locations = hit.references.isEmpty ? [hit.definition].compactMap { $0 } : hit.references
                if locations.isEmpty {
                    lines.append("\(style.level1)definition not in the index (an external symbol?) — try `\(style.referencesCommand) \(symbol)`")
                }
                locations.forEach { lines.append("\(style.level1)• \(located($0, symbolName: hit.name))") }
            } else {
                if let definition = hit.definition { lines.append("\(style.level1)def: \(located(definition, symbolName: hit.name))") }
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
                        lines.append("\(style.level2)• \(located(reference, symbolName: hit.name))")
                    }
                    if hit.references.count > style.referenceLimit {
                        lines.append("\(style.level2)… \(hit.references.count - style.referenceLimit) more")
                    }
                }
            }
            if style.separatesHits { lines.append("") }
        }

        if shown.count < hits.count {
            let hidden = hits.count - shown.count
            let usages = hits.dropFirst(shown.count).reduce(0) { $0 + $1.references.count }
            var line = "\(style.headerPrefix)… \(hidden) more symbol(s) named '\(symbol)', "
                + "\(usages) usage(s) between them — shown: the \(shown.count) most used"
            if let hint = style.moreSymbolsHint { line += " (\(hint))" }
            lines.append(line)
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
        if shifted > 0 {
            advisories.append("⚠ \(shifted) snippet(s) withheld: the recorded line no longer contains the symbol — "
                              + "the file has changed since it was indexed. Rebuild the project or run `sextant index`.")
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
