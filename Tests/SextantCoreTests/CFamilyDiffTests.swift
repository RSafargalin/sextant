import Foundation
import Testing
@testable import SextantCore

/// The symbol-level diff for the C family rests on one thing being true: the text of an older
/// revision parses against the flags the file is built with today. These check that, and the two
/// ways it is allowed to fail.
@Suite("C-family diff", .serialized)
struct CFamilyDiffTests {
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

    /// Declarations of arbitrary text, read as if it were the file — which is what diffing a past
    /// revision amounts to.
    private func declarations(of source: String, file suffix: String) throws -> [Declaration] {
        let command = try #require(CompilationDatabase.load(forRoot: Self.fixture.path)
            .first { $0.file.hasSuffix(suffix) })
        let unit = try ClangTranslationUnit.parse(
            file: command.file,
            arguments: CompilationDatabase.parseArguments(of: command),
            library: try ClangLibrary.shared(),
            overlay: source
        )
        #expect(unit.isComplete, "\(unit.errors.map { $0.text })")
        return ClangDeclarations.declarations(of: unit.root.children, source: Data(source.utf8),
                                              publicOnly: false, access: .internal)
    }

    @Test("A revision's text yields its declarations, nested under their container",
          .enabled(if: isReady, "the fixture has not been built and indexed, or there is no toolchain"))
    func readsDeclarationsOfArbitraryText() throws {
        let source = """
        #import "ObjCFixture.h"

        @implementation OCFeeder
        - (NSInteger)ocFeed { return 1; }
        @end
        """
        let declarations = try declarations(of: source, file: "ObjCFixture.m")
        let container = try #require(declarations.first)
        // `@implementation Foo` opens no brace of its own; cutting the signature at the first one
        // would swallow the method that follows it.
        #expect(container.header == "@implementation OCFeeder")
        #expect(container.members.map { $0.header } == ["- (NSInteger)ocFeed"])
    }

    @Test("Adding a method to a class shows up as an addition inside it",
          .enabled(if: isReady, "the fixture has not been built and indexed, or there is no toolchain"))
    func diffsAgainstAnotherRevision() throws {
        let before = """
        #import "ObjCFixture.h"

        @implementation OCFeeder
        - (NSInteger)ocFeed { return 1; }
        @end
        """
        let after = """
        #import "ObjCFixture.h"

        @implementation OCFeeder
        - (NSInteger)ocFeed { return 2; }
        - (NSInteger)ocFeedTwice { return 4; }
        @end
        """
        let result = DeclarationDiff.compare(old: try declarations(of: before, file: "ObjCFixture.m"),
                                             new: try declarations(of: after, file: "ObjCFixture.m"))
        #expect(result.added.map { $0.header } == ["OCFeeder.- (NSInteger)ocFeedTwice"])
        // The body of ocFeed changed, its signature did not: a symbol-level diff stays quiet.
        #expect(result.removed.isEmpty && result.changed.isEmpty)
    }

    /// A copy of the fixture's C-family sources in a git repository, with the fixture's commands
    /// moved onto it: a header and a deleted source are then compared against the commit.
    private func repositoryCopy() throws -> (root: URL, commands: [CompileCommand]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-cdiff-\(UUID().uuidString.prefix(8))")
        for target in ["CFixture", "ObjCFixture", "CxxFixture"] {
            let destination = root.appendingPathComponent("Sources/\(target)")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Self.fixture.appendingPathComponent("Sources/\(target)"), to: destination)
        }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", root.path, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments)")
        }
        try git(["init", "-q"])
        try git(["add", "."])
        try git(["commit", "-q", "-m", "one"])
        let from = Self.fixture.path + "/Sources", to = root.path + "/Sources"
        let commands = CompilationDatabase.load(forRoot: Self.fixture.path).map {
            CompileCommand(directory: $0.directory, file: $0.file.replacingOccurrences(of: from, with: to),
                           arguments: $0.arguments.map { $0.replacingOccurrences(of: from, with: to) })
        }
        return (root, commands)
    }

    @Test("Headers are compared with the flags of the source that includes them, not refused",
          .enabled(if: isReady, "the fixture has not been built and indexed, or there is no toolchain"))
    func comparesHeaders() throws {
        let (root, commands) = try repositoryCopy()
        defer { try? FileManager.default.removeItem(at: root) }
        let objc = root.appendingPathComponent("Sources/ObjCFixture/include/ObjCFixture.h")
        try (try String(contentsOf: objc, encoding: .utf8) + "\n@interface OCGreeter (Whisper)\n- (NSString *)ocWhisper;\n@end\n")
            .write(to: objc, atomically: true, encoding: .utf8)
        let c = root.appendingPathComponent("Sources/CFixture/include/CFixture.h")
        try (try String(contentsOf: c, encoding: .utf8)).replacingOccurrences(
            of: "int c_fixture_double(int input);", with: "int c_fixture_double(int input);\nint c_fixture_triple(int input);")
            .write(to: c, atomically: true, encoding: .utf8)
        let outcome = CFamilyDiff.changes(files: ["Sources/CFixture/include/CFixture.h", "Sources/ObjCFixture/include/ObjCFixture.h"],
                                          topLevel: root.path, projectRoot: root.path, from: "HEAD", to: nil,
                                          commands: commands)
        #expect(outcome.notDiffed.isEmpty, "\(outcome.notDiffed)")
        let added = outcome.files.flatMap { $0.result.added.map(\.header) }
        #expect(added.contains { $0.contains("c_fixture_triple") }, "\(added)")
        #expect(added.contains { $0.contains("ocWhisper") }, "\(added)")
    }

    @Test("A deleted source lists the declarations it took with it, read from the base revision",
          .enabled(if: isReady, "the fixture has not been built and indexed, or there is no toolchain"))
    func deletedSourceListsItsDeclarations() throws {
        let (root, commands) = try repositoryCopy()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/CxxFixture/CxxFixture.cpp"))
        let outcome = CFamilyDiff.changes(files: ["Sources/CxxFixture/CxxFixture.cpp"], topLevel: root.path,
                                          projectRoot: root.path, from: "HEAD", to: nil, commands: commands)
        #expect(outcome.notDiffed.isEmpty, "\(outcome.notDiffed)")
        let removed = outcome.files.flatMap { $0.result.removed.map(\.header) }
        #expect(removed.contains { $0.contains("nestedDouble") }, "\(removed)")
        // With its entry gone too, flags are borrowed from another source; whatever that gives, the
        // advice is never to build the index, which cannot bring a deleted file's flags back.
        let borrowed = CFamilyDiff.changes(files: ["Sources/CxxFixture/CxxFixture.cpp"], topLevel: root.path,
                                           projectRoot: root.path, from: "HEAD", to: nil,
                                           commands: commands.filter { !$0.file.hasSuffix("CxxFixture.cpp") })
        #expect(!borrowed.notDiffed.contains { $0.reason.contains("sextant index") }, "\(borrowed.notDiffed)")
    }

    @Test("A file with no compile flags is named, not silently skipped")
    func namesFilesWithoutFlags() {
        let outcome = CFamilyDiff.changes(files: ["Sources/Nothing/Unknown.m"],
                                          topLevel: Self.fixture.path,
                                          projectRoot: Self.fixture.path,
                                          from: "HEAD", to: nil)
        #expect(outcome.files.isEmpty)
        #expect(outcome.notDiffed.first?.file == "Sources/Nothing/Unknown.m")
        #expect(outcome.notDiffed.first?.reason.contains("sextant index") == true)
    }

    @Test("Without a compile database every changed file is named")
    func namesEverythingWithoutDatabase() {
        let outcome = CFamilyDiff.changes(files: ["A.m", "B.c"],
                                          topLevel: Self.fixture.path,
                                          projectRoot: "/nowhere-\(UUID().uuidString)",
                                          from: "HEAD", to: nil)
        #expect(outcome.files.isEmpty)
        #expect(outcome.notDiffed.count == 2)
    }
}
