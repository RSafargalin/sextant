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
}
