import Foundation
@testable import SextantCore

/// Where a SwiftPM build leaves what the tests run and read. Kept in one place because the
/// layout of `.build` belongs to SwiftPM and differs between its build systems.
enum BuildProducts {
    /// The built `sextant` binary of a package, or nil when it has not been built.
    /// `.build/debug` is a symlink into the layout of whichever build system ran last.
    static func sextantBinary(under root: URL) -> URL? {
        let candidate = root.appendingPathComponent(".build/debug/sextant")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// The debug index store of a package, found the way the tool itself finds it: the one
    /// `sextant index` wrote in its own build tree when there is one, otherwise the one a
    /// `swift build --enable-index-store` wrote in `.build`.
    static func indexStore(under root: URL) -> String? {
        let usable = IndexStoreLocator.usableStorePaths(under: root)
        let own = IndexStoreLocator.indexBuildDirectory(ofPackage: root).path + "/"
        return usable.first { $0.hasPrefix(own) } ?? usable.first
    }

    /// libIndexStore of the active toolchain, found the way the tool finds it.
    static var indexStoreLibrary: String? { IndexStoreUnits.discoverLibrary() }

    /// The compile flags of a built and indexed package. The native build system leaves a graph
    /// beside the store; the Swift Build system leaves none, and there the flags are the ones
    /// `sextant index` read from the build's own output and stored.
    static func compileCommands(under root: URL) -> [CompileCommand] {
        let fromGraph = CompilationDatabase.capture(fromStores: IndexStoreLocator.usableStorePaths(under: root))
        return fromGraph.isEmpty ? CompilationDatabase.load(forRoot: root.path) : fromGraph
    }

    /// Removes the snapshots `sextant index` recorded in the real cache for the stores of a
    /// package's own build tree, for tests that run it outside a sandboxed home.
    static func removeIndexSnapshots(under root: URL) {
        for store in IndexStoreLocator.storePaths(inBuildDirectory: IndexStoreLocator.indexBuildDirectory(ofPackage: root)) {
            try? FileManager.default.removeItem(at: IndexSnapshot.location(forStore: store))
        }
    }
}
