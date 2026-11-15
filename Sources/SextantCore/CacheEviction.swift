import Darwin
import Foundation

/// The names of sextant's persistent caches, one place for all of them. A value-format change
/// bumps the version of its namespace; the eviction removes every other version of the family.
public enum CacheNamespace {
    public static let declarations = "declarations-v5"
    public static let driftDeclarations = "drift-declarations-v2"
    public static let search = "search-v4"
    public static let lint = "lint-v4"
    public static let storeCoverage = "store-coverage-v3"

    /// Every versioned namespace in use. A directory `<family>-v<N>` of one of these families with
    /// another version is a leftover of an earlier format.
    public static let versioned = [declarations, driftDeclarations, search, lint, storeCoverage]
}

/// Removes what sextant's cache directory (`~/Library/Caches/sextant`) holds for nothing: versions
/// of a cache that a newer format replaced, and entries for stores and projects that no longer
/// exist. Runs from `sextant index` and `sextant doctor`, never while a query is answered.
///
/// Nothing outside the cache directory is ever removed: every removal is checked against it, and a
/// symbolic link is removed as a link, never followed.
public enum CacheEviction {
    /// What one run removed.
    public struct Report: Sendable, Equatable {
        /// Removed entries, relative to the cache directory, sorted.
        public var removed: [String] = []
        /// Bytes those entries held on disk.
        public var bytes: Int64 = 0

        public var summary: String? {
            guard !removed.isEmpty else { return nil }
            let megabytes = Double(bytes) / 1_048_576
            return "cache: removed \(removed.count) obsolete entr\(removed.count == 1 ? "y" : "ies") "
                + "(\(String(format: "%.1f", megabytes)) MB) from \(CacheEviction.displayRoot)"
        }
    }

    static let displayRoot = "~/Library/Caches/sextant"

    /// Where the caches live.
    public static func root(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Caches/sextant", isDirectory: true)
    }

    /// The file in an entry that names what the entry belongs to — a store or a project root —
    /// for entries whose name is a hash of it.
    public static let ownerFileName = "sextant-owner"

    /// Records what a hash-named cache entry belongs to, so that the eviction can tell when it is gone.
    public static func recordOwner(_ owner: String, in entry: URL) {
        try? Data(owner.utf8).write(to: entry.appendingPathComponent(ownerFileName), options: .atomic)
    }

    /// How long a socket no daemon holds is kept: a daemon starting at that moment owns it already.
    static let graceInterval: TimeInterval = 24 * 60 * 60

    /// One pass over every namespace.
    @discardableResult
    public static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           now: Date = Date(),
                           cap: Int = PersistentCacheLimit.files) -> Report {
        let cache = root(home: home)
        var pass = Pass(root: cache)
        guard pass.isDirectory(cache) else { return pass.report }

        pass.removeSupersededVersions()
        for namespace in CacheNamespace.versioned {
            pass.bound(cache.appendingPathComponent(namespace), cap: cap)
        }
        // Projects first: an umbrella that goes takes its store with it, and the store's database
        // and snapshot go in the passes after it.
        pass.removeEntries(in: "umbrella") { entry in
            if let owner = Pass.owner(of: entry) { return !FileManager.default.fileExists(atPath: owner) }
            // An umbrella from before owners were recorded: gone when none of its packages exist.
            let packages = Pass.umbrellaPackages(entry)
            return !packages.isEmpty && !packages.contains { FileManager.default.fileExists(atPath: $0) }
        }
        pass.removeEntries(in: "gitdir") { entry in
            guard let owner = Pass.owner(of: entry) else { return true }
            return !FileManager.default.fileExists(atPath: owner)
        }
        pass.removeEntries(in: "compile-db") { entry in
            // Gone when the database names files and none of them exist any more.
            let files = Pass.compiledFiles(entry)
            return !files.isEmpty && !files.contains { FileManager.default.fileExists(atPath: $0) }
        }
        pass.removeEntries(in: "index-db") { entry in
            // A database is named by a hash of its store and names the store inside; one without
            // that, under the earlier naming, is never read again.
            guard let owner = Pass.owner(of: entry) else { return true }
            return !FileManager.default.fileExists(atPath: owner)
        }
        pass.pruneSnapshots()
        // The copies of indexed text no remaining snapshot refers to, by the rule `sextant index`
        // applies after it records a snapshot.
        let copies = IndexedText.prune(home: home)
        pass.report.removed += copies.removed.map { "index-snapshot-text/\($0)" }
        pass.report.bytes += copies.bytes
        pass.removeOrphanedSockets(now: now)
        pass.report.removed.sort()
        return pass.report
    }

    /// Whether `url` lies strictly inside the cache directory, judged on the path as written with
    /// `.` and `..` resolved — so a path that climbs out with `..` is outside.
    public static func isInside(_ url: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard !url.path.split(separator: "/").contains("..") else { return false }
        return target.hasPrefix(base.hasSuffix("/") ? base : base + "/") && target != base
    }

    private struct Pass {
        let root: URL
        var report = Report()

        init(root: URL) { self.root = root }

        func isDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        func entries(of namespace: String) -> [URL] {
            let directory = root.appendingPathComponent(namespace, isDirectory: true)
            // A namespace that is itself a link is not walked: its entries are somewhere else.
            guard !Self.isSymbolicLink(directory), isDirectory(directory) else { return [] }
            return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .sorted().map { directory.appendingPathComponent($0) }
        }

        static func isSymbolicLink(_ url: URL) -> Bool {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
        }

        static func owner(of entry: URL) -> String? {
            guard !Self.isSymbolicLink(entry),
                  let data = FileManager.default.contents(atPath: entry.appendingPathComponent(ownerFileName).path),
                  let text = String(data: data, encoding: .utf8), text.hasPrefix("/") else { return nil }
            return text
        }

        func isOlder(_ entry: URL, than now: Date) -> Bool {
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path)
            let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
            return now.timeIntervalSince(modified) > graceInterval
        }

        mutating func remove(_ url: URL) {
            guard CacheEviction.isInside(url, root: root) else { return }
            let size = Self.allocatedSize(of: url)
            guard (try? FileManager.default.removeItem(at: url)) != nil else { return }
            report.removed.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
            report.bytes += size
        }

        mutating func removeEntries(in namespace: String, where shouldRemove: (URL) -> Bool) {
            for entry in entries(of: namespace) where shouldRemove(entry) { remove(entry) }
        }

        /// `<family>-v<N>` directories whose family is in use under another version.
        mutating func removeSupersededVersions() {
            let current = Set(CacheNamespace.versioned)
            let families = Set(CacheNamespace.versioned.compactMap(Self.family))
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
            for name in names where !current.contains(name) {
                guard let family = Self.family(of: name), families.contains(family) else { continue }
                remove(root.appendingPathComponent(name))
            }
        }

        static func family(of namespace: String) -> String? {
            guard let range = namespace.range(of: "-v", options: .backwards),
                  !namespace[range.upperBound...].isEmpty,
                  namespace[range.upperBound...].allSatisfy(\.isNumber) else { return nil }
            return String(namespace[..<range.lowerBound])
        }

        /// The oldest entries of a namespace past the limit, as `PersistentCache` bounds it.
        mutating func bound(_ directory: URL, cap: Int) {
            guard cap > 0, !Self.isSymbolicLink(directory),
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
                  files.count > cap else { return }
            for url in PersistentCache<Int>.oldestBeyondLimit(files, cap: cap) { remove(url) }
        }

        /// Removes snapshots whose store is gone.
        mutating func pruneSnapshots() {
            for entry in entries(of: "index-snapshot") {
                guard let data = FileManager.default.contents(atPath: entry.path),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let store = object["storePath"] as? String,
                      !FileManager.default.fileExists(atPath: store) else { continue }
                remove(entry)
            }
        }

        static func umbrellaPackages(_ entry: URL) -> [String] {
            guard let manifest = try? String(contentsOf: entry.appendingPathComponent("Package.swift"), encoding: .utf8)
            else { return [] }
            return manifest.components(separatedBy: ".package(path: \"").dropFirst().compactMap { rest in
                rest.components(separatedBy: "\")").first.map { $0.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\") }
            }
        }

        static func compiledFiles(_ entry: URL) -> [String] {
            guard let data = FileManager.default.contents(atPath: entry.path),
                  let commands = try? JSONDecoder().decode([CompileCommand].self, from: data) else { return [] }
            return commands.map(\.file)
        }

        /// A socket whose lock no daemon holds, left by a daemon that did not stop cleanly.
        mutating func removeOrphanedSockets(now: Date) {
            for entry in entries(of: "serve") where entry.pathExtension == "sock" && isOlder(entry, than: now) {
                let lockPath = entry.path + ".lock"
                let lock = open(lockPath, O_RDWR)
                if lock >= 0 {
                    defer { _ = Darwin.close(lock) }
                    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { continue }
                    remove(URL(fileURLWithPath: lockPath))
                }
                remove(entry)
            }
        }

        static func allocatedSize(of url: URL) -> Int64 {
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
            if let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink == true { return 0 }
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
                return Int64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
            }
            var total = Int64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
            for case let file as URL in enumerator {
                total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
            }
            return total
        }
    }
}
