import Foundation
import Testing
@testable import SextantCore

/// Every column sextant reports is 1-based and counted in UTF-16 code units. The sources of
/// positions — the index store, SwiftSyntax, libclang — all count bytes of UTF-8, so on a line with
/// Cyrillic or an emoji before the symbol each of them used to report a column further right than
/// an editor shows, and the same place got a column no LSP client could use.
///
/// The lines checked, in turn: nothing but ASCII before the symbol, Cyrillic (two bytes a letter,
/// one unit), an emoji (four bytes, two units — a surrogate pair) and a tab (one of each).
@Suite("Columns: 1-based, in UTF-16 code units", .serialized)
struct ColumnUnitTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = repositoryRoot.appendingPathComponent("Tests/Fixtures/IndexFixture")
    private static var binary: URL? { BuildProducts.sextantBinary(under: repositoryRoot) }

    /// The fixture file with one call to `columnProbe` after each kind of text.
    private static let swiftFile = fixture.appendingPathComponent("Sources/IndexFixture/Columns.swift")
    /// The C function with one call to `c_fixture_double` after each kind of text.
    private static let cFile = fixture.appendingPathComponent("Sources/CFixture/CFixture.c")

    /// Where an editor puts each call in `Columns.swift`: lines 7 to 10, ASCII, Cyrillic, emoji, tab.
    private static let swiftCalls: [(line: Int, column: Int)] = [(7, 17), (8, 36), (9, 35), (10, 15)]
    /// Where an editor puts each call in `CFixture.c`: Cyrillic, emoji, tab.
    private static let cCalls: [(line: Int, column: Int)] = [(11, 33), (12, 26), (13, 15)]

    /// The UTF-16 column of `needle` on `line`, counted independently of `SourceColumn`.
    private func editorColumn(of needle: String, in line: String) -> Int? {
        line.range(of: needle).map { line.utf16.distance(from: line.startIndex, to: $0.lowerBound) + 1 }
    }

    private func lines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
    }

    // MARK: - The conversion

    @Test("ASCII, Cyrillic, an emoji (a surrogate pair, two units) and a tab")
    func conversionCountsUTF16Units() {
        #expect(SourceColumn.column(ofUTF8Column: 9, inLine: "let x = f()") == 9)
        // "let привет = " is 13 characters and 19 bytes.
        #expect(SourceColumn.column(ofUTF8Column: 20, inLine: "let привет = f()") == 14)
        // `s = "` (5), the emoji (4 bytes, 2 units), `"; ` (3).
        #expect(SourceColumn.column(ofUTF8Column: 13, inLine: "s = \"😀\"; f()") == 11)
        #expect(SourceColumn.column(ofUTF8Column: 2, inLine: "\tf()") == 2)
        #expect(SourceColumn.column(ofUTF8Column: 1, inLine: "привет") == 1)
    }

    @Test("a column past the end of its line is not converted into a guess")
    func conversionRefusesWhatTheLineCannotHold() {
        #expect(SourceColumn.column(ofUTF8Column: 4, inLine: "abc") == 4, "just after the last character")
        #expect(SourceColumn.column(ofUTF8Column: 5, inLine: "abc") == nil)
        #expect(SourceColumn.column(ofUTF8Column: 0, inLine: "abc") == nil)
    }

    @Test("a byte offset is restated as a line and a column")
    func byteOffsetsBecomePositions() {
        let text = "ab\nпр x\n😀y"
        let bytes = Array(text.utf8)
        let lines = ByteLines(bytes)
        let x = bytes.firstIndex(of: UInt8(ascii: "x"))!
        let y = bytes.firstIndex(of: UInt8(ascii: "y"))!
        #expect(lines.position(ofOffset: 0)! == (1, 1))
        #expect(lines.position(ofOffset: x)! == (2, 4))
        #expect(lines.position(ofOffset: y)! == (3, 3))
        #expect(lines.line(3).map { String(decoding: $0, as: UTF8.self) } == "😀y")
        #expect(lines.column(line: 2, utf8Column: 6) == 4)
        #expect(lines.line(4) == nil)
    }

    // MARK: - SwiftSyntax: search and lint

    @Test("Swift structural search reports the column an editor shows")
    func swiftSearchColumns() throws {
        let source = try String(contentsOf: Self.swiftFile, encoding: .utf8)
        let matches = try PatternSearch(pattern: "columnProbe($X)").search(source: source, fileName: "Columns.swift")
        #expect(matches.map { [$0.line, $0.column] } == Self.swiftCalls.map { [$0.line, $0.column] })
        let text = try lines(of: Self.swiftFile)
        for match in matches {
            #expect(match.column == editorColumn(of: "columnProbe(", in: text[match.line - 1]))
        }
    }

    @Test("lint reports the same columns as search")
    func lintColumns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-columns-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Columns.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.swiftFile, to: file)

        let rules = [Rule(id: "probe", message: "a probe", patterns: ["columnProbe($X)"])]
        let violations = RuleEngine.run(rules: rules, projectRoot: root.path, includeTests: false)
        #expect(violations.map { [$0.line, $0.column] } == Self.swiftCalls.map { [$0.line, $0.column] })
    }

    // MARK: - The candidates of a stale answer

    @Test("candidates in changed files carry the same unit")
    func candidateColumns() throws {
        let text = try lines(of: Self.swiftFile)
        let source = text.joined(separator: "\n")
        let tokens = IndexDrift.swiftIdentifiers(named: "columnProbe", in: source, declarationsOnly: false)
        #expect(tokens.filter { $0.line >= 7 }.map { [$0.line, $0.column] } == Self.swiftCalls.map { [$0.line, $0.column] })
        let words = IndexDrift.wholeWords("columnProbe", in: text)
        #expect(words.filter { $0.line >= 7 }.map { [$0.line, $0.column] } == Self.swiftCalls.map { [$0.line, $0.column] })

        let c = try String(contentsOf: Self.cFile, encoding: .utf8)
        let lexical = IndexDrift.lexicalIdentifiers(named: "c_fixture_double", in: c).filter { $0.line > 3 }
        #expect(lexical.map { [$0.line, $0.column] } == Self.cCalls.map { [$0.line, $0.column] })
    }

    // MARK: - The index store

    @Test("an index position is restated from the text of its line, and a line that cannot be read states no column")
    func indexPositionsAreRestated() throws {
        let text = try lines(of: Self.swiftFile)
        let columns = IndexColumns(drift: nil)
        for (line, column) in Self.swiftCalls {
            let recorded = try #require(text[line - 1].utf8.firstRange(of: "columnProbe(".utf8))
            let utf8Column = text[line - 1].utf8.distance(from: text[line - 1].utf8.startIndex, to: recorded.lowerBound) + 1
            let location = SourceLocation(path: Self.swiftFile.path, line: line, column: utf8Column, isDefinition: false)
            #expect(columns.restate(location).column == column)
        }

        let gone = SourceLocation(path: "/nonexistent/sextant/Gone.swift", line: 1, column: 5, isDefinition: false)
        #expect(columns.restate(gone).column == nil)
        #expect(columns.restate(gone).position == "1")
        let tooShort = SourceLocation(path: Self.swiftFile.path, line: 11, column: 400, isDefinition: false)
        #expect(columns.restate(tooShort).column == nil)
    }

    // MARK: - Every layer agrees

    private struct Output { let code: Int32, stdout: String, stderr: String }

    private func sextant(_ arguments: [String]) throws -> Output {
        let binary = try #require(Self.binary, "sextant is not built — run `swift build` first")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SEXTANT_NO_DAEMON"] = "1"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let collected = OutputCapture.collect(from: [out, err]) { process.waitUntilExit() }
        return Output(code: process.terminationStatus, stdout: collected[0], stderr: collected[1])
    }

    private func json(_ arguments: [String]) throws -> Any {
        let run = try sextant(arguments + ["--project", Self.fixture.path, "--json"])
        do {
            return try JSONSerialization.jsonObject(with: Data(run.stdout.utf8))
        } catch {
            Issue.record("not JSON:\n\(run.stdout)\n\(run.stderr)")
            throw error
        }
    }

    /// (file name, line, column) of the references in a `refs --json` answer.
    private func referencePositions(_ symbol: String) throws -> Set<String> {
        let hits = try #require(try json(["refs", symbol]) as? [[String: Any]])
        return Set(hits.flatMap { ($0["references"] as? [[String: Any]]) ?? [] }.compactMap { reference in
            guard let path = reference["path"] as? String, let line = reference["line"] as? Int,
                  let column = reference["column"] as? Int else { return nil }
            return "\((path as NSString).lastPathComponent):\(line):\(column)"
        })
    }

    /// (file name, line, column) of the matches in a `search --json` answer.
    private func matchPositions(_ pattern: String) throws -> Set<String> {
        let answer = try #require(try json(["search", pattern]) as? [String: Any])
        return Set(((answer["matches"] as? [[String: Any]]) ?? []).compactMap { match in
            guard let file = match["file"] as? String, let line = match["line"] as? Int,
                  let column = match["column"] as? Int else { return nil }
            return "\((file as NSString).lastPathComponent):\(line):\(column)"
        })
    }

    private static var fixtureIsIndexed: Bool {
        binary != nil && BuildProducts.indexStore(under: fixture) != nil
            && ClangLibrary.discoverPath() != nil && !CompilationDatabase.load(forRoot: fixture.path).isEmpty
    }

    @Test("refs (the index store) and search (SwiftSyntax) give a Swift call the same column",
          .enabled(if: fixtureIsIndexed, "the fixture is not built and indexed (`make fixture`)"))
    func swiftLayersAgree() throws {
        let expected = Set(Self.swiftCalls.map { "Columns.swift:\($0.line):\($0.column)" })
        #expect(try referencePositions("columnProbe") == expected)
        #expect(try matchPositions("columnProbe($X)") == expected)
    }

    @Test("refs (the index store) and search (libclang) give a C call the same column",
          .enabled(if: fixtureIsIndexed, "the fixture is not built and indexed (`make fixture`)"))
    func cLayersAgree() throws {
        let expected = Set(Self.cCalls.map { "CFixture.c:\($0.line):\($0.column)" })
        #expect(try referencePositions("c_fixture_double").filter { $0.hasPrefix("CFixture.c:") } == expected)
        #expect(try matchPositions("c_fixture_double($X)").filter { $0.hasPrefix("CFixture.c:") } == expected)
        let text = try lines(of: Self.cFile)
        for (line, column) in Self.cCalls {
            #expect(editorColumn(of: "c_fixture_double(", in: text[line - 1]) == column)
        }
    }

    @Test("the text answer prints the same column as --json",
          .enabled(if: fixtureIsIndexed, "the fixture is not built and indexed (`make fixture`)"))
    func textAgreesWithJSON() throws {
        let run = try sextant(["refs", "columnProbe", "--full", "--project", Self.fixture.path])
        for (line, column) in Self.swiftCalls {
            #expect(run.stdout.contains("Columns.swift:\(line):\(column) "), "\(run.stdout)")
        }
    }
}
