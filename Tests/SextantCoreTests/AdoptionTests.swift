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

        // A read written into the same call as the answer was decided before the answer was seen.
        let sameCall = [AdoptionSample(act: .sextant, shape: nil, call: "1"),
                        AdoptionSample(act: .fileRead, shape: .path, call: "1")]
        #expect(Adoption.readsAfterAnswers(in: sameCall) == 0)
        let nextCall = [AdoptionSample(act: .sextant, shape: nil, call: "1"),
                        AdoptionSample(act: .fileRead, shape: .path, call: "2")]
        #expect(Adoption.readsAfterAnswers(in: nextCall) == 1)
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

    /// A session started in a worktree is kept by the client under the worktree's own slug; read
    /// from the root alone, the transcripts missed most of a repository that is worked on in
    /// worktrees, while the live log saw all of it.
    @Test("Transcripts are gathered for the whole repository, worktrees included")
    func gathersWorktreeTranscripts() throws {
        let repository = try TemporaryRepository()
        defer { repository.remove() }
        let projects = repository.root.deletingLastPathComponent().appendingPathComponent("projects")
        func session(in directory: String, cwd: String) throws {
            let folder = projects.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let record = String(decoding: try JSONSerialization.data(withJSONObject: ["cwd": cwd, "type": "user"]), as: UTF8.self)
            try record.write(to: folder.appendingPathComponent("\(UUID().uuidString).jsonl"), atomically: true, encoding: .utf8)
        }
        let main = repository.root.resolvingSymlinksInPath().path
        let worktree = main + "/.claude/worktrees/feature"
        try session(in: Adoption.slug(main), cwd: main)
        try session(in: Adoption.slug(main) + "-Sources", cwd: main + "/Sources")
        try session(in: Adoption.slug(worktree), cwd: worktree)
        // A sibling whose slug happens to extend ours, and is another directory.
        try session(in: Adoption.slug(main) + "-old", cwd: main + "-old")

        #expect(Adoption.transcripts(forProjectRoot: main, in: projects).count == 3)
        // Asked from a linked worktree, the repository — and so the answer — is the same.
        #expect(Adoption.transcripts(forProjectRoot: repository.worktree.path, in: projects).count == 3)
    }

    @Test("Subagent transcripts are read however deep the client files them")
    func readsNestedSubagents() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-sub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let session = base.appendingPathComponent("s.jsonl")
        let nested = base.appendingPathComponent("s/subagents/workflows/wf_1")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "".write(to: session, atomically: true, encoding: .utf8)
        try "".write(to: base.appendingPathComponent("s/subagents/agent-a.jsonl"), atomically: true, encoding: .utf8)
        try "".write(to: nested.appendingPathComponent("agent-b.jsonl"), atomically: true, encoding: .utf8)
        #expect(Adoption.subagentTranscripts(of: session).map(\.lastPathComponent) == ["agent-a.jsonl", "agent-b.jsonl"])
    }

    @Test("The transcript directory is named the way the client names it")
    func slugMatchesTheClient() {
        #expect(Adoption.slug("/Users/a/PSBR-1_Screen Part5/app.x") == "-Users-a-PSBR-1-Screen-Part5-app-x")
        #expect(Adoption.slug("/Users/a/Проект") == "-Users-a-------")
    }

    /// Working on sextant itself, most "answers" were runs of a fresh build against fixtures and
    /// scratch directories — testing the tool, not navigating this repository.
    @Test("A sextant call about another repository is not navigation of this one")
    func callsAboutOtherProjects() throws {
        let repository = try TemporaryRepository()
        defer { repository.remove() }
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let main = repository.root.path
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let calls = ["sextant refs A --project \(elsewhere.path)", "sextant refs B --project Sources/Core",
                     "sextant refs C", "sextant search 'x' | head; grep -rn x Sources",
                     "cd \(elsewhere.path) && sextant refs D --project .", "D=\(elsewhere.path); sextant refs E --project $D"]
        let lines = try calls.map { command -> String in
            let record: [String: Any] = ["cwd": main, "message": ["content": [
                ["type": "tool_use", "name": "Bash", "input": ["command": command]]]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let samples = Adoption.samples(inTranscript: file)
        // The calls about another directory are gone; one inside this repository stays.
        #expect(samples.filter { $0.act == .sextant }.count == 3)
        #expect(samples.filter(\.crossChecked).count == 1)
        #expect(samples.filter { $0.act == .textSearch }.count == 1)

        // So is a search made after moving into another project.
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-m-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: moved) }
        let record: [String: Any] = ["cwd": main, "message": ["content": [
            ["type": "tool_use", "name": "Bash", "input": ["command": "cd \(elsewhere.path) && grep -rn X Sources"]],
            ["type": "tool_use", "name": "Bash", "input": ["command": "cd Sources && grep -rn Y ."]]]]]
        try String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
            .write(to: moved, atomically: true, encoding: .utf8)
        #expect(Adoption.samples(inTranscript: moved).filter { $0.act == .textSearch }.count == 1)
    }

    @Test("A subdirectory is the same project, inside a repository or outside any")
    func subdirectoriesBelong() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("LocalPackages/Kit"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(Adoption.isWithinProject("LocalPackages/Kit", of: plain.path))
        #expect(Adoption.isWithinProject(plain.path + "/LocalPackages", of: plain.path))
        #expect(!Adoption.isWithinProject("/somewhere/else", of: plain.path))
        #expect(!Adoption.isWithinProject("..", of: plain.path))

        let repository = try TemporaryRepository()
        defer { repository.remove() }
        #expect(Adoption.isWithinProject(repository.worktree.path, of: repository.root.appendingPathComponent("Sources").path))
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
        // The log lives at a fixed path; this checks what would be written, rather than appending
        // to the user's real file.
        let entry = AdoptionLog.entry(act: .textSearch, shape: .identifier, channel: nil, session: "s-1", agent: nil,
                                      projectRoot: "/Users/someone/Secret Project", timestamp: 1_700_000_000)
        let line = String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self)
        #expect(!line.contains("Secret"))
        #expect(!line.contains("/Users"))
        #expect(line.contains("textSearch") && line.contains("identifier"))
        #expect(entry["v"] as? Int == AdoptionLog.schemaVersion)
        #expect(entry["session"] as? String == "s-1")
        // A channel belongs to a sextant answer only; an absent agent is the main conversation.
        #expect(entry["via"] == nil)
        #expect(entry["agent"] == nil)

        let answer = AdoptionLog.entry(act: .sextant, shape: nil, channel: .mcp, session: "s-1", agent: "a-7",
                                       projectRoot: "/p", timestamp: 1)
        #expect(answer["via"] as? String == "mcp")
        #expect(answer["agent"] as? String == "a-7")
        #expect(answer["checked"] == nil)
        let checked = AdoptionLog.entry(act: .sextant, shape: nil, channel: .cli, crossChecked: true,
                                        session: "s-1", agent: nil, projectRoot: "/p", timestamp: 1)
        #expect(checked["checked"] as? Int == 1)
        let key = AdoptionLog.projectKey(forRoot: "/p")
        let contents = [self.line(checked), self.line(answer)].joined(separator: "\n")
        #expect(AdoptionLog.report(forProjectKey: key, in: contents).crossCheckedAnswers == 1)
    }

    private func line(_ entry: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self)
    }

    private func entry(_ act: NavigationAct, _ channel: NavigationChannel? = nil, session: String,
                       agent: String? = nil, project: String = "/p") -> String {
        line(AdoptionLog.entry(act: act, shape: act == .textSearch ? .identifier : nil, channel: channel,
                               session: session, agent: agent, projectRoot: project, timestamp: 1))
    }

    @Test("The report counts sessions, splits the channels, and leaves the earlier format out")
    func readsTheCurrentFormat() {
        let key = AdoptionLog.projectKey(forRoot: "/p")
        // The first format, as it was written for months: no version, no session.
        let legacy = line(["ts": 1, "project": key, "act": "sextant", "shape": "path"])
        let contents = [
            legacy, legacy,
            entry(.sextant, .mcp, session: "one"),
            entry(.textSearch, session: "one"),
            entry(.sextant, .cli, session: "two"),
            entry(.fileRead, session: "two"),
            entry(.textSearch, session: "two", project: "/elsewhere"),
            "not json at all"
        ].joined(separator: "\n")

        let report = AdoptionLog.report(forProjectKey: key, in: contents)
        #expect(report.sessions == 2)
        #expect(report.sextant == 2)
        #expect(report.throughMCP == 1)
        #expect(report.throughCLI == 1)
        #expect(report.textSearch == 1)          // the other project's search is not ours
        #expect(report.fileRead == 1)
        #expect(report.legacyRecords == 2)       // counted apart, never added
        #expect(report.residue[.identifier] == 1)
    }

    @Test("Lines of the first format are found under every directory of the project, and a later format is skipped")
    func findsLegacyLinesOfWorktrees() {
        let key = AdoptionLog.projectKey(forRoot: "/p")
        let worktree = AdoptionLog.legacyKey(forDirectory: "/p/.claude/worktrees/w")
        let contents = [
            line(["ts": 1, "project": worktree, "act": "textSearch", "shape": "identifier"]),
            line(["ts": 1, "project": AdoptionLog.legacyKey(forDirectory: "/q"), "act": "textSearch", "shape": ""]),
            line(["v": AdoptionLog.schemaVersion + 1, "ts": 1, "project": key, "act": "sextant", "shape": ""]),
            entry(.textSearch, session: "one"),
        ].joined(separator: "\n")
        let report = AdoptionLog.report(forProjectKey: key, legacyKeys: [worktree], in: contents)
        #expect(report.legacyRecords == 1)       // the worktree's, not the other project's
        #expect(report.navigation == 1)          // the later format is neither counted nor legacy
    }

    /// Sessions run side by side and their hook lines interleave in the file. Read in file order,
    /// one session's read would be taken for the follow-up of another session's answer.
    @Test("An answer is followed by a read only within its own session and agent")
    func followUpsDoNotCrossSessions() {
        let key = AdoptionLog.projectKey(forRoot: "/p")
        let contents = [
            entry(.sextant, .mcp, session: "one"),
            entry(.fileRead, session: "two"),             // another session's read
            entry(.sextant, .cli, session: "two", agent: "sub"),
            entry(.fileRead, session: "two"),             // the parent's read, not the subagent's
            entry(.fileRead, session: "one"),             // the real follow-up of the first answer
        ].joined(separator: "\n")
        #expect(AdoptionLog.report(forProjectKey: key, in: contents).readAfterSextant == 1)
    }

    @Test("Every worktree and subdirectory of a repository is one project")
    func projectKeyIsTheRepository() throws {
        let main = try TemporaryRepository()
        defer { main.remove() }
        let key = AdoptionLog.projectKey(forRoot: main.root.path)
        #expect(AdoptionLog.projectKey(forRoot: main.root.appendingPathComponent("Sources/Core").path) == key)
        #expect(AdoptionLog.projectKey(forRoot: main.worktree.path) == key)
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
