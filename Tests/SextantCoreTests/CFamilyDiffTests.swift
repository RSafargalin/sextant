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
