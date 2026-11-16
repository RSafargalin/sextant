import Foundation
import Testing
@testable import SextantCore

/// The compile flags had no notion of time at all. They are captured by `sextant index`; every
/// other way of building — Xcode, `swift build`, CI — moves the index forward and leaves them
/// behind, and nothing in a structural answer said so. That is not ordinary incompleteness: a
/// `-DFEATURE=1` that has since become `0` produces a structural match inside code the current
/// build does not contain, which is the tool's highest confidence standing on a stale fact.
@Suite("Compile flags: freshness and pruning", .serialized)
struct CompileFlagsFreshnessTests {

    private func makeRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-flags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    private func makeStore(newerThan captured: Date) throws -> String {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-flagstore-\(UUID().uuidString)")
        let units = store.appendingPathComponent("v5/units")
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try Data("unit".utf8).write(to: units.appendingPathComponent("Main.o-HASH"))
        try FileManager.default.setAttributes([.modificationDate: captured.addingTimeInterval(600)],
                                              ofItemAtPath: units.path)
        return store.path
    }

    @Test("a build newer than the capture is named, with the gap")
    func staleFlagsAreNamed() throws {
        let root = try makeRoot()
        let source = "\(root)/legacy.c"
        try "int legacy(void) { return 1; }\n".write(toFile: source, atomically: true, encoding: .utf8)
        try CompilationDatabase.save([CompileCommand(directory: root, file: source, arguments: ["clang", source])],
                                     forRoot: root)
        defer { try? FileManager.default.removeItem(at: CompilationDatabase.entry(forRoot: root)) }

        let captured = try #require(CompilationDatabase.capturedAt(forRoot: root))
        let store = try makeStore(newerThan: captured)
        defer { try? FileManager.default.removeItem(atPath: store) }

        let note = CompilationDatabase.stalenessNote(forRoot: root, storePaths: [store]).joined()
        #expect(note.contains("compile flags captured"))
        #expect(note.contains("10 minutes later"))
        #expect(note.contains("sextant index"))
    }

    /// Regression: an incremental `sextant index` that recompiled no C-family file kept the flags as
    /// they were, and the note then warned after every reindex with advice that could not clear it.
    @Test("flags `sextant index` confirmed after the build say nothing; a later build by other means is named")
    func confirmedFlagsAreCurrent() throws {
        let root = try makeRoot()
        let source = "\(root)/legacy.c"
        try "int legacy(void) { return 1; }\n".write(toFile: source, atomically: true, encoding: .utf8)
        try CompilationDatabase.save([CompileCommand(directory: root, file: source, arguments: ["clang", source])],
                                     forRoot: root)
        defer { try? FileManager.default.removeItem(at: CompilationDatabase.entry(forRoot: root)) }
        let captured = try #require(CompilationDatabase.capturedAt(forRoot: root))
        try FileManager.default.setAttributes([.modificationDate: captured.addingTimeInterval(-1200)],
                                              ofItemAtPath: CompilationDatabase.path(forRoot: root).path)
        let store = try makeStore(newerThan: captured.addingTimeInterval(-1200))
        defer { try? FileManager.default.removeItem(atPath: store) }
        #expect(!CompilationDatabase.stalenessNote(forRoot: root, storePaths: [store]).isEmpty)

        CompilationDatabase.confirm(forRoot: root)
        #expect(CompilationDatabase.stalenessNote(forRoot: root, storePaths: [store]).isEmpty)

        // A build made some other way after the confirmation leaves the flags behind again.
        let later = try makeStore(newerThan: Date())
        defer { try? FileManager.default.removeItem(atPath: later) }
        let note = CompilationDatabase.stalenessNote(forRoot: root, storePaths: [later]).joined()
        #expect(note.contains("last confirmed by `sextant index`"), "\(note)")
    }

    /// A query reads the flags of the roots around the one asked about and inside it, so the note
    /// has to judge those: judging only the root's own database said nothing about flags read
    /// from a containing root's.
    @Test("the flags read from a containing root's database are the ones judged")
    func containingDatabaseIsJudged() throws {
        let outer = try makeRoot()
        let inner = "\(outer)/Nested"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        let source = "\(inner)/legacy.c"
        try "int legacy(void) { return 1; }\n".write(toFile: source, atomically: true, encoding: .utf8)
        try CompilationDatabase.save([CompileCommand(directory: outer, file: source, arguments: ["clang", source])],
                                     forRoot: outer)
        defer { try? FileManager.default.removeItem(at: CompilationDatabase.entry(forRoot: outer)) }
        try #require(!CompilationDatabase.commands(forFilesUnder: inner).isEmpty)

        let captured = try #require(CompilationDatabase.capturedAt(forRoot: outer))
        let store = try makeStore(newerThan: captured)
        defer { try? FileManager.default.removeItem(atPath: store) }

        let note = CompilationDatabase.stalenessNote(forRoot: inner, storePaths: [store]).joined()
        #expect(note.contains("compile flags captured"), "\(note)")
        #expect(note.contains("10 minutes later"), "\(note)")
    }

    /// The ordinary case — `sextant index` captures after building — must stay silent, or the
    /// warning becomes noise and stops being read.
    @Test("flags captured after the build say nothing")
    func freshFlagsAreSilent() throws {
        let root = try makeRoot()
        let source = "\(root)/legacy.c"
        try "int legacy(void) { return 1; }\n".write(toFile: source, atomically: true, encoding: .utf8)

        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-flagstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: store.appendingPathComponent("v5/units"),
                                                withIntermediateDirectories: true)
        try Data("unit".utf8).write(to: store.appendingPathComponent("v5/units/Main.o-HASH"))
        defer { try? FileManager.default.removeItem(at: store) }
        Thread.sleep(forTimeInterval: 1.1)   // the capture lands after the build, as it does in practice
        try CompilationDatabase.save([CompileCommand(directory: root, file: source, arguments: ["clang", source])],
                                     forRoot: root)
        defer { try? FileManager.default.removeItem(at: CompilationDatabase.entry(forRoot: root)) }

        #expect(CompilationDatabase.stalenessNote(forRoot: root, storePaths: [store.path]).isEmpty)
    }

    /// Measured on this machine: two databases held 75 of 75 and 72 of 73 entries for files
    /// deleted weeks earlier, because pruning happened only when a new capture merged over them.
    @Test("entries for files that are gone are dropped when the database is read")
    func deletedEntriesAreDroppedOnLoad() throws {
        let root = try makeRoot()
        let alive = "\(root)/alive.c"
        let gone = "\(root)/gone.c"
        try "int alive(void) { return 1; }\n".write(toFile: alive, atomically: true, encoding: .utf8)
        try "int gone(void) { return 1; }\n".write(toFile: gone, atomically: true, encoding: .utf8)
        try CompilationDatabase.save([
            CompileCommand(directory: root, file: alive, arguments: ["clang", alive]),
            CompileCommand(directory: root, file: gone, arguments: ["clang", gone]),
        ], forRoot: root)
        defer { try? FileManager.default.removeItem(at: CompilationDatabase.entry(forRoot: root)) }

        #expect(CompilationDatabase.load(forRoot: root).count == 2)
        try FileManager.default.removeItem(atPath: gone)
        let remaining = CompilationDatabase.load(forRoot: root)
        #expect(remaining.count == 1)
        #expect(remaining.first?.file == alive)
    }
}
