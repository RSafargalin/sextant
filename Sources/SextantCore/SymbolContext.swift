/// A context pack for a symbol: everything an agent normally extracts through a series of greps,
/// in one query — definition, usages, callers, callees, hierarchy.
public struct SymbolContext: Sendable, Codable {
    public let name: String
    public let kinds: [String]
    public let definitions: [SourceLocation]
    public let referenceCount: Int
    public let references: [SourceLocation]
    public let callerCount: Int
    public let callers: [SourceLocation]
    public let callees: [RelatedSymbol]
    public let implementations: [RelatedSymbol]
    public let supertypes: [RelatedSymbol]
}

extension IndexStore: SemanticIndex {}
extension IndexStoreSet: SemanticIndex {}

/// A semantic index — a single store or a union of them — behind a common query interface.
public protocol SemanticIndex {
    func lookup(name: String, query: SymbolQuery, limit: Int) -> [SymbolHit]
    func related(toName name: String, query: RelationQuery, limit: Int) -> [RelatedSymbol]
}

public extension SemanticIndex {
    /// Assembles the context pack for a symbol name. Returns nil when the symbol is not found.
    func context(forName name: String, sampleLimit: Int = 10) -> SymbolContext? {
        let definitions = lookup(name: name, query: .definitions, limit: .max)
        guard !definitions.isEmpty else { return nil }

        let referenceHits = lookup(name: name, query: .references, limit: .max).flatMap { $0.references }
        let callerHits = lookup(name: name, query: .callers, limit: .max).flatMap { $0.references }

        return SymbolContext(
            name: name,
            kinds: Array(Set(definitions.map { $0.kind })).sorted(),
            definitions: definitions.compactMap { $0.definition },
            referenceCount: referenceHits.count,
            references: Array(referenceHits.prefix(sampleLimit)),
            callerCount: callerHits.count,
            callers: Array(callerHits.prefix(sampleLimit)),
            callees: related(toName: name, query: .callees, limit: sampleLimit),
            implementations: related(toName: name, query: .implementations, limit: .max),
            supertypes: related(toName: name, query: .supertypes, limit: .max)
        )
    }
}
