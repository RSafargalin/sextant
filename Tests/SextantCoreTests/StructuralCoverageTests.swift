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
        let unscanned = StructuralCoverage.unscannedFiles(projectRoot: fixture.path, includeTests: false)
        #expect(unscanned.contains("Sources/ObjCFixture/ObjCFixture.m"))
        #expect(unscanned.contains("Sources/CFixture/CFixture.c"))
        #expect(unscanned.contains("Sources/CxxFixture/CxxFixture.cpp"))
        #expect(unscanned.contains("Sources/ObjCFixture/include/ObjCFixture.h"))
        #expect(!unscanned.contains { $0.hasSuffix(".swift") })
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
        let files = (1...15).map { "Sources/File\($0).m" }
        let lines = StructuralCoverage.report(files, limit: 10)
        #expect(lines.first?.contains("(15)") == true)
        #expect(lines.count == 12)                       // header + 10 names + "and 5 more"
        #expect(lines.last?.contains("5 more") == true)
    }
}
