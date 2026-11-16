import Foundation
import Testing
@testable import SextantCore

/// The IndexStoreDB database sextant keeps per store: where it lives, and when an earlier run's
/// database is opened instead of importing every unit again.
@Suite("Index database", .serialized)
struct IndexDatabaseTests {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = repositoryRoot.appendingPathComponent("Tests/Fixtures/IndexFixture")
    static var fixtureStore: String? { BuildProducts.indexStore(under: fixture) }
    static var ready: Bool { fixtureStore != nil && BuildProducts.indexStoreLibrary != nil }

    private final class Scratch {
        let base: URL
        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("sextant-db-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) }

        /// A copy of the fixture's store at `relativePath` under the scratch directory.
        func store(at relativePath: String) throws -> String {
            let source = try #require(IndexDatabaseTests.fixtureStore)
            let target = base.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
            return target.path
        }
    }

    // MARK: Naming

    /// IndexStoreDB removes its discarded copies on a background queue that a short command never
    /// lets run, so concurrent cold queries each left a full copy behind until the next `index`.
    @Test("Copies IndexStoreDB discarded are removed when a database is opened, nothing else")
    func discardedCopiesAreRemoved() throws {
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-db-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: database) }
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let gone = finished.processIdentifier
        let own = getpid()
        let names = ["saved", "p1-saved-dead", "p\(gone)-saved", "p\(own)-saved", "p\(own)", "p\(gone)", "notes"]
        for name in names {
            try FileManager.default.createDirectory(at: database.appendingPathComponent("v13/\(name)"), withIntermediateDirectories: true)
        }
        IndexStoreSet.removeDiscardedCopies(in: database)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: database.appendingPathComponent("v13").path))
        #expect(left == ["saved", "p\(own)-saved", "p\(own)", "p\(gone)", "notes"], "\(left.sorted())")
    }

    @Test("A database is named by a bounded hash of the canonical store path")
    func namingIsBoundedAndCanonical() {
        let deep = "/" + Array(repeating: String(repeating: "d", count: 60), count: 8).joined(separator: "/") + "/index/store"
        let name = IndexStoreSet.databaseDirectory(forStore: deep, in: "/cache/index-db").lastPathComponent
        #expect(name.count == 24)
        // Distinct stores that the old naming (`/` → `_`) folded into one name.
        let first = IndexStoreSet.databaseDirectory(forStore: "/w/a_b/store", in: "/c")
        let second = IndexStoreSet.databaseDirectory(forStore: "/w/a/b_store", in: "/c")
        #expect(first != second)
        // Two spellings of one store share it.
        let tmp = IndexStoreSet.databaseDirectory(forStore: "/tmp/x/../store", in: "/c")
        let canonical = IndexStoreSet.databaseDirectory(forStore: CanonicalPath.of("/tmp/store"), in: "/c")
        #expect(tmp == canonical)
    }

    @Test("A store too deep for a file name, and two stores the old naming confused, each get a database",
          .enabled(if: IndexDatabaseTests.ready, "needs the fixture's index store — run `make fixture`"),
          .timeLimit(.minutes(3)))
    func deepAndCollidingStoresOpen() throws {
        let scratch = try Scratch()
        let library = try #require(BuildProducts.indexStoreLibrary)
        let databaseRoot = scratch.base.appendingPathComponent("index-db").path
        let deep = try scratch.store(at: Array(repeating: String(repeating: "d", count: 60), count: 5)
                                          .joined(separator: "/") + "/index/store")
        #expect(deep.replacingOccurrences(of: "/", with: "_").utf8.count > 255)
        let deepSet = try IndexStoreSet(storePaths: [deep], libraryPath: library, databaseRoot: databaseRoot)
        #expect(!deepSet.lookup(name: "EnglishGreeter", query: .definitions).isEmpty)

        let first = try scratch.store(at: "w/a_b/store")
        let second = try scratch.store(at: "w/a/b_store")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: databaseRoot)) ?? [])
        let set = try IndexStoreSet(storePaths: [first, second], libraryPath: library, databaseRoot: databaseRoot)
        #expect(set.storeCount == 2)
        let added = Set(try FileManager.default.contentsOfDirectory(atPath: databaseRoot)).subtracting(before)
        #expect(added.count == 2, "one database for two stores: \(added)")
    }

    // MARK: Reuse

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// The unit files of a store whose name starts with `prefix` — a unit is named after the
    /// object file it describes.
    private func units(named prefix: String, inStore store: String) throws -> [URL] {
        let root = URL(fileURLWithPath: store)
        var found: [URL] = []
        for version in try FileManager.default.contentsOfDirectory(atPath: store) where version.hasPrefix("v") {
            let directory = root.appendingPathComponent("\(version)/units")
            for unit in try FileManager.default.contentsOfDirectory(atPath: directory.path) where unit.hasPrefix(prefix) {
                found.append(directory.appendingPathComponent(unit))
            }
        }
        return found
    }

    @Test("A closed database is opened again over unchanged units, and answers as a new one does",
          .enabled(if: IndexDatabaseTests.ready, "needs the fixture's index store — run `make fixture`"),
          .timeLimit(.minutes(3)))
    func unchangedUnitsReuseTheDatabase() throws {
        let scratch = try Scratch()
        let library = try #require(BuildProducts.indexStoreLibrary)
        let store = try scratch.store(at: "pkg/index/store")
        let kept = scratch.base.appendingPathComponent("kept").path
        let names = ["EnglishGreeter", "greet", "c_fixture_double", "OCGreeter"]
        func answers(_ set: IndexStoreSet) throws -> Data {
            try encoded(names.flatMap { name in [set.lookup(name: name, query: .definitions), set.lookup(name: name, query: .references)] })
        }

        let first: Data
        do {
            let set = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
            #expect(set.reusedDatabase == [false])
            first = try answers(set)
        }
        let reopened = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
        #expect(reopened.reusedDatabase == [true], "the database was imported again over the same units")
        let fresh = try IndexStoreSet(storePaths: [store], libraryPath: library,
                                      databaseRoot: scratch.base.appendingPathComponent("fresh").path)
        #expect(try answers(reopened) == first)
        #expect(try answers(reopened) == answers(fresh))
    }

    /// IndexStoreDB's import on open adds and re-reads units but never drops one that is gone: a
    /// database that knew a unit the store no longer holds would keep answering from it.
    @Test("A database that knew a unit the store no longer holds is built anew",
          .enabled(if: IndexDatabaseTests.ready, "needs the fixture's index store — run `make fixture`"),
          .timeLimit(.minutes(3)))
    func vanishedUnitDiscardsTheDatabase() throws {
        let scratch = try Scratch()
        let library = try #require(BuildProducts.indexStoreLibrary)
        let store = try scratch.store(at: "pkg/index/store")
        let kept = scratch.base.appendingPathComponent("kept").path
        do {
            let set = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
            try #require(!set.lookup(name: "c_fixture_double", query: .definitions).compactMap(\.definition).isEmpty)
        }
        let removed = try units(named: "CFixture.o-", inStore: store)
        try #require(!removed.isEmpty, "no unit of CFixture.c in the fixture's store")
        for unit in removed { try FileManager.default.removeItem(at: unit) }

        let reopened = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
        #expect(reopened.reusedDatabase == [false])
        let fresh = try IndexStoreSet(storePaths: [store], libraryPath: library,
                                      databaseRoot: scratch.base.appendingPathComponent("fresh").path)
        // The header's declaration is still in the store; the definition went with the unit.
        #expect(fresh.lookup(name: "c_fixture_double", query: .definitions).compactMap(\.definition).isEmpty)
        #expect(try encoded(reopened.lookup(name: "c_fixture_double", query: .definitions))
                == encoded(fresh.lookup(name: "c_fixture_double", query: .definitions)))
    }

    /// IndexStoreDB reads a unit again on open only when its modification time moved. A unit
    /// rewritten with its old time put back (a restored backup, `touch -r`, a build that keeps
    /// times) left the database answering from the unit as it was.
    @Test("A database is built anew when a unit has the recorded modification time but is another file",
          .enabled(if: IndexDatabaseTests.ready, "needs the fixture's index store — run `make fixture`"),
          .timeLimit(.minutes(3)))
    func unitRewrittenUnderItsOldTimeDiscardsTheDatabase() throws {
        let scratch = try Scratch()
        let library = try #require(BuildProducts.indexStoreLibrary)
        let store = try scratch.store(at: "pkg/index/store")
        let kept = scratch.base.appendingPathComponent("kept").path
        do {
            let set = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
            try #require(!set.lookup(name: "c_fixture_double", query: .definitions).compactMap(\.definition).isEmpty)
        }
        // CFixture.c's unit now holds what another unit holds — the definition went with it — and
        // keeps the modification time it had, as a rewrite with the time put back leaves it.
        let rewritten = try #require(try units(named: "CFixture.o-", inStore: store).first)
        let other = try #require(try units(named: "", inStore: store).first {
            !$0.lastPathComponent.hasPrefix("CFixture.o-")
                && (try? Data(contentsOf: $0))?.count != (try? Data(contentsOf: rewritten))?.count
        })
        // To the nanosecond, as `touch -r` puts it back: IndexStoreDB compares the time exactly.
        var before = stat()
        try #require(lstat(rewritten.path, &before) == 0)
        try Data(contentsOf: other).write(to: rewritten)
        var times = [before.st_atimespec, before.st_mtimespec]
        try #require(utimensat(AT_FDCWD, rewritten.path, &times, 0) == 0)

        let reopened = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
        #expect(reopened.reusedDatabase == [false])
        let fresh = try IndexStoreSet(storePaths: [store], libraryPath: library,
                                      databaseRoot: scratch.base.appendingPathComponent("fresh").path)
        #expect(fresh.lookup(name: "c_fixture_double", query: .definitions).compactMap(\.definition).isEmpty)
        #expect(try encoded(reopened.lookup(name: "c_fixture_double", query: .definitions))
                == encoded(fresh.lookup(name: "c_fixture_double", query: .definitions)))
    }

    /// A record from an earlier version lists unit names alone, and says nothing about whether the
    /// units are still the files the database imported.
    @Test("A record of unit names alone, from an earlier version, has the database built anew",
          .enabled(if: IndexDatabaseTests.ready, "needs the fixture's index store — run `make fixture`"),
          .timeLimit(.minutes(3)))
    func recordInTheEarlierFormatDiscardsTheDatabase() throws {
        let scratch = try Scratch()
        let library = try #require(BuildProducts.indexStoreLibrary)
        let store = try scratch.store(at: "pkg/index/store")
        let kept = scratch.base.appendingPathComponent("kept").path
        _ = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
        let database = IndexStoreSet.databaseDirectory(forStore: store, in: kept)
        let names = try FileManager.default.contentsOfDirectory(atPath: store).filter { $0.hasPrefix("v") }.flatMap { version in
            try FileManager.default.contentsOfDirectory(atPath: "\(store)/\(version)/units").map { "\(version)/\($0)" }
        }
        try #require(!names.isEmpty)
        try Data(names.sorted().joined(separator: "\n").utf8).write(to: database.appendingPathComponent("sextant-units"))

        do {
            let reopened = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
            #expect(reopened.reusedDatabase == [false])
            #expect(!reopened.lookup(name: "EnglishGreeter", query: .definitions).isEmpty)
        }
        // Opened over the units it now records, it is kept again.
        let again = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
        #expect(again.reusedDatabase == [true])
    }

    /// A long-lived process brings its database up to date with the store while it runs; the units
    /// it imported then were missing from the record written on open, so their later removal from
    /// the store went unnoticed by the next run.
    @Test("A unit imported while the database was open is recorded, and its removal is noticed",
          .enabled(if: IndexDatabaseTests.ready, "needs the fixture's index store — run `make fixture`"),
          .timeLimit(.minutes(3)))
    func unitImportedWhileOpenIsRecorded() throws {
        let scratch = try Scratch()
        let library = try #require(BuildProducts.indexStoreLibrary)
        let store = try scratch.store(at: "pkg/index/store")
        let kept = scratch.base.appendingPathComponent("kept").path
        let source = try #require(try units(named: "CFixture.o-", inStore: store).first)
        let added = source.deletingLastPathComponent().appendingPathComponent("Added.o-0000000000000")
        do {
            let set = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
            try FileManager.default.copyItem(at: source, to: added)
            set.pollForChanges()
        }
        let database = IndexStoreSet.databaseDirectory(forStore: store, in: kept)
        let version = added.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        #expect(IndexStoreSet.recordedUnits(in: database)?["\(version)/\(added.lastPathComponent)"] != nil)

        try FileManager.default.removeItem(at: added)
        let reopened = try IndexStoreSet(storePaths: [store], libraryPath: library, databaseRoot: kept)
        #expect(reopened.reusedDatabase == [false])
    }

    @Test("The record of units round-trips, and only a same-time different file counts against a database")
    func unitRecordFormat() throws {
        let scratch = try Scratch()
        let database = scratch.base.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: database.appendingPathComponent("v13/saved"), withIntermediateDirectories: true)
        let stamp = IndexStoreSet.UnitStamp(modified: 1_700_000_000_123_456_789, size: 4096, inode: 42, statusChanged: 1_700_000_000_123_456_789)
        IndexStoreSet.recordUnits(["v5/units/A.o-1": stamp], in: database)
        #expect(IndexStoreSet.recordedUnits(in: database) == ["v5/units/A.o-1": stamp])

        // Moved time: IndexStoreDB reads the unit again itself.
        let moved = IndexStoreSet.UnitStamp(modified: stamp.modified + 1, size: 10, inode: 43, statusChanged: stamp.modified + 1)
        #expect(IndexStoreSet.prepareDatabase(database, forUnits: ["v5/units/A.o-1": moved, "v5/units/B.o-2": moved]))
        // Same time, another size — or the same size in another file — is a rewrite it would not read.
        for rewritten in [IndexStoreSet.UnitStamp(modified: stamp.modified, size: 4000, inode: 42, statusChanged: stamp.statusChanged),
                          IndexStoreSet.UnitStamp(modified: stamp.modified, size: 4096, inode: 99, statusChanged: stamp.statusChanged + 5)] {
            try FileManager.default.createDirectory(at: database.appendingPathComponent("v13/saved"), withIntermediateDirectories: true)
            IndexStoreSet.recordUnits(["v5/units/A.o-1": stamp], in: database)
            #expect(!IndexStoreSet.prepareDatabase(database, forUnits: ["v5/units/A.o-1": rewritten]))
            #expect(!FileManager.default.fileExists(atPath: database.appendingPathComponent("v13").path))
        }
        // A record that is not in this format — the earlier names-only one, or a damaged line.
        for text in ["v5/units/A.o-1", "sextant-units 2\nv5/units/A.o-1\t1\t2", ""] {
            try FileManager.default.createDirectory(at: database.appendingPathComponent("v13/saved"), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: database.appendingPathComponent("sextant-units"))
            #expect(IndexStoreSet.recordedUnits(in: database) == nil)
            #expect(!IndexStoreSet.prepareDatabase(database, forUnits: ["v5/units/A.o-1": stamp]))
        }
    }

    /// IndexStoreDB moves a database to `<version>/saved` when it is closed and imports every unit
    /// again when it finds none. A command that exited with its index open left the database
    /// under a per-process name, so every query paid for a full import.
    @Test("A command closes its index database, so the next one opens it instead of importing every unit",
          .enabled(if: IndexDatabaseTests.ready && BuildProducts.sextantBinary(under: repositoryRoot) != nil,
                   "needs the fixture's index store and the built binary"),
          .timeLimit(.minutes(3)))
    func commandLeavesTheDatabaseSaved() throws {
        let scratch = try Scratch()
        let store = try scratch.store(at: "pkg/index/store")
        let home = scratch.base.appendingPathComponent("home")
        let process = Process()
        let executable: URL = try #require(BuildProducts.sextantBinary(under: Self.repositoryRoot))
        process.executableURL = executable
        process.arguments = ["defs", "EnglishGreeter", "--project", Self.fixture.path, "--index-store", store]
        var environment = ProcessInfo.processInfo.environment
        for name in ["SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA", "CLAUDE_PROJECT_DIR", "SEXTANT_TELEMETRY"] {
            environment[name] = nil
        }
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SEXTANT_NO_DAEMON"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let databases = home.appendingPathComponent("Library/Caches/sextant/index-db")
        let entries = try FileManager.default.contentsOfDirectory(atPath: databases.path)
        #expect(entries.count == 1, "\(entries)")
        let database = databases.appendingPathComponent(try #require(entries.first))
        let saved = try FileManager.default.contentsOfDirectory(atPath: database.path)
            .filter { $0.hasPrefix("v") }
            .flatMap { version in
                ((try? FileManager.default.contentsOfDirectory(atPath: database.appendingPathComponent(version).path)) ?? [])
                    .map { "\(version)/\($0)" }
            }
        #expect(saved.contains { $0.hasSuffix("/saved") }, "the database was left open: \(saved)")
    }
}
