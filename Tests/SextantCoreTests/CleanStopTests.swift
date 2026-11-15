import Darwin
import Foundation
import Testing
@testable import SextantCore

/// A long-lived process — `sextant serve`, `sextant mcp` — keeps the index database it opened for
/// the next run however it is stopped: IndexStoreDB moves a database to `<version>/saved` only when
/// it is closed, and one left open is imported again from every unit by the next command.
@Suite("Clean stop", .serialized)
struct CleanStopTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = packageRoot.appendingPathComponent("Tests/Fixtures/IndexFixture")
    static var ready: Bool {
        BuildProducts.indexStore(under: fixture) != nil && BuildProducts.sextantBinary(under: packageRoot) != nil
    }

    /// A short home (a socket path has to fit in `sun_path`) holding a copy of the fixture's store.
    private final class Sandbox {
        let home: URL
        let store: String

        init() throws {
            home = URL(fileURLWithPath: "/tmp/sx-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let source = try #require(BuildProducts.indexStore(under: CleanStopTests.fixture))
            store = home.appendingPathComponent("store").path
            try FileManager.default.copyItem(atPath: source, toPath: store)
        }

        deinit { try? FileManager.default.removeItem(at: home) }

        func environment(daemon: Bool) -> [String: String] {
            var environment = ProcessInfo.processInfo.environment
            for name in ["SEXTANT_NO_DAEMON", "SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA",
                         "CLAUDE_PROJECT_DIR", "SEXTANT_TELEMETRY"] {
                environment[name] = nil
            }
            environment["CFFIXED_USER_HOME"] = home.path
            if !daemon { environment["SEXTANT_NO_DAEMON"] = "1" }
            return environment
        }

        var indexArguments: [String] { ["--project", CleanStopTests.fixture.path, "--index-store", store] }

        func process(_ arguments: [String], daemon: Bool) throws -> Process {
            let process = Process()
            process.executableURL = try #require(BuildProducts.sextantBinary(under: CleanStopTests.packageRoot))
            process.arguments = arguments
            process.currentDirectoryURL = home
            process.environment = environment(daemon: daemon)
            process.standardError = FileHandle.nullDevice
            return process
        }

        /// The entries of the store's database directory, as `<version>/<entry>`.
        var databaseEntries: [String] {
            let database = IndexStoreSet.databaseDirectory(
                forStore: store, in: home.appendingPathComponent("Library/Caches/sextant/index-db").path)
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: database.path)) ?? []).filter { $0.hasPrefix("v") }
            return versions.flatMap { version in
                ((try? FileManager.default.contentsOfDirectory(atPath: database.appendingPathComponent(version).path)) ?? [])
                    .map { "\(version)/\($0)" }
            }
        }

        var databaseSaved: Bool { databaseEntries.contains { $0.hasSuffix("/saved") } }
    }

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        var waited = 0.0
        while !condition(), waited < seconds {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
        }
        return condition()
    }

    @Test("`sextant serve` stopped by SIGTERM closes its index database and removes its socket",
          .enabled(if: CleanStopTests.ready, "needs the fixture's index store and the built binary"),
          .timeLimit(.minutes(2)))
    func serveStoppedBySignalSavesTheDatabase() throws {
        let sandbox = try Sandbox()
        let daemon = try sandbox.process(["serve"] + sandbox.indexArguments, daemon: true)
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardInput = FileHandle.nullDevice
        try daemon.run()
        defer { if daemon.isRunning { kill(daemon.processIdentifier, SIGKILL); daemon.waitUntilExit() } }
        let socket = DaemonSocket.path(forProject: Self.fixture.path, home: sandbox.home)
        try #require(Self.waitUntil(30) { FileManager.default.fileExists(atPath: socket) }, "the daemon never listened")

        let query = try sandbox.process(["defs", "EnglishGreeter"] + sandbox.indexArguments, daemon: true)
        let output = Pipe()
        query.standardOutput = output
        query.standardInput = FileHandle.nullDevice
        try query.run()
        let answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        query.waitUntilExit()
        #expect(query.terminationStatus == 0)
        #expect(answer.contains("EnglishGreeter"), "\(answer)")
        #expect(!sandbox.databaseSaved, "the database was saved before the daemon stopped: \(sandbox.databaseEntries)")

        kill(daemon.processIdentifier, SIGTERM)
        daemon.waitUntilExit()
        #expect(daemon.terminationReason == .exit && daemon.terminationStatus == 0)
        #expect(sandbox.databaseSaved, "the database was left open: \(sandbox.databaseEntries)")
        #expect(!FileManager.default.fileExists(atPath: socket), "the socket outlived the daemon")
    }

    /// An MCP client ends a session either by closing stdin or by a signal; both keep the database.
    @Test("`sextant mcp` closes its index database at the end of input and on SIGTERM and SIGINT",
          .enabled(if: CleanStopTests.ready, "needs the fixture's index store and the built binary"),
          .timeLimit(.minutes(2)), arguments: [nil, SIGTERM, SIGINT] as [Int32?])
    func mcpStoppedSavesTheDatabase(signal number: Int32?) throws {
        let sandbox = try Sandbox()
        let server = try sandbox.process(["mcp"] + sandbox.indexArguments, daemon: false)
        let input = Pipe(), output = Pipe()
        server.standardInput = input
        server.standardOutput = output
        try server.run()
        defer { if server.isRunning { kill(server.processIdentifier, SIGKILL); server.waitUntilExit() } }

        // An answer to a request means the start-up — where the index is opened — is over.
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        try input.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
        var received = Data()
        while !received.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            received.append(chunk)
        }
        #expect(String(decoding: received, as: UTF8.self).contains(#""id":1"#))
        #expect(!sandbox.databaseEntries.isEmpty && !sandbox.databaseSaved, "\(sandbox.databaseEntries)")

        if let number {
            kill(server.processIdentifier, number)
        } else {
            try input.fileHandleForWriting.close()
        }
        server.waitUntilExit()
        #expect(server.terminationReason == .exit && server.terminationStatus == 0)
        #expect(sandbox.databaseSaved, "the database was left open: \(sandbox.databaseEntries)")
    }
}
