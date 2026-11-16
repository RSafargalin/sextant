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
        var databases: [URL] = []
        self.stores = try storePaths.map { path in
            let database = Self.databaseDirectory(forStore: path, in: databaseRoot)
            try? FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
            CacheEviction.recordOwner(CanonicalPath.of(path), in: database)
            Self.removeDiscardedCopies(in: database)
            let units = Self.unitStamps(ofStore: path)
            let recorded = Self.recordedUnits(in: database)
            let kept = Self.prepareDatabase(database, forUnits: units, recorded: recorded)
            reused.append(kept)
            let store = try IndexStore(storePath: path, libraryPath: libraryPath, databasePath: database.path, listenToUnitEvents: listenToUnitEvents, projectRoot: projectRoot)
            // A record that already says exactly this is not written again.
            if !kept || recorded != units { Self.recordUnits(units, in: database) }
            databases.append(database)
            return store
        }
        self.storeCount = stores.count
        self.storePaths = storePaths
        self.reusedDatabase = reused
        self.databases = databases
        self.projectRoot = projectRoot
        self.polled = listenToUnitEvents
    }

    /// The database directory of each store, in the order of `storePaths`.
    private let databases: [URL]
    /// The project the stores were opened for, when one was named.
    public let projectRoot: String?
    /// Whether the databases may have been brought up to date with the stores while open (polled,
    /// or listening to unit events), importing units the record written on open does not list.
    private var polled: Bool

    /// Adds to each database's record the units that appeared in its store while it was open, so
    /// that the next run knows the database may hold them. Runs before the stores close.
    deinit {
        guard polled else { return }
        for (path, database) in zip(storePaths, databases) {
            guard let recorded = Self.recordedUnits(in: database) else { continue }
            let added = Self.unitStamps(ofStore: path).filter { recorded[$0.key] == nil }
            guard !added.isEmpty else { continue }
            Self.recordUnits(recorded.merging(added) { kept, _ in kept }, in: database)
        }
    }

    /// The file in a database directory that lists the units the database was last opened over,
    /// with the stamp of each unit file at that moment.
    static let unitListFileName = "sextant-units"
    /// The first line of that file in the format this version writes.
    static let unitListHeader = "sextant-units 2"

    /// What the record keeps of one unit file: its modification time (the only thing IndexStoreDB
    /// compares when it decides whether to read a unit again), its size, its inode and its status
    /// change time, all from one `lstat`.
    struct UnitStamp: Equatable, Sendable {
        let modified: Int64
        let size: Int64
        let inode: UInt64
        let statusChanged: Int64

        /// Whether the database may answer from an earlier version of this unit: IndexStoreDB reads
        /// a unit again only when its modification time moved, so a unit whose time is the same
        /// but whose file is not the one recorded was rewritten with its time put back. A unit
        /// rewritten in place under the same modification time, size, inode and status change time
        /// is not told apart — writing a file always moves its status change time, so that takes a
        /// clock set back or a file system that does not keep the time.
        func mayBeStale(against recorded: UnitStamp) -> Bool {
            modified == recorded.modified && self != recorded
        }
    }

    /// Keeps the database from an earlier run only when it can be brought up to date by the
    /// import IndexStoreDB runs on open, which adds new units and re-reads the units whose
    /// modification time moved, but never drops a unit that has disappeared from the store and
    /// never re-reads one rewritten under the same modification time. A database that knew a unit
    /// the store no longer holds, or one whose unit file has the recorded modification time but is
    /// not the recorded file (`UnitStamp.mayBeStale`), would keep answering from what it imported.
    /// Such a database — or one with no record of its units, or a record in an earlier format — is
    /// removed, and a new one is built from every unit. Returns whether it was kept.
    static func prepareDatabase(_ database: URL, forUnits units: [String: UnitStamp]) -> Bool {
        prepareDatabase(database, forUnits: units, recorded: recordedUnits(in: database))
    }

    /// `prepareDatabase(_:forUnits:)` with the record already read.
    static func prepareDatabase(_ database: URL, forUnits units: [String: UnitStamp], recorded: [String: UnitStamp]?) -> Bool {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(atPath: database.path)) ?? []
        let data = entries.filter { $0 != unitListFileName && $0 != CacheEviction.ownerFileName }
        guard !data.isEmpty else { return false }
        if let recorded,
           recorded.allSatisfy({ name, stamp in units[name].map { !$0.mayBeStale(against: stamp) } ?? false }) {
            // IndexStoreDB keeps a closed database under `<version>/saved`; without one it builds anew.
            return data.contains { manager.fileExists(atPath: database.appendingPathComponent("\($0)/saved").path) }
        }
        for entry in data { try? manager.removeItem(at: database.appendingPathComponent(entry)) }
        return false
    }

    /// Removes the copies of a database that IndexStoreDB itself has discarded, by its own rule: a
    /// directory named `…-dead`, or `p<pid>-…` of a process that is no longer running. IndexStoreDB
    /// removes them on a background queue after it opens, which a command that exits right after
    /// answering never lets finish — so every concurrent cold query left a full copy behind.
    static func removeDiscardedCopies(in database: URL) {
        let manager = FileManager.default
        let own = getpid()
        for version in (try? manager.contentsOfDirectory(atPath: database.path)) ?? [] {
            let directory = database.appendingPathComponent(version)
            for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where isDiscarded(name, ownProcess: own) {
                try? manager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Whether IndexStoreDB treats a directory of a database version as discarded.
    static func isDiscarded(_ name: String, ownProcess: pid_t) -> Bool {
        if name.hasSuffix("-dead") { return true }
        guard name.hasPrefix("p"), let dash = name.firstIndex(of: "-"),
              let pid = pid_t(name[name.index(after: name.startIndex)..<dash]), pid != ownProcess, pid > 0 else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    static func recordUnits(_ units: [String: UnitStamp], in database: URL) {
        let lines = units.sorted { $0.key < $1.key }.map { name, stamp in
            "\(name)\t\(stamp.modified)\t\(stamp.size)\t\(stamp.inode)\t\(stamp.statusChanged)"
        }
        try? Data(([unitListHeader] + lines).joined(separator: "\n").utf8)
            .write(to: database.appendingPathComponent(unitListFileName), options: .atomic)
    }

    /// The units a database's record lists; nil when there is no record, or it is not in the
    /// format this version writes.
    static func recordedUnits(in database: URL) -> [String: UnitStamp]? {
        guard let text = try? String(contentsOf: database.appendingPathComponent(unitListFileName), encoding: .utf8)
        else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.popFirst() == Substring(unitListHeader) else { return nil }
        var units: [String: UnitStamp] = [:]
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, !fields[0].isEmpty,
                  let modified = Int64(fields[1]), let size = Int64(fields[2]),
                  let inode = UInt64(fields[3]), let changed = Int64(fields[4]) else { return nil }
            units[String(fields[0])] = UnitStamp(modified: modified, size: size, inode: inode, statusChanged: changed)
        }
        return units
    }

    /// The unit files of a store, as `<version>/<name>`, each with its stamp — a directory listing
    /// and one `lstat` per unit, never a read.
    static func unitStamps(ofStore storePath: String) -> [String: UnitStamp] {
        let store = URL(fileURLWithPath: storePath, isDirectory: true)
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
        var stamps: [String: UnitStamp] = [:]
        for version in versions where version.hasPrefix("v") {
            guard let directory = opendir(store.appendingPathComponent("\(version)/units").path) else { continue }
            defer { closedir(directory) }
            let descriptor = dirfd(directory)
            while let entry = readdir(directory) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                guard name != ".", name != ".." else { continue }
                var status = stat()
                guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                stamps["\(version)/\(name)"] = UnitStamp(
                    modified: Int64(status.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_mtimespec.tv_nsec),
                    size: Int64(status.st_size),
                    inode: UInt64(status.st_ino),
                    statusChanged: Int64(status.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(status.st_ctimespec.tv_nsec))
            }
        }
        return stamps
    }

    /// The database directory of one store: a hash of the store's canonical path, so the name has
    /// a fixed length however deep the store lies, two stores never share one, and two spellings
    /// of one store do. The directory records the store it belongs to, for the cache eviction.
    public static func databaseDirectory(forStore storePath: String, in databaseRoot: String) -> URL {
        URL(fileURLWithPath: databaseRoot, isDirectory: true)
            .appendingPathComponent(CanonicalPath.entryName(of: storePath), isDirectory: true)
    }

    /// Reads newly written units across all stores (freshness for a long-lived server).
    public func pollForChanges() {
        polled = true
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
                    base[hit.usr] = existing.replacing(definition: definition, references: existing.references)
                }
                for reference in hit.references where seen[hit.usr]?.insert(key(reference)).inserted == true {
                    references[hit.usr]?.append(reference)
                }
            }
        }

        return order.map { usr in
            let hit = base[usr]!
            let merged = (references[usr] ?? []).sorted(by: SourceLocation.isOrderedBefore)
            return hit.replacing(definition: hit.definition, references: Array(merged.prefix(limit)),
                                 totalReferences: merged.count)
        }
        .sorted { $0.usr < $1.usr }
    }
}
