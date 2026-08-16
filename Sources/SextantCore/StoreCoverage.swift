import Foundation

/// How much of a project an index store actually covers: of the source files on disk, how many the
/// store was built from.
///
/// This is the fact selection needs and the one it never had. Unit count is not it — measured on
/// this repository, the store with 560 units covered 12 files of the answer while the one with 525
/// covered 22 — and a timestamp is not it either. Coverage is measured against the files that are
/// there now, so a store that indexed a thousand files that have since been deleted scores by what
/// remains, which is what a question about today's code depends on.
public enum StoreCoverage {
    public struct Result: Sendable, Equatable, Codable {
        /// Project files the store was built from.
        public let covered: Int
        /// Project files on disk.
        public let total: Int
        /// Units whose main file lies outside the project — another checkout, or the SDK.
        public let foreign: Int

        public var fraction: Double { total == 0 ? 0 : Double(covered) / Double(total) }
        public var summary: String {
            total == 0 ? "no sources to cover" : "\(covered)/\(total) files (\(Int((fraction * 100).rounded()))%)"
        }
    }

    /// Coverage of one store, cached against the store's own state.
    ///
    /// Reading every unit costs real time on a large store (measured: 22 725 units), and the answer
    /// only changes when the store or the file list changes — so the cache key is both. A stale
    /// cache entry here would be a wrong number in a trust label, which is worse than the wait.
    public static func measure(store: String, projectRoot: URL, includeTests: Bool = true,
                               libraryPath: String? = nil) -> Result? {
        // The walk is memoised and cheap; resolving 12 000 paths through their symlinks is not, so
        // it happens only when the cache has nothing — measured 1.7s against 0.1s on a large project.
        let files = SwiftSources.files(under: projectRoot, includeTests: includeTests,
                                       extensions: ["swift"] + IndexDeclarations.clangExtensions)
        guard !files.isEmpty else { return nil }

        let key = cacheKey(store: store, fileCount: files.count)
        if let cached = cache.value(forKey: key) { return cached }
        let onDisk = Set(files.map { $0.resolvingSymlinksInPath().path })

        guard let reader = try? IndexStoreUnits.shared(libraryPath: libraryPath),
              let mainFiles = try? reader.mainFiles(inStore: store), !mainFiles.isEmpty
        else { return nil }

        let covered = onDisk.intersection(mainFiles)
        let result = Result(covered: covered.count, total: onDisk.count,
                            foreign: mainFiles.subtracting(onDisk).count)
        cache.set(result, forKey: key)
        return result
    }

    /// The store's identity for caching: its path, when its units were last written, and how many
    /// files the project has. A build writes units under new names, which moves the directory's
    /// timestamp; adding or deleting sources moves the count. Listing the units themselves would
    /// be a third signal and costs 0.3s on a large store — the two cheap ones move together with it.
    private static func cacheKey(store: String, fileCount: Int) -> String {
        let stamp = IndexFreshness.timestamp(ofStore: store)?.timeIntervalSince1970 ?? 0
        return ContentHash.of("\(store)|\(stamp)|\(fileCount)")
    }

    private static let cache = PersistentCache<Result>(namespace: "store-coverage-v1")
}
