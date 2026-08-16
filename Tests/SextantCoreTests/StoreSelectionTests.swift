import Foundation
import Testing
import SextantCore

/// Regression from the field report of 2026-08-02: with a one-off release build and regular debug
/// builds, the release store was chosen — "newer" by directory mtime, although its units were days
/// older and it held an order of magnitude less. The result was permanent STALE and semantic
/// blindness to Sources.
@Suite("Index store selection across configurations")
struct StoreSelectionTests {
    /// A package with two stores: release has the newer directory, debug has the newer units.
    private func makePackage() throws -> (root: URL, debug: String, release: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sextant-store-selection-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.2\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8
        )

        let build = root.appendingPathComponent(".build/x86_64-apple-macosx")
        var paths: [String: String] = [:]
        for configuration in ["debug", "release"] {
            let store = build.appendingPathComponent("\(configuration)/index/store")
            try manager.createDirectory(
                at: store.appendingPathComponent("v5/units"), withIntermediateDirectories: true
            )
            paths[configuration] = store.path
        }

        let now = Date()
        let week = now.addingTimeInterval(-7 * 24 * 3600)
        // Units: debug was updated just now, release a week ago.
        try manager.setAttributes([.modificationDate: now], ofItemAtPath: paths["debug"]! + "/v5/units")
        try manager.setAttributes([.modificationDate: week], ofItemAtPath: paths["release"]! + "/v5/units")
        // Store directories: release is newer — the old signal would have picked it.
        try manager.setAttributes([.modificationDate: week], ofItemAtPath: paths["debug"]!)
        try manager.setAttributes([.modificationDate: now], ofItemAtPath: paths["release"]!)

        return (root, paths["debug"]!, paths["release"]!)
    }

    @Test("The store with fresher units wins over the one with a newer directory")
    func picksStoreWithNewerUnits() throws {
        let (root, debug, release) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let stores = IndexStoreLocator.usableStorePaths(under: root)
        #expect(stores == [debug])
        #expect(!stores.contains(release))
    }

    @Test("A store without a units directory is not a candidate")
    func ignoresStoreWithoutUnits() throws {
        let (root, debug, release) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(atPath: debug + "/v5/units")

        // Only release remains — an empty debug store does not quietly pass itself off as fresh.
        #expect(IndexStoreLocator.usableStorePaths(under: root) == [release])
    }

    @Test("Store freshness is read from the units, not the directory")
    func freshnessReadsUnits() throws {
        let (root, debug, release) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let debugStamp = try #require(IndexFreshness.timestamp(ofStore: debug))
        let releaseStamp = try #require(IndexFreshness.timestamp(ofStore: release))
        #expect(debugStamp > releaseStamp)
    }
}
