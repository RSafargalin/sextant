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
        /// Project files on disk a unit can be built from: sources, not manifests or headers.
        public let total: Int
        /// Units whose main file lies outside the project — another checkout, or the SDK.
        public let foreign: Int
        /// Test files the store was NOT built from. Called out separately because this is the
        /// systematic hole rather than a random one: a build that skips the test targets removes
        /// every usage written in a test from every answer, and on a well-tested package that is
        /// most of them — measured on Alamofire, 25 references against 504.
        public let uncoveredTests: Int
        /// Real paths of project sources the store holds a unit for that no longer exist — deleted,
        /// or renamed — sorted.
        public let missingSources: [String]
        /// Real paths of project sources on disk the store holds no unit for, sorted.
        public let uncoveredSources: [String]

        public init(covered: Int, total: Int, foreign: Int, uncoveredTests: Int = 0,
                    missingSources: [String] = [], uncoveredSources: [String] = []) {
            self.covered = covered
            self.total = total
            self.foreign = foreign
            self.uncoveredTests = uncoveredTests
            self.missingSources = missingSources
            self.uncoveredSources = uncoveredSources
        }

        public var fraction: Double { total == 0 ? 0 : Double(covered) / Double(total) }
        public var summary: String {
            guard total > 0 else { return "no sources to cover" }
            let base = "\(covered)/\(total) files (\(Int((fraction * 100).rounded()))%)"
            return uncoveredTests > 0 ? base + ", \(uncoveredTests) test file(s) outside it" : base
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
        // Only what a unit is built from: a package manifest describes the build and a header is
        // compiled inside the sources that include it, so neither is ever a unit's main file, and
        // counting them kept a complete index short of 100%.
        let files = unitSources(under: projectRoot, includeTests: includeTests)
        guard !files.isEmpty else { return nil }

        let key = cacheKey(store: store, projectRoot: projectRoot, includeTests: includeTests, files: files)
        if let cached = cache.value(forKey: key) { return cached }
        let onDisk = Set(files.map { $0.resolvingSymlinksInPath().path })

        guard let reader = try? IndexStoreUnits.shared(libraryPath: libraryPath),
              let mainFiles = try? reader.mainFiles(inStore: store), !mainFiles.isEmpty
        else { return nil }

        let covered = onDisk.intersection(mainFiles)
        let missedTests = onDisk.subtracting(mainFiles).filter { $0.hasSuffix("Tests.swift") }
        // Foundation spells an existing `/private/tmp/x` as `/tmp/x` and a missing one as it is, so a
        // missing file is compared by its canonical spelling.
        let rootPath = CanonicalPath.of(projectRoot.path) + "/"
        let missing = mainFiles.subtracting(onDisk).filter { path in
            !FileManager.default.fileExists(atPath: path) && CanonicalPath.ofFile(path).hasPrefix(rootPath)
        }
        let result = Result(covered: covered.count, total: onDisk.count,
                            foreign: mainFiles.subtracting(onDisk).count,
                            uncoveredTests: missedTests.count,
                            missingSources: missing.sorted(),
                            uncoveredSources: onDisk.subtracting(mainFiles).sorted())
        cache.set(result, forKey: key)
        return result
    }

    /// Coverage of several stores read together: a file is covered when any of them holds a unit
    /// for it, so what is left out is what every one of them leaves out — not a sum of
    /// overlapping counts. nil when any store could not be measured, or they were measured against
    /// different file sets.
    public static func union(_ results: [Result]) -> Result? {
        guard let first = results.first, results.allSatisfy({ $0.total == first.total }) else { return nil }
        guard results.count > 1 else { return first }
        let uncovered = results.dropFirst().reduce(Set(first.uncoveredSources)) { $0.intersection($1.uncoveredSources) }
        return Result(covered: first.total - uncovered.count, total: first.total,
                      foreign: results.map(\.foreign).max() ?? 0,
                      uncoveredTests: uncovered.filter { $0.hasSuffix("Tests.swift") }.count,
                      missingSources: Array(Set(results.flatMap(\.missingSources))).sorted(),
                      uncoveredSources: uncovered.sorted())
    }

    /// The project files a unit can be built from: sources, not package manifests or headers.
    public static func unitSources(under projectRoot: URL, includeTests: Bool) -> [URL] {
        SwiftSources.files(under: projectRoot, includeTests: includeTests,
                           extensions: ["swift"] + IndexDeclarations.clangExtensions)
            .filter { !SwiftSources.isPackageManifest(relativePath: $0.lastPathComponent)
                      && !IndexDeclarations.headerExtensions.contains($0.pathExtension) }
    }

    /// The measurement's identity for caching: the store's path and when its units were last
    /// written, the project it is measured against (canonical, so two spellings share an entry),
    /// whether tests count, and which files the project has. A build writes units under new
    /// names, which moves the directory's timestamp; adding, deleting or renaming a source changes
    /// the file set — a count alone stays the same over a rename, and served the old figure.
    /// Listing the units themselves would be a further signal and costs 0.3s on a large store —
    /// the cheap ones move together with it. One store measured against two projects, or with and
    /// without tests, is two different numbers.
    static func cacheKey(store: String, projectRoot: URL, includeTests: Bool, files: [URL]) -> String {
        let stamp = IndexFreshness.timestamp(ofStore: store)?.timeIntervalSince1970 ?? 0
        let root = CanonicalPath.of(projectRoot.path)
        let fileSet = ContentHash.of(files.map(\.path).sorted().joined(separator: "\n"))
        return ContentHash.of("\(store)|\(stamp)|\(root)|\(includeTests)|\(fileSet)")
    }

    private static let cache = PersistentCache<Result>(namespace: CacheNamespace.storeCoverage)
}
