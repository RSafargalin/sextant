import Darwin
import Foundation

/// The live half of the adoption signal: one line per navigation act, written as it happens.
///
/// The transcripts already hold this, so the log is not there to duplicate them. It is there
/// because it is written at the moment of the decision — which is the point a later version can
/// answer "sextant can tell you that" instead of merely counting the grep — and because it does
/// not depend on a transcript format staying what it is.
///
/// What it never contains: the query, the command, the file path, the project path. A line is a
/// timestamp, a hash of the project's repository root, an act, a shape, the channel of a sextant
/// answer, and the client's session, subagent and tool-call identifiers. The log alone says what kinds of
/// question went where, and nothing about the code or the conversation. On the same machine a
/// session identifier is also the name of that session's transcript, which the client files under
/// the project's path — so whoever can read the transcripts can tell which project a line is about.
public enum AdoptionLog {
    /// The format of a line. Lines without a version are the first format, which counted a word
    /// `sextant` anywhere in a command — a path included — as a call, counted a `grep` filtering
    /// a pipe as a search of the sources, and keyed a project by the directory the session stood in.
    /// They are not added to lines of this format.
    public static let schemaVersion = 2

    public static func path() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sextant/adoption.jsonl")
    }

    /// A project is identified by a hash of its repository root, so the log by itself cannot be read
    /// back into a list of what someone works on, and every worktree and subdirectory of a
    /// repository is one project.
    public static func projectKey(forRoot root: String) -> String {
        String(ContentHash.of(RepositoryRoot.of(root)).prefix(12))
    }

    /// The line written for one act.
    static func entry(act: NavigationAct, shape: QueryShape?, channel: NavigationChannel?, crossChecked: Bool = false,
                      session: String?, agent: String?, call: String? = nil, projectRoot: String,
                      timestamp: Double) -> [String: Any] {
        var entry: [String: Any] = [
            "v": schemaVersion,
            "ts": Int(timestamp.rounded()),
            "project": projectKey(forRoot: projectRoot),
            "act": act.rawValue,
            "shape": shape?.rawValue ?? ""
        ]
        if act == .sextant, let channel { entry["via"] = channel.rawValue }
        if act == .sextant, crossChecked { entry["checked"] = 1 }
        if let session, !session.isEmpty { entry["session"] = session }
        if let agent, !agent.isEmpty { entry["agent"] = agent }
        if let call, !call.isEmpty { entry["call"] = call }
        return entry
    }

    /// Appends one act. Silent on every failure: a metric must never take a session down with it.
    public static func record(act: NavigationAct, shape: QueryShape?, channel: NavigationChannel?, crossChecked: Bool = false,
                              session: String?, agent: String?, call: String? = nil, projectRoot: String, timestamp: Double) {
        let entry = entry(act: act, shape: shape, channel: channel, crossChecked: crossChecked,
                          session: session, agent: agent, call: call, projectRoot: projectRoot, timestamp: timestamp)
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let file = path()
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Written 0600 and appended atomically, the way the telemetry log is: concurrent hooks
        // must not tear each other's lines apart, and no other user needs to read this.
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
    }

    /// When the hook last wrote anything, for any project. A hook that is registered and silent is
    /// the failure this answers: it looks installed and records nothing.
    public static func lastRecordedAt() -> Date? {
        guard let contents = try? String(contentsOf: path(), encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stamp = entry["ts"] as? Int else { continue }
            return Date(timeIntervalSince1970: TimeInterval(stamp))
        }
        return nil
    }

    /// Reads back what was logged for one project. Lines of the first format were keyed by the
    /// directory a session stood in, so the directories known to belong to the project — the root,
    /// its worktrees under `.claude/worktrees`, the directories the given transcripts were recorded
    /// in — are looked up too, and their lines counted apart.
    public static func report(forProjectRoot root: String, transcripts: [URL] = []) -> AdoptionReport {
        let contents = (try? String(contentsOf: path(), encoding: .utf8)) ?? ""
        let repository = RepositoryRoot.of(root)
        let worktrees = URL(fileURLWithPath: repository).appendingPathComponent(".claude/worktrees")
        let directories = [root, repository]
            + ((try? FileManager.default.contentsOfDirectory(atPath: worktrees.path)) ?? []).map { worktrees.appendingPathComponent($0).path }
            + transcripts.compactMap(Adoption.workingDirectory(ofTranscript:))
        let legacyKeys = Set(directories.map(legacyKey(forDirectory:)))
        return report(forProjectKey: projectKey(forRoot: root), legacyKeys: legacyKeys, in: contents)
    }

    /// The key the first format gave a directory: a hash of the directory itself.
    static func legacyKey(forDirectory directory: String) -> String {
        let canonical = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        return String(ContentHash.of(canonical).prefix(12))
    }

    /// The report for one project out of the log's contents. Only lines of the current format are
    /// counted; lines of an earlier one under `key` or `legacyKeys` are counted apart, as
    /// `legacyRecords`, and lines of a later one are skipped. Sessions are told apart by their
    /// identifier, and an answer followed by a read is looked for within one session and one agent,
    /// in the order the lines were written.
    static func report(forProjectKey key: String, legacyKeys: Set<String> = [], in contents: String) -> AdoptionReport {
        var counts: [NavigationAct: Int] = [:]
        var residue: [QueryShape: Int] = [:]
        var throughMCP = 0
        var crossChecked = 0
        var legacy = 0
        var sessions = Set<String>()
        var sequences: [String: [AdoptionSample]] = [:]

        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let project = entry["project"] as? String else { continue }
            let version = entry["v"] as? Int ?? 1
            if version < schemaVersion {
                if project == key || legacyKeys.contains(project) { legacy += 1 }
                continue
            }
            guard version == schemaVersion, project == key else { continue }
            guard let act = (entry["act"] as? String).flatMap(NavigationAct.init(rawValue:)) else { continue }
            let shape = (entry["shape"] as? String).flatMap(QueryShape.init(rawValue:))
            counts[act, default: 0] += 1
            if act == .textSearch, let shape { residue[shape, default: 0] += 1 }
            if act == .sextant, entry["via"] as? String == NavigationChannel.mcp.rawValue { throughMCP += 1 }
            if act == .sextant, entry["checked"] as? Int == 1 { crossChecked += 1 }

            let session = entry["session"] as? String ?? ""
            if !session.isEmpty { sessions.insert(session) }
            sequences["\(session)\u{0}\(entry["agent"] as? String ?? "")", default: []]
                .append(AdoptionSample(act: act, shape: shape, call: entry["call"] as? String))
        }
        var report = AdoptionReport(sessions: sessions.count, sextant: counts[.sextant] ?? 0,
                                    textSearch: counts[.textSearch] ?? 0, fileRead: counts[.fileRead] ?? 0,
                                    residue: residue, queries: [])
        report.throughMCP = throughMCP
        report.crossCheckedAnswers = crossChecked
        report.legacyRecords = legacy
        report.readAfterSextant = sequences.values.reduce(0) { $0 + Adoption.readsAfterAnswers(in: $1) }
        return report
    }

    /// What a client has to be told to send events here. Printed rather than written: installing a
    /// hook edits the user's own configuration, and that is their call to make.
    public static func installationSnippet(binaryPath: String) -> String {
        """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "*",
                "hooks": [{ "type": "command", "command": "\(binaryPath) hook" }]
              }
            ]
          }
        }
        """
    }
}
