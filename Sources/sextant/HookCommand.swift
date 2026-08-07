import SextantCore
import Foundation

/// `sextant hook` — reads one tool-use event from stdin and records what kind of act it was.
///
/// It runs inside someone else's session, so it holds to two rules. It never fails loudly: a
/// metric that breaks a session is worse than no metric, so every unreadable input ends in exit 0
/// and silence. And it never keeps what it read: the event carries the command and the pattern,
/// and only their classification reaches the disk.
func runHook(arguments: [String]) -> Int32 {
    if arguments.contains("--install") { return printHookInstallation() }

    var input = Data()
    while let line = readLine(strippingNewline: false) { input.append(Data(line.utf8)) }
    guard let event = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          let tool = event["tool_name"] as? String else { return 0 }

    let toolInput = event["tool_input"] as? [String: Any]
    let query = (toolInput?["pattern"] as? String)
        ?? (toolInput?["command"] as? String)
        ?? (toolInput?["file_path"] as? String)
    let act = NavigationAct.of(tool: tool, command: query)
    guard act != .other else { return 0 }

    // A shell search is classified by its pattern, not by the command line carrying it.
    let searched = (tool == "Bash" && act == .textSearch)
        ? query.flatMap(NavigationAct.searchPattern(inShellCommand:))
        : query
    let root = (event["cwd"] as? String) ?? projectRoot(in: arguments)
    AdoptionLog.record(act: act, shape: searched.map(QueryShape.of), projectRoot: root,
                       timestamp: Date().timeIntervalSince1970)
    return 0
}

private func printHookInstallation() -> Int32 {
    let binary = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "sextant"
    print("""
    Add this to .claude/settings.json (or the user-level settings) to record navigation live:

    \(AdoptionLog.installationSnippet(binaryPath: binary))

    What gets written to \(AdoptionLog.path().path):
      a timestamp, a hash of the project root, the kind of act, and the shape of the query.
    Not the query, not the command, not the file path, not the project path. Nothing is sent
    anywhere. Delete the file to erase it; remove the hook to stop it.
    """)
    return 0
}
