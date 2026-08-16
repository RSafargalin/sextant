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

    private static func candidates(inPackage directory: URL) -> [StoreCandidate] {
        let build = directory.appendingPathComponent(".build")
        guard let triples = try? FileManager.default.contentsOfDirectory(atPath: build.path) else { return [] }
        var found: [StoreCandidate] = []
        for triple in triples.sorted() {
            for configuration in ["debug", "release"] {
                let path = build.appendingPathComponent("\(triple)/\(configuration)/index/store").path
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
        }
        // Debug and release of one package are different builds of different code; mixing them
        // would answer about a configuration nobody asked for. Only the configuration that was
        // built last takes part, and the other is named as left out.
        let usable = found.filter(\.isUsable)
        guard usable.count > 1, let newest = usable.max(by: { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) })
        else { return found }
        let winning = configuration(ofStorePath: newest.path)
        return found.map { candidate in
            guard candidate.isUsable, configuration(ofStorePath: candidate.path) != winning else { return candidate }
            return StoreCandidate(path: candidate.path, origin: candidate.origin, unitCount: candidate.unitCount,
                                  modified: candidate.modified,
                                  rejection: "another configuration than the one built last (\(winning))")
        }
    }

    /// `debug` or `release` from `.build/<triple>/<configuration>/index/store`.
    private static func configuration(ofStorePath path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent
    }

    private static func hasManifest(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path)
    }

}
