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

    guard FileManager.default.fileExists(atPath: directory.path) else {
        reportError("sextant adoption: no session transcripts for \(shorten(root)) (looked in \(directory.path)).")
        reportError("   They are written by the client per project directory; a project worked on elsewhere has its own.")
        return 1
    }

    let report = Adoption.report(forProjectRoot: root, keepingQueries: showQueries)

    if arguments.contains("--json") {
        struct Output: Encodable {
            let sessions: Int
            let sextant: Int
            let textSearch: Int
            let fileRead: Int
            let share: Double?
            let residue: [String: Int]
            let queries: [String]
        }
        printJSON(Output(
            sessions: report.sessions, sextant: report.sextant, textSearch: report.textSearch,
            fileRead: report.fileRead, share: report.share,
            residue: Dictionary(uniqueKeysWithValues: report.residue.map { ($0.key.rawValue, $0.value) }),
            queries: report.queries
        ))
        return 0
    }

    print("# sextant adoption — \(shorten(root))")
    print("   sessions read: \(report.sessions)")
    guard let share = report.share else {
        print("\nNo code navigation in these sessions — nothing to take a share of.")
        return 0
    }
    print("""

    through sextant:  \(report.sextant)
    text search:      \(report.textSearch)
    reading a file:   \(report.fileRead)
    ── share: \(Int((share * 100).rounded()))% of \(report.navigation) navigation acts
    """)

    if !report.residue.isEmpty {
        print("\nwhat went past it, by shape of the query:")
        for shape in QueryShape.allCases {
            guard let count = report.residue[shape] else { continue }
            print("   \(shape.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \(count)\(hint(for: shape))")
        }
    }
    // The hook records the same acts as the transcript does, so the two are shown apart and never
    // added: one is the session as the client wrote it down, the other as the hook saw it live.
    let live = AdoptionLog.report(forProjectRoot: root)
    if live.navigation > 0 {
        print("\nlive log (hook), the same acts as they happened — NOT to be added to the above:")
        print("   through sextant: \(live.sextant) · text search: \(live.textSearch) · reading a file: \(live.fileRead)")
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
