import SextantCore
import Foundation

/// `sextant adoption` — the share of code navigation that went through the tool rather than past it.
///
/// The number alone would be a scoreboard. What makes it actionable is the residue: the shapes of
/// the searches that went to grep instead. An identifier searched textually is a question `defs`
/// or `refs` answers exactly, and every one of those is either a gap in the tool or a gap in how
/// it describes itself.
func runAdoption(arguments: [String]) -> Int32 {
    let root = projectRoot(in: arguments)
    let showQueries = arguments.contains("--show-queries")
    let directory = Adoption.transcriptDirectory(forProjectRoot: root)
    // The hook records the same acts as the transcript does, so the two are shown apart and never
    // added: one is the session as the client wrote it down, the other as the hook saw it live.
    let transcripts = Adoption.transcripts(forProjectRoot: root)
    let live = AdoptionLog.report(forProjectRoot: root, transcripts: transcripts)
    let hasTranscripts = !transcripts.isEmpty

    guard hasTranscripts || FileManager.default.fileExists(atPath: directory.path)
            || live.navigation > 0 || live.legacyRecords > 0 else {
        reportError("sextant adoption: no session transcripts for the repository of \(shorten(root)) (looked in \(directory.path) and its worktrees),")
        reportError("   and nothing in the live log for its repository.")
        reportError("   Transcripts are written by the client per directory; a project worked on elsewhere has its own.")
        return 1
    }

    let report = hasTranscripts
        ? Adoption.report(forProjectRoot: root, keepingQueries: showQueries)
        : AdoptionReport.empty

    if arguments.contains("--json") {
        struct Counts: Encodable {
            let sessions: Int
            let sextant: Int
            let throughMCP: Int
            let throughCLI: Int
            let textSearch: Int
            let fileRead: Int
            let share: Double?
            let readAfterSextant: Int
            let crossCheckedAnswers: Int
            let residue: [String: Int]

            init(_ report: AdoptionReport) {
                sessions = report.sessions
                sextant = report.sextant
                throughMCP = report.throughMCP
                throughCLI = report.throughCLI
                textSearch = report.textSearch
                fileRead = report.fileRead
                share = report.share
                readAfterSextant = report.readAfterSextant
                crossCheckedAnswers = report.crossCheckedAnswers
                residue = Dictionary(uniqueKeysWithValues: report.residue.map { ($0.key.rawValue, $0.value) })
            }
        }
        struct Live: Encodable {
            let counts: Counts
            let legacyRecords: Int
            enum CodingKeys: String, CodingKey { case legacyRecords }
            func encode(to encoder: Encoder) throws {
                try counts.encode(to: encoder)
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(legacyRecords, forKey: .legacyRecords)
            }
        }
        struct Output: Encodable {
            let counts: Counts
            let transcripts: Bool
            let queries: [String]
            let live: Live
            enum CodingKeys: String, CodingKey { case transcripts, queries, live }
            func encode(to encoder: Encoder) throws {
                try counts.encode(to: encoder)
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(transcripts, forKey: .transcripts)
                try container.encode(queries, forKey: .queries)
                try container.encode(live, forKey: .live)
            }
        }
        printJSON(Output(counts: Counts(report), transcripts: hasTranscripts, queries: report.queries,
                         live: Live(counts: Counts(live), legacyRecords: live.legacyRecords)))
        return 0
    }

    print("# sextant adoption — \(shorten(root))")
    if hasTranscripts {
        print("   sessions read: \(report.sessions)")
        if let share = report.share {
            print("""

            through sextant:  \(report.sextant)\(channels(report))
            text search:      \(report.textSearch)
            reading a file:   \(report.fileRead)
            ── share: \(Int((share * 100).rounded()))% of \(report.navigation) navigation acts
            """)
            printReadsAfterAnswers(report)
        } else {
            print("\nNo code navigation in these sessions — nothing to take a share of.")
        }
    } else {
        print("   no session transcripts for this repository — the live log below is all there is")
    }

    if !report.residue.isEmpty {
        print("\nwhat went past it, by shape of the query:")
        for shape in QueryShape.allCases {
            guard let count = report.residue[shape] else { continue }
            print("   \(shape.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \(count)\(hint(for: shape))")
        }
    }

    if live.navigation > 0 || live.legacyRecords > 0 {
        print("\nlive log (hook), the whole repository as it happened — NOT to be added to the above:")
        if live.navigation > 0 {
            print("   sessions: \(live.sessions) · through sextant: \(live.sextant)\(channels(live))"
                  + " · text search: \(live.textSearch) · reading a file: \(live.fileRead)")
            if let share = live.share {
                print("   ── share: \(Int((share * 100).rounded()))% of \(live.navigation) navigation acts")
            }
            printReadsAfterAnswers(live, indent: "   ")
        }
        if live.legacyRecords > 0 {
            print("   \(live.legacyRecords) lines of the earlier log format are left out: it counted a path containing")
            print("   `sextant` as a call and a grep over piped output as a search of the sources.")
        }
    }

    if showQueries, !report.queries.isEmpty {
        print("\nthe searches themselves (local, not sent anywhere):")
        for query in report.queries.prefix(40) { print("   \(query.prefix(120))") }
        if report.queries.count > 40 { print("   … and \(report.queries.count - 40) more") }
    } else if !report.queries.isEmpty || !report.residue.isEmpty {
        print("\n(the patterns themselves are not printed; --show-queries shows them)")
    }
    return 0
}

/// ` (MCP n · CLI m)` when any answer was asked for at all.
private func channels(_ report: AdoptionReport) -> String {
    report.sextant > 0 ? " (MCP \(report.throughMCP) · CLI \(report.throughCLI))" : ""
}

/// A share says how often the tool was reached for. It does not say whether the answer was
/// enough — and an answer that always needs a file opened after it is a question we answered
/// badly, not a search we won.
private func printReadsAfterAnswers(_ report: AdoptionReport, indent: String = "") {
    guard report.sextant > 0 else { return }
    let share = Double(report.readAfterSextant) / Double(report.sextant)
    print("""

    \(indent)after \(report.readAfterSextant) of \(report.sextant) answers (\(Int((share * 100).rounded()))%) \
    the next act was opening a file
    \(indent)   — adjacency, not the same file: calls are recorded, not answers. High means our \
    answers stop one step short.
    """)
    if report.crossCheckedAnswers > 0 {
        let checked = Double(report.crossCheckedAnswers) / Double(report.sextant)
        print("\(indent)\(report.crossCheckedAnswers) of \(report.sextant) answers (\(Int((checked * 100).rounded()))%) " +
              "came in a call that also searched the sources — checked, or not enough")
    }
}

/// What each shape says about the gap it represents. A phrase in prose is not sextant's business;
/// an identifier is exactly its business, and finding it in this list is the finding.
private func hint(for shape: QueryShape) -> String {
    switch shape {
    case .identifier:   return "  — `defs`/`refs`/`context` answer this exactly"
    case .memberAccess: return "  — `search '$X.member'` answers this structurally"
    case .pattern:      return "  — a regex; `search` covers the structural half"
    case .path, .phrase, .unknown: return ""
    }
}
