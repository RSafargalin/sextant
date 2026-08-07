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

/// The public surface of a non-Swift target is what its public headers declare. These cover the
/// rule itself and the case it deliberately refuses to answer.
@Suite("Public surface from headers")
struct PublicHeaderTests {
    /// An index that answers from a table instead of a compiler, so the rule can be tested
    /// without building anything.
    private struct StubIndex: FileSymbolIndex {
        var byPath: [String: [SourceLanguage: [String]]] = [:]

        func declarations(inFile path: String, languages: Set<SourceLanguage>?) -> [Declaration] {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let perLanguage = byPath[name] ?? [:]
            return perLanguage
                .filter { languages?.contains($0.key) ?? true }
                .flatMap { $0.value }
                .sorted()
                .map { Declaration(kind: .function, header: $0, access: .internal) }
        }
    }

    private func makeTree(_ files: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sextant-headers-\(UUID().uuidString)")
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "// header\n".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("Headers under include/ are the public surface; other headers are not")
    func onlyPublicHeaders() throws {
        let root = try makeTree(["Sources/Core/include/Core.h", "Sources/Core/Private.h"])
        defer { try? FileManager.default.removeItem(at: root) }
        let index = StubIndex(byPath: [
            "Core.h": [.objc: ["func publicThing"]],
            "Private.h": [.objc: ["func privateThing"]],
        ])

        let result = IndexDeclarations.publicHeaderSummaries(root: root, index: index, package: nil)
        #expect(result.summaries.count == 1)
        #expect(result.summaries.first?.relativePath.hasSuffix("include/Core.h") == true)
        // Marked public: this is what `api` promises, and the layout is the one making the promise.
        #expect(result.summaries.first?.declarations.allSatisfy { $0.access == .public } == true)
    }

    @Test("A C++ header is handed to clang, never half-reported from the index")
    func cxxHeaderGoesToClang() throws {
        let root = try makeTree(["Sources/Cxx/include/Cxx.hpp"])
        defer { try? FileManager.default.removeItem(at: root) }
        let index = StubIndex(byPath: ["Cxx.hpp": [.cxx: ["func maybePrivate"]]])

        let result = IndexDeclarations.publicHeaderSummaries(root: root, index: index, package: nil)
        // The index has no access level, so public and private members are indistinguishable.
        #expect(result.summaries.isEmpty)
        #expect(result.cxxHeaders.count == 1)
    }

    @Test("A header mixing C and C++ goes to clang whole, not split between two sources")
    func mixedHeaderGoesToClang() throws {
        let root = try makeTree(["Sources/Mixed/include/Mixed.h"])
        defer { try? FileManager.default.removeItem(at: root) }
        let index = StubIndex(byPath: ["Mixed.h": [.c: ["func cThing"], .cxx: ["func cxxThing"]]])

        let result = IndexDeclarations.publicHeaderSummaries(root: root, index: index, package: nil)
        // Reporting the C half from the index would show the free functions and drop every class,
        // which reads as a complete surface. Either clang answers for the header, or it is named.
        #expect(result.summaries.isEmpty)
        #expect(result.cxxHeaders.count == 1)
    }

    @Test("Without an index there is no surface to add")
    func noIndex() throws {
        let root = try makeTree(["Sources/Core/include/Core.h"])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = IndexDeclarations.publicHeaderSummaries(root: root, index: nil, package: nil)
        #expect(result.summaries.isEmpty && result.cxxHeaders.isEmpty)
    }
}
