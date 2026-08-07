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
/// timestamp, a hash of the project root, an act and a shape. Reading the log tells you what kinds
/// of question went where, and nothing about the code or the conversation.
public enum AdoptionLog {
    public static func path() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sextant/adoption.jsonl")
    }

    /// A project is identified by a hash of its root, so the log cannot be read back into a list
    /// of what someone works on.
    public static func projectKey(forRoot root: String) -> String {
        let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        return String(ContentHash.of(canonical).prefix(12))
    }

    /// Appends one act. Silent on every failure: a metric must never take a session down with it.
    public static func record(act: NavigationAct, shape: QueryShape?, projectRoot: String, timestamp: Double) {
        let entry: [String: Any] = [
            "ts": Int(timestamp.rounded()),
            "project": projectKey(forRoot: projectRoot),
            "act": act.rawValue,
            "shape": shape?.rawValue ?? ""
        ]
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

    /// Reads back what was logged for one project.
    public static func report(forProjectRoot root: String) -> AdoptionReport {
        guard let contents = try? String(contentsOf: path(), encoding: .utf8) else {
            return AdoptionReport(sessions: 0, sextant: 0, textSearch: 0, fileRead: 0, residue: [:], queries: [])
        }
        let key = projectKey(forRoot: root)
        var counts: [NavigationAct: Int] = [:]
        var residue: [QueryShape: Int] = [:]
        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["project"] as? String == key,
                  let act = (entry["act"] as? String).flatMap(NavigationAct.init(rawValue:)) else { continue }
            counts[act, default: 0] += 1
            if act == .textSearch, let shape = (entry["shape"] as? String).flatMap(QueryShape.init(rawValue:)) {
                residue[shape, default: 0] += 1
            }
        }
        return AdoptionReport(sessions: 0, sextant: counts[.sextant] ?? 0, textSearch: counts[.textSearch] ?? 0,
                              fileRead: counts[.fileRead] ?? 0, residue: residue, queries: [])
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
