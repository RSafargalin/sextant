import Foundation
import Testing
@testable import SextantCore

/// A directory that is not a repository still has a `.gitignore`, and the old fallback read only
/// bare directory names from it — dropping every line with a `/` or a `*`. Rather than growing a
/// subset of gitignore (attempted, and unpredictable), git is borrowed: the project becomes a work
/// tree whose git dir lives in the cache.
@Suite("Borrowed git for non-git projects", .serialized)
struct BorrowedGitTests {
    /// A project outside any repository, with the rules the old reader threw away.
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-nogit-\(UUID().uuidString)")
        for directory in ["Sources/App/Generated", "Debug", "Sources/Legacy"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory),
                                                    withIntermediateDirectories: true)
        }
        try """
        Sources/**/Generated/*.swift
        [Dd]ebug/
        Sources/Legacy/
        """.write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        for file in ["Sources/App/Main.swift", "Sources/App/Generated/Api.swift",
                     "Debug/Dbg.swift", "Sources/Legacy/Old.swift"] {
            try "struct X {}".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("The rules the old reader dropped are honoured")
    func honoursFullGitignore() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try #require(SwiftSources.borrowedGitFiles(under: root, includeTests: true, extensions: ["swift"]))
        // A glob across components, a bracket class, and a directory — none of which survived the
        // hand-rolled reader, which kept only bare directory names.
        #expect(files.map { $0.lastPathComponent } == ["Main.swift"])
    }

    @Test("Nothing is written inside the project")
    func writesNothingIntoTheProject() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = SwiftSources.borrowedGitFiles(under: root, includeTests: true, extensions: ["swift"])
        // Answering a read-only question must not turn someone's directory into a repository.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
        #expect(SwiftSources.borrowedGitDirectory(for: root).path.contains("Library/Caches/sextant"))
    }

    @Test("The walk uses it, so a non-git project answers like a git one")
    func theWalkUsesIt() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root); SwiftSources.clearFileListMemo() }
        SwiftSources.clearFileListMemo()

        #expect(SwiftSources.files(under: root, includeTests: true).map { $0.lastPathComponent } == ["Main.swift"])
    }
}
