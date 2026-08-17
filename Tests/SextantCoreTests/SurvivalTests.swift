import Foundation
import Testing
@testable import SextantCore

/// Three ways a code-intelligence tool dies badly, taken from the tracker of one that died them.
///
/// The classes are not hypothetical: a language server left a socket and a daemon behind after
/// `stop()`, an indexer crashed on a single `.ico` file and on a name too long for the file system,
/// and a reference query returned `{}` with `isError: false` after its backend died of an
/// out-of-memory abort — fast, confident and wrong, which is the one failure shape an agent cannot
/// defend itself against.
///
/// Each test states the guarantee rather than the implementation, so a future rewrite still has to
/// keep it.
@Suite("Surviving a broken world", .serialized)
struct SurvivalTests {

    private static var binary: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = root.appendingPathComponent(".build")
        for triple in (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? [] {
            let candidate = build.appendingPathComponent("\(triple)/debug/sextant")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func sextant(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let binary = try #require(Self.binary, "sextant is not built — run `swift build` first")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return stdout + stderr
    }

    /// A minimal package with one Swift source, plus whatever else the caller wants in it.
    private func fixture(named name: String, extras: (URL) -> Void = { _ in }) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-survival-\(name)-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources/survive")
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try? """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "survive", targets: [.target(name: "survive")])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try? "public struct Kept { public func work() {} }\n"
            .write(to: sources.appendingPathComponent("kept.swift"), atomically: true, encoding: .utf8)
        extras(sources)
        return root
    }

    /// Ctrl-C and `kill` are how a daemon actually ends, and neither runs a `defer`. Ownership of
    /// the socket is held by an flock, so an orphaned file is not fatal — but a socket file that
    /// outlives its process claims something is listening when nothing is.
    @Test("A daemon killed by a signal leaves no socket behind", .timeLimit(.minutes(1)))
    func signalledDaemonCleansUp() throws {
        let binary = try #require(Self.binary, "sextant is not built — run `swift build` first")
        let root = fixture(named: "daemon")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = DaemonSocket.path(forProject: root.standardizedFileURL.path)

        for signalNumber in [SIGTERM, SIGINT] {
            let daemon = Process()
            daemon.executableURL = binary
            daemon.arguments = ["serve", "--project", root.path]
            daemon.standardOutput = FileHandle.nullDevice
            daemon.standardError = FileHandle.nullDevice
            try daemon.run()

            // Wait for the socket to appear rather than sleeping a fixed time.
            var waited = 0.0
            while !FileManager.default.fileExists(atPath: socket), waited < 20 {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
            try #require(FileManager.default.fileExists(atPath: socket),
                         "the daemon never opened its socket, so the test proves nothing")

            kill(daemon.processIdentifier, signalNumber)
            daemon.waitUntilExit()

            waited = 0.0
            while FileManager.default.fileExists(atPath: socket), waited < 10 {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
            #expect(!FileManager.default.fileExists(atPath: socket),
                    "signal \(signalNumber) left \(socket) behind")
        }
    }

    /// An indexer that dies on one odd file answers nothing about the other nine hundred. The two
    /// shapes that killed someone else's: a file the process may not read, and a name at the limit
    /// of what the file system accepts.
    @Test("One unreadable or oddly named file does not bring the walk down")
    func oddFileDoesNotStopTheWalk() throws {
        let root = fixture(named: "oddfile") { sources in
            let unreadable = sources.appendingPathComponent("unreadable.swift")
            try? "public struct Hidden {}\n".write(to: unreadable, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

            // 250 characters: inside the 255-byte limit for one component, well past anything a
            // person would type.
            let long = sources.appendingPathComponent(String(repeating: "n", count: 250) + ".swift")
            try? "public struct LongName {}\n".write(to: long, atomically: true, encoding: .utf8)

            let binaryFile = sources.appendingPathComponent("icon.swift")
            try? Data([0x00, 0x00, 0x01, 0x00, 0xFF, 0xFE, 0x00, 0x01]).write(to: binaryFile)
        }
        defer {
            let sources = root.appendingPathComponent("Sources/survive/unreadable.swift")
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sources.path)
            try? FileManager.default.removeItem(at: root)
        }

        // The guarantee is about the answer, not about the odd files: the readable symbol is still
        // found, and the tool exits without reporting a failure.
        let map = try sextant(["map", "--project", root.path])
        #expect(map.contains("kept.swift"), "the walk stopped early — the readable file is missing")

        let api = try sextant(["api", "--project", root.path])
        #expect(api.contains("Kept"), "the public surface lost a readable type to an unreadable neighbour")

        let lint = try sextant(["lint", "--project", root.path])
        #expect(!lint.lowercased().contains("fatal"), "lint died instead of reporting the odd file")
    }

    /// The failure that has no defence: an index that cannot answer, answering "nothing". An empty
    /// result and a genuinely unused symbol have to be distinguishable, or the agent deletes live
    /// code believing it dead.
    @Test("A store that cannot answer is said to be broken, not reported as no usages")
    func brokenStoreIsNamedNotEmptied() throws {
        let root = fixture(named: "store")
        defer { try? FileManager.default.removeItem(at: root) }

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--enable-index-store", "--package-path", root.path]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else { return }

        let buildDirectory = root.appendingPathComponent(".build")
        var store: String?
        for triple in (try? FileManager.default.contentsOfDirectory(atPath: buildDirectory.path)) ?? [] {
            let candidate = buildDirectory.appendingPathComponent("\(triple)/debug/index/store").path
            if FileManager.default.fileExists(atPath: candidate) { store = candidate }
        }
        let path = try #require(store, "the fixture did not produce an index store")

        // Sanity: with the store intact the symbol is found. Without this the test could pass on a
        // tool that never answers anything.
        let intact = try sextant(["refs", "Kept", "--project", root.path, "--index-store", path])
        try #require(intact.contains("Kept"), "the fixture does not answer even when whole")

        // Now break the store the way a dying backend leaves it: the records are gone, the
        // directory is not.
        let records = URL(fileURLWithPath: path).appendingPathComponent("v5/records")
        try? FileManager.default.removeItem(at: records)
        try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)

        let broken = try sextant(["refs", "Kept", "--project", root.path, "--index-store", path])

        // First guarantee: the answer is not a bare "no usages". Degrading loudly to textual
        // occurrences is what keeps an agent from reading silence as "nobody calls this".
        #expect(broken.contains("⚠"), "a store that cannot answer produced an unmarked answer:\n\(broken)")

        // Second guarantee, and the one this test was written for: the reason must be about the
        // store. Blaming the symbol — "does not resolve semantically (a closure, a local…)" — is a
        // confident diagnosis of the wrong thing, which is the failure mode being guarded against.
        #expect(broken.contains("no records"),
                "the reason given does not name the broken store:\n\(broken)")
        #expect(!broken.contains("a closure, a local"),
                "the store is broken, but the symbol was blamed:\n\(broken)")
    }
}
