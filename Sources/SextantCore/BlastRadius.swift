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
}

public extension IndexStoreSet {
    func blastRadius(forName name: String) -> BlastRadius? {
        let referenceHits = lookup(name: name, query: .references)
        let callerHits = lookup(name: name, query: .callers)
        guard !referenceHits.isEmpty || !callerHits.isEmpty else { return nil }

        let definitions = referenceHits.compactMap { $0.definition }
        let references = referenceHits.flatMap { $0.references }
        let callers = callerHits.flatMap { $0.references }

        var files = Set<String>()
        (references + callers + definitions).forEach { files.insert($0.path) }

        return BlastRadius(
            symbol: name,
            kind: referenceHits.first?.kind ?? callerHits.first?.kind ?? "",
            definitions: definitions,
            referenceCount: references.count,
            callerCount: callers.count,
            affectedFiles: files.sorted(),
            implementations: related(toName: name, query: .implementations).map { $0.name }
        )
    }
}
