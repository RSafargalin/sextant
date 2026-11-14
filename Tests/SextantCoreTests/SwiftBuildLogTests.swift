import Foundation
import Testing
@testable import SextantCore

/// SwiftPM's Swift Build system states the C-family compile flags in one place only: the verbose
/// output of the build. These cover reading them back from it.
@Suite("Verbose SwiftPM build log")
struct SwiftBuildLogTests {
    /// A shortened task list in the shape `swift build -v` prints: a dependency scan, the compile
    /// itself and a link, all of them running clang.
    private func log(responseFile: String) -> String {
        """
        Building for debugging...
        Scan dependencies of Greeter.m
            cd /pkg

            builtin-ScanDependencies -o /pkg/.build/out/Greeter.o.scan -- /toolchain/usr/bin/clang -x objective-c -target arm64-apple-macos12.0 @\(responseFile) -c /pkg/Sources/Greeter/Greeter.m -o /pkg/.build/out/Greeter.o

        Compile Greeter.m (arm64)
            cd /pkg

            Using response file: \(responseFile)

            /toolchain/usr/bin/clang -x objective-c -target arm64-apple-macos12.0 -fmessage-length\\=0 -index-store-path /pkg/.build/out/Products/Debug/index/store @\(responseFile) -MMD -MT dependencies -MF /pkg/.build/out/Greeter.d --serialize-diagnostics /pkg/.build/out/Greeter.dia -c /pkg/Sources/Greeter/Greeter.m -o /pkg/.build/out/Greeter.o -index-unit-output-path /Greeter.o

        Link Greeter.o (arm64)
            cd /pkg
            /toolchain/usr/bin/clang -Xlinker -reproducible -target arm64-apple-macos12.0 -r -o /pkg/.build/out/Products/Debug/Greeter.o
        [3 / 6] Greeter
        Build complete! (1.20 sec)
        """
    }

    @Test("The compile is read, and the scan and the link are not")
    func readsCompileInvocations() throws {
        let responseFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-swiftbuild-\(UUID().uuidString).resp")
        defer { try? FileManager.default.removeItem(at: responseFile) }
        try "-fobjc-arc '-DDEBUG=1' -I/pkg/Sources/Greeter/include".write(to: responseFile, atomically: true, encoding: .utf8)

        let commands = CompilationDatabase.commands(inBuildLog: log(responseFile: responseFile.path))
        #expect(commands.count == 1)
        let command = try #require(commands.first)
        #expect(command.file == "/pkg/Sources/Greeter/Greeter.m")
        #expect(command.directory == "/pkg")
        #expect(command.arguments.first == "/toolchain/usr/bin/clang")
        #expect(CompilationDatabase.target(of: command) == "arm64-apple-macos12.0")

        let arguments = CompilationDatabase.parseArguments(of: command)
        #expect(arguments.contains("-DDEBUG=1"))              // from the response file
        #expect(arguments.contains("-fmessage-length=0"))     // unescaped
        // Where the build put its by-products is not a fact about the source.
        #expect(!arguments.contains { $0.hasPrefix("/pkg/.build/out/Greeter") || $0 == "/Greeter.o" })
        #expect(!arguments.contains("--serialize-diagnostics"))
        #expect(!arguments.contains("-index-unit-output-path"))
    }

    @Test("A build that compiled nothing yields no commands rather than a guess")
    func incrementalBuildIsEmpty() {
        let log = "Building for debugging...\nTarget PACKAGE-TARGET:Greeter up to date.\nBuild complete! (0.26 sec)\n"
        #expect(CompilationDatabase.commands(inBuildLog: log).isEmpty)
    }
}
