import SwiftParser
import Testing
@testable import SextantCore

/// A declaration pattern constrains what it states and nothing else: modifiers, attributes, a
/// generic clause, an inheritance clause and a `where` clause it leaves out may be on the
/// declaration or not; those it writes must be there. Counts are by hand over `source`.
@Suite("Declaration patterns")
struct DeclarationPatternTests {
    static let source = """
    protocol P {}
    protocol Q<Element>: P where Element: Equatable { associatedtype Element }
    struct A: P {}
    public struct B: P {}
    @frozen struct C: P {}
    struct G<T>: P where T: Equatable {}
    struct Plain {}
    final class D {}
    public final class E: NSObject {}
    @MainActor open class F {}
    class H {}
    public indirect enum Tree { case leaf }
    distributed actor Remote {}
    actor Counter {}
    public extension A {}
    extension B: Q where Element == Int {}
    func plain() -> Int { 1 }
    public func pub() -> Int { 1 }
    func gen<T>(_ t: T) -> Int { 1 }
    @discardableResult func attr() -> Int { 1 }
    nonisolated func detached() -> Int { 1 }
    func constrained<T>(_ t: T) -> Int where T: Equatable { 1 }
    struct Holder {
        init() {}
        public init(x: Int) {}
        @inlinable init<T>(t: T) {}
        static let shared = Holder()
        private var count = 0
        @Published var name = ""
        lazy var cache = 0
        public typealias ID = Int
        typealias Pair<T> = (T, T)
        subscript(i: Int) -> Int { i }
        public subscript<T>(t: T) -> Int { 0 }
    }
    """

    private func matches(_ pattern: String) throws -> [String] {
        try PatternSearch(pattern: pattern).search(source: Self.source, fileName: "S.swift").map(\.text)
    }

    @Test("A pattern without modifiers, attributes or clauses matches declarations that have them",
          arguments: [
              ("struct $S: $P { $$$ }", 4),       // A, B, C, G — not Plain or Holder, which inherit nothing
              ("struct $S { $$$ }", 6),           // A, B, C, G, Plain, Holder
              ("class $C { $$$ }", 4),            // D, E, F, H
              ("enum $E { $$$ }", 1),
              ("actor $A { $$$ }", 2),
              ("protocol $P { $$$ }", 2),
              ("extension $T { $$$ }", 2),
              ("func $F($$$) -> $R { $$$ }", 6),
              ("func $F($$$) -> Int", 6),
              ("init($$$) { $$$ }", 3),
              ("init($$$)", 3),
              ("let $X = $V", 1),
              ("var $X = $V", 3),
              ("typealias $T = $V", 2),
              ("subscript($$$) -> Int { $$$ }", 2),
          ])
    func unstatedPartsAreUnconstrained(pattern: String, expected: Int) throws {
        let found = try matches(pattern)
        #expect(found.count == expected, "\(pattern): \(found)")
    }

    @Test("What a pattern states must be there",
          arguments: [
              ("public struct $S: $P { $$$ }", ["public struct B: P {}"]),
              ("@frozen struct $S: $P { $$$ }", ["@frozen struct C: P {}"]),
              ("final class $C { $$$ }", ["final class D {}", "public final class E: NSObject {}"]),
              ("public final class $C { $$$ }", ["public final class E: NSObject {}"]),
              ("open class $C { $$$ }", ["@MainActor open class F {}"]),
              ("@MainActor class $C { $$$ }", ["@MainActor open class F {}"]),
              ("public func $F($$$) -> $R { $$$ }", ["public func pub() -> Int { 1 }"]),
              ("nonisolated func $F($$$) -> $R { $$$ }", ["nonisolated func detached() -> Int { 1 }"]),
              ("func $F<$T>($$$) -> $R { $$$ }", ["func gen<T>(_ t: T) -> Int { 1 }",
                                                 "func constrained<T>(_ t: T) -> Int where T: Equatable { 1 }"]),
              ("static let $X = $V", ["static let shared = Holder()"]),
              ("private var $X = $V", ["private var count = 0"]),
              ("public typealias $T = $V", ["public typealias ID = Int"]),
              ("public extension $T { $$$ }", ["public extension A {}"]),
              ("distributed actor $A { $$$ }", ["distributed actor Remote {}"]),
          ])
    func statedPartsMustMatch(pattern: String, expected: [String]) throws {
        #expect(try matches(pattern) == expected)
    }

    @Test("No new false positives: a different kind, keyword or signature still does not match")
    func noNewFalsePositives() throws {
        #expect(try matches("public struct $S { $$$ }") == ["public struct B: P {}"])
        #expect(try matches("class $C: NSObject { $$$ }") == ["public final class E: NSObject {}"])
        #expect(try matches("struct $S<$T> { $$$ }") == ["struct G<T>: P where T: Equatable {}"])
        #expect(try matches("static func $F() { $$$ }").isEmpty)
        #expect(try matches("let $X = Holder()") == ["static let shared = Holder()"])
        #expect(try matches("private struct $S { $$$ }").isEmpty)
        #expect(try matches("func $F() -> Int { $$$ }").count == 4)     // not gen or constrained, which take a parameter
    }

    @Test("Lint rules follow the same rule: one walk over several declaration patterns")
    func lintFollowsTheSameRule() throws {
        let searches = try ["class $C { $$$ }", "final class $C { $$$ }"].map { try PatternSearch(pattern: $0) }
        let found = PatternSearch.searchAll(searches, in: Parser.parse(source: Self.source), fileName: "S.swift")
        #expect(found.filter { $0.index == 0 }.count == 4)
        #expect(found.filter { $0.index == 1 }.count == 2)
    }
}
