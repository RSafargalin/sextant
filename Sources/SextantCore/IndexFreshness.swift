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
        public var state: State
        public let basis: Basis
        /// Sources whose content differs from what the store was built from, relative to the
        /// project root and sorted — the sources a failed build left without a unit for their
        /// present text included (`notBuiltFiles`). On the build-time basis, which cannot tell
        /// what changed, only `unindexedFiles`: empty unless sources were removed since the build.
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
        /// Sources the failed build the store came from left without a unit for their present
        /// text, which exist now. They are among `changedFiles`, with no indexed text: the store
        /// holds nothing, or something older than the snapshot, for them.
        public var notBuiltFiles: [String] = []
        /// When a `sextant index` run for the project started that has not finished — still
        /// building, or stopped before it recorded what it built. The stores may then be partial,
        /// so the index is not fresh on either basis.
        public var unfinishedIndexRun: Date?
        /// On the build-time basis, sources the store was built from that were deleted or renamed
        /// after it was built, relative to the project root. A deletion moves no file's time, so
        /// without them such an index reads as fresh while answers lose what was in those files.
        public var removedSources: [String] = []
        /// On the build-time basis, when `removedSources` is not empty: the sources on disk the
        /// store holds nothing for that appeared or moved since it was built — where a renamed
        /// file's uses now are. They are among `changedFiles`, so their text is searched for
        /// candidates.
        public var unindexedFiles: [String] = []
        /// On the snapshot basis, for each changed file that existed when the store was built, the
        /// blob hash of the content it was built from — what `IndexDrift` reads the indexed text
        /// by. A changed file absent here did not exist then.
        public var indexedContent: [String: String] = [:]

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

        /// Why the snapshot was not used, when one exists and was not, in the words the trust label
        /// and `sextant store` both state it in.
        public var snapshotNote: String? { snapshotProblem.map { "snapshot not used: \($0)" } }

        /// The basis, with `snapshotNote` when there is one — as the trust label states it.
        public var basisWithReason: String { basisDescription + (snapshotNote.map { "; \($0)" } ?? "") }

        /// Why the index is stale, as short clauses: the files that changed (up to `naming` of
        /// them by name), the manifests, the toolchain, a failed build. Empty when nothing is known
        /// beyond "stale", as on the build-time basis.
        public func reasons(naming limit: Int = 3) -> [String] {
            var reasons: [String] = []
            if let unfinishedIndexRun {
                reasons.append("the `sextant index` run started \(StoreSelection.stamp(unfinishedIndexRun)) did not finish — it is still building, "
                               + "or it was stopped — so the store may be partial")
            }
            if !removedSources.isEmpty {
                let named = removedSources.prefix(limit).joined(separator: ", ")
                let more = removedSources.count > limit ? " and \(removedSources.count - limit) more" : ""
                reasons.append("\(removedSources.count) source(s) the index was built from were deleted or renamed "
                               + "since: \(named)\(more)")
            }
            let notBuilt = Set(notBuiltFiles).union(unindexedFiles)
            let edited = changedFiles.filter { !notBuilt.contains($0) }
            if !edited.isEmpty {
                let named = edited.prefix(limit).joined(separator: ", ")
                let more = edited.count > limit ? " and \(edited.count - limit) more" : ""
                reasons.append("\(edited.count) file(s) changed since the index was built: \(named)\(more)")
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
                if notBuiltFiles.isEmpty {
                    reasons.append("the build it came from failed with code \(failedBuildStatus)\(files) — "
                                   + "files that did not compile are indexed as they were before")
                } else {
                    let named = notBuiltFiles.prefix(limit).joined(separator: ", ")
                    let more = notBuiltFiles.count > limit ? " and \(notBuiltFiles.count - limit) more" : ""
                    reasons.append("the build it came from failed with code \(failedBuildStatus)\(files) — "
                                   + "\(notBuiltFiles.count) file(s) it did not compile are not indexed: \(named)\(more)")
                }
            }
            return reasons
        }
    }

    /// When the store was last updated: the mtime of `<store>/v*/units`. A build writes new unit
    /// files there (the name carries a compilation hash), which moves the directory mtime —
    /// verified both when adding a symbol and when editing an existing file. The signal is O(1):
    /// walking tens of thousands of units would cost hundreds of milliseconds on EVERY query, and
    /// truncating the walk gives a non-deterministically wrong answer (entries are not in time order).
    ///
    /// A `units` directory with nothing in it gives no timestamp: a store with no units has nothing
    /// to read, and dating it would make every caller treat it as a built store — usable, and
    /// judged fresh or stale against a time nothing was written at.
    public static func timestamp(ofStore storePath: String) -> Date? {
        let store = URL(fileURLWithPath: storePath, isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { return nil }

        var newest: Date?
        for version in versions where version.hasPrefix("v") {
            let units = store.appendingPathComponent("\(version)/units")
            guard let modified = (try? units.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  holdsAnyEntry(units.path)
            else { continue }
            if modified > (newest ?? .distantPast) { newest = modified }
        }
        return newest
    }

    /// Whether a directory holds at least one entry, read up to the first one rather than listed.
    static func holdsAnyEntry(_ directory: String) -> Bool {
        guard let handle = opendir(directory) else { return false }
        defer { closedir(handle) }
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { return true }
        }
        return false
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
        var report = judged(storePaths: storePaths, projectRoot: projectRoot, home: home, toolchain: toolchain, git: git)
        // An index run that has not finished leaves the store in the middle of a rewrite, whatever
        // either basis would say about it.
        if report.state != .unknown, let started = IndexBuild.unfinishedRun(forRoot: projectRoot, home: home) {
            report.unfinishedIndexRun = started
            report.state = .stale
        }
        return report
    }

    private static func judged(storePaths: [String], projectRoot: String, home: URL,
                               toolchain: () -> ToolchainIdentity?, git: SourceSnapshot.GitRunner) -> Report {
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
                // What a failed build did not compile is not indexed, whatever its content: its
                // positions are unconfirmed and its text is searched for candidates, as an edit's.
                let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
                let notBuilt = Set(snapshots.flatMap { $0.build.filesNotBuilt ?? [] }).filter { relative in
                    FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
                }.sorted()
                let changed = Set(differences.flatMap(\.changedFiles)).union(notBuilt).sorted()
                let manifests = Set(differences.flatMap(\.changedManifests)).sorted()
                let toolchainChange = differences.compactMap(\.toolchain).first
                let stale = !changed.isEmpty || !manifests.isEmpty || toolchainChange != nil || failed != nil
                var report = Report(state: stale ? .stale : .fresh, basis: .snapshot, changedFiles: changed,
                                    changedManifests: manifests, toolchain: toolchainChange,
                                    failedBuildStatus: failed?.build.exitStatus,
                                    filesWithErrors: failed?.build.filesWithErrors ?? [],
                                    testsSkipped: snapshots.contains { !$0.build.testsBuilt })
                for difference in differences {
                    report.indexedContent.merge(difference.indexedContent) { first, _ in first }
                }
                report.notBuiltFiles = notBuilt
                for file in notBuilt { report.indexedContent[file] = nil }
                return report
            }
        }

        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let stale = SwiftSources.hasSourceNewer(than: oldest, under: root)
        let removed = removedSinceBuild(storePaths: storePaths, projectRoot: root)
        var report = Report(state: stale || !removed.removed.isEmpty ? .stale : .fresh, basis: .buildTime,
                            changedFiles: removed.unindexed, snapshotProblem: problem)
        report.removedSources = removed.removed
        report.unindexedFiles = removed.unindexed
        return report
    }

    /// The sources the stores were built from that were deleted or renamed after the build — a
    /// unit whose file is gone from a directory changed since the store was written — and the
    /// sources without a unit in directories changed since, where a renamed file now is. A file
    /// deleted before the build whose unit stayed behind is not among them: the build saw the
    /// directory without it, and what it indexed is still all there is. Read from the stores'
    /// coverage, which the trust label measures anyway; nothing without it.
    static func removedSinceBuild(storePaths: [String], projectRoot: URL,
                                  coverage measure: (String) -> StoreCoverage.Result? = { _ in nil })
        -> (removed: [String], unindexed: [String]) {
        let rootPath = CanonicalPath.of(projectRoot.path)
        var removed = Set<String>(), unindexed = Set<String>()
        for store in storePaths {
            guard let built = timestamp(ofStore: store),
                  let coverage = measure(store) ?? StoreCoverage.measure(store: store, projectRoot: projectRoot)
            else { continue }
            func changedSince(_ path: String) -> Bool {
                let directory = (path as NSString).deletingLastPathComponent
                let modified = (try? FileManager.default.attributesOfItem(atPath: directory))?[.modificationDate] as? Date
                return modified.map { $0 > built } ?? true
            }
            let gone = coverage.missingSources.filter(changedSince)
            guard !gone.isEmpty else { continue }
            removed.formUnion(gone)
            unindexed.formUnion(coverage.uncoveredSources.filter(changedSince))
        }
        func relative(_ path: String) -> String {
            let canonical = CanonicalPath.ofFile(path)
            return canonical.hasPrefix(rootPath + "/") ? String(canonical.dropFirst(rootPath.count + 1)) : path
        }
        return (removed.map(relative).sorted(), unindexed.map(relative).sorted())
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
