import Darwin
import Foundation
import Testing
@testable import SextantCore

/// The commands that set a project up or look after it — `doctor`, `store use`, and the telemetry
/// log they leave — say when something failed, and keep what they write private. Every process
/// runs with a home of its own and without a daemon.
@Suite("Setup commands (CLI, e2e)", .serialized)
struct SetupCommandsCLITests {
    private final class Scratch {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-setup-\(UUID().uuidString.prefix(8))", isDirectory: true).resolvingSymlinksInPath()
        var home: URL { base.appendingPathComponent("home", isDirectory: true) }
        var root: URL { base.appendingPathComponent("pkg", isDirectory: true) }

        init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        deinit {
            // A directory made read-only by a test is made writable again so it can be removed.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: base)
        }
    }

    /// `doctor --fix` ran the build and discarded its result, so a build that failed over an
    /// older store ended in "ready".
    @Test("doctor --fix reports a failed index build as a problem",
          .enabled(if: BuildProducts.hasSextantBinary, "sextant is not built — run `swift build` first"),
          .timeLimit(.minutes(5)))
    func doctorFixReportsAFailedBuild() throws {
        let scratch = try Scratch()
        try BuildProducts.writeCPackage(at: scratch.root, swift: "import CLib\nlet value = lib_value()\n")
        let index = try BuildProducts.runSextant(["index", "--project", scratch.root.path], home: scratch.home)
        try #require(index.code == 0, "\(index.errors)")
        try "import CLib\nlet broken: Int = \"text\"\n"
            .write(to: scratch.root.appendingPathComponent("Sources/App/app.swift"), atomically: true, encoding: .utf8)

        let doctor = try BuildProducts.runSextant(["doctor", "--fix", "--project", scratch.root.path], home: scratch.home)
        #expect(doctor.code == 1, "\(doctor.output)\n\(doctor.errors)")
        #expect(doctor.output.contains("❌ doctor --fix: the index build failed (exit 1)"), "\(doctor.output)")
        #expect(!doctor.output.contains("✅ ready"), "\(doctor.output)")
    }

    /// Exit code 2 says the command line was wrong; a file the system refuses to write is not that.
    @Test("store use exits 1, not 2, when the policy cannot be written",
          .enabled(if: BuildProducts.hasSextantBinary && getuid() != 0, "needs the built binary, and a user a read-only directory stops"))
    func storeUseWriteFailureIsNotAUsageError() throws {
        let scratch = try Scratch()
        try FileManager.default.createDirectory(at: scratch.root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.root.path)

        let run = try BuildProducts.runSextant(["store", "use", "recency", "--project", scratch.root.path], home: scratch.home)
        #expect(run.code == 1, "\(run.errors)")
        #expect(run.errors.contains("could not write"), "\(run.errors)")
        let usage = try BuildProducts.runSextant(["store", "use", "bogus", "--project", scratch.root.path], home: scratch.home)
        #expect(usage.code == 2, "\(usage.errors)")
    }

    /// The log names every query asked; it was created readable by every user on the machine.
    @Test("The telemetry log is created readable by its owner only",
          .enabled(if: BuildProducts.hasSextantBinary, "sextant is not built — run `swift build` first"))
    func telemetryLogIsPrivate() throws {
        let scratch = try Scratch()
        try BuildProducts.writeCPackage(at: scratch.root, swift: "let value = 1\n")
        let log = scratch.base.appendingPathComponent("telemetry.jsonl")
        let run = try BuildProducts.runSextant(["map", "--project", scratch.root.path], home: scratch.home,
                                               environment: ["SEXTANT_TELEMETRY": log.path])
        #expect(run.code == 0, "\(run.errors)")
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int)
        #expect(mode & 0o077 == 0, "mode \(String(mode, radix: 8))")
    }
}
