import Testing
@testable import SextantCore

/// Metavariables beyond expression position: types, binding names, catch clauses, declaration
/// names and parameters. Every position has a source it must match and a near miss it must not —
/// a hole that silently matched nothing would pass a test that only checks the positive case.
@Suite("Metavariable positions")
struct MetavariablePositionTests {
    struct Position: CustomStringConvertible, Sendable {
        let pattern: String
        let match: String
        /// The text of the match, as reported.
        let matched: String
        let nearMiss: String
        var description: String { pattern }
    }

    static let positions: [Position] = [
        // Type position.
        Position(pattern: "$X as! $T", match: "let n = value as! [Int]", matched: "value as! [Int]",
                 nearMiss: "let n = value as? [Int]"),
        Position(pattern: "$X as? $T", match: "let n = value as? Int", matched: "value as? Int",
                 nearMiss: "let n = value as! Int"),
        Position(pattern: "$X is $T", match: "let b = value is Int", matched: "value is Int",
                 nearMiss: "let b = value == Int"),
        Position(pattern: "let $N: $T = $V", match: "let s: String = name", matched: "let s: String = name",
                 nearMiss: "let s = name"),
        Position(pattern: "let $N: Array<$T> = $V", match: "let xs: Array<[Int]> = []", matched: "let xs: Array<[Int]> = []",
                 nearMiss: "let xs: Set<Int> = []"),
        Position(pattern: "func $F(a: $T) -> $R { $$$ }", match: "func f(a: Int) -> String { \"\" }",
                 matched: "func f(a: Int) -> String { \"\" }", nearMiss: "func f(b: Int) -> String { \"\" }"),
        // Binding names.
        Position(pattern: "let $X = $Y", match: "let n = compute()", matched: "let n = compute()",
                 nearMiss: "var n = compute()"),
        Position(pattern: "var $X = $Y", match: "var n = compute()", matched: "var n = compute()",
                 nearMiss: "let n = compute()"),
        Position(pattern: "if let $X = $Y { $$$ }", match: "if let v = lookup() { use(v) }",
                 matched: "if let v = lookup() { use(v) }", nearMiss: "if var v = lookup() { use(v) }"),
        Position(pattern: "guard let $X = $Y else { $$$ }", match: "guard let v = lookup() else { return }",
                 matched: "guard let v = lookup() else { return }", nearMiss: "guard ok else { return }"),
        Position(pattern: "for $X in $Y { $$$ }", match: "for item in items { use(item) }",
                 matched: "for item in items { use(item) }", nearMiss: "for case let item? in items { use(item) }"),
        Position(pattern: "{ $X in $$$ }", match: "items.map { item in item + 1 }", matched: "{ item in item + 1 }",
                 nearMiss: "items.map { $0 + 1 }"),
        Position(pattern: "{ ($X: $T) in $$$ }", match: "items.map { (item: Int) in item }",
                 matched: "{ (item: Int) in item }", nearMiss: "items.map { (item) in item }"),
        // Catch clauses.
        Position(pattern: "catch let $E", match: "do { try go() } catch let error { log(error) }",
                 matched: "catch let error { log(error) }", nearMiss: "do { try go() } catch { log(error) }"),
        Position(pattern: "catch $P { $$$ }", match: "do { try go() } catch Failure.bad { log(1) }",
                 matched: "catch Failure.bad { log(1) }", nearMiss: "do { try go() } catch { log(1) }"),
        // Declaration names and parameters.
        Position(pattern: "func $F() { $$$ }", match: "func reset() { count = 0 }", matched: "func reset() { count = 0 }",
                 nearMiss: "func reset(to value: Int) { count = value }"),
        Position(pattern: "func $F($ARGS) { $$$ }", match: "func set(value: Int) { count = value }",
                 matched: "func set(value: Int) { count = value }", nearMiss: "func set(a: Int, b: Int) { count = a }"),
        Position(pattern: "func $F($$$) { $$$ }", match: "func set(a: Int, b: Int) { count = a }",
                 matched: "func set(a: Int, b: Int) { count = a }", nearMiss: "var set: Int { 0 }"),
        Position(pattern: "class $C { $$$ }", match: "class Box { var x = 1 }", matched: "class Box { var x = 1 }",
                 nearMiss: "struct Box { var x = 1 }"),
        Position(pattern: "struct $S: $P { $$$ }", match: "struct Point: Equatable { var x: Int }",
                 matched: "struct Point: Equatable { var x: Int }", nearMiss: "struct Point { var x: Int }"),
        Position(pattern: "enum $E { $$$ }", match: "enum Mode { case a }", matched: "enum Mode { case a }",
                 nearMiss: "struct Mode { }"),
        Position(pattern: "var $N: $T", match: "var counter: Int", matched: "var counter: Int",
                 nearMiss: "var counter = 0"),
        // An interpolation is an expression position inside a string, and is supported.
        Position(pattern: "print(\"\\($X)\")", match: "print(\"\\(value)\")", matched: "print(\"\\(value)\")",
                 nearMiss: "print(\"total: \\(value)\")"),
    ]

    @Test("Every position matches its source and not its near miss", arguments: positions)
    func position(_ position: Position) throws {
        let search = try PatternSearch(pattern: position.pattern)
        let matches = search.search(source: position.match, fileName: "A.swift")
        #expect(matches.map(\.text) == [position.matched], "\(position.pattern) on \(position.match)")
        #expect(search.search(source: position.nearMiss, fileName: "A.swift").isEmpty,
                "\(position.pattern) must not match \(position.nearMiss)")
    }

    @Test("A repeated metavariable binds the same text in a type and in an expression position")
    func bindsAcrossPositionKinds() throws {
        let search = try PatternSearch(pattern: "register($T.self, $X as! $T)")
        let source = """
        register(Int.self, value as! Int)
        register(Int.self, value as! String)
        """
        #expect(search.search(source: source, fileName: "A.swift").map(\.line) == [1])

        // A name and a reference: the function returns its own parameter.
        let identity = try PatternSearch(pattern: "func $F($P: $T) -> $T { $P }")
        #expect(identity.search(source: "func id(x: Int) -> Int { x }", fileName: "A.swift").count == 1)
        #expect(identity.search(source: "func id(x: Int) -> Int { y }", fileName: "A.swift").isEmpty)
        #expect(identity.search(source: "func id(x: Int) -> String { x }", fileName: "A.swift").isEmpty)
    }

    @Test("A name in the user's code that equals the substituted placeholder is not a hole")
    func placeholderCannotCollide() throws {
        // Written literally, without `$`, the placeholder's spelling is an ordinary name.
        let literal = try PatternSearch(pattern: "SEXTANTMETA_X as! Int")
        #expect(literal.search(source: "let a = value as! Int", fileName: "A.swift").isEmpty)
        #expect(literal.search(source: "let a = SEXTANTMETA_X as! Int", fileName: "A.swift").count == 1)
        // And next to a real metavariable it stays literal too.
        let mixed = try PatternSearch(pattern: "$Y + SEXTANTMETA_Y")
        #expect(mixed.search(source: "let a = b + c", fileName: "A.swift").isEmpty)
        #expect(mixed.search(source: "let a = b + SEXTANTMETA_Y", fileName: "A.swift").count == 1)
    }

    struct Rejection: CustomStringConvertible, Sendable {
        let pattern: String
        let mentions: String
        var description: String { pattern }
    }

    static let rejections: [Rejection] = [
        Rejection(pattern: "print(\"$X\")", mentions: "inside a string literal"),
        Rejection(pattern: "log(\"$$$\")", mentions: "inside a string literal"),
        Rejection(pattern: "foo(); bar()", mentions: "several statements"),
        Rejection(pattern: "foo($X) // $Y", mentions: "inside a comment"),
        Rejection(pattern: "foo($$$, $$$)", mentions: "only one variadic"),
    ]

    @Test("A metavariable that could not be bound is refused, never left to match nothing", arguments: rejections)
    func refusesUnbindable(_ rejection: Rejection) {
        do {
            _ = try PatternSearch(pattern: rejection.pattern)
            Issue.record("\(rejection.pattern) was accepted")
        } catch let failure as PatternSearch.Failure {
            #expect(failure.description.contains(rejection.mentions), "\(failure)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("What every existing pattern shape does is unchanged")
    func existingShapesStillMatch() throws {
        let source = """
        func f() {
            try? context.save()
            print(a, b)
            let x = y!
            guard ok else { return }
        }
        """
        for (pattern, expected) in [("try? $X.save()", 1), ("print($$$)", 1), ("$X!", 1), ("guard $X else { return }", 1),
                                    ("$X.current", 0)] {
            #expect(try PatternSearch(pattern: pattern).search(source: source, fileName: "A.swift").count == expected,
                    "\(pattern)")
        }
    }
}
