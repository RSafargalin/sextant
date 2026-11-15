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

    /// Hits ordered by how many usages each has, most used first, with the USR breaking ties so
    /// the order is the same on every run. Counted by `totalReferences`, the index's own total,
    /// because `references` stops at the internal cap and would rank every capped symbol equal.
    public static func orderedByUsage(_ hits: [SymbolHit]) -> [SymbolHit] {
        hits.sorted { left, right in
            left.totalReferences != right.totalReferences
                ? left.totalReferences > right.totalReferences
                : left.usr < right.usr
        }
    }

    /// The refs/defs/callers answer: a definition, a histogram, or a line-by-line list. The hits
    /// may arrive in any order: they are put in usage order here, where the cut relies on it.
    public static func lookup(
        symbol: String,
        hits: [SymbolHit],
        query: SymbolQuery,
        style: Style,
        path: (String) -> String,
        snippet: (SourceLocation) -> String?,
        refresh: String = StoreSelection.refreshAdvice(forStores: [])
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
            let position = style.showsColumns ? location.position : "\(location.line)"
            // An unconfirmed position is stated as the index recorded it; the current text at that
            // line is someone else's, so no snippet is quoted.
            guard location.isConfirmed else { return "\(path(location.path)):\(position)\(location.marker)" }
            if !FileManager.default.fileExists(atPath: location.path) { vanished.insert(path(location.path)) }
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
        // Ordered by how many usages each has, so a cut keeps the ones a reader is most likely to
        // have meant. What is cut is stated with its count: an answer that shows ten of 337
        // symbols and says nothing is a wrong answer, not a short one.
        let hits = orderedByUsage(hits)
        let shown = style.symbolLimit >= hits.count ? hits : Array(hits.prefix(max(1, style.symbolLimit)))
        let someDefined = hits.contains { $0.definition != nil }
        for hit in shown {
            lines.append("\(style.headerPrefix)\(hit.name)  [\(hit.kind)]")
            if query == .definitions {
                let locations = hit.references.isEmpty ? [hit.definition].compactMap { $0 } : hit.references
                if locations.isEmpty {
                    lines.append("\(style.level1)definition not in the index (an external symbol?) — try `\(style.referencesCommand) \(symbol)`")
                }
                locations.forEach { lines.append("\(style.level1)• \(located($0, symbolName: hit.name))") }
            } else {
                if let definition = hit.definition {
                    lines.append("\(style.level1)def: \(located(definition, symbolName: hit.name))")
                } else if someDefined {
                    // Beside symbols of the same name that do have one, a missing definition line
                    // would read as an oversight; it is a fact about the index, and said as one.
                    lines.append("\(style.level1)def: not in the index (an external symbol, or one only declared here)")
                }
                let label = query == .callers ? "calls" : "usages"
                if style.compact {
                    // A histogram by file without snippets — exact, every occurrence is grouped.
                    // Unconfirmed positions are grouped apart: their numbers are lines as indexed,
                    // and mixing them with current ones would put two coordinate systems in one list.
                    let confirmed = hit.references.filter(\.isConfirmed)
                    let unconfirmed = hit.references.filter { !$0.isConfirmed }
                    let histogram = ReferenceHistogram.byFile(confirmed) { path($0.path) }
                    let files = Set(hit.references.map { path($0.path) }).count
                    lines.append("\(style.level1)\(label): \(counted(hit)) in \(files) file(s)")
                    for entry in histogram {
                        lines.append("\(style.level2)\(entry.file): \(entry.lines.map(String.init).joined(separator: ", "))")
                    }
                    for entry in ReferenceHistogram.byFile(unconfirmed, path: { path($0.path) }) {
                        lines.append("\(style.level2)\(entry.file): \(entry.lines.map(String.init).joined(separator: ", "))"
                                     + "  [unconfirmed — lines as indexed, changed since]")
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

        lines += staleness(hits.first?.staleness,
                           locations: shown.flatMap { $0.references + [$0.definition].compactMap { $0 } },
                           symbol: symbol, style: style, path: path)

        if shown.count < hits.count {
            let hidden = hits.count - shown.count
            // The index's own totals: `references` stops at the internal cap, and a sum of capped
            // lists would report the cap as the count.
            let usages = hits.dropFirst(shown.count).reduce(0) { $0 + $1.totalReferences }
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
                Deleting a file cannot make an index look stale by time. To refresh it: \(refresh).
                """)
        }
        if shifted > 0 {
            advisories.append("⚠ \(shifted) snippet(s) withheld: the recorded line no longer contains the symbol — "
                              + "the file has changed since it was indexed. To refresh the index: \(refresh).")
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
            guard location.isConfirmed else { return "\(path(location.path)):\(location.line)\(location.marker)" }
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
            // Counted from every callee the index records, not from the sample below it.
            let total = max(context.calleeCount, context.callees.count)
            lines.append("\(style.level1)calls: \(total)")
            let shown = context.callees.prefix(sampleLimit)
            for callee in shown {
                lines.append("\(style.level2)→ \(callee.name) [\(callee.kind)]  \(path(callee.location.path)):\(callee.location.line)\(callee.location.marker)")
            }
            if let note = CallHierarchy.omissionNote(total: total, shown: shown.count, direction: .callees) {
                lines.append("\(style.level2)\(note)")
            }
        }
        if !context.implementations.isEmpty {
            lines.append("\(style.level1)implementations: " + context.implementations.map { $0.name }.joined(separator: ", "))
        }
        if !context.supertypes.isEmpty {
            lines.append("\(style.level1)bases and protocols: " + context.supertypes.map { $0.name }.joined(separator: ", "))
        }
        let shownCallees = context.callees.prefix(sampleLimit).map(\.location)
        lines += staleness(context.staleness,
                           locations: context.definitions + context.references + context.callers + shownCallees,
                           symbol: context.name, style: style, path: path)
        return lines
    }

    /// The section an answer over a stale index ends with: what was mapped, what could not be
    /// confirmed, where the name is written that the index does not know, and which changed files
    /// changed declarations. Empty when there is no note, or nothing in it bears on this answer.
    public static func staleness(_ note: Staleness?, locations: [SourceLocation], symbol: String,
                                 style: Style, path: (String) -> String, extra: [String] = []) -> [String] {
        guard let note else { return [] }
        let mapped = locations.filter { location in
            location.isConfirmed && location.indexedLine.map { $0 != location.line } == true
        }.count
        let unconfirmed = locations.filter { !$0.isConfirmed }.count
        var body: [String] = extra.map { "\(style.level1)\($0)" }
        if mapped > 0 {
            body.append("\(style.level1)\(mapped) position(s) moved to their current lines "
                        + "(the lines themselves are unchanged since indexing)")
        }
        if unconfirmed > 0 {
            body.append("\(style.level1)\(unconfirmed) position(s) unconfirmed, marked [unconfirmed]: their line "
                        + "changed or their file is gone since indexing — not verifiable against the current text")
        }
        if note.candidateCount > 0 {
            body.append("\(style.level1)not in the index — '\(IndexDrift.baseName(symbol))' written in changed files "
                        + "(text match only: same name, possibly another symbol; not counted above): \(note.candidateCount)")
            for candidate in note.candidates {
                let position = style.showsColumns ? "\(candidate.line):\(candidate.column)" : "\(candidate.line)"
                body.append("\(style.level2)? \(path(candidate.path)):\(position)  \(candidate.text)")
            }
            if note.candidateCount > note.candidates.count {
                body.append("\(style.level2)… \(note.candidateCount - note.candidates.count) more")
            }
        }
        if !note.declarationsChanged.isEmpty {
            let named = note.declarationsChanged.prefix(5).joined(separator: ", ")
            let more = note.declarationsChanged.count > 5 ? " and \(note.declarationsChanged.count - 5) more" : ""
            body.append("\(style.level1)declarations changed since indexing in \(named)\(more) — uses elsewhere may now "
                        + "resolve to a different symbol (overloads, shadowing), which the index cannot show")
        }
        guard !body.isEmpty else { return [] }
        let header = "\(style.headerPrefix)⚠ stale index: \(note.changedFiles.count) file(s) changed since it was built; "
            + "positions are stated against the current text — run `sextant index` to refresh"
        return [header] + body + (style.separatesHits ? [""] : [])
    }

    /// What an answer left out because the files the index records it in no longer exist
    /// (`AbsentSources`): said beside the answer, never dropped in silence. nil when nothing was.
    public static func leftOut(_ summary: AbsentSources.Summary?, path: (String) -> String) -> String? {
        guard let summary else { return nil }
        let named = summary.files.prefix(5).map(path).joined(separator: ", ")
        let more = summary.files.count > 5 ? " and \(summary.files.count - 5) more" : ""
        return "⚠ left out of this answer: \(summary.positions) position(s) in \(summary.files.count) file(s) "
            + "the index still records but that no longer exist — \(named)\(more). A build leaves the units "
            + "of deleted sources in its store; `sextant index` removes them from the stores it builds."
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
