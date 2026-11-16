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
        let executable: URL = try #require(Self.binary, "sextant is not built — run `swift build` first")
        process.executableURL = executable
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

    @Test("A missing toolchain is named as what is missing, not as a missing store or an unknown flag",
          .enabled(if: binary != nil && BuildProducts.indexStore(under: fixture) != nil,
                   "needs the built binary and the fixture's store — run `make fixture`"), .timeLimit(.minutes(2)))
    func missingToolchainPiecesAreNamed() throws {
        let scratch = try Scratch()
        let store = try #require(BuildProducts.indexStore(under: Self.fixture))
        let broken = ["DEVELOPER_DIR": scratch.base.appendingPathComponent("no-such-developer-dir").path]
        let refs = try run(["refs", "EnglishGreeter", "--project", Self.fixture.path, "--index-store", store],
                           scratch: scratch, environment: broken)
        #expect(refs.errors.contains("libIndexStore.dylib was not found"), "\(refs.errors)")
        #expect(!refs.errors.contains("no index store found"), "\(refs.errors)")
        #expect(!ClangLibrary.Failure.libraryNotFound.description.contains("--clang-lib"))
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
            (["refs", "Greeter", "extra"], "'extra' would be ignored"),
            (["map", "extra"], "takes no positional argument; got 'extra'"),
            (["hierarchy", "Greeter", "--callers", "--callees"], "--callees and --callers cannot be given together"),
            (["refs", "Greeter", "--compact", "--full"], "--full and --compact cannot be given together"),
            (["map", "--semantic", "--pagerank"], "--semantic and --pagerank cannot be given together"),
        ]
        for (arguments, named) in cases {
            let result = try run(arguments + ["--project", project], scratch: scratch)
            #expect(result.code == 2, "\(arguments) exited \(result.code)\n\(result.errors)")
            #expect(result.errors.contains(named), "\(arguments): \(result.errors)")
            #expect(result.output.isEmpty, "\(arguments) answered anyway:\n\(result.output)")
        }
        let version = try run(["version", "--bogus"], scratch: scratch)
        #expect(version.code == 2 && version.errors.contains("--bogus"), "\(version.errors)")
        let last = try run(["map", "--project", project, "--budget"], scratch: scratch)
        #expect(last.code == 2, "\(last.errors)")
        #expect(last.errors.contains("--budget expects a positive integer, and none was given"), "\(last.errors)")
    }

    @Test("A budget past the maximum is lowered and named; the largest counts neither crash nor hang",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func hugeNumbersAreBounded() throws {
        let scratch = try Scratch()
        let project = Self.fixture.path
        let huge = String(Int.max)
        for command in ["map", "api"] {
            let result = try run([command, "--budget", huge, "--project", project], scratch: scratch)
            #expect(result.code == 0, "\(command) exited \(result.code)\n\(result.errors)")
            #expect(result.errors.contains("--budget \(huge) is above the maximum of \(TokenBudget.maximum)"),
                    "\(command): \(result.errors)")
        }
        let body = try run(["body", "greet", "--context-lines", huge, "--project", project], scratch: scratch)
        #expect(body.code != 133 && body.code < 128, "body --context-lines \(huge) crashed: \(body.code)")
        // The gutter is sized from the lines shown: for the same file, a larger request past its
        // end prints the same lines the same way.
        let modest = try run(["body", "greet", "--context-lines", "1000", "--project", project], scratch: scratch)
        let lines: (String) -> [Substring] = { $0.split(separator: "\n").filter { !$0.hasPrefix("──") } }
        #expect(!lines(modest.output).isEmpty, "\(modest.output)\n\(modest.errors)")
        #expect(lines(body.output) == lines(modest.output), "\(body.output)")

        // A budget from the config is named as the config's, never as a flag nobody passed.
        let configured = scratch.base.appendingPathComponent("configured")
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        try "struct A {}\n".write(to: configured.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try #"{"budget": \#(huge)}"#.write(to: configured.appendingPathComponent(".sextant.json"), atomically: true, encoding: .utf8)
        let map = try run(["map", "--project", configured.path], scratch: scratch)
        #expect(map.errors.contains(".sextant.json budget \(huge) is above the maximum"), "\(map.errors)")
        #expect(!map.errors.contains("--budget"), "\(map.errors)")
    }

    /// With a cache directory nothing can be written to, the store exists and cannot be opened —
    /// and the map then said there was no index store and to build one.
    @Test("A store that cannot be opened is not reported as a missing one",
          .enabled(if: binary != nil && getuid() != 0, "needs the built binary, and a user a read-only directory stops"),
          .timeLimit(.minutes(2)))
    func unopenableStoreIsNotMissing() throws {
        let scratch = try Scratch()
        let caches = scratch.home.appendingPathComponent("Library/Caches/sextant")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: caches.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: caches.path) }
        let map = try run(["map", "--project", Self.fixture.path], scratch: scratch)
        guard map.errors.contains("could not open the index") else { return }   // the store opened after all
        #expect(!map.errors.contains("no index store"), "\(map.errors)")
        #expect(map.errors.contains("could not be opened"), "\(map.errors)")
    }

    /// A nested package's C-family sources are built only by that package. Counting them against
    /// the root told a user to run `sextant index` at the root, which never builds them.
    @Test("doctor names a nested package's sources as that package's to index",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func doctorNamesNestedPackage() throws {
        let scratch = try Scratch()
        let root = scratch.base.appendingPathComponent("outer")
        let files = ["Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"outer\")\n",
                     "Sources/Outer/Outer.swift": "public struct Outer {}\n",
                     "Nested/Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"nested\")\n",
                     "Nested/Sources/NC/nc.c": "int nc(int x) { return x; }\n"]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let doctor = try run(["doctor", "--project", root.path], scratch: scratch)
        let lines = doctor.output.split(separator: "\n").filter { $0.contains("compile database") }
        #expect(lines.count == 1, "\(doctor.output)")
        #expect(lines.first?.contains("nested package Nested") == true, "\(doctor.output)")
        #expect(lines.first?.contains("sextant index --project Nested") == true, "\(doctor.output)")
    }

    /// `rules` takes a path; an array there made the config unparseable, and the CLI then linted
    /// with the built-in set and passed while the MCP tool refused the same config.
    @Test("lint refuses a config it cannot parse instead of checking the built-in rules",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func lintRefusesAnUnparseableConfig() throws {
        let scratch = try Scratch()
        let root = scratch.base.appendingPathComponent("gate")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "struct A {}\n".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try #"{"rules": [{"id": "x", "message": "m", "patterns": ["print($$$)"]}]}"#
            .write(to: root.appendingPathComponent(".sextant.json"), atomically: true, encoding: .utf8)
        for json in [false, true] {
            let lint = try run(["lint", "--project", root.path] + (json ? ["--json"] : []), scratch: scratch)
            #expect(lint.code == 2, "\(lint.output)\n\(lint.errors)")
            #expect(lint.errors.contains("sextant lint: .sextant.json could not be parsed"), "\(lint.errors)")
            #expect(!lint.output.contains("No violations"), "\(lint.output)")
        }
    }

    /// `version` was listed twice: once from the catalog, once in a hand-written "Other" section.
    @Test("The general help lists every command once, as the catalog declares it",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func helpListsEachCommandOnce() throws {
        let scratch = try Scratch()
        let help = try run(["--help"], scratch: scratch)
        let listed = help.output.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("  "), !line.hasPrefix("   ") else { return nil }
            return line.split(separator: " ").first.map(String.init)
        }
        for spec in CommandCatalog.commands {
            #expect(listed.filter { $0 == spec.name }.count == 1, "\(spec.name) is listed \(listed.filter { $0 == spec.name }.count) time(s)")
        }
    }

    @Test("A lint whose rules check nothing fails with a usage error instead of reporting success",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func lintThatChecksNothingFails() throws {
        let scratch = try Scratch()
        for (name, rules) in [("empty", "[]"), ("broken", #"[{"id":"b","patterns":["func ( {"],"message":"m"}]"#)] {
            let file = scratch.base.appendingPathComponent("\(name).json")
            try rules.write(to: file, atomically: true, encoding: .utf8)
            for json in [false, true] {
                let result = try run(["lint", "--rules", file.path, "--project", Self.fixture.path] + (json ? ["--json"] : []),
                                     scratch: scratch)
                #expect(result.code == 2, "\(name) json=\(json): exit \(result.code)\n\(result.errors)")
                #expect(!result.output.contains("✅"), "\(name): \(result.output)")
                #expect(result.errors.contains("nothing was checked"), "\(name): \(result.errors)")
            }
        }
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
