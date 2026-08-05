import Foundation
import Testing
@testable import SextantCore

/// The repository map reads non-Swift files from the compiler index instead of a second parser.
/// These cover the two decisions that are not obvious from the code: which index kinds become
/// declarations, and what happens when a header and its implementation say the same thing.
@Suite("Declarations from the index")
struct IndexDeclarationsTests {
    private func summary(_ path: String, _ declarations: [(DeclarationKind, String)]) -> FileSummary {
        FileSummary(
            relativePath: path,
            package: "Pkg",
            declarations: declarations.map { Declaration(kind: $0.0, header: $0.1, access: .internal) }
        )
    }

    @Test("A header loses what its implementation already shows")
    func headerDuplicatesDropped() {
        let result = IndexDeclarations.withoutHeaderDuplicates([
            summary("Sources/Core/include/Core.h", [(.classKind, "class Greeter"), (.function, "func greet")]),
            summary("Sources/Core/Core.m", [(.classKind, "class Greeter"), (.function, "func greet")]),
        ])
        // The header contributed nothing new, so it drops out of the map entirely.
        #expect(result.map { $0.relativePath } == ["Sources/Core/Core.m"])
    }

    @Test("A declaration that exists only in a header is kept")
    func headerOnlyDeclarationSurvives() {
        let result = IndexDeclarations.withoutHeaderDuplicates([
            summary("Sources/Core/include/Core.h", [(.structKind, "struct Counter"), (.function, "func bump")]),
            summary("Sources/Core/Core.cpp", [(.function, "func bump")]),
        ])
        let header = try? #require(result.first { $0.relativePath.hasSuffix(".h") })
        // `bump` is implemented, `Counter` is not — dropping it would hide it from the map, which
        // is the only place a reader would learn it exists.
        #expect(header?.declarations.map { $0.header } == ["struct Counter"])
    }

    @Test("Swift files are untouched by header deduplication")
    func swiftUnaffected() {
        let swift = summary("Sources/A/A.swift", [(.structKind, "struct A")])
        #expect(IndexDeclarations.withoutHeaderDuplicates([swift]).count == 1)
    }

    @Test("Index kinds map onto the declaration model, and unmappable ones are dropped")
    func kindMapping() {
        #expect(IndexDeclarations.declarationKind(for: "class") == .classKind)
        #expect(IndexDeclarations.declarationKind(for: "instanceMethod") == .function)
        #expect(IndexDeclarations.declarationKind(for: "classMethod") == .function)
        #expect(IndexDeclarations.declarationKind(for: "instanceProperty") == .property)
        #expect(IndexDeclarations.declarationKind(for: "enumConstant") == .caseKind)
        // Forcing these into some declaration kind would put noise on the map.
        #expect(IndexDeclarations.declarationKind(for: "module") == nil)
        #expect(IndexDeclarations.declarationKind(for: "parameter") == nil)
        #expect(IndexDeclarations.declarationKind(for: "namespace") == nil)
    }

    @Test("Without an index there is nothing to add, and the Swift path is unchanged")
    func noIndexMeansNoExtraFiles() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        #expect(IndexDeclarations.summaries(root: root, index: nil, includeTests: false).isEmpty)
    }
}
