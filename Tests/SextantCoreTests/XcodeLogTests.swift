import Foundation
import Testing
@testable import SextantCore

/// Xcode states the compile flags in one place only: its build log, escaped for a shell and with
/// most of them behind a response file. These cover reading them back — the fragile half of the
/// C-family layer, and the half a fixture cannot exercise.
@Suite("Xcode build log")
struct XcodeLogTests {
    @Test("Words are split the way a shell would")
    func splitsLikeAShell() {
        // Xcode escapes `=` in its log and quotes flags in response files.
        #expect(ShellWords.split("clang -fmessage-length\\=0 -x objective-c")
                == ["clang", "-fmessage-length=0", "-x", "objective-c"])
        #expect(ShellWords.split("'-std=gnu11' -fobjc-arc '-DFOO=bar baz'")
                == ["-std=gnu11", "-fobjc-arc", "-DFOO=bar baz"])
        #expect(ShellWords.split("-I \"/My Path/include\"") == ["-I", "/My Path/include"])
        // A path with a space is escaped, not quoted, in a CompileC line.
        #expect(ShellWords.split("/Demo/My\\ App/main.m") == ["/Demo/My App/main.m"])
        #expect(ShellWords.split("   ") == [])
    }

    @Test("A response file is expanded, because most flags live there")
    func expandsResponseFiles() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-resp-\(UUID().uuidString).resp")
        defer { try? FileManager.default.removeItem(at: file) }
        try "'-std=gnu11' -fobjc-arc '-fmodule-name=SDWebImage'".write(to: file, atomically: true, encoding: .utf8)

        let expanded = ShellWords.expandingResponseFiles(["-x", "objective-c", "@\(file.path)", "-g"])
        #expect(expanded == ["-x", "objective-c", "-std=gnu11", "-fobjc-arc", "-fmodule-name=SDWebImage", "-g"])
        // A response file that does not exist stays as it is, rather than vanishing silently.
        #expect(ShellWords.expandingResponseFiles(["@/nowhere.resp"]) == ["@/nowhere.resp"])
    }

    /// A shortened `CompileC` block in Xcode's own shape, including a path with a space.
    private func log(responseFile: String) -> String {
        """
        Build description signature: 5149a4fbc7e9c87f
        CompileC /DerivedData/Build/Objects-normal/x86_64/My\\ Cache.o /Demo/My\\ App/My\\ Cache.m normal x86_64 objective-c com.apple.compilers.llvm.clang.1_0.compiler (in target 'App' from project 'App')
            cd /Demo/My\\ App

            Using response file: \(responseFile)

            /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -x objective-c -target x86_64-apple-macos10.11 -fmessage-length\\=0 @\(responseFile) -c /Demo/My\\ App/My\\ Cache.m -o /DerivedData/Build/Objects-normal/x86_64/My\\ Cache.o

        CompileSwift normal x86_64 /Demo/Other.swift
            /usr/bin/swiftc -module-name Other /Demo/Other.swift
        """
    }

    @Test("A CompileC block yields the file, its directory and the whole flag set")
    func readsCompileBlocks() throws {
        let responseFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-log-\(UUID().uuidString).resp")
        defer { try? FileManager.default.removeItem(at: responseFile) }
        try "'-std=gnu11' -fobjc-arc".write(to: responseFile, atomically: true, encoding: .utf8)

        let commands = CompilationDatabase.commands(inXcodeLog: log(responseFile: responseFile.path))
        // Only the Objective-C compile is one: a Swift compile is not this layer's business.
        #expect(commands.count == 1)
        let command = try #require(commands.first)
        #expect(command.file == "/Demo/My App/My Cache.m")
        #expect(command.directory == "/Demo/My App")
        #expect(CompilationDatabase.target(of: command) == "x86_64-apple-macos10.11")

        let arguments = CompilationDatabase.parseArguments(of: command)
        #expect(arguments.contains("-fmessage-length=0"))     // unescaped
        #expect(arguments.contains("-std=gnu11"))             // from the response file
        #expect(arguments.contains("-fobjc-arc"))
        #expect(!arguments.contains("-c"))                    // build-only bookkeeping is dropped
        #expect(!arguments.contains(command.file))
    }

    @Test("A log with no compile blocks yields nothing rather than a guess")
    func emptyLog() {
        #expect(CompilationDatabase.commands(inXcodeLog: "** BUILD SUCCEEDED **").isEmpty)
    }

    @Test("A fresh capture merges with what was known, and drops files that are gone")
    func mergeKeepsWhatIsStillThere() {
        let existing = [
            CompileCommand(directory: "/p", file: "/p/gone.m", arguments: ["clang"]),
            CompileCommand(directory: "/p", file: #filePath, arguments: ["clang", "-old"])
        ]
        let fresh = [CompileCommand(directory: "/p", file: #filePath, arguments: ["clang", "-new"])]
        let merged = CompilationDatabase.merge(existing: existing, fresh: fresh)
        // One build covers one scheme, so the rest of the project must survive the next one —
        // but an entry whose file no longer exists is not worth keeping.
        #expect(merged.count == 1)
        #expect(merged.first?.arguments.contains("-new") == true)
    }
}
