import Foundation

/// A union of several index stores: queries run across all of them, deduplicated by USR and position.
/// Needed for multi-package projects, where each package produces its own store.
public final class IndexStoreSet {
    let stores: [IndexStore]
    public let storeCount: Int

    /// `databaseRoot` is a stable directory for the IndexStoreDB database, reused between runs:
    /// warm queries are faster because only changed units are imported.
    public init(storePaths: [String], libraryPath: String, databaseRoot: String, listenToUnitEvents: Bool = false, projectRoot: String? = nil) throws {
        try? FileManager.default.createDirectory(atPath: databaseRoot, withIntermediateDirectories: true)
        self.stores = try storePaths.map { path in
            let sanitized = path.replacingOccurrences(of: "/", with: "_")
            return try IndexStore(storePath: path, libraryPath: libraryPath, databasePath: "\(databaseRoot)/\(sanitized)", listenToUnitEvents: listenToUnitEvents, projectRoot: projectRoot)
        }
        self.storeCount = stores.count
    }

    /// Reads newly written units across all stores (freshness for a long-lived server).
    public func pollForChanges() {
        stores.forEach { $0.pollForChanges() }
    }

    /// Canonical position key for cross-store dedup: USR plus the symlink-resolved path.
    /// resolvingSymlinks removes duplicates arising from different spellings of one path
    /// (/tmp vs /private/tmp, /var vs /private/var) — otherwise one symbol is counted twice.
    static func locationKey(usr: String, _ location: SourceLocation) -> String {
        let path = URL(fileURLWithPath: location.path).resolvingSymlinksInPath().path
        return "\(usr)|\(path):\(location.line):\(location.column)"
    }

    /// Records rejected by the scope filter across every open store.
    public func outOfScope(forName name: String) -> (count: Int, roots: Set<String>) {
        stores.reduce(into: (count: 0, roots: Set<String>())) { total, store in
            let store = store.outOfScope(forName: name)
            total.count += store.count
            total.roots.formUnion(store.roots)
        }
    }

    public func related(toName name: String, query: RelationQuery, limit: Int = 1000) -> [RelatedSymbol] {
        var seen = Set<String>()
        var results: [RelatedSymbol] = []
        for store in stores {
            for item in store.related(toName: name, query: query, limit: .max) {
                let key = Self.locationKey(usr: item.usr, item.location)
                if seen.insert(key).inserted { results.append(item) }
            }
        }
        return Array(results.sorted { SourceLocation.isOrderedBefore($0.location, $1.location) }.prefix(limit))
    }

    public func resolveSymbols(forName name: String) -> [RelatedSymbol] {
        var seen = Set<String>()
        var results: [RelatedSymbol] = []
        for store in stores {
            for symbol in store.resolveSymbols(forName: name) where seen.insert(symbol.usr).inserted {
                results.append(symbol)
            }
        }
        return results
    }

    public func calls(ofUSR usr: String, direction: CallDirection) -> [RelatedSymbol] {
        var seen = Set<String>()
        var results: [RelatedSymbol] = []
        for store in stores {
            for symbol in store.calls(ofUSR: usr, direction: direction) {
                let key = Self.locationKey(usr: symbol.usr, symbol.location)
                if seen.insert(key).inserted { results.append(symbol) }
            }
        }
        return results.sorted { SourceLocation.isOrderedBefore($0.location, $1.location) }
    }

    public func symbolNames(matchingPrefix prefix: String, limit: Int = 50) -> [String] {
        var names = Set<String>()
        for store in stores { names.formUnion(store.symbolNames(matchingPrefix: prefix, limit: limit)) }
        return Array(names.sorted().prefix(limit))
    }

    public func lookup(name: String, query: SymbolQuery, limit: Int = 1000) -> [SymbolHit] {
        // Per store without truncation (.max), so the limit applies deterministically after merging.
        Self.merge(stores.map { $0.lookup(name: name, query: query, limit: .max) }, limit: limit)
    }

    /// Merges results from several stores: definitions deduplicated by USR, occurrences by
    /// canonical position (resolvingSymlinks removes /private-style duplicate spellings of a path).
    static func merge(_ hitsPerStore: [[SymbolHit]], limit: Int) -> [SymbolHit] {
        var order: [String] = []
        var base: [String: SymbolHit] = [:]
        var seen: [String: Set<String>] = [:]
        var references: [String: [SourceLocation]] = [:]

        func key(_ location: SourceLocation) -> String {
            let path = URL(fileURLWithPath: location.path).resolvingSymlinksInPath().path
            return "\(path):\(location.line):\(location.column)"
        }

        for hits in hitsPerStore {
            for hit in hits {
                if base[hit.usr] == nil {
                    base[hit.usr] = hit
                    order.append(hit.usr)
                    seen[hit.usr] = []
                    references[hit.usr] = []
                } else if base[hit.usr]?.definition == nil, let definition = hit.definition {
                    // another store knows the definition — prefer the non-nil one
                    let existing = base[hit.usr]!
                    base[hit.usr] = SymbolHit(name: existing.name, usr: existing.usr, kind: existing.kind, definition: definition, references: existing.references)
                }
                for reference in hit.references where seen[hit.usr]?.insert(key(reference)).inserted == true {
                    references[hit.usr]?.append(reference)
                }
            }
        }

        return order.map { usr in
            let hit = base[usr]!
            let merged = (references[usr] ?? []).sorted(by: SourceLocation.isOrderedBefore)
            return SymbolHit(
                name: hit.name,
                usr: usr,
                kind: hit.kind,
                definition: hit.definition,
                references: Array(merged.prefix(limit)),
                totalReferences: merged.count
            )
        }
        .sorted { $0.usr < $1.usr }
    }
}
