import Foundation
import Testing
@testable import SextantCore

@Suite("Variadics and rules")
struct RuleEngineTests {
    @Test("$$$ absorbs any number of arguments")
    func variadicMatchesAnyArgs() throws {
        let search = try PatternSearch(pattern: "print($$$)")
        let source = """
        func a() { print("x") }
        func b() { print(1, 2, 3) }
        func c() { print() }
        func d() { log("x") }
        """
        let matches = search.search(source: source, fileName: "X.swift")
        #expect(matches.count == 3)
    }

    @Test("Variadic with a prefix: foo(a, $$$) also absorbs zero elements")
    func variadicWithPrefix() throws {
        let search = try PatternSearch(pattern: "foo(a, $$$)")
        let source = """
        let p = foo(a, b, c)
        let q = foo(a)
        let r = foo(b, c)
        """
        let matches = search.search(source: source, fileName: "X.swift")
        // foo(a, b, c) and foo(a) (variadic absorbs zero); foo(b, c) is excluded (first ≠ a).
        #expect(matches.count == 2)
    }

    @Test("The built-in rules compile")
    func builtinRulesCompile() {
        for rule in RuleEngine.builtinRules {
            for pattern in rule.patterns {
                #expect(throws: Never.self) { _ = try PatternSearch(pattern: pattern) }
            }
        }
    }

    @Test("The rule engine finds system-state on disk")
    func ruleEngineFindsViolation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("A.swift")
        try "let now = Calendar.current\nlet ok = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let violations = RuleEngine.run(rules: RuleEngine.builtinRules, projectRoot: directory.path, includeTests: false)
        #expect(violations.contains { $0.ruleID == "system-state" })
    }

    // MARK: - The C family

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

    @Test("An Objective-C rule is checked, and files no rule could cover are named",
          .enabled(if: isReady, "the fixture has not been built, or there is no toolchain"))
    func lintsObjectiveC() throws {
        let rules = [
            Rule(id: "objc-feed", message: "Direct ocFeed call", patterns: ["[$X ocFeed]"]),
            Rule(id: "force-try", message: "Forced try!", patterns: ["try! $X"])
        ]
        let outcome = RuleEngine.run(rules: rules, projectRoot: Self.fixture.path,
                                     lintRoot: Self.fixture.path, includeTests: false)

        let feed = outcome.violations.filter { $0.ruleID == "objc-feed" }
        #expect(feed.count == 2)
        #expect(feed.allSatisfy { $0.file == "Sources/ObjCFixture/ObjCFixture.m" })
        #expect(feed.allSatisfy { $0.text == "[self ocFeed]" })

        // Neither rule is valid C or C++, so those files were not checked at all — and a lint
        // report that stayed silent about them would be a clean bill of health for unread code.
        let unscanned = Set(outcome.unscanned.map { $0.file })
        #expect(unscanned.contains("Sources/CFixture/CFixture.c"))
        #expect(unscanned.contains("Sources/CxxFixture/CxxFixture.cpp"))
        #expect(!unscanned.contains("Sources/ObjCFixture/ObjCFixture.m"))
    }

    @Test("A rule violation in an #if branch the build lacks is reported, textually",
          .enabled(if: isReady, "the fixture has not been built, or there is no toolchain"))
    func namesViolationsInInactiveBranches() throws {
        let rules = [Rule(id: "objc-feed", message: "Direct ocFeed call", patterns: ["[$X ocFeed]"])]
        let outcome = RuleEngine.run(rules: rules, projectRoot: Self.fixture.path,
                                     lintRoot: Self.fixture.path, includeTests: false)

        #expect(outcome.violations.filter { $0.ruleID == "objc-feed" }.count == 2)
        // The third call sits under `#if TARGET_OS_IPHONE`. A rule report that stayed silent
        // about it would be clean about code it never checked — the same gap `search` closes.
        #expect(outcome.inactive.count == 1)
        #expect(outcome.inactive.first?.text.contains("objc-feed") == true)
    }

    @Test("A rule that does compile keeps its file scanned, whatever the other rules do",
          .enabled(if: isReady, "the fixture has not been built, or there is no toolchain"))
    func oneCompilableRuleIsEnough() throws {
        let rules = [
            Rule(id: "swift-only", message: "Forced try!", patterns: ["try! $X"]),
            Rule(id: "c-double", message: "Doubling by hand", patterns: ["$X * 2"])
        ]
        let outcome = RuleEngine.run(rules: rules, projectRoot: Self.fixture.path,
                                     lintRoot: Self.fixture.path, includeTests: false)

        #expect(outcome.violations.contains { $0.ruleID == "c-double" && $0.file.hasSuffix("CFixture.c") })
        #expect(!outcome.unscanned.contains { $0.file.hasSuffix("CFixture.c") })
    }
}
