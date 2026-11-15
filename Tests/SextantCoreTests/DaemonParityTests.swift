import Darwin
import Foundation
import Testing
@testable import SextantCore

/// A command answers the same with `sextant serve` running as without it: same output, same exit
/// code. Each test runs a real daemon and the same command twice, once through it and once with
/// `SEXTANT_NO_DAEMON=1`, and checks in the daemon's log that it really answered — otherwise two
/// identical local runs would pass for parity.
///
/// The daemon and its clients get a home directory of their own (`CFFIXED_USER_HOME`), so the
/// socket, the adoption log and the index database never touch the user's, and no other test's
/// process can reach this daemon.
@Suite("Daemon parity", .serialized)
struct DaemonParityTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = packageRoot.appendingPathComponent("Tests/Fixtures/IndexFixture")
    static var fixtureStore: String? { BuildProducts.indexStore(under: fixture) }

    private struct Run: Equatable, CustomStringConvertible {
        let output: String
        let errorOutput: String
        let exitCode: Int32
        var description: String { "exit \(exitCode)\n--- stdout\n\(output)--- stderr\n\(errorOutput)" }
    }

    /// A scratch area: a short home (the socket path has to fit in `sun_path`) and a work directory.
    private final class Sandbox {
        let home: URL
        let work: URL

        init() throws {
            let tag = UUID().uuidString.prefix(8)
            home = URL(fileURLWithPath: "/tmp/sx-\(tag)", isDirectory: true)
            work = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-parity-\(tag)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: work)
        }

        /// A package with one Swift source.
        func package(named name: String) throws -> URL {
            let root = work.appendingPathComponent(name, isDirectory: true)
            let sources = root.appendingPathComponent("Sources/parity")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(name: "parity", targets: [.target(name: "parity")])
                """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "public struct Kept { public func work() {} }\n"
                .write(to: sources.appendingPathComponent("kept.swift"), atomically: true, encoding: .utf8)
            return root
        }

        /// The environment of every process here: the caller's own, minus whatever would steer
        /// sextant from outside the test, plus the sandbox home and `extra`.
        func environment(_ extra: [String: String] = [:]) -> [String: String] {
            var environment = ProcessInfo.processInfo.environment
            for name in ["SEXTANT_NO_DAEMON", "SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA",
                         "CLAUDE_PROJECT_DIR", "SEXTANT_TELEMETRY"] {
                environment[name] = nil
            }
            environment["CFFIXED_USER_HOME"] = home.path
            return environment.merging(extra) { _, new in new }
        }
    }

    private final class Daemon {
        let process = Process()
        let log: URL

        init(binary: URL, project: URL, sandbox: Sandbox, environment: [String: String] = [:]) throws {
            log = sandbox.work.appendingPathComponent("serve-\(UUID().uuidString.prefix(8)).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            process.executableURL = binary
            process.arguments = ["serve", "--project", project.path]
            // Anywhere but the project: a relative path resolved here would name another file.
            process.currentDirectoryURL = sandbox.home
            process.environment = sandbox.environment(environment)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = try FileHandle(forWritingTo: log)
            try process.run()

            let socket = DaemonSocket.path(forProject: project.path, home: sandbox.home)
            var waited = 0.0
            while !FileManager.default.fileExists(atPath: socket), waited < 20, process.isRunning {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
            try #require(FileManager.default.fileExists(atPath: socket),
                         "the daemon never opened its socket, so nothing here would test it:\n\(text)")
        }

        var text: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

        /// Whether the daemon ran `command` itself rather than leaving it to the client.
        func answered(_ command: String) -> Bool {
            text.contains("sextant serve: \(command) → exit")
        }

        func stop() {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func sextant(_ arguments: [String], in directory: URL, sandbox: Sandbox, daemon: Bool,
                         environment: [String: String] = [:], input: Data? = nil) throws -> Run {
        let binary = try #require(BuildProducts.sextantBinary(under: Self.packageRoot),
                                  "sextant is not built — run `swift build` first")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = sandbox.environment(environment.merging(daemon ? [:] : ["SEXTANT_NO_DAEMON": "1"]) { _, new in new })
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        try process.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        let collected = OutputCapture.collect(from: [out, err]) { process.waitUntilExit() }
        return Run(output: collected[0], errorOutput: collected[1], exitCode: process.terminationStatus)
    }

    private func bothWays(_ arguments: [String], in directory: URL, sandbox: Sandbox,
                          environment: [String: String] = [:]) throws -> (viaDaemon: Run, direct: Run) {
        (try sextant(arguments, in: directory, sandbox: sandbox, daemon: true, environment: environment),
         try sextant(arguments, in: directory, sandbox: sandbox, daemon: false, environment: environment))
    }

    /// Regression: `--rules rules/hygiene.json` was opened in the daemon's working directory, so
    /// the command that passed on its own failed with exit 2 the moment a daemon was running.
    @Test("A relative path names the same file through the daemon", .timeLimit(.minutes(2)))
    func relativePathIsTheClients() throws {
        let binary = try #require(BuildProducts.sextantBinary(under: Self.packageRoot), "sextant is not built")
        let sandbox = try Sandbox()
        let project = try sandbox.package(named: "rules")
        let rules = project.appendingPathComponent("rules")
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.packageRoot.appendingPathComponent("sextant-rules.json"),
                                         to: rules.appendingPathComponent("hygiene.json"))
        let daemon = try Daemon(binary: binary, project: project, sandbox: sandbox)
        defer { daemon.stop() }

        let (viaDaemon, direct) = try bothWays(["lint", "--rules", "rules/hygiene.json"], in: project, sandbox: sandbox)
        #expect(daemon.answered("lint"), "the daemon never answered, so this compared two local runs:\n\(daemon.text)")
        #expect(direct.exitCode == 0, "\(direct)")
        #expect(viaDaemon == direct)
    }

    /// Regression: the socket was named after the resolved path but the daemon compared the
    /// request against its own spelling, so a project reached through a symlink was refused.
    @Test("A project reached through a symlink is answered by its daemon", .timeLimit(.minutes(2)))
    func symlinkedProjectIsServed() throws {
        let binary = try #require(BuildProducts.sextantBinary(under: Self.packageRoot), "sextant is not built")
        let sandbox = try Sandbox()
        let project = try sandbox.package(named: "real")
        let link = sandbox.work.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        let daemon = try Daemon(binary: binary, project: project, sandbox: sandbox)
        defer { daemon.stop() }

        let (viaDaemon, direct) = try bothWays(["map", "--project", "link"], in: sandbox.work, sandbox: sandbox)
        #expect(daemon.answered("map"), "the daemon never answered:\n\(daemon.text)")
        #expect(direct.exitCode == 0, "\(direct)")
        #expect(viaDaemon == direct)
    }

    /// Regression: everything not on a refusal list was forwarded. `hook` then read the daemon's
    /// stdin and recorded nothing, and `completion` failed on the `--project` the client appends.
    @Test("hook, completion and store run in the client even with a daemon up", .timeLimit(.minutes(2)))
    func clientOnlyCommandsStayInTheClient() throws {
        let binary = try #require(BuildProducts.sextantBinary(under: Self.packageRoot), "sextant is not built")
        let sandbox = try Sandbox()
        let project = try sandbox.package(named: "local")
        let daemon = try Daemon(binary: binary, project: project, sandbox: sandbox)
        defer { daemon.stop() }

        let (completion, direct) = try bothWays(["completion", "zsh"], in: project, sandbox: sandbox)
        #expect(completion.exitCode == 0, "\(completion)")
        #expect(completion == direct)

        let event = #"{"tool_name":"Grep","tool_input":{"pattern":"Kept"},"cwd":"\#(project.path)","session_id":"parity"}"#
        let hook = try sextant(["hook"], in: project, sandbox: sandbox, daemon: true, input: Data(event.utf8))
        #expect(hook.exitCode == 0)
        let log = sandbox.home.appendingPathComponent("Library/Caches/sextant/adoption.jsonl")
        let recorded = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(recorded.split(separator: "\n").count == 1, "the hook's event never reached the client: \(recorded)")

        _ = try sextant(["store", "use", "recency"], in: project, sandbox: sandbox, daemon: true)

        for command in ["completion", "hook", "store"] {
            #expect(!daemon.text.contains("sextant serve: \(command) "), "\(command) went to the daemon:\n\(daemon.text)")
        }
    }

    /// Regression: `SEXTANT_STORE_POLICY` was read from the daemon's environment. A daemon started
    /// with one policy answered every client with it — including a client that had set none, where
    /// the command on its own refuses to pick between two stores.
    @Test("The caller's store policy is the one in force", .timeLimit(.minutes(3)),
          .enabled(if: DaemonParityTests.fixtureStore != nil, "needs the fixture's index store — run `make fixture`"))
    func callerEnvironmentIsInForce() throws {
        let binary = try #require(BuildProducts.sextantBinary(under: Self.packageRoot), "sextant is not built")
        let store = try #require(Self.fixtureStore)
        let sandbox = try Sandbox()
        // Two usable stores of one configuration, both left by ordinary builds: the policy decides
        // which is read, and with none set nothing is read.
        let project = try sandbox.package(named: "stores")
        for layout in [".build/out/Products/Debug/index", ".build/arm64-apple-macosx/debug/index"] {
            let directory = project.appendingPathComponent(layout)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: store), to: directory.appendingPathComponent("store"))
        }
        try #require(IndexStoreLocator.usableStorePaths(under: project).count == 2,
                     "the copies are not both usable, so no policy would be needed")

        let daemon = try Daemon(binary: binary, project: project, sandbox: sandbox,
                                environment: ["SEXTANT_STORE_POLICY": "union"])
        defer { daemon.stop() }

        let (unsetViaDaemon, unsetDirect) = try bothWays(["defs", "EnglishGreeter"], in: project, sandbox: sandbox)
        #expect(daemon.answered("defs"), "the daemon never answered:\n\(daemon.text)")
        #expect(unsetDirect.errorOutput.contains("no store policy is set"), "\(unsetDirect)")
        #expect(unsetViaDaemon == unsetDirect)

        let (setViaDaemon, setDirect) = try bothWays(["defs", "EnglishGreeter"], in: project, sandbox: sandbox,
                                                     environment: ["SEXTANT_STORE_POLICY": "recency"])
        #expect(!setDirect.errorOutput.contains("no store policy is set"), "\(setDirect)")
        #expect(setViaDaemon == setDirect)
    }

    /// An answer over a stale index is mapped onto the current text per request, never from
    /// anything the daemon kept: through it, the same edit gives the same unconfirmed position.
    @Test("A stale answer is mapped the same way through the daemon", .timeLimit(.minutes(5)))
    func staleAnswerParity() throws {
        let binary = try #require(BuildProducts.sextantBinary(under: Self.packageRoot), "sextant is not built")
        let sandbox = try Sandbox()
        let project = try sandbox.package(named: "stale")
        let use = project.appendingPathComponent("Sources/parity/use.swift")
        try "func use() {\n    Kept().work()\n}\n".write(to: use, atomically: true, encoding: .utf8)
        let index = try sextant(["index", "--project", project.path], in: project, sandbox: sandbox, daemon: false)
        try #require(index.exitCode == 0, "\(index)")
        let daemon = try Daemon(binary: binary, project: project, sandbox: sandbox)
        defer { daemon.stop() }

        try "// moved\nfunc use() {\n    _ = 1; Kept().work()\n}\n".write(to: use, atomically: true, encoding: .utf8)
        let (viaDaemon, direct) = try bothWays(["refs", "work", "--full"], in: project, sandbox: sandbox)
        #expect(daemon.answered("refs"), "the daemon never answered:\n\(daemon.text)")
        #expect(direct.output.contains("Sources/parity/use.swift:2:12  [unconfirmed"), "\(direct)")
        #expect(viaDaemon == direct)
    }
}
