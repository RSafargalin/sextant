import Foundation

/// One navigation act, reduced to what a metric needs.
public struct AdoptionSample: Sendable {
    public let act: NavigationAct
    /// The shape of the query, when there was one. The query itself is not kept.
    public let shape: QueryShape?
    /// The query text — present ONLY when the caller explicitly asked to keep it.
    public let query: String?
    /// For a sextant answer: whether it was asked over MCP or on the command line.
    public let channel: NavigationChannel?
    /// For a sextant answer: the same call also searched the sources.
    public let crossChecked: Bool
    /// The tool call the act came from, when known. Acts of one call were decided together, before
    /// any of them was answered.
    public let call: String?

    public init(act: NavigationAct, shape: QueryShape?, query: String? = nil, channel: NavigationChannel? = nil,
                crossChecked: Bool = false, call: String? = nil) {
        self.act = act
        self.shape = shape
        self.query = query
        self.channel = channel
        self.crossChecked = crossChecked
        self.call = call
    }
}

/// How much of the code navigation in a project went through sextant.
public struct AdoptionReport: Sendable {
    public let sessions: Int
    public let sextant: Int
    public let textSearch: Int
    public let fileRead: Int
    /// Shapes of the queries that went past sextant — what to fix, in categories rather than text.
    public let residue: [QueryShape: Int]
    /// Queries kept verbatim, when the caller asked for them; empty otherwise.
    public let queries: [String]
    /// Answers of ours after which the very next navigation act was opening a file.
    ///
    /// It measures adjacency, not identity: the transcript is read for tool *calls*, so which file
    /// was opened cannot be compared with which file we named. Read as "the answer was a step, not
    /// an end" — and as the first place to look for what our answers leave out. On another tool
    /// with the same shape of question, the same follow-up ran at 18.4 %, and four fifths of those
    /// already had the declaration in hand and were reaching for the lines around it.
    public var readAfterSextant: Int = 0
    /// Of `sextant`, the answers asked over MCP; the rest came from the command line.
    public var throughMCP: Int = 0
    /// Of `sextant`, the answers whose call also searched the sources — checked by grep, or not
    /// enough on their own.
    public var crossCheckedAnswers: Int = 0
    /// Lines of an earlier log format for the same project, left out of every count above.
    public var legacyRecords: Int = 0

    public var throughCLI: Int { sextant - throughMCP }

    /// Nothing read, nothing counted.
    public static let empty = AdoptionReport(sessions: 0, sextant: 0, textSearch: 0, fileRead: 0, residue: [:], queries: [])

    /// Acts that sextant could have answered.
    public var navigation: Int { sextant + textSearch + fileRead }

    /// The share, or nil when nothing navigational happened — a session that only built and
    /// edited says nothing about adoption, and 0/0 rendered as 0% would be a lie about it.
    public var share: Double? {
        navigation == 0 ? nil : Double(sextant) / Double(navigation)
    }
}

/// Reading the metric out of the sessions that already happened.
///
/// The denominator lives in the client's transcripts, because the searches that went past sextant
/// are by definition invisible to it. Only two fields of each record are ever looked at — the
/// tool's name and its query — and the query is reduced to a shape immediately. Nothing is sent
/// anywhere; a transcript is a conversation, and this reads it the way a counter reads a turnstile.
public enum Adoption {
    /// Claude Code stores a project's sessions under a slug of the path (see `slug`). That is a
    /// convention of the client, not a contract, so a missing directory is reported rather than
    /// counted as "no sessions".
    public static func transcriptDirectory(forProjectRoot root: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug(RepositoryRoot.of(root)))")
    }

    /// Sessions of the whole repository the root belongs to: the root's own directory, and every
    /// directory whose slug extends it — worktrees under `.claude/worktrees`, subdirectories — whose
    /// sessions stood inside the same repository. A slug is lossy (`a-b` may be `a/b` or `a.b`), so a
    /// candidate is admitted by the `cwd` its first record names, never by its name alone.
    public static func transcripts(forProjectRoot root: String, in projects: URL? = nil) -> [URL] {
        let repository = RepositoryRoot.of(root)
        let projects = projects ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let own = slug(repository)
        let candidates = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return candidates
            .filter { $0.lastPathComponent == own || $0.lastPathComponent.hasPrefix(own + "-") }
            .flatMap { directory -> [URL] in
                let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "jsonl" }
                guard directory.lastPathComponent != own else { return files }
                return files.filter { file in
                    workingDirectory(ofTranscript: file).map { RepositoryRoot.of($0) == repository } ?? false
                }
            }
            .sorted { $0.path < $1.path }
    }

    /// The client's directory name for a path: every character that is not an ASCII letter or digit
    /// becomes `-`.
    static func slug(_ path: String) -> String {
        String(URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path.map {
            $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-"
        })
    }

    /// The `cwd` of the first record that names one, read from the start of the file only.
    static func workingDirectory(ofTranscript url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256 * 1024) else { return nil }
        for line in head.split(separator: 0x0A) {
            if let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let cwd = record["cwd"] as? String {
                return cwd
            }
        }
        return nil
    }

    /// Transcripts of the subagents a session ran, kept by the client under `<session>/subagents/`,
    /// workflow agents a level deeper. Their calls are the session's work, so they are counted;
    /// each is its own sequence, since a subagent's calls are not interleaved with its parent's.
    public static func subagentTranscripts(of session: URL) -> [URL] {
        let directory = session.deletingPathExtension().appendingPathComponent("subagents")
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
    }

    /// Samples from one transcript. Records are read one line at a time and nothing but the tool's
    /// name, its one query field and the record's `cwd` is retained, so the conversation never
    /// exists in memory as a whole. An act about another project than `projectRoot` — the session's
    /// own directory when none is given — (a `cd`, or sextant's `--project`, elsewhere) is not
    /// navigation of this one, and is left out.
    public static func samples(inTranscript url: URL, keepingQueries: Bool = false,
                               projectRoot: String? = nil) -> [AdoptionSample] {
        guard let handle = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var samples: [AdoptionSample] = []
        var sessionDirectory: String?
        var calls = 0
        for line in handle.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = record["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            let cwd = record["cwd"] as? String
            if sessionDirectory == nil { sessionDirectory = cwd }
            for block in blocks where (block["type"] as? String) == "tool_use" {
                guard let tool = block["name"] as? String else { continue }
                calls += 1
                for event in NavigationAct.events(tool: tool, input: block["input"] as? [String: Any]) {
                    if let cwd, let base = projectRoot ?? sessionDirectory, let project = event.project,
                       !isWithinProject(resolve(project, from: cwd), of: base) { continue }
                    samples.append(AdoptionSample(
                        act: event.act,
                        shape: event.shape,
                        query: keepingQueries ? event.searched : nil,
                        channel: event.channel,
                        crossChecked: event.crossChecked,
                        call: String(calls)
                    ))
                }
            }
        }
        return samples
    }

    /// A path as a shell standing in `directory` reads it: absolute as is, `~` from home, otherwise
    /// relative to the directory.
    public static func resolve(_ path: String, from directory: String) -> String {
        if path.hasPrefix("/") { return path }
        if path == "~" || path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
        }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL.path
    }

    /// Whether `path` is about the same project as `directory`: inside the root of `directory`'s
    /// project — its repository, or the directory itself outside any repository; a repository
    /// nested inside counts as part of it — or in another worktree of the same repository. A
    /// relative path is taken from `directory`.
    public static func isWithinProject(_ path: String, of directory: String) -> Bool {
        let canonical = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        let root = canonical(RepositoryRoot.of(directory))
        let target = canonical(resolve(path, from: directory))
        return target == root || target.hasPrefix(root + "/") || RepositoryRoot.of(target) == root
    }

    /// How many of our answers were followed straight away by opening a file.
    ///
    /// Counted inside one session and only when the read is the very next navigational act:
    /// anything looser stops being about that answer. It cannot tell whether the file opened is the
    /// file we named — the transcript records calls, not results — so it is an upper bound on
    /// "the answer was not enough" and a lower bound on nothing.
    public static func readsAfterAnswers(in session: [AdoptionSample]) -> Int {
        zip(session, session.dropFirst()).count { answer, next in
            answer.act == .sextant && next.act == .fileRead && (answer.call == nil || answer.call != next.call)
        }
    }

    public static func report(forProjectRoot root: String, keepingQueries: Bool = false) -> AdoptionReport {
        let files = transcripts(forProjectRoot: root)
        var counts: [NavigationAct: Int] = [:]
        var residue: [QueryShape: Int] = [:]
        var queries: [String] = []

        var readAfterSextant = 0
        var throughMCP = 0
        var crossChecked = 0

        for file in files.flatMap({ [$0] + subagentTranscripts(of: $0) }) {
            let session = samples(inTranscript: file, keepingQueries: keepingQueries, projectRoot: root)
            readAfterSextant += readsAfterAnswers(in: session)
            for sample in session {
                counts[sample.act, default: 0] += 1
                if sample.channel == .mcp { throughMCP += 1 }
                if sample.crossChecked { crossChecked += 1 }
                guard sample.act == .textSearch else { continue }
                if let shape = sample.shape { residue[shape, default: 0] += 1 }
                if let query = sample.query { queries.append(query) }
            }
        }
        var report = AdoptionReport(
            sessions: files.count,
            sextant: counts[.sextant] ?? 0,
            textSearch: counts[.textSearch] ?? 0,
            fileRead: counts[.fileRead] ?? 0,
            residue: residue,
            queries: queries
        )
        report.readAfterSextant = readAfterSextant
        report.throughMCP = throughMCP
        report.crossCheckedAnswers = crossChecked
        return report
    }
}
