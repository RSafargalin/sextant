import Foundation
import Testing
@testable import SextantCore

@Suite("Structural coverage")
struct StructuralCoverageTests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndexFixture")
    }

    @Test("Every non-Swift source under the root is reported as unscanned")
    func namesNonSwiftSources() {
        let files = StructuralCoverage.unscannedFiles(projectRoot: fixture.path, includeTests: false).map { $0.file }
        #expect(files.contains("Sources/ObjCFixture/ObjCFixture.m"))
        #expect(files.contains("Sources/CFixture/CFixture.c"))
        #expect(files.contains("Sources/CxxFixture/CxxFixture.cpp"))
        #expect(files.contains("Sources/ObjCFixture/include/ObjCFixture.h"))
        #expect(!files.contains { $0.hasSuffix(".swift") })
    }

    @Test("A Swift-only project reports nothing")
    func silentOnSwiftOnlyProject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-coverage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "struct A {}".write(to: directory.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)

        let unscanned = StructuralCoverage.unscannedFiles(projectRoot: directory.path, includeTests: false)
        #expect(unscanned.isEmpty)
        #expect(StructuralCoverage.report(unscanned).isEmpty)
    }

    @Test("The report states the count and truncates the list")
    func reportCountsAndTruncates() {
        let files = (1...15).map { UnscannedFile(file: "Sources/File\($0).m", reason: "no compile flags") }
        let lines = StructuralCoverage.report(files, limit: 10)
        #expect(lines.first?.contains("(15)") == true)
        #expect(lines.count == 12)                       // header + 10 names + "and 5 more"
        #expect(lines.last?.contains("5 more") == true)
    }

    @Test("The answer states the configuration the C family was read in")
    func configurationNote() {
        #expect(StructuralCoverage.configurationNote(targets: []).isEmpty)
        let note = StructuralCoverage.configurationNote(targets: ["x86_64-apple-macosx10.13"])
        #expect(note.first?.contains("x86_64-apple-macosx10.13") == true)
        // Measured on SDWebImage: grep finds 28 occurrences, the structural search 15, and the
        // other 13 sit inside `#if SD_UIKIT` — inactive in a macOS build. Without this line the
        // narrower answer looks like it covered the file whole.
        #expect(note.first?.contains("#if") == true)
    }

    @Test("Files are grouped by reason, each reason explained once")
    func reportGroupsByReason() {
        let lines = StructuralCoverage.report([
            UnscannedFile(file: "A.m", reason: "no compile flags"),
            UnscannedFile(file: "B.h", reason: "a header is not a compilation unit"),
            UnscannedFile(file: "C.m", reason: "no compile flags")
        ])
        #expect(lines.filter { $0.hasPrefix("⚠") }.count == 2)
        #expect(lines.first?.contains("(2)") == true)     // the two files sharing a reason are one group
    }
}
