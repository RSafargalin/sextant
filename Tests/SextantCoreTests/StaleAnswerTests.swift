import Foundation
import Testing
@testable import SextantCore

/// The mechanism itself under mutation: one package indexed by the real `sextant index` in a home
/// of its own, then edited WITHOUT reindexing, and asked again. Each case restores the sources
/// afterwards, so the one index serves them all.
///
/// The invariant checked throughout: no occurrence is presented as confirmed at a position where
/// the current text does not carry the symbol's name.
@Suite("Stale answers under mutation", .serialized)
struct StaleAnswerTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var binary: URL? { BuildProducts.sextantBinary(under: repositoryRoot) }

    private static let sources: [String: String] = [
        "Package.swift": """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "stale", targets: [.target(name: "stale")])

            """,
        "Sources/stale/Kept.swift": """
            public struct Kept {
                public init() {}
                public func work() {}
                public func rest() { let pause = 1; _ = pause }
            }

            """,
        "Sources/stale/Use.swift": """
            public func use() {
                let kept = Kept()
                kept.work()
            }

            public func again() {
                Kept().work()
            }

            """,
        "Sources/stale/Other.swift": """
            func other() {
                let elsewhere = Kept()
                elsewhere.work()
            }

            """,
        // Uses after text that is not ASCII: Cyrillic, an emoji and a tab before the call.
        "Sources/stale/Wide.swift": """
            func wide() {
                let привет = Kept(); привет.work()
                let smile = "😀"; Kept().work(); _ = smile
            \tKept().work()
            }

            """,
    ]

    /// The indexed package, built once for the whole suite.
    final class Indexed: @unchecked Sendable {
        let base: URL
        let root: URL
        let home: URL
        private(set) var indexSeconds = 0.0

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("sextant-stale-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
            root = base.appendingPathComponent("package")
            home = base.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for (path, contents) in StaleAnswerTests.sources {
                try Self.write(contents, to: root.appendingPathComponent(path))
            }
            try ".build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            _ = try git("init", "-q")
            _ = try git("add", "-A")
            _ = try git("commit", "-q", "-m", "initial")
            let started = Date()
            let index = try run(["index", "--project", root.path])
            indexSeconds = Date().timeIntervalSince(started)
            guard index.code == 0 else {
                throw IndexFailure(description: "sextant index failed:\n\(index.output)\n\(index.errors)")
            }
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        struct IndexFailure: Error, CustomStringConvertible { let description: String }

        static func write(_ contents: String, to file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }

        func write(_ path: String, _ contents: String) throws {
            try Self.write(contents, to: root.appendingPathComponent(path))
        }

        func text(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        func git(_ arguments: String...) throws -> String {
            let output = Command.successOutput("/usr/bin/env", ["git", "-C", root.path, "-c", "user.name=t",
                                                                "-c", "user.email=t@example.com",
                                                                "-c", "commit.gpgsign=false"] + arguments)
            guard let output else { throw IndexFailure(description: "git \(arguments.joined(separator: " ")) failed") }
            return output
        }

        /// Puts the sources back as they were indexed.
        func restore() throws {
            _ = try git("checkout", "-q", "--", ".")
            _ = try git("clean", "-fdq", "--", "Sources")
        }

        func run(_ arguments: [String], input: String? = nil) throws -> (code: Int32, output: String, errors: String) {
            let process = Process()
            process.executableURL = StaleAnswerTests.binary
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            for name in ["SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA", "CLAUDE_PROJECT_DIR", "SEXTANT_TELEMETRY"] {
                environment[name] = nil
            }
            environment["CFFIXED_USER_HOME"] = home.path
            environment["SEXTANT_NO_DAEMON"] = "1"
            process.environment = environment
            let out = Pipe(), err = Pipe(), stdin = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            try process.run()
            if let input {
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try stdin.fileHandleForWriting.close()
            }
            let collected = OutputCapture.collect(from: [out, err]) { process.waitUntilExit() }
            return (process.terminationStatus, collected[0], collected[1])
        }

        func sextant(_ arguments: String...) throws -> (code: Int32, output: String, errors: String) {
            try run(arguments + ["--project", root.path])
        }
    }

    private static let shared = Result { try Indexed() }

    private func indexed() throws -> Indexed {
        try Self.shared.get()
    }

    // MARK: - Reading answers

    /// A position as `--json` prints it.
    private struct Position {
        let path: String
        let line: Int
        /// Absent when the recorded line cannot be read.
        let column: Int?
        let unconfirmed: String?

        init?(_ object: Any?) {
            guard let object = object as? [String: Any], let path = object["path"] as? String,
                  let line = object["line"] as? Int else { return nil }
            let column = object["column"] as? Int
            self.path = path
            self.line = line
            self.column = column
            self.unconfirmed = object["unconfirmed"] as? String
        }

        var file: String { (path as NSString).lastPathComponent }
    }

    private struct Answer {
        let hits: [[String: Any]]

        var references: [Position] { hits.flatMap { ($0["references"] as? [Any] ?? []).compactMap(Position.init) } }
        var definitions: [Position] { hits.compactMap { Position($0["definition"]) } }
        var staleness: [String: Any]? { hits.first?["staleness"] as? [String: Any] }
        var candidates: [(file: String, line: Int)] {
            (staleness?["candidates"] as? [[String: Any]] ?? []).compactMap { candidate in
                guard let path = candidate["path"] as? String, let line = candidate["line"] as? Int else { return nil }
                return ((path as NSString).lastPathComponent, line)
            }
        }
        var declarationsChanged: [String] { staleness?["declarationsChanged"] as? [String] ?? [] }
        var totalReferences: Int { hits.reduce(0) { $0 + ($1["totalReferences"] as? Int ?? 0) } }
    }

    private func refs(_ symbol: String, in package: Indexed) throws -> Answer {
        let run = try package.sextant("refs", symbol, "--json")
        try #require(run.code == 0, "\(run.output)\n\(run.errors)")
        let hits = try #require(try JSONSerialization.jsonObject(with: Data(run.output.utf8)) as? [[String: Any]],
                                "not a list of hits:\n\(run.output)")
        return Answer(hits: hits)
    }

    /// The invariant: every confirmed position has the name at its column — in UTF-16 code units —
    /// in the current text.
    private func expectConfirmedPositionsCarry(_ name: String, _ answer: Answer,
                                               sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        for position in answer.references + answer.definitions where position.unconfirmed == nil {
            let lines = ((try? String(contentsOfFile: position.path, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            let carries = position.line >= 1 && position.line <= lines.count && position.column.map { column in
                Array(lines[position.line - 1].utf16).dropFirst(column - 1).starts(with: Array(name.utf16))
            } == true
            #expect(carries, "\(position.file):\(position.line):\(position.column ?? 0) is confirmed, and the text there does not carry '\(name)'",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - Cases

    @Test("lines inserted above a use: the use is confirmed at its new line",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func insertedLines() throws {
        let package = try indexed()
        defer { try? package.restore() }
        let fresh = try refs("work", in: package)
        #expect(fresh.staleness == nil)
        #expect(fresh.references.contains { $0.file == "Use.swift" && $0.line == 3 })

        try package.write("Sources/stale/Use.swift", "// one\n// two\n" + (try package.text("Sources/stale/Use.swift")))
        let stale = try refs("work", in: package)

        let uses = stale.references.filter { $0.file == "Use.swift" }
        #expect(uses.map(\.line) == [5, 9])
        #expect(uses.allSatisfy { $0.unconfirmed == nil })
        expectConfirmedPositionsCarry("work", stale)
        let text = try package.sextant("refs", "work", "--full")
        #expect(text.output.contains("Sources/stale/Use.swift:5:10  kept.work()"), "\(text.output)")
        #expect(text.output.contains("2 position(s) moved to their current lines"), "\(text.output)")
    }

    @Test("lines inserted above uses after Cyrillic, an emoji and a tab: columns stay in UTF-16 units",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func insertedLinesAboveWideUses() throws {
        let package = try indexed()
        defer { try? package.restore() }
        let fresh = try refs("work", in: package).references.filter { $0.file == "Wide.swift" }
        // `work` after "let привет = Kept(); привет." (28 characters, 40 bytes) and 4 spaces; after the
        // emoji (2 units, 4 bytes); after a tab (1 of each).
        #expect(fresh.map { [$0.line, $0.column ?? 0] } == [[2, 33], [3, 30], [4, 9]], "\(fresh)")

        try package.write("Sources/stale/Wide.swift", "// одна\n// 😀\n" + (try package.text("Sources/stale/Wide.swift")))
        let stale = try refs("work", in: package)
        let moved = stale.references.filter { $0.file == "Wide.swift" }
        #expect(moved.map { [$0.line, $0.column ?? 0] } == [[4, 33], [5, 30], [6, 9]], "\(moved)")
        #expect(moved.allSatisfy { $0.unconfirmed == nil })
        #expect(!stale.candidates.contains { $0.file == "Wide.swift" }, "a confirmed use is not a candidate: \(stale.candidates)")
        expectConfirmedPositionsCarry("work", stale)

        let search = try package.sextant("search", "Kept().work()", "--json")
        let matches = try #require(try JSONSerialization.jsonObject(with: Data(search.output.utf8)) as? [String: Any])
        let found = ((matches["matches"] as? [[String: Any]]) ?? []).filter { ($0["file"] as? String)?.hasSuffix("Wide.swift") == true }
        // A match starts at `Kept`, seven units before `work`: the same unit as the index answer.
        #expect(found.compactMap { ($0["column"] as? Int).map { $0 + 7 } } == [30, 9], "\(found)")
    }

    @Test("the line of a use modified: unconfirmed, never confirmed at a wrong line",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func modifiedLine() throws {
        let package = try indexed()
        defer { try? package.restore() }
        let source = try package.text("Sources/stale/Use.swift")
        try package.write("Sources/stale/Use.swift",
                          source.replacingOccurrences(of: "    kept.work()\n", with: "    print(0); kept.work()\n"))
        let stale = try refs("work", in: package)

        let use = try #require(stale.references.first { $0.file == "Use.swift" && $0.line == 3 })
        #expect(use.unconfirmed == "line-changed")
        #expect(!stale.references.contains { $0.file == "Use.swift" && $0.line == 3 && $0.unconfirmed == nil })
        expectConfirmedPositionsCarry("work", stale)
        let text = try package.sextant("refs", "work", "--full")
        #expect(text.output.contains("Sources/stale/Use.swift:3:10  [unconfirmed: line changed since indexing"), "\(text.output)")
    }

    /// Regression: a declaration whose line changed with its name left in place was listed twice —
    /// as the unconfirmed definition and as a candidate the index does not know, at one position.
    @Test("an unconfirmed position is not offered again as a candidate; candidates are spelled as the index spells files",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func unconfirmedPositionIsNotACandidate() throws {
        let package = try indexed()
        defer { try? package.restore() }
        let source = try package.text("Sources/stale/Kept.swift")
        try package.write("Sources/stale/Kept.swift",
                          source.replacingOccurrences(of: "public func work() {}", with: "public func work() { _ = 1 }")
                            + "func extra() { Kept().work() }\n")
        let stale = try refs("work", in: package)
        let definition = try #require(stale.definitions.first { $0.file == "Kept.swift" })
        #expect(definition.unconfirmed != nil, "\(definition)")
        #expect(!stale.candidates.contains { $0.file == "Kept.swift" && $0.line == definition.line }, "\(stale.candidates)")
        let spelled = (stale.staleness?["candidates"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        let directory = (definition.path as NSString).deletingLastPathComponent
        #expect(!spelled.isEmpty && spelled.allSatisfy { $0.hasPrefix(directory + "/") }, "\(spelled) vs \(directory)")
    }

    @Test("a new call in an existing file and in a new file: candidates, not confirmed",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func newCalls() throws {
        let package = try indexed()
        defer { try? package.restore() }
        let fresh = try refs("work", in: package)
        try package.write("Sources/stale/Use.swift",
                          (try package.text("Sources/stale/Use.swift")) + "public func more() { Kept().work() }\n")
        try package.write("Sources/stale/New.swift", "func brandNew() { Kept().work() }\n")
        let stale = try refs("work", in: package)

        #expect(stale.candidates.contains { $0.file == "Use.swift" && $0.line == 9 }, "\(stale.candidates)")
        #expect(stale.candidates.contains { $0.file == "New.swift" && $0.line == 1 }, "\(stale.candidates)")
        #expect(stale.totalReferences == fresh.totalReferences, "a text match must never be counted as confirmed")
        #expect(stale.references.filter { $0.unconfirmed == nil }.count == fresh.references.count)
        #expect(!stale.references.contains { $0.file == "New.swift" })
        expectConfirmedPositionsCarry("work", stale)
        let text = try package.sextant("refs", "work", "--full")
        #expect(text.output.contains("not in the index — 'work' written in changed files"), "\(text.output)")
        #expect(text.output.contains("? Sources/stale/New.swift:1:"), "\(text.output)")
    }

    @Test("a deleted file with uses: its occurrences are not presented as present",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func deletedFile() throws {
        let package = try indexed()
        defer { try? package.restore() }
        try FileManager.default.removeItem(at: package.root.appendingPathComponent("Sources/stale/Other.swift"))
        let stale = try refs("work", in: package)

        let gone = stale.references.filter { $0.file == "Other.swift" }
        #expect(!gone.isEmpty, "the index's occurrence is listed, not dropped")
        #expect(gone.allSatisfy { $0.unconfirmed == "file-deleted" })
        expectConfirmedPositionsCarry("work", stale)
        let blast = try package.sextant("blast", "work")
        #expect(blast.output.contains("Sources/stale/Other.swift  [unconfirmed"), "\(blast.output)")
    }

    @Test("the symbol renamed at its declaration: the note about changed declarations appears",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func renamedDeclaration() throws {
        let package = try indexed()
        defer { try? package.restore() }
        try package.write("Sources/stale/Kept.swift", (try package.text("Sources/stale/Kept.swift"))
            .replacingOccurrences(of: "public func work() {}", with: "public func labor() {}"))
        let stale = try refs("work", in: package)

        #expect(stale.declarationsChanged == ["Sources/stale/Kept.swift"])
        #expect(stale.definitions.allSatisfy { $0.unconfirmed == "line-changed" })
        expectConfirmedPositionsCarry("work", stale)
        let text = try package.sextant("refs", "work")
        #expect(text.output.contains("declarations changed since indexing in Sources/stale/Kept.swift"), "\(text.output)")
    }

    @Test("a body-only edit: no note about changed declarations",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func bodyOnlyEdit() throws {
        let package = try indexed()
        defer { try? package.restore() }
        try package.write("Sources/stale/Kept.swift", (try package.text("Sources/stale/Kept.swift"))
            .replacingOccurrences(of: "let pause = 1", with: "let pause = 2"))
        let stale = try refs("work", in: package)

        #expect(stale.staleness != nil, "the index is stale, so the answer carries the note")
        #expect(stale.declarationsChanged.isEmpty)
        let text = try package.sextant("refs", "work")
        #expect(text.errors.contains("STALE"), "\(text.errors)")
        #expect(!text.output.contains("declarations changed"), "\(text.output)")
    }

    @Test("a touch changes nothing: every answer is byte for byte the fresh one",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func touchIsFresh() throws {
        let package = try indexed()
        defer { try? package.restore() }
        let commands: [[String]] = [
            ["refs", "work", "--full"], ["refs", "work", "--json"], ["defs", "work"], ["callers", "work"],
            ["context", "Kept"], ["context", "Kept", "--json"], ["blast", "work", "--json"], ["construct", "Kept"],
            ["body", "work"], ["callees", "use"], ["hierarchy", "use"],
        ]
        let fresh = try commands.map { try package.run($0 + ["--project", package.root.path]) }
        for file in ["Kept.swift", "Use.swift", "Other.swift"] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)],
                                                  ofItemAtPath: package.root.appendingPathComponent("Sources/stale/\(file)").path)
        }
        for (command, before) in zip(commands, fresh) {
            let after = try package.run(command + ["--project", package.root.path])
            #expect(after.output == before.output, "\(command.joined(separator: " ")) changed:\n\(after.output)")
            #expect(after.errors == before.errors, "\(command.joined(separator: " ")) changed:\n\(after.errors)")
            #expect(!after.output.contains("unconfirmed") && !after.output.contains("staleness"))
        }
    }

    @Test("MCP answers from the same mapping: a modified line is unconfirmed there too",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func mcpAnswersTheSame() throws {
        let package = try indexed()
        defer { try? package.restore() }
        let source = try package.text("Sources/stale/Use.swift")
        try package.write("Sources/stale/Use.swift",
                          "// moved\n" + source.replacingOccurrences(of: "    kept.work()\n", with: "    print(0); kept.work()\n"))
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 0, "method": "initialize",
             "params": ["protocolVersion": MCPProtocol.revision, "capabilities": [String: Any](),
                        "clientInfo": ["name": "stale", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": ["name": "find_references", "arguments": ["symbol": "work"]]],
        ]
        let input = try messages.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let session = try package.run(["mcp", "--project", package.root.path], input: input)
        let text = session.output.split(separator: "\n").compactMap { line -> String? in
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  message["id"] as? Int == 1, let result = message["result"] as? [String: Any] else { return nil }
            return ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        }.first
        let answer = try #require(text, "no answer to find_references:\n\(session.output)\n\(session.errors)")
        #expect(answer.contains("Sources/stale/Use.swift: 8"), "\(answer)")
        #expect(answer.contains("Sources/stale/Use.swift: 3  [unconfirmed"), "\(answer)")
        #expect(answer.contains("⚠ stale index"), "\(answer)")
    }
}
