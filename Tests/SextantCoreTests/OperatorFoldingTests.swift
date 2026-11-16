import Foundation
import SwiftParser
import Testing
@testable import SextantCore

/// Operator expressions are matched with the structure the compiler gives them. SwiftParser leaves
/// `y = value as! Int` as one flat sequence, and a pattern that is part of a larger expression
/// used to match nothing there — with exit 0.
@Suite("Operator folding")
struct OperatorFoldingTests {
    struct Case: CustomStringConvertible, Sendable {
        let pattern: String
        let source: String
        /// The matched texts, in source order; empty for a near miss.
        let matched: [String]
        var description: String { "\(pattern) in \(source)" }
    }

    static let cases: [Case] = [
        // A cast inside an assignment, a discard, larger arithmetic, an argument and a return.
        Case(pattern: "$X as! $T", source: """
        let x = value as! Int
        y = value as! Int
        _ = value as! String
        let z = b + (value as! Int)
        use(value as! Int, 2)
        func f() -> Int { return value as! Int + 1 }
        """, matched: ["value as! Int", "value as! Int", "value as! String", "value as! Int", "value as! Int", "value as! Int"]),
        Case(pattern: "$X + 1", source: "y = b + 1", matched: ["b + 1"]),
        Case(pattern: "$X + 1", source: "use(a * 2 + 1)", matched: ["a * 2 + 1"]),
        Case(pattern: "$X + 1", source: "y = a + 1 * 2", matched: []),
        Case(pattern: "$X ?? $Y", source: "let a = b ?? c ?? d", matched: ["b ?? c ?? d", "c ?? d"]),
        Case(pattern: "$X ?? $Y", source: "total = cached ?? 0", matched: ["cached ?? 0"]),
        Case(pattern: "$X == nil", source: "flag = value == nil", matched: ["value == nil"]),
        Case(pattern: "$X == nil", source: "func f() -> Bool { return a == nil && b }", matched: ["a == nil"]),
        Case(pattern: "$X == nil", source: "flag = value != nil", matched: []),
        Case(pattern: "$A = $B", source: "x = y + 1", matched: ["x = y + 1"]),
        Case(pattern: "$A = $B", source: "let x = y + 1", matched: []),
        Case(pattern: "try? $X", source: "result = try? load()", matched: ["try? load()"]),
        Case(pattern: "try? $X", source: "func f() -> Int? { return try? load() }", matched: ["try? load()"]),
        Case(pattern: "$C ? $A : $B", source: "let v = flag ? 1 : 2", matched: ["flag ? 1 : 2"]),
        Case(pattern: "$C ? $A : $B", source: "x = a ? b : c + 1", matched: ["a ? b : c + 1"]),
        Case(pattern: "$C ? $A : 2", source: "x = a ? b : 2 + 1", matched: []),
        // Precedence: `a + b * c` is `a + (b * c)`.
        Case(pattern: "$X * $Y", source: "let r = a + b * c", matched: ["b * c"]),
        Case(pattern: "$X + $Y", source: "let r = a + b * c", matched: ["a + b * c"]),
        Case(pattern: "$X + $Y * $Z", source: "let r = a + b * c", matched: ["a + b * c"]),
        Case(pattern: "($X + $Y) * $Z", source: "let r = a + b * c", matched: []),
        Case(pattern: "$X * $Y", source: "let r = (a + b) * c", matched: ["(a + b) * c"]),
        Case(pattern: "$X + $Y", source: "let r = a + b + c", matched: ["a + b + c", "a + b"]),
        Case(pattern: "$X && $Y || $Z", source: "if a && b || c {}", matched: ["a && b || c"]),
        Case(pattern: "$X && $Y", source: "if a || b && c {}", matched: ["b && c"]),
    ]

    @Test("Operator patterns match with the compiler's grouping, and not with any other", arguments: cases)
    func folded(_ testCase: Case) throws {
        let matches = try PatternSearch(pattern: testCase.pattern).search(source: testCase.source, fileName: "A.swift")
        #expect(matches.map(\.text) == testCase.matched)
    }

    @Test("A pattern with an operator of unknown precedence is refused, naming the operator")
    func unknownOperatorInPattern() {
        do {
            _ = try PatternSearch(pattern: "$X |> $Y")
            Issue.record("accepted")
        } catch let failure as PatternSearch.Failure {
            #expect(failure.description.contains("|>"), "\(failure)")
        } catch {
            Issue.record("\(error)")
        }
    }

    private func project(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-folding-\(UUID().uuidString.prefix(8))", isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func scan(_ pattern: String, _ root: URL) throws -> SwiftPatternScan.Outcome {
        SwiftPatternScan.run(try PatternSearch(pattern: pattern), pattern: pattern,
                             files: SwiftSources.files(under: root, includeTests: false), root: root,
                             cache: SourceParseCache())
    }

    @Test("An operator of unknown precedence is not guessed: its expression stays as written, the rest matches, and the file is named")
    func unknownOperatorInSource() throws {
        let root = try project(["Use.swift": "let r = a |> b + c\nlet s = d + 1\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = try scan("$X + $Y", root)
        #expect(outcome.hits.map(\.text) == ["d + 1"])
        #expect(outcome.recovered.map(\.file) == ["Use.swift"])
        #expect(outcome.recovered.first?.reason.contains("|>") == true)
        #expect(StructuralCoverage.recoveredReport(outcome.recovered).first?.contains("read with reservations") == true)
    }

    @Test("An operator declared in the searched files is folded with its declared precedence")
    func declaredOperatorIsFolded() throws {
        let root = try project([
            "Operators.swift": "infix operator |>: AdditionPrecedence\n",
            "Use.swift": "let r = a |> b + c\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = try scan("$X + $Y", root)
        // Left-associative at addition precedence: `(a |> b) + c`.
        #expect(outcome.hits.map(\.text) == ["a |> b + c"])
        #expect(outcome.recovered.isEmpty)
    }

    @Test("A pattern using an operator the searched files declare is folded by that declaration, not refused")
    func patternWithDeclaredOperator() throws {
        let declaring = "infix operator <+> : AdditionPrecedence\nfunc <+> (a: Int, b: Int) -> Int { a + b }\n"
        let source = "let v = 1 <+> 2 * 3\n"
        // Without the files' declarations the pattern cannot be grouped, and is refused.
        #expect(throws: PatternSearch.Failure.self) { _ = try PatternSearch(pattern: "$X <+> $Y") }
        let table = OperatorFolding.table(declaredIn: [Parser.parse(source: declaring)])
        let search = try PatternSearch(pattern: "$X <+> $Y", operators: { table })
        let folded = OperatorFolding.fold(Parser.parse(source: source), operators: table).tree
        // At addition precedence, `*` binds tighter: the whole `1 <+> 2 * 3` is the match.
        #expect(search.search(inFolded: folded, fileName: "S.swift").map(\.text) == ["1 <+> 2 * 3"])
        // An operator declared nowhere is still refused, naming where it was looked for.
        #expect(throws: PatternSearch.Failure.self) { _ = try PatternSearch(pattern: "$X <*> $Y", operators: { table }) }
    }
}
