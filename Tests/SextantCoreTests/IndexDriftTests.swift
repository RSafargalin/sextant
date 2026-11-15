import Foundation
import Testing
@testable import SextantCore

/// Answers over a stale index, stated against the current text: the line diff, the mapping of
/// positions, the candidates the index does not confirm, and the declaration/body classification.
/// Nothing here needs a build: the indexed text is a kept copy in a home of the test's own.
@Suite("Index drift")
struct IndexDriftTests {
    typealias Location = SextantCore.SourceLocation

    // MARK: - Line diff

    @Test("unchanged text maps every line onto itself")
    func unchangedMapsToItself() {
        let lines = ["a", "b", "c"]
        #expect(LineDiff.map(old: lines, new: lines) == [0, 1, 2])
    }

    @Test("lines inserted above move what follows")
    func insertionMoves() {
        #expect(LineDiff.map(old: ["a", "b", "c"], new: ["x", "y", "a", "b", "c"]) == [2, 3, 4])
    }

    @Test("a modified line maps to nothing, its neighbours keep their place")
    func modificationIsUnmapped() {
        #expect(LineDiff.map(old: ["a", "b", "c"], new: ["a", "B", "c"]) == [0, nil, 2])
    }

    @Test("a deleted line maps to nothing and what follows moves up")
    func deletionIsUnmapped() {
        #expect(LineDiff.map(old: ["a", "b", "c", "d"], new: ["a", "c", "d"]) == [0, nil, 1, 2])
    }

    @Test("edits in the middle of a file are matched by the edit script, not by position")
    func middleEdits() {
        let old = ["p", "q", "keep1", "gone", "keep2", "r"]
        let new = ["p", "q", "new", "keep1", "keep2", "added", "r"]
        #expect(LineDiff.map(old: old, new: new) == [0, 1, 3, nil, 4, 6])
    }

    @Test("an emptied file and a file grown from nothing")
    func emptySides() {
        #expect(LineDiff.map(old: ["a", "b"], new: []) == [nil, nil])
        #expect(LineDiff.map(old: [], new: ["a"]).isEmpty)
    }

    /// Several thousand lines, rewritten throughout: the worst case for an edit script.
    @Test("a 6000-line file rewritten throughout is mapped within a second")
    func largeRewriteIsBounded() {
        let old = (0..<6000).map { "let value\($0) = \($0)" }
        let new = old.enumerated().map { $0.offset % 3 == 0 ? "\($0.element) // edited" : $0.element }
        let started = Date()
        let map = LineDiff.map(old: old, new: new)
        let elapsed = Date().timeIntervalSince(started)
        #expect(map.count == 6000)
        #expect(map[0] == nil && map[1] == 1 && map[2] == 2 && map[3] == nil)
        #expect(elapsed < 1.0, "took \(elapsed)s")
    }

    // MARK: - Fixtures

    /// A project directory and a home, with a file's indexed text kept as `sextant index` keeps it.
    private final class Workspace {
        let base: URL
        let root: URL
        let home: URL

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("sextant-drift-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
            root = base.appendingPathComponent("project")
            home = base.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

        func write(_ relative: String, _ contents: String) throws {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }

        /// Keeps `indexed` as the text the store was built from and returns its hash.
        func keepIndexed(_ indexed: String) throws -> String {
            let data = Data(indexed.utf8)
            let hash = SourceSnapshot.blobHash(of: data)
            let folder = IndexedText.directory(home: home)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(hash))
            return hash
        }

        /// A drift over the given changed files, each with its indexed text (nil: did not exist).
        func drift(_ files: [String: String?], unavailable: Set<String> = []) throws -> IndexDrift? {
            var report = IndexFreshness.Report(state: .stale, basis: .snapshot, changedFiles: files.keys.sorted())
            for (path, indexed) in files {
                guard let indexed else { continue }
                report.indexedContent[path] = unavailable.contains(path)
                    ? SourceSnapshot.blobHash(of: Data(indexed.utf8))
                    : try keepIndexed(indexed)
            }
            return IndexDrift(report: report, projectRoot: root.path, home: home,
                              git: SourceSnapshot.GitRunner { _ in nil }, classificationCache: { nil })
        }
    }

    private func location(_ path: String, _ line: Int, _ column: Int) -> Location {
        Location(path: path, line: line, column: column, isDefinition: false)
    }

    // MARK: - Translation

    @Test("no drift without a snapshot basis or without changed files")
    func noDriftOnBuildTimeOrFresh() {
        #expect(IndexDrift(report: .init(state: .stale, basis: .buildTime), projectRoot: "/x") == nil)
        #expect(IndexDrift(report: .init(state: .fresh, basis: .snapshot), projectRoot: "/x") == nil)
        #expect(IndexDrift(report: .init(state: .stale, basis: .snapshot, changedManifests: ["Package.swift"]),
                           projectRoot: "/x") == nil)
    }

    @Test("a use under inserted lines is confirmed at its new line")
    func insertedLinesMoveTheUse() throws {
        let workspace = try Workspace()
        let indexed = "func f() {\n    work()\n}\n"
        try workspace.write("Use.swift", "// one\n// two\nfunc f() {\n    work()\n}\n")
        let drift = try #require(try workspace.drift(["Use.swift": indexed]))

        let moved = drift.translate(location(workspace.path("Use.swift"), 2, 5))
        #expect(moved.isConfirmed)
        #expect(moved.line == 4)
        #expect(moved.column == 5)
        #expect(moved.indexedLine == 2)
    }

    @Test("a use on a modified line is unconfirmed at the line as indexed, never moved")
    func modifiedLineIsUnconfirmed() throws {
        let workspace = try Workspace()
        try workspace.write("Use.swift", "func f() {\n    other(); work()\n}\n")
        let drift = try #require(try workspace.drift(["Use.swift": "func f() {\n    work()\n}\n"]))

        let use = drift.translate(location(workspace.path("Use.swift"), 2, 5))
        #expect(use.unconfirmed == IndexDrift.Reason.lineChanged)
        #expect(use.line == 2)
        #expect(use.marker.contains("unconfirmed"))
    }

    @Test("a use in a deleted file is unconfirmed as deleted")
    func deletedFileIsUnconfirmed() throws {
        let workspace = try Workspace()
        let drift = try #require(try workspace.drift(["Gone.swift": "work()\n"]))
        let use = drift.translate(location(workspace.path("Gone.swift"), 1, 1))
        #expect(use.unconfirmed == IndexDrift.Reason.fileDeleted)
    }

    @Test("a changed file whose indexed text is unavailable cannot be mapped")
    func unavailableTextIsUnconfirmed() throws {
        let workspace = try Workspace()
        try workspace.write("Use.swift", "work()\n")
        let drift = try #require(try workspace.drift(["Use.swift": "x\nwork()\n"], unavailable: ["Use.swift"]))
        let use = drift.translate(location(workspace.path("Use.swift"), 2, 1))
        #expect(use.unconfirmed == IndexDrift.Reason.noIndexedText)
        #expect(drift.indexedLines(ofFile: workspace.path("Use.swift")) == nil)
    }

    @Test("a position in a file that did not change is returned as it is")
    func unchangedFileIsUntouched() throws {
        let workspace = try Workspace()
        try workspace.write("Use.swift", "work()\n")
        try workspace.write("Other.swift", "a\nb\n")
        let drift = try #require(try workspace.drift(["Use.swift": "work()\n"]))
        let other = location(workspace.path("Other.swift"), 2, 1)
        #expect(drift.translate(other) == other)
    }

    /// The invariant the whole layer exists for, over a range of edits: a confirmed position always
    /// carries the name in the current text.
    @Test("no confirmed position lands where the current text does not carry the name")
    func confirmedPositionsCarryTheName() throws {
        let indexed = (1...40).map { $0 % 4 == 0 ? "    work() // \($0)" : "    let v\($0) = \($0)" }.joined(separator: "\n")
        var current = indexed.components(separatedBy: "\n")
        current.insert("    // inserted", at: 3)
        current.remove(at: 10)
        current[20] = "    changed()"
        current.insert(contentsOf: ["", "    work() // new"], at: 30)
        let workspace = try Workspace()
        try workspace.write("Use.swift", current.joined(separator: "\n"))
        let drift = try #require(try workspace.drift(["Use.swift": indexed]))

        let indexedLines = indexed.components(separatedBy: "\n")
        for (offset, text) in indexedLines.enumerated() where text.contains("work()") {
            let column = text.utf8.count - text.drop { $0 == " " }.utf8.count + 1
            let translated = drift.translate(location(workspace.path("Use.swift"), offset + 1, column))
            guard translated.isConfirmed else { continue }
            let line = Array(current[translated.line - 1].utf8)
            #expect(line[(translated.column - 1)...].starts(with: Array("work".utf8)),
                    "line \(offset + 1) confirmed at \(translated.line): \(current[translated.line - 1])")
        }
    }

    // MARK: - Reference verification against the indexed text

    /// The review finding: checking a stale file's recorded columns against its current text drops
    /// real references that merely moved. Checked against the indexed text, both survive.
    @Test("macro-duplicate verification reads the indexed text of a changed file")
    func verificationUsesIndexedText() throws {
        let workspace = try Workspace()
        let indexed = "let a = Widget(); let b = Widget()\n"
        try workspace.write("Use.swift", "let a = Widget(); let c = 0\nlet a = Widget(); let b = Widget()\n")
        let drift = try #require(try workspace.drift(["Use.swift": indexed]))
        let path = workspace.path("Use.swift")
        let positions = [location(path, 1, 9), location(path, 1, 27)]

        #expect(ReferencePositions.verified(positions, name: "Widget").count == 1,
                "against the current text one of the two real positions is dropped")
        #expect(ReferencePositions.verified(positions, name: "Widget", indexedText: drift.indexedLines(ofFile:)).count == 2)
    }

    // MARK: - Candidates

    @Test("Swift candidates are identifier tokens, not comments, strings or longer names")
    func swiftCandidatesAreTokens() {
        let source = """
            // work() in a comment
            let s = "work()"
            func work() {}
            workload()
            x.work()
            """
        let found = IndexDrift.swiftIdentifiers(named: "work", in: source, declarationsOnly: false)
        #expect(found.map(\.line) == [3, 5])
        #expect(found.last?.column == 3)
        #expect(IndexDrift.swiftIdentifiers(named: "work", in: source, declarationsOnly: true).map(\.line) == [3])
    }

    @Test("C-family candidates are lexical identifiers outside comments and literals")
    func lexicalCandidates() {
        let source = """
            /* work */ int work(void); // work
            const char *s = "work"; char c = 'w';
            int working = work();
            """
        let found = IndexDrift.lexicalIdentifiers(named: "work", in: source)
        #expect(found.map(\.line) == [1, 3])
        #expect(found.first?.column == 16)
    }

    @Test("a candidate the index confirms is not offered; one it does not know is")
    func candidatesExcludeConfirmedPositions() throws {
        let workspace = try Workspace()
        try workspace.write("Use.swift", "work()\nwork()\n")
        try workspace.write("New.swift", "func g() { work() }\n")
        let drift = try #require(try workspace.drift(["Use.swift": "work()\n", "New.swift": nil]))
        let known = [drift.translate(location(workspace.path("Use.swift"), 1, 1))]

        let found = drift.candidates(forName: "work()", excluding: known, declarationsOnly: false)
        #expect(found.total == 2)
        #expect(Set(found.shown.map { "\(($0.path as NSString).lastPathComponent):\($0.line)" }) == ["Use.swift:2", "New.swift:1"])
    }

    // MARK: - Declarations or bodies

    @Test("a body-only edit does not change declarations; a signature or a rename does")
    func classification() {
        let indexed = "struct A {\n    func run() { print(1) }\n}\n"
        #expect(!IndexDrift.declarationsDiffer(indexed: indexed, current: "struct A {\n    func run() { print(2) }\n}\n",
                                               path: "A.swift", existed: true))
        #expect(IndexDrift.declarationsDiffer(indexed: indexed, current: "struct A {\n    func run(_ x: Int) { print(1) }\n}\n",
                                              path: "A.swift", existed: true))
        #expect(IndexDrift.declarationsDiffer(indexed: indexed, current: "struct A {\n    func go() { print(1) }\n}\n",
                                              path: "A.swift", existed: true))
        #expect(IndexDrift.declarationsDiffer(indexed: nil, current: "func f() {}\n", path: "New.swift", existed: false))
        #expect(IndexDrift.declarationsDiffer(indexed: nil, current: indexed, path: "A.swift", existed: true),
                "an indexed text that is unavailable cannot be compared, and counts as changed")
        #expect(IndexDrift.declarationsDiffer(indexed: indexed, current: "struct A {\n    func run( {\n}\n",
                                              path: "A.swift", existed: true), "a file that does not parse counts as changed")
        #expect(IndexDrift.declarationsDiffer(indexed: "int f(void);", current: "int f(void); ", path: "a.h", existed: true))
        #expect(!IndexDrift.declarationsDiffer(indexed: "int f(void) {}", current: "int f(int x) {}", path: "a.m", existed: true))
    }

    // MARK: - Rendering

    @Test("no note renders nothing, and confirmed positions carry no marker")
    func freshRendersNothing() {
        #expect(SymbolReport.staleness(nil, locations: [], symbol: "x", style: .mcp, path: { $0 }).isEmpty)
        #expect(location("/a.swift", 1, 1).marker.isEmpty)
    }

    @Test("a position without markers encodes exactly the keys it always had")
    func legacyJSONKeys() throws {
        let data = try JSONEncoder().encode(location("/a.swift", 3, 4))
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["path", "line", "column", "isDefinition"])
        let hit = SymbolHit(name: "a", usr: "u", kind: "k", definition: nil, references: [])
        let hitKeys = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(hit)) as? [String: Any]).keys
        #expect(Set(hitKeys) == ["name", "usr", "kind", "references", "totalReferences"])
    }

    @Test("the compact histogram groups unconfirmed lines apart and the section names them")
    func compactRendering() throws {
        let workspace = try Workspace()
        try workspace.write("Use.swift", "// new\nwork()\nother()\n")
        let drift = try #require(try workspace.drift(["Use.swift": "work()\nwork(1)\n"]))
        let path = workspace.path("Use.swift")
        var hit = SymbolHit(name: "work()", usr: "u", kind: "function", definition: nil,
                            references: [drift.translate(location(path, 1, 1)), drift.translate(location(path, 2, 1))])
        hit.staleness = drift.note(forName: "work", known: hit.references, declarationsOnly: false)
        let lines = SymbolReport.lookup(symbol: "work", hits: [hit], query: .references, style: .mcp,
                                        path: { ($0 as NSString).lastPathComponent }, snippet: { _ in nil }).lines
        #expect(lines.contains("    Use.swift: 2"))
        #expect(lines.contains { $0.hasPrefix("    Use.swift: 2  [unconfirmed") })
        #expect(lines.contains { $0.contains("1 position(s) unconfirmed") })
        #expect(lines.contains { $0.contains("1 position(s) moved to their current lines") })
    }

    // MARK: - Indexed text

    @Test("copies are kept by hash, read back, and pruned once no snapshot refers to them")
    func keptCopies() throws {
        let workspace = try Workspace()
        try workspace.write("Dirty.swift", "let dirty = 1\n")
        let sources = SourceSnapshot(git: nil, files: [
            "Dirty.swift": SourceSnapshot.record(of: workspace.root.appendingPathComponent("Dirty.swift")),
        ])
        #expect(IndexedText.keepCopies(of: sources, projectRoot: workspace.root.path, home: workspace.home) == 1)
        let hash = try #require(sources.files["Dirty.swift"]?.hash)
        let data = IndexedText.content(hash: hash, projectRoot: workspace.root.path, home: workspace.home,
                                       git: SourceSnapshot.GitRunner { _ in nil })
        #expect(data.map { String(decoding: $0, as: UTF8.self) } == "let dirty = 1\n")

        IndexedText.prune(home: workspace.home)
        #expect(!FileManager.default.fileExists(atPath: IndexedText.directory(home: workspace.home).appendingPathComponent(hash).path))
    }

    @Test("batch output is split by the sizes it states, and a missing object is skipped")
    func batchParsing() {
        let output = Data("aaaa blob 3\nab\n\nbbbb missing\ncccc blob 0\n\n".utf8)
        let parsed = IndexedText.parseBatch(output)
        #expect(parsed["aaaa"].map { String(decoding: $0, as: UTF8.self) } == "ab\n")
        #expect(parsed["bbbb"] == nil)
        #expect(parsed["cccc"] == Data())
    }

    @Test("a file clean in git is read back from the repository by its blob hash")
    func cleanFileFromGit() throws {
        let workspace = try Workspace()
        try workspace.write("A.swift", "struct A {}\n")
        func git(_ arguments: String...) -> String? {
            Command.successOutput("/usr/bin/env", ["git", "-C", workspace.root.path, "-c", "user.name=t",
                                                   "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments)
        }
        try #require(git("init", "-q") != nil)
        try #require(git("add", "-A") != nil)
        try #require(git("commit", "-q", "-m", "init") != nil)
        let snapshot = try IndexSnapshot.sources(ofProject: workspace.root.path).get()
        try workspace.write("A.swift", "struct A { var x = 1 }\n")
        try workspace.write("New.swift", "struct N {}\n")

        guard case .compared(let changed, let indexed) = snapshot.changes(projectRoot: workspace.root) else {
            Issue.record("the comparison did not run")
            return
        }
        #expect(changed == ["A.swift", "New.swift"])
        #expect(indexed["New.swift"] == nil, "a file that did not exist then has no indexed text")
        let hash = try #require(indexed["A.swift"])
        let data = IndexedText.content(hash: hash, projectRoot: workspace.root.path, home: workspace.home)
        #expect(data.map { String(decoding: $0, as: UTF8.self) } == "struct A {}\n")
        let oneByOne = SourceSnapshot.GitRunner { SourceSnapshot.GitRunner.system.run($0) }
        let fallback = IndexedText.content(hash: hash, projectRoot: workspace.root.path, home: workspace.home, git: oneByOne)
        #expect(fallback == data, "a runner without stdin reads the object one process at a time")
    }
}
