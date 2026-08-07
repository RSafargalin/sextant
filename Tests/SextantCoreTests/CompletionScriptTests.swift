import Foundation
import Testing
@testable import SextantCore

/// Completion is generated from the catalog rather than written down, so what needs testing is
/// that the generation stays faithful to it — and that the result is a script the shell accepts.
@Suite("Shell completion")
struct CompletionScriptTests {
    @Test("Every command in the catalog is offered, in both shells")
    func coversEveryCommand() {
        // The point of generating: a command added to the catalog cannot fall out of completion.
        for shell in CompletionScript.Shell.allCases {
            let script = CompletionScript.script(for: shell)
            for command in CommandCatalog.commands {
                #expect(script.contains(command.name), "\(shell.rawValue) does not offer \(command.name)")
            }
        }
    }

    @Test("Flags are offered per command, not as one flat list")
    func flagsArePerCommand() throws {
        let bash = CompletionScript.script(for: .bash)
        let mapLine = try #require(bash.split(separator: "\n").first { $0.contains("    map)") })
        #expect(mapLine.contains("--budget"))          // map's own
        #expect(!mapLine.contains("--symbols"))        // bench's, and no business here

        let benchLine = try #require(bash.split(separator: "\n").first { $0.contains("    bench)") })
        #expect(benchLine.contains("--symbols"))
        #expect(!benchLine.contains("--budget"))
    }

    @Test("A flag that takes a value expects one; a switch does not")
    func valueFlagsConsumeTheirValue() {
        let zsh = CompletionScript.script(for: .zsh)
        // `--json` is a switch: nothing follows it. `--budget` takes a value, so the spec has to
        // say so, or the shell offers the next flag where the value belongs.
        #expect(zsh.contains("'--json[structured output instead of text]'"))
        #expect(zsh.contains("'--budget[") && zsh.contains(":value:"))

        let bash = CompletionScript.script(for: .bash)
        #expect(bash.contains("--budget|") || bash.contains("|--budget"))   // in the value-flag case
    }

    @Test("A path flag completes paths, and a directory flag only directories")
    func pathFlagsCompletePaths() {
        let zsh = CompletionScript.script(for: .zsh)
        #expect(zsh.contains("'--project[project root") && zsh.contains("_files -/"))
        #expect(zsh.contains("'--rules[") && zsh.contains(":value:_files'"))

        let bash = CompletionScript.script(for: .bash)
        #expect(bash.contains("compgen -d"))          // directories for --project and --scope
        #expect(bash.contains("compgen -f"))          // files for --rules and --spec
    }

    /// The real check: a shell parses what was generated. An unescaped `:` or `[` in a future
    /// command summary would produce a script that looks fine and fails on load.
    @Test("The generated script is accepted by the shell itself", arguments: CompletionScript.Shell.allCases)
    func shellsAcceptTheScript(shell: CompletionScript.Shell) throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-completion-\(UUID().uuidString)")
        try CompletionScript.script(for: shell).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [shell.rawValue, "-n", file.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0,
                "\(shell.rawValue) rejected the script: \(String(decoding: output, as: UTF8.self))")
    }
}
