import SextantCore
import Darwin
import Foundation

// MARK: - Help

/// Build time of the running binary — it distinguishes builds of the same version
/// (`--version` stays a bare version string: the release workflow checks it).
private func buildStamp() -> String {
    guard let built = (try? launchURL().resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate else { return "" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return " (built \(formatter.string(from: built)))"
}

/// General help is assembled from the command catalog, so the list cannot drift from the
/// actual set of commands and flags. Per-command detail: `sextant <command> --help`.
func printUsage() {
    print("""
    \(Sextant.about)

    Version: \(Sextant.version)\(buildStamp())  •  CLI + MCP server (\(MCPTools.names.count) tools)

    Getting started: `sextant init` — config, MCP server registration, and a setup check.
    \(CommandCatalog.overview())

    Other:
      version                 tool version
      help                    this help

    Detail on a command and its flags: sextant <command> --help
    Defaults come from .sextant.json (budget, scope, maxFiles, rules); both the CLI and MCP honour them.
    Semantic commands report the index source and freshness on stderr. When semantics find
    nothing they degrade to textual occurrences behind an explicit ⚠ marker — those are NOT
    references. Never a confident wrong answer.
    """)
}
