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
        process.executableURL = try #require(BuildProducts.sextantBinary(under: Self.repositoryRoot))
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
