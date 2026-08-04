import Foundation
import Testing
@testable import SextantCore

@Suite("Store union")
struct IndexStoreSetMergeTests {
    @Test("Definitions deduplicated by USR, occurrences by position")
    func dedupsByUSRAndLocation() {
        let locA = SourceLocation(path: "A.swift", line: 1, column: 1, isDefinition: false)
        let locB = SourceLocation(path: "B.swift", line: 2, column: 1, isDefinition: false)
        let definition = SourceLocation(path: "Def.swift", line: 5, column: 1, isDefinition: true)
        let store1 = [SymbolHit(name: "X", usr: "u1", kind: "struct", definition: definition, references: [locA, locB])]
        let store2 = [SymbolHit(name: "X", usr: "u1", kind: "struct", definition: definition, references: [locB])]

        let merged = IndexStoreSet.merge([store1, store2], limit: 100)
        #expect(merged.count == 1)
        #expect(merged.first?.references.count == 2)
    }

    @Test("Different USRs are not collapsed")
    func keepsDistinctUSRs() {
        let location = SourceLocation(path: "A.swift", line: 1, column: 1, isDefinition: false)
        let hit1 = SymbolHit(name: "X", usr: "u1", kind: "struct", definition: nil, references: [location])
        let hit2 = SymbolHit(name: "X", usr: "u2", kind: "class", definition: nil, references: [location])

        let merged = IndexStoreSet.merge([[hit1], [hit2]], limit: 100)
        #expect(merged.count == 2)
    }
}

@Suite("Repository map and cache")
struct RepoMapTests {
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-map-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A", "B", "C", "D"] {
            try "public struct \(name) { public let value: Int }\n"
                .write(to: root.appendingPathComponent("\(name).swift"), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("Full mode shows the types")
    func fullModeListsTypes() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = RepoMap.generate(projectRoot: root.path, options: .init(tokenBudget: 100_000))
        #expect(output.contains("# Repository map"))
        #expect(output.contains("struct A"))
        #expect(output.contains("struct D"))
    }

    @Test("A small budget triggers degradation")
    func smallBudgetDegrades() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = RepoMap.generate(projectRoot: root.path, options: .init(tokenBudget: 1))
        #expect(output.contains("truncated") || output.contains("partial"))
    }

    @Test("The cache does not grow when the same file is read again")
    func cacheReusesByMtime() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SourceParseCache()
        let path = root.appendingPathComponent("A.swift").path
        _ = cache.tree(atPath: path)
        _ = cache.tree(atPath: path)
        #expect(cache.count == 1)
    }
}
