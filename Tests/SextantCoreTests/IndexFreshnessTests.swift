import Foundation
import Testing
@testable import SextantCore

/// Freshness used to be computed from the store directory mtime — a false signal, because a build
/// writes unit files into `v*/units` without moving the store's own mtime. Hence "⚠ STALE" on a
/// fresh index. The signal is the `units` directory mtime: it moves both when a symbol is added
/// and when an existing file is edited (the unit gets a new hashed name), costs O(1), and does not
/// depend on directory iteration order (a truncated walk gave a non-deterministically wrong answer).
@Suite("Index freshness")
struct IndexFreshnessTests {
    /// A miniature store in the IndexStoreDB layout: `<store>/v5/units`.
    private func makeStore(unitsModified: Date, storeModified: Date? = nil) throws -> URL {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-store-\(UUID().uuidString.prefix(8))")
        let units = store.appendingPathComponent("v5/units")
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: unitsModified], ofItemAtPath: units.path)
        if let storeModified {
            try FileManager.default.setAttributes([.modificationDate: storeModified], ofItemAtPath: store.path)
        }
        return store
    }

    @Test("The timestamp comes from the units directory, not the store directory")
    func timestampComesFromUnits() throws {
        // Both stamps are in the past and differ: reading the store instead, or picking up the
        // natural mtime of a just-created directory, would fail this test.
        let units = Date().addingTimeInterval(-1800)
        let store = try makeStore(unitsModified: units, storeModified: Date().addingTimeInterval(-86400))
        defer { try? FileManager.default.removeItem(at: store) }

        let timestamp = try #require(IndexFreshness.timestamp(ofStore: store.path))
        #expect(abs(timestamp.timeIntervalSince(units)) < 1)
    }

    @Test("A build (a new unit file) moves the update timestamp")
    func rebuildAdvancesTimestamp() throws {
        let store = try makeStore(unitsModified: Date().addingTimeInterval(-7200))
        defer { try? FileManager.default.removeItem(at: store) }
        let before = try #require(IndexFreshness.timestamp(ofStore: store.path))

        // A build writes a unit under a new hashed name, so the directory mtime moves.
        let units = store.appendingPathComponent("v5/units")
        try "unit".write(to: units.appendingPathComponent("Alpha.o-NEWHASH"), atomically: true, encoding: .utf8)
        let after = try #require(IndexFreshness.timestamp(ofStore: store.path))
        #expect(after > before)
    }

    @Test("No data means the state is unknown, not fresh")
    func missingDataIsUnknown() throws {
        // There is no units directory: calling that fresh would make the trust label lie.
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store) }

        #expect(IndexFreshness.timestamp(ofStore: store.path) == nil)
        #expect(IndexFreshness.state(storePaths: [store.path], projectRoot: store.path) == .unknown)
        #expect(IndexFreshness.state(storePaths: [], projectRoot: store.path) == .unknown)
        #expect(IndexFreshness.state(storePaths: ["/no/such/store"], projectRoot: store.path) == .unknown)
        // Provenance must show the unknown state rather than "fresh".
        let summary = IndexProvenance(source: .spm, storeCount: 1, freshness: .unknown).summary
        #expect(summary.contains("unknown"))
        #expect(!summary.contains("· fresh]"))
    }

    @Test("With several store versions the freshest is used")
    func picksNewestVersionDirectory() throws {
        let store = try makeStore(unitsModified: Date().addingTimeInterval(-7200))
        defer { try? FileManager.default.removeItem(at: store) }
        let recent = Date().addingTimeInterval(-60)
        let v13 = store.appendingPathComponent("v13/units")
        try FileManager.default.createDirectory(at: v13, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: v13.path)

        let timestamp = try #require(IndexFreshness.timestamp(ofStore: store.path))
        #expect(abs(timestamp.timeIntervalSince(recent)) < 1)
    }

    @Test("Staleness: a source newer than the store yes, older no")
    func detectsRealStaleness() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-project-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = project.appendingPathComponent("Alpha.swift")
        try "struct Alpha {}".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: source.path)

        let stale = try makeStore(unitsModified: Date().addingTimeInterval(-3600))
        let fresh = try makeStore(unitsModified: Date().addingTimeInterval(60))
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(at: fresh)
        }

        #expect(IndexFreshness.state(storePaths: [stale.path], projectRoot: project.path) == .stale)
        #expect(IndexFreshness.state(storePaths: [fresh.path], projectRoot: project.path) == .fresh)
        // Multi-package project: building one package does not make the others fresh, so the
        // oldest store decides — a loud "stale" is safer than a quiet "fresh".
        #expect(IndexFreshness.state(storePaths: [fresh.path, stale.path], projectRoot: project.path) == .stale)
    }

    @Test("The signature changes when a store updates, and distinguishes sets")
    func signatureTracksRebuilds() throws {
        let first = try makeStore(unitsModified: Date().addingTimeInterval(-3600))
        let second = try makeStore(unitsModified: Date().addingTimeInterval(-1800))
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let before = try #require(IndexFreshness.signature(ofStores: [first.path]))
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                              ofItemAtPath: first.appendingPathComponent("v5/units").path)
        let after = try #require(IndexFreshness.signature(ofStores: [first.path]))
        #expect(before != after, "a rebuild must change the signature, or MCP will not re-open the index")

        // Different store sets are distinguishable; order within a set does not matter.
        #expect(IndexFreshness.signature(ofStores: [first.path]) != IndexFreshness.signature(ofStores: [first.path, second.path]))
        #expect(IndexFreshness.signature(ofStores: [first.path, second.path]) == IndexFreshness.signature(ofStores: [second.path, first.path]))
        #expect(IndexFreshness.signature(ofStores: []) == nil)
    }
}
