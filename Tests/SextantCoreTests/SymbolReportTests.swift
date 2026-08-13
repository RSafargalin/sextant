import Foundation
import Testing
@testable import SextantCore

/// The renderer is shared by the CLI and MCP: the styles differ in presentation, while the
/// substantive decisions — histogram, hints, degradation — are the same.
@Suite("Rendering of semantic answers")
struct SymbolReportTests {
    private func location(_ path: String, _ line: Int, _ column: Int = 1, isDefinition: Bool = false) -> SextantCore.SourceLocation {
        SextantCore.SourceLocation(path: path, line: line, column: column, isDefinition: isDefinition)
    }

    private var hit: SymbolHit {
        SymbolHit(
            name: "Event", usr: "s:Event", kind: "struct",
            definition: location("/repo/Sources/Event.swift", 6, 15, isDefinition: true),
            references: [location("/repo/Sources/A.swift", 10), location("/repo/Sources/A.swift", 20),
                         location("/repo/Sources/B.swift", 3)]
        )
    }

    private func render(_ hits: [SymbolHit], query: SymbolQuery, style: SymbolReport.Style, symbol: String = "Event") -> SymbolReport.Rendering {
        SymbolReport.lookup(symbol: symbol, hits: hits, query: query, style: style,
                            path: { URL(fileURLWithPath: $0).lastPathComponent }, snippet: { _ in nil })
    }

    @Test("Compact: a histogram by file instead of a line-by-line list")
    func compactRendersHistogram() {
        let lines = render([hit], query: .references, style: .mcp).lines
        #expect(lines.contains { $0.contains("usages: 3 in 2 file(s)") })
        #expect(lines.contains { $0.contains("A.swift: 10, 20") })
        #expect(lines.contains { $0.contains("B.swift: 3") })
    }

    @Test("Full mode: line by line, with a limit and a remainder")
    func fullListRespectsLimit() {
        let style = SymbolReport.Style.cli(compact: false, referenceLimit: 2)
        let lines = render([hit], query: .references, style: style).lines
        #expect(lines.contains { $0.contains("usages: 3") })
        #expect(lines.contains { $0.contains("… 1 more") })
        #expect(lines.contains { $0.contains("A.swift:10:1") })   // the CLI shows columns
    }

    @Test("MCP prints neither columns nor the CLI hint about --full")
    func mcpStyleOmitsCLIDetails() {
        let lines = render([hit], query: .references, style: .mcp).lines
        #expect(!lines.contains { $0.contains("--full") })
        #expect(lines.contains { $0.contains("A.swift: 10, 20") })
        #expect(!lines.contains { $0.contains(":10:1") })
    }

    @Test("defs with no definition and no references gives an honest hint, not emptiness")
    func definitionsWithoutAnythingExplainItself() {
        let empty = SymbolHit(name: "URLSession", usr: "s:URLSession", kind: "struct", definition: nil, references: [])
        let cli = render([empty], query: .definitions, style: .cli(compact: true, referenceLimit: 40), symbol: "URLSession").lines
        let mcp = render([empty], query: .definitions, style: .mcp, symbol: "URLSession").lines
        #expect(cli.contains { $0.contains("definition not in the index") && $0.contains("`refs URLSession`") })
        #expect(mcp.contains { $0.contains("definition not in the index") && $0.contains("`find_references URLSession`") })
    }

    @Test("callers on a type: a hint about having no call sites, phrased per surface")
    func typeCallersAdvisory() {
        let type = SymbolHit(name: "Event", usr: "s:Event", kind: "struct",
                             definition: location("/repo/Event.swift", 1), references: [])
        #expect(render([type], query: .callers, style: .mcp).advisory?.contains("find_references") == true)
        #expect(render([type], query: .callers, style: .cli(compact: true, referenceLimit: 40)).advisory?.contains("`refs Event`") == true)
        // A function gets no such hint — it would be noise. The path is this very file: a location
        // whose file is gone raises an advisory of its own, which would mask the absence of this one.
        let function = SymbolHit(name: "save", usr: "s:save", kind: "function",
                                 definition: location(#filePath, 1), references: [])
        #expect(render([function], query: .callers, style: .mcp).advisory == nil)
    }

    @Test("Textual degradation is always marked as NOT semantics")
    func textualIsMarked() {
        let matches = [IdentifierScan.Match(path: "/repo/A.swift", line: 4, text: "let x = Event()")]
        let lines = SymbolReport.textual(symbol: "Event", matches: matches, truncated: true,
                                         style: .mcp, path: { URL(fileURLWithPath: $0).lastPathComponent })
        #expect(lines[0].contains("⚠"))
        #expect(lines[0].contains("NOT calls or references"))
        #expect(lines[0].contains("1+"))          // truncation is marked, not passed off as complete
        #expect(lines[1].contains("A.swift:4"))
    }
}
