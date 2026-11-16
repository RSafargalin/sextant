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
    /// The first callees, up to the sample limit; `calleeCount` is how many there are in all.
    public let callees: [RelatedSymbol]
    /// Every callee the index records, of which `callees` is the sample. Not part of the encoded
    /// form, whose shape is fixed.
    public var calleeCount: Int = 0
    /// How many call sites those callees are called from — more than `calleeCount` when one is
    /// called several times. Not part of the encoded form.
    public var calleeSiteCount: Int = 0
    public let implementations: [RelatedSymbol]
    public let supertypes: [RelatedSymbol]
    /// Present only over an index that is stale against its snapshot.
    public var staleness: Staleness?

    enum CodingKeys: String, CodingKey {
        case name, kinds, definitions, referenceCount, references, callerCount, callers, callees,
             implementations, supertypes, staleness
    }
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
        let callees = related(toName: name, query: .callees, limit: .max)

        var context = SymbolContext(
            name: name,
            kinds: Array(Set(definitions.map { $0.kind })).sorted(),
            definitions: definitions.compactMap { $0.definition },
            referenceCount: referenceHits.count,
            references: Array(referenceHits.prefix(sampleLimit)),
            callerCount: callerHits.count,
            callers: Array(callerHits.prefix(sampleLimit)),
            callees: Array(callees.prefix(sampleLimit)),
            implementations: related(toName: name, query: .implementations, limit: .max),
            supertypes: related(toName: name, query: .supertypes, limit: .max)
        )
        // Callees are counted by symbol, as `callees` counts them; the sites are counted apart.
        context.calleeCount = Set(callees.map(\.usr)).count
        context.calleeSiteCount = callees.count
        return context
    }
}
