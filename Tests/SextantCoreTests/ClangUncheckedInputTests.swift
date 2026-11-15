import Foundation
import Testing
@testable import SextantCore

/// The C-family half of naming what was not really checked: operators that must be told apart, a
/// file clang reported errors in, headers a lint never reads, and patterns clang compiles but the
/// matcher could not bind. Each needs a real libclang parse.
@Suite("Unchecked C-family input is named", .serialized)
struct ClangUncheckedInputTests {
    private static var hasClang: Bool { ClangLibrary.discoverPath() != nil }

    private static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndexFixture")
    }

    private static var fixtureReady: Bool {
        FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".build").path)
            && hasClang && !CompilationDatabase.load(forRoot: fixture.path).isEmpty
    }

    /// A scratch C project with its compile flags recorded, as `sextant index` would.
    private final class Project {
        let root: URL

        init(_ files: [String: String]) throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("sextant-clang-unchecked-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            root = base.resolvingSymlinksInPath()
            for (path, contents) in files {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            let commands = files.keys.filter { $0.hasSuffix(".c") }.map { path in
                let file = root.appendingPathComponent(path).path
                return CompileCommand(directory: root.path, file: file, arguments: ["clang", "-x", "c", "-c", file])
            }
            try CompilationDatabase.save(commands, forRoot: root.path)
        }

        deinit {
            try? FileManager.default.removeItem(at: CompilationDatabase.entry(forRoot: root.path))
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func matches(_ pattern: String, in project: Project, file: String) throws -> [String] {
        let path = project.root.appendingPathComponent(file).path
        return try ClangPatternSearch(pattern: pattern)
            .search(file: path, arguments: ["-x", "c"], library: try ClangLibrary.shared())
            .map(\.text)
    }

    @Test("Unary, binary and assignment operators are told apart",
          .enabled(if: hasClang, "no libclang in the toolchain"))
    func operatorsAreCompared() throws {
        let project = try Project(["ops.c": """
        int ops(int x, int y) {
            int a = !x;
            int b = -x;
            int c = x + y;
            int d = x - y;
            x += 1;
            x -= 1;
            x++;
            ++x;
            return a + b + c + d;
        }
        """])
        #expect(try matches("!$X", in: project, file: "ops.c") == ["!x"])
        #expect(try matches("-$X", in: project, file: "ops.c") == ["-x"])
        #expect(try matches("$X - $Y", in: project, file: "ops.c") == ["x - y"])
        #expect(try matches("$X -= 1", in: project, file: "ops.c") == ["x -= 1"])
        #expect(try matches("$X++", in: project, file: "ops.c") == ["x++"])
        #expect(try matches("++$X", in: project, file: "ops.c") == ["++x"])
    }

    @Test("clang's tree is already structured: an operator pattern matches inside an assignment",
          .enabled(if: hasClang, "no libclang in the toolchain"))
    func operatorInsideAssignment() throws {
        let project = try Project(["a.c": "int f(int b) { int a; a = b + 1; return a * 2 + 1; }\n"])
        #expect(try matches("$X + 1", in: project, file: "a.c") == ["b + 1", "a * 2 + 1"])
    }

    @Test("Without libclang's operator kinds, the operator is read from the text around the operands")
    func operatorFromText() {
        func node(_ kind: String, _ start: Int, _ end: Int, _ children: [ClangNode] = []) -> ClangNode {
            ClangNode(kind: 0, kindName: kind, spelling: "", file: "", line: 1, column: 1, startOffset: start,
                      endOffset: end, access: 0, operatorKind: 0, children: children)
        }
        let source = Data("!x -x x++ a += b".utf8)
        let x = { (start: Int) in node("DeclRefExpr", start, start + 1) }
        #expect(ClangPatternSearch.operatorSpelling(of: node("UnaryOperator", 0, 2, [x(1)]), in: source) == "!")
        #expect(ClangPatternSearch.operatorSpelling(of: node("UnaryOperator", 3, 5, [x(4)]), in: source) == "-")
        #expect(ClangPatternSearch.operatorSpelling(of: node("UnaryOperator", 6, 9, [x(6)]), in: source) == "postfix ++")
        #expect(ClangPatternSearch.operatorSpelling(of: node("CompoundAssignOperator", 10, 16, [x(10), x(15)]),
                                                    in: source) == "+=")
    }

    @Test("A file clang reports errors in is searched but named, not counted as a clean scan",
          .enabled(if: hasClang, "no libclang in the toolchain"))
    func fileWithErrorsIsNamed() throws {
        let project = try Project([
            "good.c": "int good(int x) { return -x; }\n",
            "broken.c": "int broken(int x) { int y = -x; return y + undeclared_thing; }\n",
        ])
        let outcome = CFamilySearch.run(pattern: "-$X", searchRoot: project.root.path,
                                        projectRoot: project.root.path, includeTests: false)
        #expect(Set(outcome.hits.map(\.file)) == ["good.c", "broken.c"])
        #expect(outcome.recovered.map(\.file) == ["broken.c"])
        #expect(outcome.recovered.first?.reason == CFamilySearch.compileErrorReason)
    }

    @Test("lint names headers, which it never reads, and files clang reported errors in",
          .enabled(if: hasClang, "no libclang in the toolchain"))
    func lintNamesHeadersAndErrors() throws {
        let project = try Project([
            "include/api.h": "static inline int negate(int x) { return -x; }\n",
            "main.c": "#include \"include/api.h\"\nint main(void) { return negate(1) + missing; }\n",
        ])
        let rules = [Rule(id: "neg", message: "m", patterns: ["-$X"])]
        let outcome = RuleEngine.run(rules: rules, projectRoot: project.root.path, lintRoot: project.root.path,
                                     includeTests: false)
        #expect(outcome.unscanned.contains { $0.file == "include/api.h" && $0.reason.contains("header") })
        #expect(outcome.recovered.map(\.file) == ["main.c"])
        // The header's `-x` is not reported: what a header holds is not matched.
        #expect(outcome.violations.isEmpty)
    }

    @Test("A C pattern that never compiled is reported broken with clang's reason; one that did is not",
          .enabled(if: hasClang, "no libclang in the toolchain"))
    func brokenCFamilyPatterns() throws {
        let project = try Project(["a.c": "int f(int x) { return -x; }\n"])
        let rules = [
            Rule(id: "valid-c", message: "m", patterns: ["-$X"]),
            Rule(id: "broken-c", message: "m", patterns: ["undeclared_fn($X"]),
        ]
        let outcome = RuleEngine.run(rules: rules, projectRoot: project.root.path, lintRoot: project.root.path,
                                     includeTests: false)
        #expect(outcome.broken.map(\.ruleID) == ["broken-c"])
        let reason = try #require(outcome.broken.first?.reason)
        #expect(reason.contains("Swift:") && reason.contains("Objective-C, C and C++: error:"), "\(reason)")
    }

    @Test("Several statements are refused by clang instead of matching the last one",
          .enabled(if: hasClang, "no libclang in the toolchain"))
    func severalStatementsAreRefused() throws {
        let project = try Project(["a.c": "void g(int x); void f(int x) { g(x); g(x + 1); }\n"])
        do {
            _ = try matches("g($X); g($Y);", in: project, file: "a.c")
            Issue.record("several statements were accepted")
        } catch ClangPatternSearch.Failure.patternNotCompiled(_, let diagnostics) {
            #expect(diagnostics.first?.contains("several statements") == true, "\(diagnostics)")
        }
    }

    @Test("A metavariable clang compiles into something other than a reference is refused",
          .enabled(if: fixtureReady, "the fixture is not built and indexed (`make fixture`), or there is no toolchain"))
    func unbindableMetavariableIsRefused() throws {
        let command = try #require(BuildProducts.compileCommands(under: Self.fixture)
            .first { $0.file.hasSuffix("ObjCFixture.m") })
        // `@selector($M)` compiles — the sentinel becomes a selector name, which the matcher
        // compares as text, so it used to match nothing and say "No matches."
        do {
            _ = try ClangPatternSearch(pattern: "@selector($M)").search(
                file: command.file, arguments: CompilationDatabase.parseArguments(of: command),
                library: try ClangLibrary.shared())
            Issue.record("@selector($M) was accepted")
        } catch ClangPatternSearch.Failure.patternNotCompiled(_, let diagnostics) {
            #expect(diagnostics.first?.contains("$M is not in an expression position") == true, "\(diagnostics)")
        }
    }
}
