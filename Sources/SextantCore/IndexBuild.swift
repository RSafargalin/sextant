import Foundation

/// Preparation for building an index store: reading manifests, validating the package set,
/// choosing the platform and the umbrella paths. The decisions are separated from running the
/// build so tests can cover them, while the build itself executes foreign code and runs only on an explicit user command.
public enum IndexBuild {
    public struct Package: Sendable, Equatable {
        public let reference: UmbrellaManifest.PackageReference
        public let macOSVersion: String?

        public init(reference: UmbrellaManifest.PackageReference, macOSVersion: String?) {
            self.reference = reference
            self.macOSVersion = macOSVersion
        }
    }

    /// Outcome of preparing the umbrella: what to write to disk, or why the package set is unusable.
    /// Every refusal carries a reason — "the umbrella failed" is never left unexplained.
    public enum UmbrellaPlan: Sendable, Equatable {
        case ready(manifest: String, macOSVersion: String, skipped: [String])
        case noManifests
        case duplicateIdentities([String])
        case unsupportedPlatform([String])
    }

    /// Planning result: the verdict plus packages whose manifests could not be read. `skipped` is
    /// reported for EVERY outcome: a refusal over duplicates or platform is decided on an incomplete
    /// set, and staying quiet about that is the same quiet wrongness as a silently partial result.
    public struct Plan: Sendable, Equatable {
        public let outcome: UmbrellaPlan
        public let skipped: [String]
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

        let withoutMacOS = packages.filter { $0.macOSVersion == nil }.map { $0.reference.identity }
        guard withoutMacOS.isEmpty else { return Plan(outcome: .unsupportedPlatform(withoutMacOS.sorted()), skipped: skipped) }

        // The umbrella platform is the maximum of the packages' requirements, or the strictest fails.
        let macOSVersion = packages.compactMap { $0.macOSVersion }.reduce(nil as String?) { best, version in
            guard let best else { return version }
            return SemanticVersion.atLeast(version, best) ? version : best
        } ?? "13.0"

        return Plan(
            outcome: .ready(
                manifest: UmbrellaManifest.manifest(packages: packages.map { $0.reference }, macOSVersion: macOSVersion),
                macOSVersion: macOSVersion,
                skipped: skipped
            ),
            skipped: skipped
        )
    }

    /// Umbrella cache directory for a project, kept outside the project so as not to litter it.
    public static func umbrellaDirectory(forRoot root: String) -> URL {
        let sanitized = root.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sextant/umbrella/\(sanitized)")
    }

    /// Path to the umbrella's index store, if built (the freshest across triple × configuration).
    /// Freshness is measured by unit update time, exactly as in `IndexStoreLocator`.
    public static func umbrellaStorePath(forRoot root: String) -> String? {
        let build = umbrellaDirectory(forRoot: root).appendingPathComponent(".build")
        guard let triples = try? FileManager.default.contentsOfDirectory(atPath: build.path) else { return nil }
        var candidates: [(path: String, modified: Date)] = []
        for triple in triples.sorted() {
            for configuration in ["debug", "release"] {
                let candidate = build.appendingPathComponent("\(triple)/\(configuration)/index/store").path
                if let modified = IndexFreshness.timestamp(ofStore: candidate) {
                    candidates.append((candidate, modified))
                }
            }
        }
        return DerivedDataLocator.freshest(from: candidates)
    }

    /// Writes the umbrella package to disk; throws a file-system error.
    public static func writeUmbrella(manifest: String, forRoot root: String) throws -> URL {
        let umbrella = umbrellaDirectory(forRoot: root)
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
        return Package(
            reference: .init(path: directory.path, identity: directory.lastPathComponent, products: libraryProducts(in: json)),
            macOSVersion: macOSRequirement(in: json)
        )
    }

    /// Library products from a manifest (executables are not pulled into the umbrella).
    public static func libraryProducts(in manifest: [String: Any]) -> [String] {
        let products = (manifest["products"] as? [[String: Any]]) ?? []
        return products.compactMap { product in
            guard let type = product["type"] as? [String: Any], type["library"] != nil else { return nil }
            return product["name"] as? String
        }
    }

    /// The macOS requirement from a manifest; nil means the package does not support the host platform.
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
