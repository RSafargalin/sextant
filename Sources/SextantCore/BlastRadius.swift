import Foundation

/// Impact analysis for a symbol: what a change to it would touch. Usages, callers and conformers
/// are composed into the set of affected files and the surface of the change, in one query.
public struct BlastRadius: Sendable, Codable {
    public let symbol: String
    public let kind: String
    public let definitions: [SourceLocation]
    public let referenceCount: Int
    public let callerCount: Int
    public let affectedFiles: [String]
    public let implementations: [String]
    /// How many distinct symbols share the name and were added together into these counts. The
    /// kind is the first one's. Text output states it; the JSON shape does not carry it.
    public var symbolCount = 1
    /// Present only over an index that is stale against its snapshot.
    public var staleness: Staleness?
    /// Over a stale index, the affected files every occurrence in which is unconfirmed against the
    /// current text (a deleted file, lines changed since indexing). nil otherwise.
    public var unconfirmedFiles: [String]?

    private enum CodingKeys: String, CodingKey {
        case symbol, kind, definitions, referenceCount, callerCount, affectedFiles, implementations
        case staleness, unconfirmedFiles
    }

    /// The line that says the radius is a sum over several symbols, or nil for a single one.
    public var mergeNote: String? {
        guard symbolCount > 1 else { return nil }
        return "⚠ \(symbolCount) distinct symbols are named '\(symbol)' — these counts and files are their sum, "
             + "and the kind shown is one of them"
    }
}

public extension SemanticIndex {
    func blastRadius(forName name: String) -> BlastRadius? {
        // No cap: the counts and the file set are totals, and a capped lookup would present the
        // cap as the count and leave out every file past it.
        let referenceHits = lookup(name: name, query: .references, limit: .max)
        let callerHits = lookup(name: name, query: .callers, limit: .max)
        guard !referenceHits.isEmpty || !callerHits.isEmpty else { return nil }

        let definitions = referenceHits.compactMap { $0.definition }
        let references = referenceHits.flatMap { $0.references }
        let callers = callerHits.flatMap { $0.references }

        var files = Set<String>()
        (references + callers + definitions).forEach { files.insert($0.path) }

        var radius = BlastRadius(
            symbol: name,
            kind: referenceHits.first?.kind ?? callerHits.first?.kind ?? "",
            definitions: definitions,
            referenceCount: referenceHits.reduce(0) { $0 + $1.totalReferences },
            callerCount: callerHits.reduce(0) { $0 + $1.totalReferences },
            affectedFiles: files.sorted(),
            implementations: related(toName: name, query: .implementations, limit: .max).map { $0.name }
        )
        radius.symbolCount = Set(referenceHits.map(\.usr) + callerHits.map(\.usr)).count
        return radius
    }
}
