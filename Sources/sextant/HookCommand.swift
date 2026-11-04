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

    // The project is the repository the session stands in, whichever worktree or subdirectory —
    // or, for an act the line moved elsewhere, the project it was about.
    let cwd = (event["cwd"] as? String) ?? projectRoot(in: arguments)
    let now = Date().timeIntervalSince1970
    for act in NavigationAct.events(tool: tool, input: event["tool_input"] as? [String: Any]) {
        AdoptionLog.record(act: act.act, shape: act.shape, channel: act.channel, crossChecked: act.crossChecked,
                           session: event["session_id"] as? String, agent: event["agent_id"] as? String,
                           call: event["tool_use_id"] as? String,
                           projectRoot: act.project.flatMap { Adoption.isWithinProject($0, of: cwd) ? nil : Adoption.resolve($0, from: cwd) } ?? cwd,
                           timestamp: now)
    }
    return 0
}

private func printHookInstallation() -> Int32 {
    // The same resolver `init` uses for the MCP registration. argv[0] is not it: launched through
    // PATH it is the bare name `sextant`, which resolves against the current directory — so the
    // snippet named a file that does not exist (`/Users/…/tea/sextant hook` when run in tea), and
    // a hook that names a missing binary records nothing while looking installed.
    let binary = executablePath()
    print("""
    Add this to .claude/settings.json (or the user-level settings) to record navigation live:

    \(AdoptionLog.installationSnippet(binaryPath: binary))

    What gets written to \(AdoptionLog.path().path):
      a timestamp, a hash of the repository root, the kind of act, the shape of the query,
      MCP or CLI for a sextant answer, and the client's session, subagent and tool-call
      identifiers.
    Not the query, not the command, not the file path, not the project path. The session
    identifier is also the name of that session's transcript, so anyone who can read your
    transcripts can tell which project a line is about. Nothing is sent anywhere. Delete the
    file to erase it; remove the hook to stop it.
    """)
    return 0
}
