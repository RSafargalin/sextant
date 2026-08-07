import Foundation
import Testing
@testable import SextantCore

/// Structural search over the C family, against the real fixture: the pattern is compiled by
/// clang inside each file, so only a real parse proves anything here.
@Suite("Clang pattern search", .serialized)
struct ClangPatternSearchTests {
    private static var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndexFixture")
    }

    private static var isReady: Bool {
        FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".build").path)
            && ClangLibrary.discoverPath() != nil
    }

    private func command(suffix: String) throws -> CompileCommand {
        let commands = CompilationDatabase.capture(fromStores: IndexStoreLocator.stores(under: Self.fixture))
        return try #require(commands.first { $0.file.hasSuffix(suffix) })
    }

    private func search(_ pattern: String, in suffix: String) throws -> [StructuralMatch] {
        let command = try command(suffix: suffix)
        return try ClangPatternSearch(pattern: pattern).search(
            file: command.file,
            arguments: CompilationDatabase.parseArguments(of: command),
            library: try ClangLibrary.shared()
        )
    }

    @Test("A message send with a metavariable receiver finds every call site",
          .enabled(if: isReady, "the fixture has not been built, or there is no toolchain"))
    func findsMessageSends() throws {
        let matches = try search("[$X ocFeed]", in: "ObjCFixture.m")
        // `return [self ocFeed] + [self ocFeed];` — two calls on one line, as grep would find them.
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.text == "[self ocFeed]" })
        #expect(Set(matches.map { $0.line }).count == 1)
        #expect(matches.map { $0.column } == [12, 28])
    }

    @Test("A selector with an argument matches, and a different selector does not",
          .enabled(if: isReady, "the fixture has not been built, or there is no toolchain"))
    func matchesSelectorWithArgument() throws {
        let matches = try search("[$X ocGreetWithName:$Y]", in: "ObjCFixture.m")
        #expect(matches.count == 1)
        #expect(matches.first?.line == 22)
        #expect(matches.first?.text == "[self ocGreetWithName:name]")

        // The same shape with another selector: the structure matches, the name does not.
        #expect(try search("[$X ocShoutWithName:$Y]", in: "ObjCFixture.m").isEmpty)
    }

    @Test("A repeated metavariable requires the same text in both places",
          .enabled(if: isReady, "the fixture has not been built, or there is no toolchain"))
    func repeatedMetavariableBindsConsistently() throws {
        #expect(try search("[$X ocFeed] + [$X ocFeed]", in: "ObjCFixture.m").count == 1)
        // Both receivers are `self`, so a pattern demanding two different receivers cannot match.
        #expect(try search("[$X ocFeed] + [$Y ocFeed]", in: "ObjCFixture.m").count == 1)
    }

    @Test("C and C++ are searched by the same engine",
          .enabled(if: isReady, "the fixture has not been built, or there is no toolchain"))
    func searchesCAndCxx() throws {
        // C++: a shape built from metavariables needs no name at all, and a repeated one still
        // has to bind the same text — `size_ * size_` matches, `value * 2` does not.
        let squares = try search("$X * $X", in: "CxxFixture.cpp")
        #expect(squares.count == 1)
        #expect(squares.first?.text == "size_ * size_")

        // C: a literal is part of the pattern, not a hole — `input * 2` is in the file, `input * 3` is not.
        #expect(try search("$X * 2", in: "CFixture.c").count == 1)
        #expect(try search("$X * 3", in: "CFixture.c").isEmpty)
    }

    @Test("A C++ name inside a namespace is out of the probe's reach, and says so",
          .enabled(if: isReady, "the fixture has not been built, or there is no toolchain"))
    func namespacedNameIsRefusedWithItsReason() throws {
        // The probe is appended at file scope, where `scale` — declared inside `namespace
        // sextantfixture` — is not visible. The refusal carries clang's own reason rather than
        // passing the pattern off as unmatched.
        let error = try #require(performAndCatch { _ = try search("scale($X)", in: "CxxFixture.cpp") })
        #expect("\(error)".contains("undeclared identifier 'scale'"))
    }

    private func performAndCatch(_ work: () throws -> Void) -> Error? {
        do { try work(); return nil } catch { return error }
    }

    @Test("A pattern that cannot compile in a file is refused, not answered with zero",
          .enabled(if: isReady, "the fixture has not been built, or there is no toolchain"))
    func refusesWhenThePatternDoesNotCompile() throws {
        // Objective-C syntax in a C file: clang cannot build the probe, and "no matches" would be
        // a confident answer to a question that was never asked.
        #expect(throws: ClangPatternSearch.Failure.self) {
            try search("[$X ocFeed]", in: "CFixture.c")
        }
    }

    @Test("Code in an #if branch this build lacks is reported textually, apart from the matches",
          .enabled(if: isReady, "the fixture has not been built, or there is no toolchain"))
    func reportsInactiveBranchesSeparately() throws {
        let outcome = CFamilySearch.run(pattern: "[$X ocFeed]", searchRoot: Self.fixture.path,
                                        projectRoot: Self.fixture.path, includeTests: false)
        // Structurally verified: the two calls in code this build contains.
        #expect(outcome.hits.count == 2)
        // Textual only: the call inside `#if TARGET_OS_IPHONE`, which clang never compiled here.
        // Left out, the answer would say "2 usages" where a reader of the sources counts three.
        #expect(outcome.inactive.count == 1)
        #expect(outcome.inactive.first?.text.contains("[self ocFeed]") == true)
        #expect(outcome.targets.contains { $0.contains("macosx") })
    }

    @Test("A variadic is refused for the C family rather than quietly ignored")
    func refusesVariadic() {
        #expect(throws: ClangPatternSearch.Failure.self) {
            try ClangPatternSearch(pattern: "scale($$$)")
        }
    }
}
