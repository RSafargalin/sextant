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

    /// The debug index store a `swift build --enable-index-store` of a package wrote, found the
    /// way the tool itself finds it.
    static func indexStore(under root: URL) -> String? {
        IndexStoreLocator.usableStorePaths(under: root).first
    }

    /// The compile flags of a built and indexed package. The native build system leaves a graph
    /// beside the store; the Swift Build system leaves none, and there the flags are the ones
    /// `sextant index` read from the build's own output and stored.
    static func compileCommands(under root: URL) -> [CompileCommand] {
        let fromGraph = CompilationDatabase.capture(fromStores: IndexStoreLocator.usableStorePaths(under: root))
        return fromGraph.isEmpty ? CompilationDatabase.load(forRoot: root.path) : fromGraph
    }
}
