import Foundation

/// Finds a project's SPM packages and their deterministic index stores (`.build/.../index/store`).
public enum IndexStoreLocator {
    /// The build tree `sextant index` builds a package in, inside its `.build`. Nothing else builds
    /// there, and every build there writes an index store, so a store in it covers what compiled.
    public static func indexBuildDirectory(ofPackage package: URL) -> URL {
        package.appendingPathComponent(".build/\(indexBuildDirectoryName)")
    }

    static let indexBuildDirectoryName = "sextant-index"

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

    /// Every store under the project's SPM packages that could be used, with the facts needed to
    /// choose between them. Several stores of one package are a normal state — `swift build` writes
    /// one and an editor's own indexer writes another — and which of them answers a question is a
    /// decision, not a detail.
    public static func candidates(under root: URL) -> [StoreCandidate] {
        swiftPackages(under: root).flatMap(candidates(inPackage:))
    }

    /// Paths of the usable candidates, for callers that only need somewhere to read units from
    /// (capturing compile flags, for instance) and have no choice to make.
    public static func usableStorePaths(under root: URL) -> [String] {
        candidates(under: root).filter(\.isUsable).map(\.path)
    }

    /// Every place a SwiftPM build directory can hold an index store, existing or not.
    ///
    /// SwiftPM has two build systems and each lays `.build` out its own way: the native one writes
    /// `<triple>/<configuration>/index/store`, the Swift Build one `out/Products/<Configuration>/index/store`.
    /// `.build/debug` is a symlink into whichever was used last, so it is never listed on its own —
    /// it would name the same store twice. For the same reason the build tree of `sextant index`
    /// inside `.build` is not read as a triple: its own `debug` symlink would name its store once
    /// more under a path of the wrong shape.
    public static func storePaths(inBuildDirectory build: URL) -> [String] {
        var paths: [String] = []
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? []
        for triple in entries.sorted() where triple != indexBuildDirectoryName {
            for configuration in ["debug", "release"] {
                paths.append(build.appendingPathComponent("\(triple)/\(configuration)/index/store").path)
            }
        }
        for configuration in ["Debug", "Release"] {
            paths.append(build.appendingPathComponent("out/Products/\(configuration)/index/store").path)
        }
        return paths
    }

    /// The stores of one package: those of its ordinary `.build` and those of the build tree
    /// `sextant index` keeps for itself, in either build system's layout.
    private static func candidates(inPackage directory: URL) -> [StoreCandidate] {
        var found: [StoreCandidate] = []
        let paths = storePaths(inBuildDirectory: directory.appendingPathComponent(".build"))
            + storePaths(inBuildDirectory: indexBuildDirectory(ofPackage: directory))
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            // A store with no units is not a candidate — there is nothing in it to open.
            let modified = IndexFreshness.timestamp(ofStore: path)
            found.append(StoreCandidate(
                path: path,
                origin: directory.path,
                unitCount: StoreCandidate.unitCount(ofStore: path),
                modified: modified,
                rejection: modified == nil ? "no units — nothing to read" : nil
            ))
        }
        return found
    }

    /// Whether a store lies in the build tree `sextant index` keeps for itself — a store nothing
    /// else writes.
    public static func isBuiltBySextant(storePath: String) -> Bool {
        storePath.contains("/.build/\(indexBuildDirectoryName)/")
    }

    private static func hasManifest(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path)
    }

}
