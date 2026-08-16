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
        defer { try? FileManager.default.removeItem(at: CompilationDatabase.path(forRoot: root)) }

        let captured = try #require(CompilationDatabase.capturedAt(forRoot: root))
        let store = try makeStore(newerThan: captured)
        defer { try? FileManager.default.removeItem(atPath: store) }

        let note = CompilationDatabase.stalenessNote(forRoot: root, storePaths: [store]).joined()
        #expect(note.contains("compile flags captured"))
        #expect(note.contains("10 minutes later"))
        #expect(note.contains("sextant index"))
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
        defer { try? FileManager.default.removeItem(at: store) }
        Thread.sleep(forTimeInterval: 1.1)   // the capture lands after the build, as it does in practice
        try CompilationDatabase.save([CompileCommand(directory: root, file: source, arguments: ["clang", source])],
                                     forRoot: root)
        defer { try? FileManager.default.removeItem(at: CompilationDatabase.path(forRoot: root)) }

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
        defer { try? FileManager.default.removeItem(at: CompilationDatabase.path(forRoot: root)) }

        #expect(CompilationDatabase.load(forRoot: root).count == 2)
        try FileManager.default.removeItem(atPath: gone)
        let remaining = CompilationDatabase.load(forRoot: root)
        #expect(remaining.count == 1)
        #expect(remaining.first?.file == alive)
    }
}
