import Foundation
import Testing
@testable import SextantCore

@Suite("Navigation acts")
struct NavigationActTests {
    @Test("A call is counted for what it is, not for who made it")
    func classifiesTools() {
        #expect(NavigationAct.of(tool: "mcp__sextant__find_references", command: nil) == .sextant)
        #expect(NavigationAct.of(tool: "Grep", command: "Store") == .textSearch)
        #expect(NavigationAct.of(tool: "Bash", command: "grep -rn Store Sources/") == .textSearch)
        #expect(NavigationAct.of(tool: "Bash", command: "sextant refs Store") == .sextant)
        #expect(NavigationAct.of(tool: "Bash", command: "./.build/debug/sextant refs Store") == .sextant)
        #expect(NavigationAct.of(tool: "Read", command: "/p/Sources/A.swift") == .fileRead)
    }

    @Test("What sextant does not replace stays out of the denominator")
    func excludesNonNavigation() {
        // Counting these would invent a gap the tool cannot close, and flatter or spoil the share
        // depending on which way it leaned.
        #expect(NavigationAct.of(tool: "Bash", command: "swift build") == .other)
        #expect(NavigationAct.of(tool: "Bash", command: "find . -name '*.o'") == .other)
        #expect(NavigationAct.of(tool: "Bash", command: "ls Sources") == .other)
        #expect(NavigationAct.of(tool: "Edit", command: nil) == .other)
        #expect(NavigationAct.of(tool: "Read", command: "/p/README.md") == .other)
    }

    /// The denominator must not depend on how a client happens to run a search. Claude Code 2.1.117
    /// stopped exposing `Grep` and `Glob` as tools on native macOS and Linux builds and started
    /// routing both through `Bash` as the embedded `ugrep` and `bfs`. The classifier knew neither,
    /// so those searches stopped being counted at all — and since they belong to the denominator,
    /// sextant's share silently rose without a single query changing hands.
    @Test("The same search weighs the same whichever binary the client runs")
    func countsSubstitutedSearchTools() {
        #expect(NavigationAct.of(tool: "Bash", command: "ugrep -n Store Sources/") == .textSearch)
        #expect(NavigationAct.of(tool: "Bash", command: "/opt/vendor/ugrep -n Store .") == .textSearch)
        #expect(NavigationAct.of(tool: "Bash", command: "bfs . -name '*.swift'") == .textSearch)
        for tool in NavigationAct.contentSearchTools + NavigationAct.fileSearchTools {
            #expect(NavigationAct.of(tool: "Bash", command: "\(tool) Store .") == .textSearch,
                    "\(tool) is listed as a search tool but is not counted as one")
        }

        // And the pattern still has to come out of the command, not the directory it walks.
        #expect(NavigationAct.searchPattern(inShellCommand: "ugrep -n Store Sources/") == "Store")
        #expect(NavigationAct.searchPattern(inShellCommand: "bfs . -name '*.swift'") == "*.swift")
        #expect(NavigationAct.searchPattern(inShellCommand: "bfs Sources -type f -name 'Store*.swift'")
                == "Store*.swift")
    }

    @Test("A shell search is classified by its pattern, not by the command line")
    func extractsPattern() {
        // Every command line has a slash in it, so classifying the line called every search a path.
        #expect(NavigationAct.searchPattern(inShellCommand: "grep -rn Store Sources/") == "Store")
        #expect(NavigationAct.searchPattern(inShellCommand: "rg --include '*.swift' Store .") == "Store")
        #expect(NavigationAct.searchPattern(inShellCommand: "grep -e 'Store.save' -r .") == "Store.save")
        #expect(NavigationAct.searchPattern(inShellCommand: "cd /p && grep -c Store A.swift") == "Store")
        #expect(NavigationAct.searchPattern(inShellCommand: "swift build") == nil)
    }

    @Test("A query is reduced to a shape, and the shape is what decides the gap")
    func classifiesShapes() {
        #expect(QueryShape.of("StoreCoordinator") == .identifier)
        #expect(QueryShape.of("store.save") == .memberAccess)
        #expect(QueryShape.of("try!|try?") == .pattern)
        #expect(QueryShape.of("Sources/Core") == .path)
        #expect(QueryShape.of("could not open") == .phrase)
        #expect(QueryShape.of("") == .unknown)
    }
}

@Suite("Adoption report")
struct AdoptionTests {
    /// A transcript in the shape the client writes, with one of each kind of call.
    private func transcript() throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-transcript-\(UUID().uuidString).jsonl")
        let records: [[String: Any]] = [
            ["type": "assistant", "message": ["content": [
                ["type": "text", "text": "a secret the metric must never read"],
                ["type": "tool_use", "name": "Grep", "input": ["pattern": "StoreCoordinator"]]
            ]]],
            ["type": "assistant", "message": ["content": [
                ["type": "tool_use", "name": "Bash", "input": ["command": "grep -rn saveAll Sources/"]]
            ]]],
            ["type": "assistant", "message": ["content": [
                ["type": "tool_use", "name": "Bash", "input": ["command": "swift build"]]
            ]]],
            ["type": "assistant", "message": ["content": [
                ["type": "tool_use", "name": "mcp__sextant__context", "input": ["symbol": "Store"]]
            ]]],
            ["type": "assistant", "message": ["content": [
                ["type": "tool_use", "name": "Read", "input": ["file_path": "/p/Sources/Store.swift"]]
            ]]],
            ["type": "user", "message": ["content": "a prompt, which is none of the metric's business"]]
        ]
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A share counts how often the tool was reached for; it cannot say whether the answer was
    /// enough. On a tool of the same shape, 18.4 % of symbol queries were followed by opening the
    /// same file, and four fifths of those already held the declaration — the answers were stopping
    /// one step short of what was wanted. Nothing in a share exposes that.
    @Test("An answer followed straight away by opening a file is counted as a step, not an end")
    func countsReadsAfterAnswers() throws {
        let file = try transcript()
        defer { try? FileManager.default.removeItem(at: file) }
        // The fixture ends with a sextant call and then a Read — exactly the pattern.
        #expect(Adoption.readsAfterAnswers(in: Adoption.samples(inTranscript: file)) == 1)

        // A read that follows a text search is somebody else's business, and one that follows
        // nothing at all is not a follow-up.
        let unrelated = [AdoptionSample(act: .textSearch, shape: .identifier),
                         AdoptionSample(act: .fileRead, shape: .path),
                         AdoptionSample(act: .sextant, shape: nil)]
        #expect(Adoption.readsAfterAnswers(in: unrelated) == 0)
        #expect(Adoption.readsAfterAnswers(in: []) == 0)
    }

    @Test("Each kind of call is counted once, and the rest is ignored")
    func countsNavigation() throws {
        let file = try transcript()
        defer { try? FileManager.default.removeItem(at: file) }

        let samples = Adoption.samples(inTranscript: file)
        #expect(samples.filter { $0.act == .sextant }.count == 1)
        #expect(samples.filter { $0.act == .textSearch }.count == 2)
        #expect(samples.filter { $0.act == .fileRead }.count == 1)
        #expect(!samples.contains { $0.act == .other })     // `swift build` is not navigation
    }

    @Test("By default not one query is kept, only its shape")
    func keepsNoQueriesByDefault() throws {
        let file = try transcript()
        defer { try? FileManager.default.removeItem(at: file) }

        let samples = Adoption.samples(inTranscript: file)
        // The promise the command makes about a file that is a conversation: it counts, it does
        // not read. A regression here would leak search patterns into whatever prints the report.
        #expect(samples.allSatisfy { $0.query == nil })
        #expect(samples.contains { $0.shape == .identifier })

        let kept = Adoption.samples(inTranscript: file, keepingQueries: true)
        #expect(kept.contains { $0.query == "StoreCoordinator" })
        #expect(kept.contains { $0.query == "saveAll" })     // the pattern, not the command line
    }

    @Test("A share of nothing is nothing, not zero per cent")
    func emptyReport() {
        let report = AdoptionReport(sessions: 1, sextant: 0, textSearch: 0, fileRead: 0, residue: [:], queries: [])
        // A session that only built and edited says nothing about adoption; 0% would say it did.
        #expect(report.share == nil)
        #expect(AdoptionReport(sessions: 1, sextant: 1, textSearch: 3, fileRead: 0,
                               residue: [:], queries: []).share == 0.25)
    }

    @Test("A project with no transcripts is reported as such, not as zero adoption")
    func missingTranscripts() {
        let root = "/nowhere-\(UUID().uuidString)"
        #expect(Adoption.transcripts(forProjectRoot: root).isEmpty)
        #expect(Adoption.transcriptDirectory(forProjectRoot: root).path.contains(".claude/projects/"))
    }
}

@Suite("Adoption log", .serialized)
struct AdoptionLogTests {
    @Test("A line carries an act and a shape, and nothing that identifies anything")
    func writesNothingIdentifying() throws {
        // The log lives at a fixed path; this checks the shape of what would be written by
        // encoding it the same way, rather than appending to the user's real file.
        let entry: [String: Any] = [
            "ts": 1_700_000_000, "project": AdoptionLog.projectKey(forRoot: "/Users/someone/Secret Project"),
            "act": NavigationAct.textSearch.rawValue, "shape": QueryShape.identifier.rawValue
        ]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self)
        #expect(!line.contains("Secret"))
        #expect(!line.contains("/Users"))
        #expect(line.contains("textSearch") && line.contains("identifier"))
    }

    @Test("The project key is stable and does not spell the path")
    func projectKeyIsAHash() {
        let key = AdoptionLog.projectKey(forRoot: "/Users/someone/Secret Project")
        #expect(key == AdoptionLog.projectKey(forRoot: "/Users/someone/Secret Project/"))
        #expect(key != AdoptionLog.projectKey(forRoot: "/Users/someone/Other"))
        #expect(!key.contains("Secret"))
    }

    @Test("The installation snippet names the binary and the event")
    func installationSnippet() {
        let snippet = AdoptionLog.installationSnippet(binaryPath: "/usr/local/bin/sextant")
        #expect(snippet.contains("PreToolUse"))
        #expect(snippet.contains("/usr/local/bin/sextant hook"))
    }
}
