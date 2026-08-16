import Foundation
import Testing
@testable import SextantCore

/// Reference positions the source does not carry. A macro records the same reference twice — at
/// the column where it is written and at the macro call it was expanded from — so a count over
/// macro-wrapped code comes out high with nothing in the text to account for it. Measured on this
/// repository, where swift-testing's `#require` wraps most references in the tests: `refs
/// SwiftSources` said 81 against 74 occurrences of the name.
@Suite("Reference positions")
struct ReferencePositionTests {

    private func write(_ contents: String) throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-pos-\(UUID().uuidString).swift")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func location(_ path: String, _ line: Int, _ column: Int) -> SextantCore.SourceLocation {
        SextantCore.SourceLocation(path: path, line: line, column: column, isDefinition: false)
    }

    @Test("a position whose column does not hold the name loses to one that does")
    func macroDuplicateIsDropped() throws {
        //            1234567890123456789012345
        let source = "let x = try #require(Widget.make())\n"
        let path = try write(source)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let realColumn = (source.range(of: "Widget").map { source.distance(from: source.startIndex, to: $0.lowerBound) } ?? 0) + 1

        let kept = ReferencePositions.verified(
            [location(path, 1, 13), location(path, 1, realColumn)], name: "Widget")
        #expect(kept.count == 1)
        #expect(kept.first?.column == realColumn)
    }

    /// The narrow half of the rule: a position with no verified sibling stays, because the name
    /// may be written in a form this check cannot see, and losing a real location is worse than
    /// counting one twice.
    @Test("a lone position is kept even when its column does not hold the name")
    func loneUnverifiedPositionIsKept() throws {
        let path = try write("let x = Self.make()\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let kept = ReferencePositions.verified(
            [location(path, 1, 9), location(path, 1, 1)], name: "Widget")
        // Neither column holds "Widget", so neither is preferred and both survive.
        #expect(kept.count == 2)
    }

    @Test("positions on different lines are never weighed against each other")
    func separateLinesAreUntouched() throws {
        let path = try write("Widget.a()\nsomethingElse()\nWidget.b()\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let kept = ReferencePositions.verified(
            [location(path, 1, 1), location(path, 3, 1), location(path, 2, 5)], name: "Widget")
        #expect(kept.count == 3, "one position per line: there is nothing to prefer")
    }

    @Test("an unreadable file drops nothing")
    func unreadableFileIsNotEvidence() {
        let missing = "/no/such/file.swift"
        let kept = ReferencePositions.verified(
            [location(missing, 1, 1), location(missing, 1, 40)], name: "Widget")
        #expect(kept.count == 2)
    }

    /// Two real references on one line — `make(a: Widget(), b: Widget())` — are two places, and
    /// both hold the name, so both are kept.
    @Test("two genuine references on one line both survive")
    func twoRealReferencesOnOneLine() throws {
        let source = "make(a: Widget(), b: Widget())\n"
        let path = try write(source)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let columns = source.ranges(of: "Widget").map { source.distance(from: source.startIndex, to: $0.lowerBound) + 1 }
        #expect(columns.count == 2)

        let kept = ReferencePositions.verified(columns.map { location(path, 1, $0) }, name: "Widget")
        #expect(kept.count == 2)
    }
}
