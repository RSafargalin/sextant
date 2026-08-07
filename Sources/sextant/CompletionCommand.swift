import SextantCore
import Foundation

/// `sextant completion zsh|bash` — the script on stdout and nothing else, so it can be redirected
/// straight into a file. Anything explanatory goes to stderr or it would corrupt the script.
func runCompletion(arguments: [String]) -> Int32 {
    guard let name = firstPositional(arguments) else {
        reportError("sextant completion: expected a shell — \(CompletionScript.Shell.allCases.map { $0.rawValue }.joined(separator: " or ")).")
        return 2
    }
    guard let shell = CompletionScript.Shell(rawValue: name) else {
        reportError("sextant completion: unknown shell '\(name)'. Supported: \(CompletionScript.Shell.allCases.map { $0.rawValue }.joined(separator: ", ")).")
        return 2
    }
    print(CompletionScript.script(for: shell))
    return 0
}
