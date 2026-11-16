import Foundation

/// What `sextant index` knew when it built a store: the sources it built from, the store it left,
/// and the build itself. Recorded only for a store that nothing but `sextant index` writes, so the
/// sources described here are exactly what the store holds — as long as the store is still the
/// one described, which the fingerprint checks.
///
/// Kept in sextant's cache directory, keyed by the store's canonical path; nothing is written into
/// the project.
public struct IndexSnapshot: Codable, Sendable, Equatable {
    /// The on-disk format. A snapshot in another format is not read.
    public static let currentFormat = 1

    public let format: Int
    public let recordedAt: Date
    /// The canonical project root the sources are relative to.
    public let projectRoot: String
    /// The canonical path of the store.
    public let storePath: String
    public let sources: SourceSnapshot
    public let store: StoreFingerprint
    public let build: BuildRecord

    public init(recordedAt: Date = Date(), projectRoot: String, storePath: String,
                sources: SourceSnapshot, store: StoreFingerprint, build: BuildRecord) {
        format = Self.currentFormat
        self.recordedAt = recordedAt
        self.projectRoot = Self.canonical(projectRoot)
        self.storePath = Self.canonical(storePath)
        self.sources = sources
        self.store = store
        self.build = build
    }

    /// The snapshot of a store a build just left, from the sources recorded before that build
    /// started: a file edited while the build runs then reads as changed rather than as built.
    /// nil when the store holds no units.
    ///
    /// After a failed build it also records the sources the build left without a unit for their
    /// present text — never compiled, or compiled before they last changed — read from the store's
    /// units (`unitTimes`, by default from the store itself): those are not indexed, whatever the
    /// snapshot says about their content.
    public static func afterBuild(store storePath: String, projectRoot: String, sources: SourceSnapshot,
                                  exitStatus: Int32, testsBuilt: Bool, buildLog: String,
                                  toolchain: ToolchainIdentity?, libraryPath: String? = nil,
                                  unitTimes: (() -> [String: Date]?)? = nil) -> IndexSnapshot? {
        guard let fingerprint = StoreFingerprint.of(store: storePath) else { return nil }
        let root = URL(fileURLWithPath: canonical(projectRoot), isDirectory: true)
        let withErrors = BuildRecord.filesWithErrors(inBuildLog: buildLog, projectRoot: root)
        var notBuilt: [String]?
        if exitStatus != 0,
           let times = unitTimes?() ?? BuildRecord.unitTimes(ofStore: storePath, libraryPath: libraryPath) {
            notBuilt = BuildRecord.filesNotBuilt(projectRoot: root, testsBuilt: testsBuilt, unitTimes: times,
                                                 filesWithErrors: withErrors)
        }
        let build = BuildRecord(toolchain: toolchain, manifests: BuildRecord.manifestHashes(projectRoot: root),
                                exitStatus: exitStatus, testsBuilt: testsBuilt,
                                filesWithErrors: withErrors, filesNotBuilt: notBuilt)
        return IndexSnapshot(projectRoot: root.path, storePath: storePath, sources: sources,
                             store: fingerprint, build: build)
    }

    /// The sources of a project as they are now, keyed relative to its canonical root.
    public static func sources(ofProject projectRoot: String, git: SourceSnapshot.GitRunner = .system)
        -> Result<SourceSnapshot, SourceSnapshot.CaptureFailure> {
        SourceSnapshot.capture(projectRoot: URL(fileURLWithPath: canonical(projectRoot), isDirectory: true), git: git)
    }

    // MARK: - Storage

    /// Where the snapshot of a store is kept: `<home>/Library/Caches/sextant/index-snapshot/<key>.json`,
    /// the key being a hash of the store's canonical path.
    public static func location(forStore storePath: String,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Caches/sextant/index-snapshot")
            .appendingPathComponent("\(ContentHash.of(canonical(storePath)).prefix(24)).json")
    }

    public func save(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = Self.location(forStore: storePath, home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// What was found for a store.
    public enum Lookup: Sendable, Equatable {
        case trusted(IndexSnapshot)
        /// A snapshot exists but does not describe the store as it is; the reason says why.
        case untrusted(String)
        case missing
    }

    /// The snapshot of a store, if there is one that still describes it.
    public static func lookup(forStore storePath: String, projectRoot: String,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Lookup {
        let url = location(forStore: storePath, home: home)
        guard let data = FileManager.default.contents(atPath: url.path) else { return .missing }
        if let format = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"] as? Int,
           format != currentFormat {
            return .untrusted("the snapshot was written by another version of sextant")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(IndexSnapshot.self, from: data) else {
            return .untrusted("the snapshot could not be read")
        }
        guard snapshot.storePath == canonical(storePath) else { return .untrusted("the snapshot names another store") }
        guard snapshot.projectRoot == canonical(projectRoot) else {
            return .untrusted("the snapshot was taken for another project root")
        }
        // The units timestamp alone: adding or removing a unit moves it, and listing every unit
        // on every query is the cost `IndexFreshness.timestamp` exists to avoid. The count and the
        // names hash stay in the file as a record of what was built.
        guard let stamp = IndexFreshness.timestamp(ofStore: storePath),
              stamp.timeIntervalSince1970 == snapshot.store.unitsModified else {
            return .untrusted("the store was rewritten after the snapshot was taken")
        }
        return .trusted(snapshot)
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Comparison

    /// How the project now differs from what the store was built from.
    public struct Difference: Sendable, Equatable {
        /// Sources whose content differs, relative to the project root, sorted.
        public let changedFiles: [String]
        /// `Package.swift` / `Package.resolved` files whose content differs, relative to the project root.
        public let changedManifests: [String]
        /// The toolchain the store was built with and the one in use now, when they differ.
        public let toolchain: ToolchainChange?
        /// For each changed file that existed when the store was built, the blob hash of the
        /// content it was built from.
        public var indexedContent: [String: String] = [:]

        public var isEmpty: Bool { changedFiles.isEmpty && changedManifests.isEmpty && toolchain == nil }
    }

    public struct ToolchainChange: Sendable, Equatable {
        public let recorded: String
        public let current: String
    }

    /// The difference between this snapshot and the project now, or why it cannot be computed.
    public func difference(currentToolchain: () -> ToolchainIdentity? = { ToolchainIdentity.current() },
                           git: SourceSnapshot.GitRunner = .system) -> Result<Difference, ComparisonFailure> {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        switch sources.changes(projectRoot: root, git: git) {
        case .incomparable(let reason):
            return .failure(ComparisonFailure(reason: reason))
        case .compared(let changed, let indexed):
            let manifests = BuildRecord.manifestHashes(projectRoot: root)
            let changedManifests = Set(manifests.keys).union(build.manifests.keys)
                .filter { manifests[$0] != build.manifests[$0] }.sorted()
            return .success(Difference(changedFiles: changed, changedManifests: changedManifests,
                                       toolchain: toolchainChange(current: currentToolchain()),
                                       indexedContent: indexed))
        }
    }

    public struct ComparisonFailure: Error, Sendable, Equatable {
        public let reason: String
    }

    private func toolchainChange(current: ToolchainIdentity?) -> ToolchainChange? {
        guard let recorded = build.toolchain, let current else { return nil }
        guard !recorded.isSameBinary(as: current) else { return nil }
        // Another binary is not necessarily another compiler (an Xcode update may reinstall the same
        // one); only its version says so.
        let currentVersion = current.version
            ?? ToolchainIdentity.version(of: current.executable, environment: CallerContext.effectiveEnvironment())
        guard let currentVersion, currentVersion != recorded.version else { return nil }
        return ToolchainChange(recorded: recorded.version ?? recorded.executable, current: currentVersion)
    }
}

/// What a store held when a snapshot was taken. Whether it is still that store is told by
/// `unitsModified` alone, which every unit added or removed moves; the count and the names hash
/// record what was built and are not recomputed per query.
public struct StoreFingerprint: Codable, Sendable, Equatable {
    public let unitCount: Int
    /// A hash of the sorted unit file names, across every `v*` directory.
    public let unitNamesHash: String
    /// The store's timestamp as `IndexFreshness` reads it, seconds since 1970.
    public let unitsModified: Double

    public init(unitCount: Int, unitNamesHash: String, unitsModified: Double) {
        self.unitCount = unitCount
        self.unitNamesHash = unitNamesHash
        self.unitsModified = unitsModified
    }

    /// The fingerprint of a store as it is now; nil when it holds no units.
    public static func of(store storePath: String) -> StoreFingerprint? {
        guard let modified = IndexFreshness.timestamp(ofStore: storePath) else { return nil }
        let store = URL(fileURLWithPath: storePath, isDirectory: true)
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
        var names: [String] = []
        for version in versions.sorted() where version.hasPrefix("v") {
            let units = store.appendingPathComponent("\(version)/units").path
            names += ((try? FileManager.default.contentsOfDirectory(atPath: units)) ?? []).map { "\(version)/\($0)" }
        }
        guard !names.isEmpty else { return nil }
        return StoreFingerprint(unitCount: names.count, unitNamesHash: ContentHash.of(names.sorted().joined(separator: "\n")),
                                unitsModified: modified.timeIntervalSince1970)
    }
}

/// How the store was built.
public struct BuildRecord: Codable, Sendable, Equatable {
    public let toolchain: ToolchainIdentity?
    /// Content hashes of every package's `Package.swift` and `Package.resolved`, keyed by the path
    /// relative to the project root; a file that did not exist is absent.
    public let manifests: [String: String]
    public let exitStatus: Int32
    public let testsBuilt: Bool
    /// Files the build log reports an `error:` in, relative to the project root. This is the set
    /// of files the compiler complained about, not the set left without fresh units: a failed
    /// compile job can take files with no error of their own down with it.
    public let filesWithErrors: [String]
    /// After a failed build, the sources it left without a unit for their present text, relative
    /// to the project root: never compiled, compiled before they last changed, or reported with an
    /// error. nil after a successful build, or when the store's units could not be read.
    public let filesNotBuilt: [String]?

    public init(toolchain: ToolchainIdentity?, manifests: [String: String], exitStatus: Int32,
                testsBuilt: Bool, filesWithErrors: [String] = [], filesNotBuilt: [String]? = nil) {
        self.toolchain = toolchain
        self.manifests = manifests
        self.exitStatus = exitStatus
        self.testsBuilt = testsBuilt
        self.filesWithErrors = filesWithErrors
        self.filesNotBuilt = filesNotBuilt
    }

    /// When the newest unit of each source in a store was written, keyed by the source's real
    /// path; nil when the store's units cannot be read.
    public static func unitTimes(ofStore storePath: String, libraryPath: String?) -> [String: Date]? {
        guard let units = try? IndexStoreUnits.shared(libraryPath: libraryPath).units(inStore: storePath) else { return nil }
        let store = URL(fileURLWithPath: storePath, isDirectory: true)
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []).filter { $0.hasPrefix("v") }
        var times: [String: Date] = [:]
        for unit in units where !unit.isSystem && !unit.mainFile.isEmpty && !unit.name.isEmpty {
            let written = versions.lazy.compactMap { version in
                (try? FileManager.default.attributesOfItem(
                    atPath: store.appendingPathComponent("\(version)/units/\(unit.name)").path))?[.modificationDate] as? Date
            }.first
            guard let written else { continue }
            let source = URL(fileURLWithPath: unit.mainFile).resolvingSymlinksInPath().path
            if written > (times[source] ?? .distantPast) { times[source] = written }
        }
        return times
    }

    /// The sources a unit can be built from that have no unit written after their last change —
    /// never compiled, or left as an earlier build compiled them — together with the files the
    /// build reported errors in, relative to the project root and sorted. Test sources count only
    /// when the build built the tests.
    public static func filesNotBuilt(projectRoot: URL, testsBuilt: Bool, unitTimes: [String: Date],
                                     filesWithErrors: [String]) -> [String] {
        var result = Set(filesWithErrors)
        for file in StoreCoverage.unitSources(under: projectRoot, includeTests: testsBuilt) {
            let path = file.resolvingSymlinksInPath().path
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let written = unitTimes[path], let modified, written >= modified { continue }
            result.insert(SwiftSources.relativePath(of: file, root: projectRoot))
        }
        return result.sorted()
    }

    /// The manifests of every package under the root, hashed.
    public static func manifestHashes(projectRoot: URL) -> [String: String] {
        var hashes: [String: String] = [:]
        for package in IndexStoreLocator.swiftPackages(under: projectRoot) {
            for name in ["Package.swift", "Package.resolved"] {
                let file = package.appendingPathComponent(name)
                guard let hash = ContentHash.ofFile(file.path) else { continue }
                hashes[SwiftSources.relativePath(of: file, root: projectRoot)] = hash
            }
        }
        return hashes
    }

    /// Files under the root that a build log reports an error in. The compiler and SwiftPM's
    /// native build system print `/absolute/path:line:column: error: …`; the Swift Build system
    /// prints `error: /absolute/path:line:column message`. Colour codes the compiler adds when it
    /// is asked to (`\u{1B}[1;31merror:`) are not part of the text.
    public static func filesWithErrors(inBuildLog log: String, projectRoot: URL) -> [String] {
        let rootPath = IndexSnapshot.canonical(projectRoot.path) + "/"
        var files = Set<String>()
        for line in log.split(separator: "\n").map(withoutColourCodes) {
            let location: Substring
            if line.hasPrefix("error: /") {
                location = line.dropFirst("error: ".count)
            } else if line.hasPrefix("/"), line.contains(": error:") {
                location = line
            } else {
                continue
            }
            let parts = location.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 3, Int(parts[1]) != nil,
                  Int(parts[2].prefix { $0.isNumber }) != nil, parts[2].first?.isNumber == true else { continue }
            let path = IndexSnapshot.canonical(String(parts[0]))
            guard path.hasPrefix(rootPath) else { continue }
            files.insert(String(path.dropFirst(rootPath.count)))
        }
        return files.sorted()
    }

    /// A log line without ANSI escape sequences (`ESC [ … letter`).
    static func withoutColourCodes(_ line: Substring) -> Substring {
        guard line.contains("\u{1B}") else { return line }
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "\u{1B}", line.index(after: index) < line.endIndex, line[line.index(after: index)] == "[" {
                var end = line.index(index, offsetBy: 2)
                while end < line.endIndex, !line[end].isLetter { end = line.index(after: end) }
                index = end < line.endIndex ? line.index(after: end) : end
                continue
            }
            result.append(line[index])
            index = line.index(after: index)
        }
        return Substring(result)
    }
}

/// Which `swift` builds the project: the executable `/usr/bin/env swift` resolves to, with its
/// size and modification time, plus the version line it prints. The executable is found without
/// running the compiler, so checking whether it changed costs a path search and a `stat`; the
/// version is asked for only where the binary differs.
public struct ToolchainIdentity: Codable, Sendable, Equatable {
    /// The first line of `swift --version`.
    public let version: String?
    public let executable: String
    public let size: Int?
    public let modified: Double?

    public init(version: String?, executable: String, size: Int?, modified: Double?) {
        self.version = version
        self.executable = executable
        self.size = size
        self.modified = modified
    }

    /// The toolchain in use now, without its version — as the caller of the command finds it, which
    /// under `sextant serve` is the client's environment rather than the daemon's.
    public static func current(environment: [String: String] = CallerContext.effectiveEnvironment())
        -> ToolchainIdentity? {
        guard let found = executable(environment: environment) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: found)
        return ToolchainIdentity(version: nil, executable: found,
                                 size: (attributes?[.size] as? NSNumber)?.intValue,
                                 modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970)
    }

    /// The toolchain in use now, with its version.
    public static func currentWithVersion() -> ToolchainIdentity? {
        guard let identity = current() else { return nil }
        return ToolchainIdentity(version: version(of: identity.executable), executable: identity.executable,
                                 size: identity.size, modified: identity.modified)
    }

    public func isSameBinary(as other: ToolchainIdentity) -> Bool {
        executable == other.executable && size == other.size && modified == other.modified
    }

    /// The first line `swift --version` prints, run through the resolved executable's directory.
    static func version(of executable: String,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let swift = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("swift").path
        let launch = FileManager.default.isExecutableFile(atPath: swift) ? swift : "/usr/bin/env"
        let arguments = launch == "/usr/bin/env" ? ["swift", "--version"] : ["--version"]
        return Command.output(launch, arguments, timeout: Command.toolchainTimeout, environment: environment)?
            .split(separator: "\n").first.map(String.init)
    }

    /// The real path of the `swift` that `PATH` names; through `xcrun` when that is the system
    /// shim, which picks a toolchain by `DEVELOPER_DIR` and `xcode-select`.
    static func executable(environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        guard let named = path.split(separator: ":").map({ "\($0)/swift" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        var resolved = URL(fileURLWithPath: named).resolvingSymlinksInPath().path
        if resolved == "/usr/bin/swift",
           let found = Command.output("/usr/bin/xcrun", ["--find", "swift"], timeout: Command.toolchainTimeout,
                                      environment: environment), !found.isEmpty {
            resolved = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
        }
        return resolved
    }
}
