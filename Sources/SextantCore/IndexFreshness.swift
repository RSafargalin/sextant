import Foundation

/// The single freshness layer for the index: one implementation shared by provenance, `doctor`,
/// `sextant store`, re-opening in MCP, and the daemon.
///
/// Two bases, chosen per answer and named in it:
/// - **the snapshot** `sextant index` took of the sources when it built the store. Where every
///   store read has one that still describes it, freshness is a comparison of content: the index
///   is stale exactly when some source differs from what was built, and the answer names those
///   files. Touching a file, or leaving a branch and coming back, changes nothing.
/// - **build time**, for every other store (Xcode's, an ordinary build's, one named with
///   `--index-store`, or one whose snapshot no longer matches it): a source modified after the
///   store's units were last written makes it stale.
///
/// The store's own timestamp is the mtime of `<store>/v*/units`: a build rewrites unit files
/// inside it, while the store directory's mtime does not move when files are merely overwritten.
public enum IndexFreshness {
    /// Index freshness. `unknown` means there is no data (no store, or an empty units directory);
    /// passing that off as "fresh" would put a trust label on something there is no basis to trust.
    public enum State: Sendable, Equatable {
        case fresh
        case stale
        case unknown
    }

    /// What freshness was judged against.
    public enum Basis: Sendable, Equatable {
        /// The snapshot `sextant index` took when it built the store.
        case snapshot
        /// The time the store's units were last written, against the sources' modification times.
        case buildTime
    }

    /// Freshness with its grounds: the basis, and on the snapshot basis everything that differs.
    public struct Report: Sendable, Equatable {
        public let state: State
        public let basis: Basis
        /// Sources whose content differs from what the store was built from, relative to the
        /// project root and sorted. Empty on the build-time basis, which cannot tell.
        public let changedFiles: [String]
        /// `Package.swift` / `Package.resolved` files changed since the build.
        public let changedManifests: [String]
        public let toolchain: IndexSnapshot.ToolchainChange?
        /// The exit status of the build the store came from, when it failed.
        public let failedBuildStatus: Int32?
        /// Files the failed build reported errors in.
        public let filesWithErrors: [String]
        /// Whether the build left test targets out (`--no-tests`).
        public let testsSkipped: Bool
        /// Why the snapshot basis was not used although a snapshot exists.
        public let snapshotProblem: String?

        public init(state: State, basis: Basis, changedFiles: [String] = [], changedManifests: [String] = [],
                    toolchain: IndexSnapshot.ToolchainChange? = nil, failedBuildStatus: Int32? = nil,
                    filesWithErrors: [String] = [], testsSkipped: Bool = false, snapshotProblem: String? = nil) {
            self.state = state
            self.basis = basis
            self.changedFiles = changedFiles
            self.changedManifests = changedManifests
            self.toolchain = toolchain
            self.failedBuildStatus = failedBuildStatus
            self.filesWithErrors = filesWithErrors
            self.testsSkipped = testsSkipped
            self.snapshotProblem = snapshotProblem
        }

        /// The basis in words, as every label states it.
        public var basisDescription: String {
            switch basis {
            case .snapshot: return "compared against the snapshot taken by `sextant index`"
            case .buildTime: return "compared by build time"
            }
        }

        /// Why the index is stale, as short clauses: the files that changed (up to `naming` of
        /// them by name), the manifests, the toolchain, a failed build. Empty when nothing is known
        /// beyond "stale", as on the build-time basis.
        public func reasons(naming limit: Int = 3) -> [String] {
            var reasons: [String] = []
            if !changedFiles.isEmpty {
                let named = changedFiles.prefix(limit).joined(separator: ", ")
                let more = changedFiles.count > limit ? " and \(changedFiles.count - limit) more" : ""
                reasons.append("\(changedFiles.count) file(s) changed since the index was built: \(named)\(more)")
            }
            if !changedManifests.isEmpty {
                reasons.append("\(changedManifests.joined(separator: ", ")) changed since the index was built")
            }
            if let toolchain {
                reasons.append("built with \(toolchain.recorded), now \(toolchain.current)")
            }
            if let failedBuildStatus {
                let files = filesWithErrors.isEmpty ? ""
                    : " (errors in \(filesWithErrors.prefix(limit).joined(separator: ", "))"
                      + (filesWithErrors.count > limit ? " and \(filesWithErrors.count - limit) more" : "") + ")"
                reasons.append("the build it came from failed with code \(failedBuildStatus)\(files) — "
                               + "files that did not compile are indexed as they were before")
            }
            return reasons
        }
    }

    /// When the store was last updated: the mtime of `<store>/v*/units`. A build writes new unit
    /// files there (the name carries a compilation hash), which moves the directory mtime —
    /// verified both when adding a symbol and when editing an existing file. The signal is O(1):
    /// walking tens of thousands of units would cost hundreds of milliseconds on EVERY query, and
    /// truncating the walk gives a non-deterministically wrong answer (entries are not in time order).
    public static func timestamp(ofStore storePath: String) -> Date? {
        let store = URL(fileURLWithPath: storePath, isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { return nil }

        var newest: Date?
        for version in versions where version.hasPrefix("v") {
            let units = store.appendingPathComponent("\(version)/units")
            guard let modified = (try? units.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if modified > (newest ?? .distantPast) { newest = modified }
        }
        return newest
    }

    /// When the freshest of the stores was last updated.
    public static func timestamp(ofStores storePaths: [String]) -> Date? {
        storePaths.compactMap { timestamp(ofStore: $0) }.max()
    }

    /// Freshness of a set of stores, with its grounds.
    ///
    /// The snapshot basis is used only when every store has a snapshot that still describes it;
    /// otherwise the whole set is judged by build time, from the OLDEST store: in a multi-package
    /// project building one package does not make the others fresh, and it is safer to err loudly
    /// towards "stale" than quietly towards "fresh".
    public static func report(storePaths: [String], projectRoot: String,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              toolchain: () -> ToolchainIdentity? = { ToolchainIdentity.current() },
                              git: SourceSnapshot.GitRunner = .system) -> Report {
        let timestamps = storePaths.compactMap { timestamp(ofStore: $0) }
        guard let oldest = timestamps.min() else {
            return Report(state: .unknown, basis: .buildTime)
        }

        var snapshots: [IndexSnapshot] = []
        var problem: String?
        for store in storePaths {
            switch IndexSnapshot.lookup(forStore: store, projectRoot: projectRoot, home: home) {
            case .trusted(let snapshot): snapshots.append(snapshot)
            case .untrusted(let reason): problem = problem ?? reason
            case .missing: break
            }
        }

        if snapshots.count == storePaths.count {
            var differences: [IndexSnapshot.Difference] = []
            for snapshot in snapshots {
                switch snapshot.difference(currentToolchain: toolchain, git: git) {
                case .success(let difference): differences.append(difference)
                case .failure(let failure): problem = problem ?? failure.reason
                }
            }
            if differences.count == snapshots.count {
                let failed = snapshots.first { $0.build.exitStatus != 0 }
                let changed = Set(differences.flatMap(\.changedFiles)).sorted()
                let manifests = Set(differences.flatMap(\.changedManifests)).sorted()
                let toolchainChange = differences.compactMap(\.toolchain).first
                let stale = !changed.isEmpty || !manifests.isEmpty || toolchainChange != nil || failed != nil
                return Report(state: stale ? .stale : .fresh, basis: .snapshot, changedFiles: changed,
                              changedManifests: manifests, toolchain: toolchainChange,
                              failedBuildStatus: failed?.build.exitStatus,
                              filesWithErrors: failed?.build.filesWithErrors ?? [],
                              testsSkipped: snapshots.contains { !$0.build.testsBuilt })
            }
        }

        let stale = SwiftSources.hasSourceNewer(than: oldest, under: URL(fileURLWithPath: projectRoot, isDirectory: true))
        return Report(state: stale ? .stale : .fresh, basis: .buildTime, snapshotProblem: problem)
    }

    /// Freshness of a set of stores, without its grounds.
    public static func state(storePaths: [String], projectRoot: String) -> State {
        report(storePaths: storePaths, projectRoot: projectRoot).state
    }

    /// Whether the index is stale. `unknown` counts as "not stale" for callers that need a boolean;
    /// where the honesty of the label matters, use `state`.
    public static func isStale(storePaths: [String], projectRoot: String) -> Bool {
        state(storePaths: storePaths, projectRoot: projectRoot) == .stale
    }

    /// Signature of the store state, to detect "appeared" or "rebuilt" without reading contents.
    /// Long-lived processes (MCP, `serve`) re-open the index when it changes. By directory mtime it
    /// did not change on an ordinary rebuild, so the index stayed stale.
    public static func signature(ofStores storePaths: [String]) -> String? {
        guard !storePaths.isEmpty else { return nil }
        let parts = storePaths.sorted().map { path in
            "\(path)@\(timestamp(ofStore: path)?.timeIntervalSince1970 ?? 0)"
        }
        return parts.joined(separator: "|")
    }
}
