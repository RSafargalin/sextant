import Foundation

/// One navigation act, reduced to what a metric needs.
public struct AdoptionSample: Sendable {
    public let act: NavigationAct
    /// The shape of the query, when there was one. The query itself is not kept.
    public let shape: QueryShape?
    /// The query text — present ONLY when the caller explicitly asked to keep it.
    public let query: String?

    public init(act: NavigationAct, shape: QueryShape?, query: String? = nil) {
        self.act = act
        self.shape = shape
        self.query = query
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
    /// Claude Code stores a project's sessions under a slug: the path with `/` and `.` replaced
    /// by `-`. That is a convention of the client, not a contract, so a missing directory is
    /// reported rather than counted as "no sessions".
    public static func transcriptDirectory(forProjectRoot root: String) -> URL {
        let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let slug = canonical
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)")
    }

    public static func transcripts(forProjectRoot root: String) -> [URL] {
        let directory = transcriptDirectory(forProjectRoot: root)
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
    }

    /// Samples from one transcript. Records are read one line at a time and nothing but the two
    /// fields is retained, so the conversation never exists in memory as a whole.
    public static func samples(inTranscript url: URL, keepingQueries: Bool = false) -> [AdoptionSample] {
        guard let handle = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var samples: [AdoptionSample] = []
        for line in handle.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = record["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks where (block["type"] as? String) == "tool_use" {
                guard let tool = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any]
                let query = queryText(tool: tool, input: input)
                let act = NavigationAct.of(tool: tool, command: query)
                guard act != .other else { continue }
                // For a shell search the query is the pattern, not the command line around it.
                let searched = (tool == "Bash" && act == .textSearch)
                    ? query.flatMap(NavigationAct.searchPattern(inShellCommand:))
                    : query
                samples.append(AdoptionSample(
                    act: act,
                    shape: searched.map(QueryShape.of),
                    query: keepingQueries ? searched : nil
                ))
            }
        }
        return samples
    }

    /// The one field a tool call is asked for. Anything else in the input — file contents, an
    /// edit's replacement text, a prompt — is never read.
    private static func queryText(tool: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        switch tool {
        case "Grep", "Glob": return input["pattern"] as? String
        case "Read": return input["file_path"] as? String
        case "Bash": return input["command"] as? String
        default: return nil
        }
    }

    public static func report(forProjectRoot root: String, keepingQueries: Bool = false) -> AdoptionReport {
        let files = transcripts(forProjectRoot: root)
        var counts: [NavigationAct: Int] = [:]
        var residue: [QueryShape: Int] = [:]
        var queries: [String] = []

        for file in files {
            for sample in samples(inTranscript: file, keepingQueries: keepingQueries) {
                counts[sample.act, default: 0] += 1
                guard sample.act == .textSearch else { continue }
                if let shape = sample.shape { residue[shape, default: 0] += 1 }
                if let query = sample.query { queries.append(query) }
            }
        }
        return AdoptionReport(
            sessions: files.count,
            sextant: counts[.sextant] ?? 0,
            textSearch: counts[.textSearch] ?? 0,
            fileRead: counts[.fileRead] ?? 0,
            residue: residue,
            queries: queries
        )
    }
}
