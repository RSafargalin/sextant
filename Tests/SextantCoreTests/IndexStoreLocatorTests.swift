import Foundation
import Testing
@testable import SextantCore

@Suite("SPM package discovery")
struct IndexStoreLocatorTests {
    @Test("Finds the root package and Packages/*")
    func findsRootAndNested() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-loc-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Packages/Foo"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Packages/Bar"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        try "// swift-tools-version: 6.2".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "// pkg".write(to: root.appendingPathComponent("Packages/Foo/Package.swift"), atomically: true, encoding: .utf8)
        try "// pkg".write(to: root.appendingPathComponent("Packages/Bar/Package.swift"), atomically: true, encoding: .utf8)

        let packages = IndexStoreLocator.swiftPackages(under: root).map { $0.lastPathComponent }
        #expect(packages.contains(root.lastPathComponent))
        #expect(packages.contains("Foo"))
        #expect(packages.contains("Bar"))
    }

    @Test("No manifest means an empty result")
    func emptyWhenNoManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-loc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(IndexStoreLocator.swiftPackages(under: root).isEmpty)
    }

    /// A package with a store at each given path under `.build`, holding one unit.
    private func package(withStoresAt relativePaths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-loc-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.2".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for relativePath in relativePaths {
            let units = root.appendingPathComponent(".build/\(relativePath)/v5/units")
            try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
            try "unit".write(to: units.appendingPathComponent("a.swift.o-1"), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// SwiftPM's two build systems lay `.build` out differently, and a locator that knows one
    /// reports a successful build of the other as having produced no index.
    @Test("A store is found in the layout of either SwiftPM build system")
    func findsBothBuildSystemLayouts() throws {
        let native = try package(withStoresAt: ["arm64-apple-macosx/debug/index/store"])
        defer { try? FileManager.default.removeItem(at: native) }
        #expect(IndexStoreLocator.usableStorePaths(under: native)
            .map { $0.hasSuffix(".build/arm64-apple-macosx/debug/index/store") } == [true])

        let swiftBuild = try package(withStoresAt: ["out/Products/Debug/index/store"])
        defer { try? FileManager.default.removeItem(at: swiftBuild) }
        // `.build/debug` is a symlink into the products of the last build; following it would
        // list the one store a second time.
        try FileManager.default.createSymbolicLink(
            atPath: swiftBuild.appendingPathComponent(".build/debug").path, withDestinationPath: "out/Products/Debug")
        #expect(IndexStoreLocator.usableStorePaths(under: swiftBuild)
            .map { $0.hasSuffix(".build/out/Products/Debug/index/store") } == [true])
    }

    /// `sextant index` builds in `.build/sextant-index`, so its store sits one level deeper than an
    /// ordinary build's, in whichever layout the toolchain's build system writes.
    @Test("The store of sextant's own build tree is found in either layout, and only once")
    func findsTheIndexBuildTreeInBothLayouts() throws {
        let native = try package(withStoresAt: ["sextant-index/arm64-apple-macosx/debug/index/store"])
        defer { try? FileManager.default.removeItem(at: native) }
        // Each build tree has its own `debug` symlink; read as a triple of `.build`, the tree's
        // symlink would list its store a second time under another path.
        try FileManager.default.createSymbolicLink(
            atPath: native.appendingPathComponent(".build/sextant-index/debug").path,
            withDestinationPath: "arm64-apple-macosx/debug")
        #expect(IndexStoreLocator.usableStorePaths(under: native)
            .map { $0.hasSuffix(".build/sextant-index/arm64-apple-macosx/debug/index/store") } == [true])

        let swiftBuild = try package(withStoresAt: ["sextant-index/out/Products/Debug/index/store"])
        defer { try? FileManager.default.removeItem(at: swiftBuild) }
        try FileManager.default.createSymbolicLink(
            atPath: swiftBuild.appendingPathComponent(".build/sextant-index/debug").path,
            withDestinationPath: "out/Products/Debug")
        #expect(IndexStoreLocator.usableStorePaths(under: swiftBuild)
            .map { $0.hasSuffix(".build/sextant-index/out/Products/Debug/index/store") } == [true])
    }

    /// A store of an ordinary build and the one `sextant index` wrote are two candidates, and the
    /// store policy decides between them like any other two.
    @Test("An ordinary build's store and sextant's own are both candidates")
    func ordinaryAndIndexBuildStoresAreBothCandidates() throws {
        let root = try package(withStoresAt: ["out/Products/Debug/index/store",
                                              "sextant-index/out/Products/Debug/index/store"])
        defer { try? FileManager.default.removeItem(at: root) }
        let usable = IndexStoreLocator.candidates(under: root).filter(\.isUsable).map(\.path)
        #expect(usable.count == 2)
        #expect(usable.contains { $0.hasSuffix("/.build/out/Products/Debug/index/store") })
        #expect(usable.contains { $0.hasSuffix("/.build/sextant-index/out/Products/Debug/index/store") })
    }

    @Test("Debug and release are told apart whichever build system spelled them")
    func configurationIsReadFromEitherSpelling() throws {
        let root = try package(withStoresAt: ["out/Products/Debug/index/store", "out/Products/Release/index/store"])
        defer { try? FileManager.default.removeItem(at: root) }
        let candidates = IndexStoreLocator.candidates(under: root)
        #expect(candidates.count == 2)
        #expect(candidates.filter(\.isUsable).count == 1)
        #expect(candidates.contains { $0.rejection?.contains("another configuration") == true })
    }
}
