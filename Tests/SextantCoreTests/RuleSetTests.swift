import Foundation
import Testing
@testable import SextantCore

/// Two rule sets used to exist and drift apart: the built-in one had three rules, the shipped
/// example two, and `--rules` replaced rather than extended — so the project`s own CI never
/// applied a rule it shipped, and a user starting from the example lost one silently.
@Suite("Rule sets")
struct RuleSetTests {
    private func write(_ json: String) throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-rules-\(UUID().uuidString).json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    @Test("A bare array replaces the built-in set, and says so")
    func arrayReplaces() throws {
        let path = try write("""
        [{ "id": "mine", "message": "m", "patterns": ["print($$$)"] }]
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let set = try RuleEngine.loadRules(fromJSONAt: path)
        #expect(set.rules.map(\.id) == ["mine"])
        // The origin is part of the answer: "no violations" from one rule is not the same claim
        // as "no violations" from five.
        #expect(set.origin.contains("replaced"))
    }

    @Test("`extends: builtin` adds to them instead of copying them by hand")
    func objectExtends() throws {
        let path = try write("""
        { "extends": "builtin", "rules": [{ "id": "mine", "message": "m", "patterns": ["print($$$)"] }] }
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let set = try RuleEngine.loadRules(fromJSONAt: path)
        #expect(set.rules.count == RuleEngine.builtinRules.count + 1)
        #expect(set.rules.map(\.id).contains("force-unwrap"))
        #expect(set.origin.contains("extended"))
    }

    @Test("An object without `extends` still replaces — nothing is inherited by accident")
    func objectWithoutExtends() throws {
        let path = try write("""
        { "rules": [{ "id": "mine", "message": "m", "patterns": ["print($$$)"] }] }
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try RuleEngine.loadRules(fromJSONAt: path).rules.map(\.id) == ["mine"])
    }

    @Test("The built-in set names itself a starting point, not a verdict")
    func builtinSaysWhatItIs() {
        // There is no universal default: `print-call` is wrong for a CLI, `force-unwrap` is noise
        // in interop code. Saying so in the output is the difference between a default and a claim.
        #expect(RuleEngine.builtinSet.origin.contains("starting point"))
        #expect(RuleEngine.builtinSet.rules.count == RuleEngine.builtinRules.count)
    }

    @Test("force-unwrap catches the mistake and not what merely looks like it")
    func forceUnwrapIsPrecise() throws {
        let rule = try #require(RuleEngine.builtinRules.first { $0.id == "force-unwrap" })
        let search = try PatternSearch(pattern: rule.patterns[0])
        let source = """
        func f(_ d: [String: Int], _ o: String?) {
            let a = d["k"]!
            let b = o?.count
            let c = a != 3
            let e: Int! = nil
            try! g()
        }
        """
        let matches = search.search(source: source, fileName: "A.swift")
        // Optional chaining, `!=`, an implicitly unwrapped type and `try!` are not force unwraps,
        // and a rule that flagged them would cost more than it catches.
        #expect(matches.count == 1)
        #expect(matches.first?.text.contains("d[\"k\"]!") == true)
    }
}
