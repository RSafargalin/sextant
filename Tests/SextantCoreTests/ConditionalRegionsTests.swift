import Foundation
import Testing
@testable import SextantCore

/// An index holds one configuration of a project, so code under `#if` may be missing from every
/// semantic answer. These cover the detector that lets the tool say so instead of answering
/// "not found".
@Suite("Conditional regions")
struct ConditionalRegionsTests {
    private let source = """
    let always = 1
    #if os(iOS)
    let onPhone = 2
    #else
    let elsewhere = 3
    #endif
    let after = 4
    """

    @Test("Lines inside a conditional block are found, directives and plain code are not")
    func findsConditionalLines() {
        let lines = ConditionalRegions.lines(inSource: source)
        #expect(lines == [3, 5])            // the two branch bodies
        #expect(!lines.contains(1) && !lines.contains(7))
    }

    @Test("Nesting is counted, not just matched")
    func handlesNesting() {
        let nested = """
        #if A
        let outer = 1
        #if B
        let inner = 2
        #endif
        let stillOuter = 3
        #endif
        let free = 4
        """
        #expect(ConditionalRegions.lines(inSource: nested) == [2, 4, 6])
    }

    @Test("A source without conditionals reports none")
    func plainSource() {
        #expect(ConditionalRegions.lines(inSource: "let a = 1\nlet b = 2").isEmpty)
        #expect(!ConditionalRegions.areUsed(inSource: "let a = 1"))
        #expect(ConditionalRegions.areUsed(inSource: source))
    }
}

@Suite("Declarations under conditional compilation")
struct ConditionalDeclarationTests {
    private let source = """
    public struct Probe {
        public func always() {}
    #if os(iOS)
        public func onPhone() {}
    #else
        public func elsewhere() {}
    #endif
    }

    #if DEBUG
    public struct DebugOnly {}
    #endif
    """

    @Test("A declaration inside #if is kept, and carries the condition")
    func keepsConditionalDeclarations() throws {
        let declarations = SwiftDeclarationExtractor.declarations(source: source)
        // Two top-level types: one plain, one under `#if DEBUG`. Dropping the second — which is
        // what a walk that only looks for declarations does — hides a public type entirely.
        #expect(declarations.count == 2)
        let debugOnly = try #require(declarations.first { $0.name == "DebugOnly" })
        #expect(debugOnly.condition == "#if DEBUG")
        #expect(debugOnly.decoratedHeader.contains("[#if DEBUG]"))

        let probe = try #require(declarations.first { $0.name == "Probe" })
        #expect(probe.members.count == 3)
        #expect(probe.members.first { $0.name == "always" }?.condition == nil)
        #expect(probe.members.first { $0.name == "onPhone" }?.condition == "#if os(iOS)")
        #expect(probe.members.first { $0.name == "elsewhere" }?.condition == "#else")
    }

    @Test("Moving a declaration under a condition is a change, not silence")
    func conditionChangeIsADiff() {
        let before = SwiftDeclarationExtractor.declarations(source: "public struct A { public func f() {} }")
        let after = SwiftDeclarationExtractor.declarations(source: """
        public struct A {
        #if os(iOS)
            public func f() {}
        #endif
        }
        """)
        let result = DeclarationDiff.compare(old: before, new: after)
        // The signature is untouched, but the method is gone from every other platform.
        #expect(result.changed.count == 1)
        #expect(result.changed.first?.new.condition == "#if os(iOS)")
    }
}
