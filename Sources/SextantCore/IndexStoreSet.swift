import Foundation

/// A union of several index stores: queries run across all of them, deduplicated by USR and position.
/// Needed for multi-package projects, where each package produces its own store.
public final class IndexStoreSet {
    let stores: [IndexStore]
    public let storeCount: Int
    /// The stores this set reads, in the order they were opened.
    public let storePaths: [String]
    /// For each store, whether the database kept from an earlier run was opened rather than a new
    /// one built from every unit.
    public let reusedDatabase: [Bool]

    /// `databaseRoot` is a stable directory for the IndexStoreDB databases, reused between runs:
    /// warm queries are faster because only changed units are imported. Each store has its own
    /// database in it, named by `databaseDirectory(forStore:in:)`.
    public init(storePaths: [String], libraryPath: String, databaseRoot: String, listenToUnitEvents: Bool = false, projectRoot: String? = nil) throws {
        try? FileManager.default.createDirectory(atPath: databaseRoot, withIntermediateDirectories: true)
        var reused: [Bool] = []
        self.stores = try storePaths.map { path in
            let database = Self.databaseDirectory(forStore: path, in: databaseRoot)
            try? FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
            CacheEviction.recordOwner(CanonicalPath.of(path), in: database)
            let units = Self.unitNames(ofStore: path)
            reused.append(Self.prepareDatabase(database, forUnits: units))
            let store = try IndexStore(storePath: path, libraryPath: libraryPath, databasePath: database.path, listenToUnitEvents: listenToUnitEvents, projectRoot: projectRoot)
            Self.recordUnits(units, in: database)
            return store
        }
        self.storeCount = stores.count
        self.storePaths = storePaths
        self.reusedDatabase = reused
    }

    /// The file in a database directory that lists the units the database was last opened over.
    static let unitListFileName = "sextant-units"

    /// Keeps the database from an earlier run only when it can be brought up to date by the
    /// import IndexStoreDB runs on open, which adds new units and re-reads rewritten ones but never
    /// drops a unit that has disappeared from the store: a database that knew a unit the store no
    /// longer holds would keep answering from it. Such a database — or one with no record of its
    /// units — is removed, and a new one is built from every unit. Returns whether it was kept.
    static func prepareDatabase(_ database: URL, forUnits units: Set<String>) -> Bool {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(atPath: database.path)) ?? []
        let data = entries.filter { $0 != unitListFileName && $0 != CacheEviction.ownerFileName }
        guard !data.isEmpty else { return false }
        if let recorded = try? String(contentsOf: database.appendingPathComponent(unitListFileName), encoding: .utf8),
           Set(recorded.split(separator: "\n").map(String.init)).isSubset(of: units) {
            // IndexStoreDB keeps a closed database under `<version>/saved`; without one it builds anew.
            return data.contains { manager.fileExists(atPath: database.appendingPathComponent("\($0)/saved").path) }
        }
        for entry in data { try? manager.removeItem(at: database.appendingPathComponent(entry)) }
        return false
    }

    static func recordUnits(_ units: Set<String>, in database: URL) {
        try? Data(units.sorted().joined(separator: "\n").utf8)
            .write(to: database.appendingPathComponent(unitListFileName), options: .atomic)
    }

    /// The unit files of a store, as `<version>/<name>` — a directory listing, not a read.
    static func unitNames(ofStore storePath: String) -> Set<String> {
        let store = URL(fileURLWithPath: storePath, isDirectory: true)
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
        var names = Set<String>()
        for version in versions where version.hasPrefix("v") {
            let units = store.appendingPathComponent("\(version)/units").path
            for name in (try? FileManager.default.contentsOfDirectory(atPath: units)) ?? [] { names.insert("\(version)/\(name)") }
        }
        return names
    }

    /// The database directory of one store: a hash of the store's canonical path, so the name has
    /// a fixed length however deep the store lies, two stores never share one, and two spellings
    /// of one store do. The directory records the store it belongs to, for the cache eviction.
    public static func databaseDirectory(forStore storePath: String, in databaseRoot: String) -> URL {
        URL(fileURLWithPath: databaseRoot, isDirectory: true)
            .appendingPathComponent(String(ContentHash.of(CanonicalPath.of(storePath)).prefix(24)), isDirectory: true)
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
        return "\(usr)|\(path):\(location.line):\(location.column ?? 0)"
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
        lookup(name: name, query: query, limit: limit, indexedText: nil)
    }

    /// `lookup`, checking positions against the text each changed file was indexed from.
    func lookup(name: String, query: SymbolQuery, limit: Int, indexedText: ((String) -> [String]?)?) -> [SymbolHit] {
        // Per store without truncation (.max), so the limit applies deterministically after merging.
        Self.merge(stores.map { $0.lookup(name: name, query: query, limit: .max, indexedText: indexedText) }, limit: limit)
    }

    /// Every position the stores record for symbols with this name, any role.
    func positions(forName name: String) -> [SourceLocation] {
        stores.flatMap { $0.positions(forName: name) }
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
            return "\(path):\(location.line):\(location.column ?? 0)"
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
