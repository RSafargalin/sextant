import Foundation
import Testing
@testable import SextantCore

/// The built binary refuses what it does not understand, with exit code 2 and a message naming
/// the flag and the value, instead of answering with the default in its place. `--reindex`
/// keeps `--json` output a JSON document and fails the command when the rebuild fails.
///
/// Every process runs with a home of its own (`CFFIXED_USER_HOME`) and without a daemon.
@Suite("Invalid input (CLI, e2e)", .serialized)
struct InvalidInputCLITests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = packageRoot.appendingPathComponent("Tests/Fixtures/IndexFixture")
    static var binary: URL? { BuildProducts.sextantBinary(under: packageRoot) }

    private struct Run {
        let code: Int32
        let output: String
        let errors: String
    }

    private final class Scratch {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-invalid-input-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var home: URL { base.appendingPathComponent("home", isDirectory: true) }

        init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: base) }
    }

    private func run(_ arguments: [String], scratch: Scratch, environment extra: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = try #require(Self.binary, "sextant is not built — run `swift build` first")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for name in ["SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA", "CLAUDE_PROJECT_DIR", "SEXTANT_TELEMETRY"] {
            environment[name] = nil
        }
        environment["CFFIXED_USER_HOME"] = scratch.home.path
        environment["SEXTANT_NO_DAEMON"] = "1"
        process.environment = environment.merging(extra) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let collected = OutputCapture.collect(from: [out, err]) { process.waitUntilExit() }
        return Run(code: process.terminationStatus, output: collected[0], errors: collected[1])
    }

    @Test("Values a command would not understand are a usage error naming the flag and the value",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func invalidValuesAreUsageErrors() throws {
        let scratch = try Scratch()
        let project = Self.fixture.path
        let cases: [(arguments: [String], named: String)] = [
            (["map", "--budget", "8k"], "--budget '8k'"),
            (["map", "--max-files", "abc"], "--max-files 'abc'"),
            (["map", "--max-files", "0"], "--max-files '0'"),
            (["search", "$X.greet()", "--limit", "x"], "--limit 'x'"),
            (["hierarchy", "Greeter", "--depth", "x"], "--depth 'x'"),
            (["refs", "Greeter", "--store-policy", "bogus"], "--store-policy 'bogus'"),
            (["refs", "Greeter", "--limit", "-5"], "--limit '-5'"),
            (["body", "Greeter", "--context-lines", "-3"], "--context-lines '-3'"),
        ]
        for (arguments, named) in cases {
            let result = try run(arguments + ["--project", project], scratch: scratch)
            #expect(result.code == 2, "\(arguments) exited \(result.code)\n\(result.errors)")
            #expect(result.errors.contains(named), "\(arguments): \(result.errors)")
            #expect(result.output.isEmpty, "\(arguments) answered anyway:\n\(result.output)")
        }
        let last = try run(["map", "--project", project, "--budget"], scratch: scratch)
        #expect(last.code == 2, "\(last.errors)")
        #expect(last.errors.contains("--budget expects a positive integer, and none was given"), "\(last.errors)")
    }

    @Test("An unknown SEXTANT_STORE_POLICY refuses the command instead of reading a store without it",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func unknownStorePolicyVariable() throws {
        let scratch = try Scratch()
        for command in [["refs", "Greeter"], ["mcp"]] {
            let result = try run(command + ["--project", Self.fixture.path], scratch: scratch,
                                 environment: ["SEXTANT_STORE_POLICY": "bogus"])
            #expect(result.code == 2, "\(command) exited \(result.code)\n\(result.errors)")
            #expect(result.errors.contains("SEXTANT_STORE_POLICY 'bogus'"), "\(command): \(result.errors)")
        }
    }

    /// The package is built twice by `sextant index`: once to have a store, once with a source
    /// that does not compile.
    @Test("--reindex --json: stdout is the JSON alone, and a failed rebuild fails the command",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(10)))
    func reindexWithJSON() throws {
        let scratch = try Scratch()
        let package = scratch.base.appendingPathComponent("reindex", isDirectory: true)
        let sources = package.appendingPathComponent("Sources/reindex", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "reindex", targets: [.target(name: "reindex")])
            """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public struct Thing { public init() {} }\n"
            .write(to: sources.appendingPathComponent("Thing.swift"), atomically: true, encoding: .utf8)

        let fresh = try run(["defs", "Thing", "--reindex", "--json", "--project", package.path], scratch: scratch)
        try #require(fresh.code == 0, "\(fresh.output)\n\(fresh.errors)")
        let parsed = try? JSONSerialization.jsonObject(with: Data(fresh.output.utf8))
        #expect(parsed is [Any], "stdout under --json is not a JSON document:\n\(fresh.output)")
        #expect(fresh.errors.contains("build log:"), "the build's progress went nowhere:\n\(fresh.errors)")

        let broken = sources.appendingPathComponent("Broken.swift")
        try "public func broken( {\n".write(to: broken, atomically: true, encoding: .utf8)
        let failed = try run(["defs", "Thing", "--reindex", "--json", "--project", package.path], scratch: scratch)
        #expect(failed.code == 1, "a failed rebuild answered with exit \(failed.code):\n\(failed.output)")
        #expect(failed.output.isEmpty, "a failed rebuild still answered from the old index:\n\(failed.output)")
        #expect(failed.errors.contains("--reindex failed"), "\(failed.errors)")
    }
}
