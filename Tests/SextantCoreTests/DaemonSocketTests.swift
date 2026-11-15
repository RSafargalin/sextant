import Dispatch
import Foundation
import Testing
@testable import SextantCore

/// The daemon socket layer: without it `serve` would quietly degrade to the normal path and the
/// benefit of a warm index would vanish unnoticed.
@Suite("Daemon socket")
struct DaemonSocketTests {
    private func temporarySocket() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-\(UUID().uuidString.prefix(8)).sock").path
    }

    /// An error from accept(2) used to end the serving loop whatever it was, so one interrupted
    /// call or a moment without free descriptors stopped the daemon.
    @Test("A transient accept error is waited out; a closed listener ends the wait")
    func transientAcceptErrorsAreRetried() {
        var script: [(Int32, Int32)] = [(-1, EINTR), (-1, ECONNABORTED), (-1, EMFILE), (-1, ENFILE), (7, 0)]
        var pauses = 0
        let accepted = DaemonSocket.acceptRetrying(attempt: { script.removeFirst() }, pause: { pauses += 1 })
        #expect(accepted == 7)
        #expect(pauses == 2)

        var closed: [(Int32, Int32)] = [(-1, EINTR), (-1, EBADF)]
        #expect(DaemonSocket.acceptRetrying(attempt: { closed.removeFirst() }, pause: {}) == nil)
        #expect(closed.isEmpty)
    }

    @Test("The socket path is under the sun_path limit and stable per project")
    func socketPathFitsLimit() {
        let long = "/Users/someone/Documents/Projects/" + String(repeating: "nested-directory/", count: 20) + "App"
        let path = DaemonSocket.path(forProject: long)
        #expect(path.utf8.count < 104, "path is \(path.utf8.count) bytes — sockaddr_un will not hold it")
        #expect(path == DaemonSocket.path(forProject: long))            // stable
        #expect(path != DaemonSocket.path(forProject: long + "/Other")) // and distinguishes projects
    }

    @Test("Request and response travel through the socket intact, including a large payload")
    func roundTrip() throws {
        let path = temporarySocket()
        let listener = try DaemonSocket.listen(at: path)
        defer { DaemonSocket.stop(listener) }

        // The response is deliberately larger than the read buffer — this checks reassembly.
        let payload = String(repeating: "a line of output\n", count: 20_000)
        let server = Thread {
            guard let client = DaemonSocket.accept(listener) else { return }
            defer { DaemonSocket.close(client) }
            guard let line = DaemonSocket.Reader(client).line(),
                  let request = try? JSONDecoder().decode(DaemonRequest.self, from: Data(line.utf8)) else { return }
            let response = DaemonResponse(exitCode: 0, output: "\(request.arguments.joined(separator: " "))\n" + payload, errorOutput: "")
            if let data = try? JSONEncoder().encode(response) {
                DaemonSocket.send(String(decoding: data, as: UTF8.self), to: client)
            }
        }
        server.start()

        let handle = try #require(DaemonSocket.connect(to: path))
        defer { DaemonSocket.close(handle) }
        let request = try JSONEncoder().encode(DaemonRequest(arguments: ["refs", "Event"], projectRoot: "/tmp/project"))
        #expect(DaemonSocket.send(String(decoding: request, as: UTF8.self), to: handle))

        let line = try #require(DaemonSocket.Reader(handle).line())
        let response = try JSONDecoder().decode(DaemonResponse.self, from: Data(line.utf8))
        #expect(response.exitCode == 0)
        #expect(response.output.hasPrefix("refs Event\n"))
        #expect(response.output.hasSuffix(payload))
    }

    @Test("The request carries a resolved root, so the daemon does not resolve it in its own directory")
    func requestCarriesProjectRoot() throws {
        let encoded = try JSONEncoder().encode(DaemonRequest(arguments: ["map", "--project", "."], projectRoot: "/repo/app"))
        let decoded = try JSONDecoder().decode(DaemonRequest.self, from: encoded)
        #expect(decoded.projectRoot == "/repo/app", "otherwise \"--project .\" would mean the daemon's directory")
    }

    @Test("With no daemon, connect returns nil and the client takes the normal path")
    func absentDaemonIsNotAnError() {
        #expect(DaemonSocket.connect(to: temporarySocket()) == nil)
    }

    /// Regression: output larger than the pipe buffer (~64 KB) hung the command on write — the
    /// client waited forever and the daemon stopped answering everyone else. This checks the
    /// draining itself; swapping the global stdout/stderr is left alone, since that is
    /// process-global and would disturb tests running in parallel.
    /// The same defect, under the condition that actually triggers it. Draining used to run on the
    /// global queue, which only promises to run a block eventually — and eventually is too late when
    /// the caller is already blocked on the write. Anything holding the pool's threads starves the
    /// reader: several `Process.waitUntilExit` calls do it, which is why this passed locally in
    /// 0.002s and timed out at 60 seconds on CI, twice, while the suite grew package-building tests.
    ///
    /// The pool is deliberately saturated here and released immediately after; with a reader on its
    /// own thread the write returns at once.
    @Test("Draining survives a starved thread pool", .timeLimit(.minutes(1)))
    func drainSurvivesStarvedPool() throws {
        let hold = DispatchSemaphore(value: 0)
        let occupied = 80
        for _ in 0..<occupied { DispatchQueue.global().async { hold.wait() } }
        defer { for _ in 0..<occupied { hold.signal() } }
        Thread.sleep(forTimeInterval: 0.3)   // let the pool actually fill

        let pipe = Pipe()
        let payload = Data(String(repeating: "a line of command output\n", count: 20_000).utf8)
        let collected = OutputCapture.collect(from: [pipe]) {
            try? pipe.fileHandleForWriting.write(contentsOf: payload)
        }
        #expect(collected[0].utf8.count == payload.count)
    }

    @Test("Draining does not block the writer on more than a pipe buffer", .timeLimit(.minutes(1)))
    func drainSurvivesLargeOutput() throws {
        let pipe = Pipe()
        let payload = Data(String(repeating: "a line of command output\n", count: 20_000).utf8)
        #expect(payload.count > 256 * 1024, "the volume must comfortably exceed the pipe buffer")

        let collected = OutputCapture.collect(from: [pipe]) {
            try? pipe.fileHandleForWriting.write(contentsOf: payload)
        }
        #expect(collected[0].utf8.count == payload.count)
        #expect(collected[0].hasSuffix("a line of command output\n"))
    }

    @Test("Several pipes drain separately; an empty stream gives an empty string")
    func drainSeparatesPipes() {
        let first = Pipe(), second = Pipe()
        let collected = OutputCapture.collect(from: [first, second]) {
            try? first.fileHandleForWriting.write(contentsOf: Data("to stdout\n".utf8))
        }
        #expect(collected[0] == "to stdout\n")
        #expect(collected[1].isEmpty)
    }

    @Test("An orphaned socket file is reused; a live one is busy")
    func staleSocketIsReclaimed() throws {
        let path = temporarySocket()
        // The file exists but nobody listens (the daemon crashed) — listen must reclaim it.
        FileManager.default.createFile(atPath: path, contents: Data())
        let listener = try DaemonSocket.listen(at: path)
        defer { DaemonSocket.stop(listener) }
        #expect(DaemonSocket.connect(to: path) != nil)

        // A second daemon on the same socket does not start.
        #expect(throws: DaemonSocket.Failure.busy) { _ = try DaemonSocket.listen(at: path) }
    }

    @Test("The daemon does not build or set up — queries only")
    func refusesUnsafeCommands() {
        for command in ["index", "init", "serve", "mcp", "doctor"] {
            #expect(!DaemonPolicy.servesCommand(command), "\(command) must not be executed by the daemon")
        }
        for command in ["refs", "defs", "context", "map", "api", "changed"] {
            #expect(DaemonPolicy.servesCommand(command), "\(command) must be served by the daemon")
        }
        #expect(!DaemonPolicy.servesCommand("no-such-command"))
    }

    /// Regression: the daemon refused a list of commands and answered everything else, so `hook`
    /// read the daemon's stdin instead of the caller's and recorded nothing, `completion` failed on
    /// the `--project` the client appends, and `store use` wrote its policy from inside the daemon.
    @Test("Commands that read stdin, write, or take no --project are not served")
    func servesOnlyQueries() {
        for command in ["hook", "completion", "store", "adoption", "golden", "bench"] {
            #expect(!DaemonPolicy.servesCommand(command), "\(command) must run where it was invoked")
        }
    }

    /// The allow-list is a mark in the catalog, not a list beside it. Changing what the daemon
    /// answers has to change this test too, so it is never a side effect of adding a command.
    @Test("The daemon answers exactly the read-only queries the catalog marks")
    func servedSetIsPinned() {
        #expect(DaemonPolicy.servedCommands == [
            "map", "api", "search", "lint", "changed",
            "refs", "defs", "callers", "callees", "impls", "supertypes", "hierarchy", "context", "blast", "body", "construct",
        ])
        let unmarked = CommandSpec(name: "new-command", summary: "", group: "")
        #expect(!unmarked.servedByDaemon, "a new command must not be forwarded until it is marked")
    }

    /// The client always appends `--project`; a served command that did not take it would fail
    /// through the daemon and succeed without one.
    @Test("Every served command takes --project")
    func servedCommandsTakeProject() {
        for spec in CommandCatalog.commands where spec.servedByDaemon {
            #expect(spec.flags.contains { $0.name == "--project" }, "\(spec.name) is served but takes no --project")
        }
    }

    @Test("Relative paths are made absolute against the client's directory; --project is replaced")
    func forwardedArgumentsResolvePaths() {
        let forwarded = DaemonPolicy.forwardedArguments(
            ["lint", "--rules", "rules/my.json", "--scope", "Sources", "--project", ".", "--json"],
            projectRoot: "/repo/app", workingDirectory: "/repo/app")
        #expect(forwarded == ["lint", "--rules", "/repo/app/rules/my.json", "--scope", "Sources", "--json",
                              "--project", "/repo/app"],
                "--scope is relative to the project, not to the working directory, and stays as given")

        let semantic = DaemonPolicy.forwardedArguments(
            ["refs", "Event", "--index-store", "../store", "--index-lib", "/abs/lib.dylib", "--derived-data", "dd"],
            projectRoot: "/repo/app", workingDirectory: "/work")
        #expect(semantic == ["refs", "Event", "--index-store", "/work/../store", "--index-lib", "/abs/lib.dylib",
                             "--derived-data", "/work/dd", "--project", "/repo/app"])
    }

    @Test("Every path flag the daemon could receive is known to be a path")
    func pathFlagsAreMarked() {
        let flags = Dictionary(CommandCatalog.commands.flatMap(\.flags).map { ($0.name, $0) }) { first, _ in first }
        for name in ["--project", "--rules", "--index-store", "--derived-data", "--index-lib"] {
            #expect(flags[name]?.takesPath == true, "\(name) would be read in the daemon's directory")
        }
    }

    /// Regression: the daemon compared the request's root with its own spelling, so a project
    /// reached through a symlink found the right socket and was then refused with exit 2.
    @Test("A symlinked spelling of a project reaches the same daemon as the real one")
    func symlinkedProjectSharesDaemon() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-link-\(UUID().uuidString.prefix(8))")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(DaemonSocket.canonicalProjectRoot(link.path) == DaemonSocket.canonicalProjectRoot(real.path))
        #expect(DaemonSocket.canonicalProjectRoot(real.path + "/") == DaemonSocket.canonicalProjectRoot(real.path))
        #expect(DaemonSocket.path(forProject: link.path) == DaemonSocket.path(forProject: real.path))
    }

    @Test("The caller's environment and terminal travel with the request and take effect inside it")
    func callerContextOverridesTheDaemon() throws {
        let daemon = ["SEXTANT_STORE_POLICY": "union", "SEXTANT_DERIVED_DATA": "/daemon/dd", "UNRELATED": "x"]
        let caller = CallerContext.current(environment: ["SEXTANT_DERIVED_DATA": "/caller/dd", "UNRELATED": "y"],
                                           outputIsTerminal: true)
        #expect(caller.environment == ["SEXTANT_DERIVED_DATA": "/caller/dd"], "only the variables that change an answer")

        let decoded = try JSONDecoder().decode(DaemonRequest.self, from: JSONEncoder().encode(
            DaemonRequest(arguments: ["refs", "X"], projectRoot: "/repo", caller: caller)))
        #expect(decoded.caller == caller)

        #expect(CallerContext.environmentValue("SEXTANT_STORE_POLICY", process: daemon) == "union")
        CallerContext.during(decoded.caller) {
            #expect(CallerContext.environmentValue("SEXTANT_DERIVED_DATA", process: daemon) == "/caller/dd")
            #expect(CallerContext.environmentValue("SEXTANT_STORE_POLICY", process: daemon) == nil,
                    "unset by the caller means unset, whatever the daemon has")
            #expect(CallerContext.outputIsTerminal(process: { false }))
        }
        #expect(CallerContext.environmentValue("SEXTANT_DERIVED_DATA", process: daemon) == "/daemon/dd")
        #expect(!CallerContext.outputIsTerminal(process: { false }))
    }

    @Test("A client takes an answer only from a daemon of its own version that did not decline")
    func responseFromAnotherVersionIsNotAnAnswer() throws {
        #expect(DaemonResponse(exitCode: 0, output: "", errorOutput: "").answersForThisVersion)
        #expect(!DaemonResponse(exitCode: 2, output: "", errorOutput: "", declined: true).answersForThisVersion)
        #expect(!DaemonResponse(exitCode: 0, output: "", errorOutput: "", version: "0.0.1").answersForThisVersion)
        // A daemon that predates the field sends no version at all.
        let old = try JSONDecoder().decode(DaemonResponse.self,
                                           from: Data(#"{"exitCode":0,"output":"x","errorOutput":""}"#.utf8))
        #expect(!old.answersForThisVersion)
    }

    @Test("`--reindex` does not bypass the ban on building through the daemon")
    func refusesReindex() {
        // The flag triggers the same runIndex as the forbidden `index`: the daemon would build an
        // arbitrary project on request, running with the owner's environment.
        #expect(!DaemonPolicy.servesRequest(["refs", "Event", "--reindex"]))
        #expect(DaemonPolicy.servesRequest(["refs", "Event"]))
        #expect(!DaemonPolicy.servesRequest(["index"]))
        #expect(!DaemonPolicy.servesRequest([]))
    }
}
