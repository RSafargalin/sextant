import Foundation

/// Finds a project's SPM packages and their deterministic index stores (`.build/.../index/store`).
public enum IndexStoreLocator {
    /// SPM package directories: the root (if it has a Package.swift) plus `Packages/*`.
    public static func swiftPackages(under root: URL) -> [URL] {
        var directories: [URL] = []
        if hasManifest(root) { directories.append(root) }

        let packagesDirectory = root.appendingPathComponent("Packages")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: packagesDirectory, includingPropertiesForKeys: nil
        ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where hasManifest(entry) {
                directories.append(entry)
            }
        }
        return directories
    }

    /// Every existing index store under the project's SPM packages.
    public static func stores(under root: URL) -> [String] {
        swiftPackages(under: root).flatMap(storePaths(inPackage:))
    }

    private static func hasManifest(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path)
    }

    /// The freshest store for a package (one per package, never debug and release at once — that
    /// would open two and become non-deterministic when one configuration is stale). Freshness is
    /// measured by unit update time (`IndexFreshness`): a build rewrites units inside the store
    /// without touching its directory mtime, so by directory a one-off release store looks forever
    /// "newer" than a debug store that is rebuilt regularly.
    /// A store with no units is not a candidate — there is nothing to open.
    private static func storePaths(inPackage directory: URL) -> [String] {
        let build = directory.appendingPathComponent(".build")
        guard let triples = try? FileManager.default.contentsOfDirectory(atPath: build.path) else { return [] }
        var candidates: [(path: String, modified: Date)] = []
        for triple in triples.sorted() {
            for configuration in ["debug", "release"] {
                let candidate = build.appendingPathComponent("\(triple)/\(configuration)/index/store").path
                if let modified = IndexFreshness.timestamp(ofStore: candidate) {
                    candidates.append((candidate, modified))
                }
            }
        }
        return DerivedDataLocator.freshest(from: candidates).map { [$0] } ?? []
    }
}
