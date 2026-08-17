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
