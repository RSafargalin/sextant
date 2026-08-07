import Foundation
import Testing
@testable import SextantCore

/// The public surface of a C++ header, read through clang. The index cannot answer this — it
/// carries no access level — so these run against a real parse of the fixture.
@Suite("C++ header surface", .serialized)
struct CxxHeaderAPITests {
    private static var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndexFixture")
    }

    private static var isReady: Bool {
        FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".build").path)
            && ClangLibrary.discoverPath() != nil
            && !CompilationDatabase.load(forRoot: fixture.path).isEmpty
    }

    private var header: URL {
        Self.fixture.appendingPathComponent("Sources/CxxFixture/include/CxxFixture.hpp")
    }

    private func summaries() -> (summaries: [FileSummary], unanswered: [UnscannedFile]) {
        IndexDeclarations.cxxHeaderSummaries([header], root: Self.fixture, compileDatabaseRoot: Self.fixture.path)
    }

    @Test("Public members are reported and private ones are not",
          .enabled(if: isReady, "the fixture has not been built and indexed, or there is no toolchain"))
    func reportsPublicMembersOnly() throws {
        let file = try #require(summaries().summaries.first)
        #expect(file.relativePath == "Sources/CxxFixture/include/CxxFixture.hpp")

        let widget = try #require(file.declarations.first { $0.header.contains("class Widget") })
        let members = widget.members.map { $0.header }
        #expect(members.contains { $0.contains("Widget(int size)") })
        #expect(members.contains { $0.contains("int area() const") })
        // `size_` is private. Listing it is exactly the confident wrong answer that kept C++
        // headers out of `api` until clang could be asked.
        #expect(!members.contains { $0.contains("size_") })
    }

    @Test("A struct, its members, both overloads and a template all survive",
          .enabled(if: isReady, "the fixture has not been built and indexed, or there is no toolchain"))
    func reportsTheWholeSurface() throws {
        let file = try #require(summaries().summaries.first)
        let headers = file.declarations.map { $0.header }

        #expect(headers.contains { $0.contains("struct Counter") })
        #expect(headers.filter { $0.contains("scale(") }.count == 2)     // one name, two signatures
        // A template's signature spans two lines; taking only the first would name no type at all.
        #expect(headers.contains { $0.contains("struct Box") })
        // A function inside a nested namespace is part of the surface a caller can reach.
        #expect(headers.contains { $0.contains("nestedDouble") })

        let counter = try #require(file.declarations.first { $0.header.contains("struct Counter") })
        #expect(counter.members.map { $0.header }.contains { $0.contains("int bump(int by)") })
    }

    @Test("A header no compiled source includes is named, not reported as empty",
          .enabled(if: isReady, "the fixture has not been built and indexed, or there is no toolchain"))
    func namesUnreachableHeader() {
        let stray = Self.fixture.appendingPathComponent("Sources/CxxFixture/include/NotIncluded.hpp")
        let result = IndexDeclarations.cxxHeaderSummaries([stray], root: Self.fixture,
                                                          compileDatabaseRoot: Self.fixture.path)
        #expect(result.summaries.isEmpty)
        #expect(result.unanswered.first?.reason.contains("no compiled source includes") == true)
    }

    @Test("Without a compile database the headers are named with what to do about it")
    func namesHeadersWithoutFlags() {
        let result = IndexDeclarations.cxxHeaderSummaries([header], root: Self.fixture,
                                                          compileDatabaseRoot: "/nowhere-\(UUID().uuidString)")
        #expect(result.summaries.isEmpty)
        #expect(result.unanswered.first?.reason.contains("sextant index") == true)
    }
}
