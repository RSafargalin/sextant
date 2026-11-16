import Foundation

/// Preparation for building an index store: reading manifests, validating the package set,
/// choosing the platform and the umbrella paths. The decisions are separated from running the
/// build so tests can cover them, while the build itself executes foreign code and runs only on an explicit user command.
public enum IndexBuild {
    /// What `swift build` is run with. Test targets are in by default because leaving them out
    /// removes their usages from every answer without removing them from the code: measured on
    /// Alamofire, the store then covered 43 of 98 files and `refs Session` answered 25 where the
    /// whole package holds 504. The build costs roughly twice as long (44s against 80s there),
    /// which is a price paid once per build against an undercount paid on every query.
    ///
    /// The build is verbose because its output is where one of SwiftPM's two build systems states
    /// the C-family compile flags, and nowhere else — the caller sends it to a log, not a terminal.
    ///
    /// The build runs in `scratchPath`, a tree only this command builds, and always with the index
    /// store on. In a tree built earlier without it, SwiftPM's Swift Build system counts every file
    /// as up to date, compiles nothing and writes no store — and a tree where only some files
    /// recompile gets a partial store, and flags for those files alone.
    public static func swiftBuildArguments(scratchPath: String, buildTests: Bool = true) -> [String] {
        ["build", "--scratch-path", scratchPath, "--enable-index-store"]
            + (buildTests ? ["--build-tests"] : []) + ["-v"]
    }

    /// The build tree of the umbrella package. Only this command builds the umbrella, so its
    /// ordinary `.build` is already a tree that is never built without an index store.
    public static func umbrellaBuildDirectory(forRoot root: String) -> URL {
        umbrellaDirectory(forRoot: root).appendingPathComponent(".build")
    }

    /// Where the output of the last `swift build` run for a project is kept.
    public static func buildLog(forRoot root: String) -> URL {
        umbrellaDirectory(forRoot: root).appendingPathComponent("swift-build.log")
    }

    /// Which build produced a store, as far as its tests are concerned.
    public enum TestsBuild: Sendable, Equatable {
        /// One package, built by `sextant index`; `testsBuilt` is false under `--no-tests`.
        case package(testsBuilt: Bool)
        /// Several packages in one umbrella manifest, which depends on their library products
        /// only — so no package's test target is ever built into it.
        case umbrella
        /// An app target, built by `xcodebuild`.
        case xcode
    }

    /// What to say when the store a build just produced holds none of the project's tests.
    ///
    /// On the SwiftPM path of one package this is a flag the user passed, or files no test target
    /// compiles. A multi-package index cannot hold tests at all: the umbrella reaches the packages
    /// through their products, so the remedy is to index the package on its own. On the Xcode path it is a property of
    /// the scheme, and the obvious remedy does not work: `xcodebuild build-for-testing` builds the
    /// test targets and writes **no index store at all** — measured on Xcode 26 against
    /// Alamofire's own project, twice, where a plain `build` of the same scheme wrote one. What
    /// does work is the scheme's Build action: with the test target in it, a plain build indexes
    /// 87 of 98 files and answers 504 references where the scheme's default 43 files answer 25.
    public static func missingTestsNote(uncoveredTests: Int, build: TestsBuild) -> String? {
        guard uncoveredTests > 0 else { return nil }
        let remedy = switch build {
        case .xcode:
            "Xcode indexes what the scheme's BUILD action builds — `build-for-testing` writes no index store at all. Add the test targets to the scheme's Build action, or pass `--scheme <one that builds them>`."
        case .package(testsBuilt: false):
            "Build them in: drop `--no-tests`."
        case .package(testsBuilt: true):
            "The test targets were built, so these are files no test target of the manifest compiles."
        case .umbrella:
            "A multi-package index builds each package's library products, never its test targets. "
                + "To have a package's tests answered, index that package on its own: `sextant index --project <package>`, "
                + "and query from there."
        }
        return "⚠ \(uncoveredTests) test file(s) are outside this index — a reference written in a test "
            + "is missing from every answer.\n   " + remedy
    }

    public struct Package: Sendable, Equatable {
        public let reference: UmbrellaManifest.PackageReference
        /// The macOS minimum the manifest declares; nil when it declares none, and SwiftPM's
        /// default for the tools version applies.
        public let macOSVersion: String?
        /// Source targets no library product reaches, directly or through a target dependency. The
        /// umbrella can depend only on products, so it never builds them.
        public let unreachableTargets: [String]

        public init(reference: UmbrellaManifest.PackageReference, macOSVersion: String?, unreachableTargets: [String] = []) {
            self.reference = reference
            self.macOSVersion = macOSVersion
            self.unreachableTargets = unreachableTargets
        }
    }

    /// Outcome of preparing the umbrella: what to write to disk, or why the package set is unusable.
    /// Every refusal carries a reason — "the umbrella failed" is never left unexplained.
    public enum UmbrellaPlan: Sendable, Equatable {
        case ready(manifest: String, macOSVersion: String, skipped: [String])
        case noManifests
        case duplicateIdentities([String])
    }

    /// Planning result: the verdict plus packages whose manifests could not be read. `skipped` is
    /// reported for EVERY outcome: a refusal over duplicates or platform is decided on an incomplete
    /// set, and staying quiet about that is the same quiet wrongness as a silently partial result.
    public struct Plan: Sendable, Equatable {
        public let outcome: UmbrellaPlan
        public let skipped: [String]
        /// Packages whose source targets the umbrella does not build, as `Package (Target, …)`:
        /// no library product reaches those targets.
        public var unreachable: [String] = []
    }

    /// Plan for the umbrella build. `expected` holds the package paths found on disk; the
    /// difference from the manifests actually read lands in `skipped` (those will NOT be indexed).
    public static func umbrellaPlan(packages: [Package], expected: [String] = []) -> Plan {
        let read = Set(packages.map { $0.reference.path })
        let skipped = expected.filter { !read.contains($0) }
            .map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()

        guard !packages.isEmpty else { return Plan(outcome: .noManifests, skipped: skipped) }

        let duplicates = Dictionary(grouping: packages, by: { $0.reference.identity })
            .filter { $0.value.count > 1 }.keys.sorted()
        guard duplicates.isEmpty else { return Plan(outcome: .duplicateIdentities(duplicates), skipped: skipped) }

        // A package that declares no macOS minimum builds on macOS with SwiftPM's default, so it
        // takes part without raising the umbrella's requirement. The umbrella platform is the
        // maximum of the declared requirements, or the strictest fails.
        let macOSVersion = packages.compactMap { $0.macOSVersion }.reduce(nil as String?) { best, version in
            guard let best else { return version }
            return SemanticVersion.atLeast(version, best) ? version : best
        } ?? "13.0"

        var plan = Plan(
            outcome: .ready(
                manifest: UmbrellaManifest.manifest(packages: packages.map { $0.reference }, macOSVersion: macOSVersion),
                macOSVersion: macOSVersion,
                skipped: skipped
            ),
            skipped: skipped
        )
        plan.unreachable = packages.filter { !$0.unreachableTargets.isEmpty }
            .sorted { $0.reference.identity < $1.reference.identity }
            .map { "\($0.reference.identity) (\($0.unreachableTargets.joined(separator: ", ")))" }
        return plan
    }

    /// Umbrella cache directory for a project, kept outside the project so as not to litter it.
    /// Named by `CanonicalPath.entryName`: `--project .` and the absolute path of the same
    /// directory are one project with one umbrella, one store and one build log, and a root of
    /// any depth has one.
    public static func umbrellaDirectory(forRoot root: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sextant/umbrella/\(CanonicalPath.entryName(of: root))")
    }

    /// Creates the umbrella directory of a project, if needed, with the record of the project it
    /// belongs to — the only way the cache eviction can tell that the project is gone.
    @discardableResult
    public static func prepareUmbrellaDirectory(forRoot root: String) throws -> URL {
        let umbrella = umbrellaDirectory(forRoot: root)
        try FileManager.default.createDirectory(at: umbrella, withIntermediateDirectories: true)
        CacheEviction.recordOwner(CanonicalPath.of(root), in: umbrella)
        return umbrella
    }

    /// Whether a store lies in an umbrella build tree in the cache.
    public static func isUmbrellaStore(_ storePath: String) -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sextant/umbrella").path + "/"
        return storePath.hasPrefix(root) || CanonicalPath.of(storePath).hasPrefix(CanonicalPath.of(root) + "/")
    }

    /// Every store with units in the umbrella's build tree, in either build system's layout and
    /// any configuration. Which of them answers is `StoreSelection.resolve`'s decision.
    public static func umbrellaCandidates(forRoot root: String) -> [StoreCandidate] {
        let origin = umbrellaDirectory(forRoot: root).path
        return IndexStoreLocator.storePaths(inBuildDirectory: umbrellaBuildDirectory(forRoot: root)).compactMap { path in
            IndexFreshness.timestamp(ofStore: path).map {
                StoreCandidate(path: path, origin: origin, unitCount: StoreCandidate.unitCount(ofStore: path), modified: $0)
            }
        }
    }

    /// Writes the umbrella package to disk; throws a file-system error.
    public static func writeUmbrella(manifest: String, forRoot root: String) throws -> URL {
        let umbrella = try prepareUmbrellaDirectory(forRoot: root)
        let sources = umbrella.appendingPathComponent("Sources/SextantUmbrella")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try manifest.write(to: umbrella.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "enum SextantUmbrella {}\n".write(to: sources.appendingPathComponent("Umbrella.swift"), atomically: true, encoding: .utf8)
        return umbrella
    }

    /// Package manifest via `swift package dump-package`: library products and the macOS requirement.
    public static func readPackage(at directory: URL) -> Package? {
        guard let output = Command.output("/usr/bin/env", ["swift", "package", "dump-package", "--package-path", directory.path]),
              let json = parseJSON(output) else { return nil }
        return package(fromManifest: json, at: directory)
    }

    /// A package as the umbrella sees it, from the output of `swift package dump-package`.
    public static func package(fromManifest json: [String: Any], at directory: URL) -> Package {
        Package(
            reference: .init(path: directory.path, identity: directory.lastPathComponent, products: libraryProducts(in: json)),
            macOSVersion: macOSRequirement(in: json),
            unreachableTargets: unreachableTargets(in: json)
        )
    }

    /// Source targets (regular and executable) that no library product reaches, directly or
    /// through the targets it depends on, in manifest order.
    public static func unreachableTargets(in manifest: [String: Any]) -> [String] {
        let targets = (manifest["targets"] as? [[String: Any]]) ?? []
        let products = (manifest["products"] as? [[String: Any]]) ?? []
        var dependencies: [String: [String]] = [:]
        for target in targets {
            guard let name = target["name"] as? String else { continue }
            dependencies[name] = ((target["dependencies"] as? [[String: Any]]) ?? []).compactMap { dependency in
                ((dependency["byName"] ?? dependency["target"]) as? [Any])?.first as? String
            }
        }
        var reached = Set<String>()
        var pending = products.filter { ($0["type"] as? [String: Any])?["library"] != nil }
            .flatMap { ($0["targets"] as? [String]) ?? [] }
        while let next = pending.popLast() {
            guard reached.insert(next).inserted else { continue }
            pending += dependencies[next] ?? []
        }
        return targets.compactMap { target in
            guard let name = target["name"] as? String, ["regular", "executable"].contains(target["type"] as? String),
                  !reached.contains(name) else { return nil }
            return name
        }
    }

    /// Library products from a manifest (executables are not pulled into the umbrella).
    public static func libraryProducts(in manifest: [String: Any]) -> [String] {
        let products = (manifest["products"] as? [[String: Any]]) ?? []
        return products.compactMap { product in
            guard let type = product["type"] as? [String: Any], type["library"] != nil else { return nil }
            return product["name"] as? String
        }
    }

    /// The macOS minimum a manifest declares; nil when it declares none (SwiftPM's default applies).
    public static func macOSRequirement(in manifest: [String: Any]) -> String? {
        let platforms = (manifest["platforms"] as? [[String: Any]]) ?? []
        return platforms.first { ($0["platformName"] as? String) == "macos" }?["version"] as? String
    }

    /// The Xcode container at the project root: a workspace is preferred over a project.
    public static func xcodeContainerFlag(root: URL) -> [String]? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        if let workspace = entries.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return ["-workspace", root.appendingPathComponent(workspace).path]
        }
        if let project = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return ["-project", root.appendingPathComponent(project).path]
        }
        return nil
    }

    /// The container's first scheme, via `xcodebuild -list -json`.
    public static func detectScheme(containerFlag: [String]) -> String? {
        guard let output = Command.output("/usr/bin/env", ["xcodebuild", "-list", "-json"] + containerFlag, timeout: 90),
              let json = parseJSON(output) else { return nil }
        let container = (json["workspace"] ?? json["project"]) as? [String: Any]
        return (container?["schemes"] as? [String])?.first
    }

    /// Container schemes from the output of `xcodebuild -list -json` (workspace or project).
    public static func schemes(inListing json: [String: Any]) -> [String] {
        let container = (json["workspace"] ?? json["project"]) as? [String: Any]
        return (container?["schemes"] as? [String]) ?? []
    }

    private static func parseJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
