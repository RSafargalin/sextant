import Foundation

/// The index as every symbol answer reads it: the stores' answers, stated against the sources as
/// they are now. Every column is restated in the reported unit (`IndexColumns`). A position in a
/// project file that no longer exists, and that no freshness report names, is left out — with
/// the symbol it belongs to, a reference from it, or a call from it — and counted in `leftOut`,
/// which every surface names (`AbsentSources`). Beyond that, over a fresh index, or one judged by
/// build time, it returns exactly what the stores return. Over an index stale against its
/// snapshot, every position in a changed file is mapped onto the current text or marked
/// unconfirmed, and every answer carries a `Staleness` note.
///
/// The one place the semantic commands of the CLI and their MCP tools pass through, so that none
/// of them can print a position the others would have corrected.
public struct TranslatedIndex: SemanticIndex {
    public let base: IndexStoreSet
    public let drift: IndexDrift?
    private let columns: IndexColumns
    private let absent: AbsentSources

    public init(_ base: IndexStoreSet, drift: IndexDrift?) {
        self.base = base
        self.drift = drift
        self.columns = IndexColumns(drift: drift)
        self.absent = AbsentSources(projectRoot: base.projectRoot, drift: drift)
    }

    /// What the answers given so far left out because their files no longer exist; nil when
    /// nothing was.
    public var leftOut: AbsentSources.Summary? { absent.summary }

    /// A position the stores recorded, stated against the current text: its column restated from
    /// the text it was recorded in, then, over a stale index, its line mapped.
    private func stated(_ location: SourceLocation) -> SourceLocation {
        let restated = columns.restate(location)
        return drift?.translate(restated) ?? restated
    }

    public func lookup(name: String, query: SymbolQuery, limit: Int = 1000) -> [SymbolHit] {
        // Every position, so that one in a missing file comes off the total and not only off the
        // part of the list the limit keeps.
        let hits = base.lookup(name: name, query: query, limit: .max, indexedText: drift.map { $0.indexedLines(ofFile:) })
            .compactMap { hit -> SymbolHit? in
                let references = hit.references.filter { !absent.leavesOut($0) }
                let definition = hit.definition.flatMap { absent.leavesOut($0) ? nil : $0 }
                let lost = references.count < hit.references.count || (hit.definition != nil && definition == nil)
                // A symbol nothing is left of was only ever in files that are gone.
                if lost && definition == nil && references.isEmpty { return nil }
                return SymbolHit(name: hit.name, usr: hit.usr, kind: hit.kind, definition: definition,
                                 references: Array(references.prefix(limit)),
                                 totalReferences: hit.totalReferences - (hit.references.count - references.count))
            }
        guard !hits.isEmpty else { return hits }
        let note = staleness(forName: name, query: query)
        return hits.map { hit in
            var translated = SymbolHit(name: hit.name, usr: hit.usr, kind: hit.kind,
                                       definition: hit.definition.map(stated),
                                       references: hit.references.map(stated).sorted(by: SourceLocation.isOrderedBefore),
                                       totalReferences: hit.totalReferences)
            translated.staleness = note
            return translated
        }
    }

    public func related(toName name: String, query: RelationQuery, limit: Int = 1000) -> [RelatedSymbol] {
        // Every symbol, so that the limit applies to what is left once missing files are out.
        translated(Array(present(base.related(toName: name, query: query, limit: .max)).prefix(limit)))
    }

    public func resolveSymbols(forName name: String) -> [RelatedSymbol] {
        translated(base.resolveSymbols(forName: name), sorting: false)
    }

    /// Whether the index knows a symbol of this name at all: one it has a definition for, or one
    /// it records only declarations or uses of (a C function declared in a header and defined
    /// nowhere the index saw).
    public func knowsSymbol(named name: String) -> Bool {
        !resolveSymbols(forName: name).isEmpty || !lookup(name: name, query: .references, limit: 1).isEmpty
    }

    public func calls(ofUSR usr: String, direction: CallDirection) -> [RelatedSymbol] {
        translated(base.calls(ofUSR: usr, direction: direction))
    }

    public func outOfScope(forName name: String) -> (count: Int, roots: Set<String>) {
        base.outOfScope(forName: name)
    }

    /// Everything about one symbol, with the note when the index is stale.
    public func context(forName name: String, sampleLimit: Int = 10) -> SymbolContext? {
        guard var context = (self as SemanticIndex).context(forName: name, sampleLimit: sampleLimit) else { return nil }
        context.staleness = staleness(forName: name, query: .references)
        return context
    }

    /// What a change to the symbol would touch, with the note when the index is stale, and the
    /// files where nothing the index recorded can be confirmed any more.
    public func blastRadius(forName name: String) -> BlastRadius? {
        guard var radius = (self as SemanticIndex).blastRadius(forName: name) else { return nil }
        guard drift != nil else { return radius }
        radius.staleness = staleness(forName: name, query: .references)
        let locations = (lookup(name: name, query: .references, limit: .max)
                         + lookup(name: name, query: .callers, limit: .max))
            .flatMap { $0.references + [$0.definition].compactMap { $0 } }
        let byFile = Dictionary(grouping: locations, by: \.path)
        radius.unconfirmedFiles = byFile.filter { $0.value.allSatisfy { !$0.isConfirmed } }.keys.sorted()
        return radius
    }

    /// The note for an answer about `name`; nil unless the index is stale against its snapshot.
    /// Candidates exclude every position the index confirms for the name in any role, so a use the
    /// index knows as a reference is not offered as unknown to a question about calls.
    public func staleness(forName name: String, query: SymbolQuery) -> Staleness? {
        guard let drift else { return nil }
        return drift.note(forName: name, known: base.positions(forName: name).map(stated),
                          declarationsOnly: query == .definitions)
    }

    /// The symbols with no position in a missing file. Both positions are judged, so that each one
    /// in a missing file is counted.
    private func present(_ symbols: [RelatedSymbol]) -> [RelatedSymbol] {
        symbols.filter { symbol in
            let located = absent.leavesOut(symbol.location)
            let called = symbol.callSite.map(absent.leavesOut) ?? false
            return !located && !called
        }
    }

    private func translated(_ symbols: [RelatedSymbol], sorting: Bool = true) -> [RelatedSymbol] {
        let mapped = present(symbols).map { symbol in
            RelatedSymbol(name: symbol.name, usr: symbol.usr, kind: symbol.kind,
                          location: stated(symbol.location),
                          callSite: symbol.callSite.map(stated),
                          definitionKnown: symbol.definitionKnown)
        }
        guard sorting, drift != nil else { return mapped }
        return mapped.sorted { SourceLocation.isOrderedBefore($0.callSite ?? $0.location, $1.callSite ?? $1.location) }
    }
}
