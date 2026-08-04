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
}
