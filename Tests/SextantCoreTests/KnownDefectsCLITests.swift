import Foundation
import Testing

/// A ledger of defects found by measurement, written as the behaviour the tool *should* have.
///
/// Each test states the correct answer and is wrapped in `withKnownIssue`, so the suite stays green
/// while the defect exists and **fails the moment the defect is fixed** — which is the point: a
/// list of defects that nobody notices being closed is a document, not a ledger. When a test here
/// starts failing with "known issue was not recorded", delete the wrapper and keep the assertion.
///
/// These cover the CLI surface only and need no index store: the binary, a temporary package and
/// git. Index-dependent defects live in their own suite because they need a build.
@Suite("Known defects: CLI surface", .serialized)
struct KnownDefectsCLITests {

    // MARK: - Harness

    /// The built binary, discovered next to the package rather than passed in: tests run from the
    /// same `.build` that produced it, and a missing binary means "not built yet", not "failure".
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

    private struct Output {
        let stdout: String
        let stderr: String
        let code: Int32
        var all: String { stdout + stderr }
    }

    private func sextant(_ arguments: [String]) throws -> Output {
        let binary = try #require(Self.binary, "sextant is not built — run `swift build` first")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return Output(stdout: stdout, stderr: stderr, code: process.terminationStatus)
    }

    @discardableResult
    private func shell(_ launch: String, _ arguments: [String], in directory: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A throwaway SPM package. `files` are paths relative to the package root.
    private func makePackage(name: String, files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-defects-\(name)-\(UUID().uuidString)")
        var all = files
        all["Package.swift"] = """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
                                  targets: [.target(name: "\(name)")])
            """
        for (path, contents) in all {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func commitAll(_ root: URL, message: String) {
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            shell("/usr/bin/env", ["git", "init", "-q", "."], in: root)
            shell("/usr/bin/env", ["git", "config", "user.email", "t@example.com"], in: root)
            shell("/usr/bin/env", ["git", "config", "user.name", "t"], in: root)
        }
        shell("/usr/bin/env", ["git", "add", "-A"], in: root)
        shell("/usr/bin/env", ["git", "commit", "-q", "-m", message], in: root)
    }

    // MARK: - A missing project is answered instead of refused

    /// `--scope` with a typo is refused with exit 2; `--project` with the same typo is answered.
    /// The dangerous half is `lint`: a clean bill of health for a directory that does not exist.
    @Test("a project path that does not exist is refused, not answered")
    func missingProjectIsRefused() throws {
        let result = try sextant(["lint", "--project", "/no/such/directory"])
        withKnownIssue("lint answers ✅ No violations found with exit 0 for a missing directory") {
            #expect(result.code != 0)
            #expect(!result.stdout.contains("No violations found"))
        }
    }

    // MARK: - Structural patterns

    /// A pattern the parser cannot make sense of is indistinguishable from "this does not occur".
    @Test("an unparsable pattern is reported, not answered with No matches")
    func invalidPatternIsReported() throws {
        let package = try makePackage(name: "pat", files: ["Sources/pat/a.swift": "public func f() { print(1) }\n"])
        let broken = try sextant(["search", "print(", "--project", package.path])
        withKnownIssue("an unbalanced pattern yields `No matches.` and exit 0") {
            #expect(broken.code != 0 || !broken.stdout.contains("No matches"))
        }
    }

    /// `--limit` is advertised in the catalog for `search` and ignored by it.
    @Test("search honours --limit, or does not advertise it")
    func searchLimitIsHonoured() throws {
        let source = (1...5).map { "public func f\($0)() { print(\($0)) }" }.joined(separator: "\n")
        let package = try makePackage(name: "lim", files: ["Sources/lim/a.swift": source + "\n"])
        let all = try sextant(["search", "print($$$)", "--project", package.path])
        let limited = try sextant(["search", "print($$$)", "--project", package.path, "--limit", "1"])
        #expect(all.stdout.contains("total: 5"))
        withKnownIssue("--limit is accepted and has no effect on search") {
            #expect(!limited.stdout.contains("total: 5"))
        }
    }

    // MARK: - Exclusions

    /// An exclusion can remove every result; the answer looks like "there is nothing".
    @Test("an answer emptied by exclusions says so")
    func exclusionsAreNamedInTheAnswer() throws {
        let package = try makePackage(name: "exc", files: ["Sources/exc/a.swift": "public func f() { print(1) }\n"])
        let plain = try sextant(["search", "print($$$)", "--project", package.path])
        let excluded = try sextant(["search", "print($$$)", "--project", package.path, "--exclude", "Sources/**"])
        #expect(plain.stdout.contains("total: 1"))
        withKnownIssue("results vanish with no mention of the exclusion that removed them") {
            #expect(excluded.all.lowercased().contains("exclud"))
        }
    }

    /// `ExclusionPattern` documents that naming a directory removes the tree; a single component
    /// is treated as a file name instead, so `--exclude Sources` quietly does nothing.
    @Test("a single-component exclusion excludes the directory it names")
    func singleComponentExclusionWorks() throws {
        let package = try makePackage(name: "exc1", files: ["Sources/exc1/a.swift": "public func f() { print(1) }\n"])
        let excluded = try sextant(["search", "print($$$)", "--project", package.path, "--exclude", "Sources"])
        withKnownIssue("`--exclude Sources` matches a file name, never a directory") {
            #expect(!excluded.stdout.contains("total: 1"))
        }
    }

    // MARK: - Rules

    /// A rule whose pattern does not compile is dropped, and the header still counts it. The report
    /// then claims a clean result produced by a rule set that never ran.
    @Test("rules that fail to compile are reported, not counted as if they ran")
    func brokenRulesAreReported() throws {
        let package = try makePackage(name: "rul", files: ["Sources/rul/a.swift": "public func f() { print(1) }\n"])
        let rules = package.appendingPathComponent("rules.json")
        try #"[{"id":"broken","message":"m","patterns":["@#%^&"]}]"#.write(to: rules, atomically: true, encoding: .utf8)
        let result = try sextant(["lint", "--project", package.path, "--rules", rules.path])
        withKnownIssue("the header says `rules: 1` for a rule that never compiled") {
            #expect(result.all.lowercased().contains("could not") || result.code != 0)
        }
    }

    // MARK: - Argument handling

    /// Only `--` prefixes are checked, so a single-dash flag is taken as the positional argument
    /// and the real one is dropped. The answer is a confident negative about the flag's own name.
    @Test("a single-dash flag is refused, not taken as the pattern")
    func singleDashFlagIsRefused() throws {
        let package = try makePackage(name: "dash", files: ["Sources/dash/a.swift": "public func f() { print(1) }\n"])
        let plain = try sextant(["search", "print($$$)", "--project", package.path])
        let mistyped = try sextant(["search", "-json", "print($$$)", "--project", package.path])
        #expect(plain.stdout.contains("total: 1"))
        withKnownIssue("`-json` becomes the pattern and the real pattern is silently dropped") {
            #expect(mistyped.code != 0 || !mistyped.stdout.contains("No matches"))
        }
    }

    /// An empty symbol is a usage error, not a question with the answer "not found".
    @Test("an empty symbol is a usage error")
    func emptySymbolIsUsageError() throws {
        let package = try makePackage(name: "empty", files: ["Sources/empty/a.swift": "public struct Thing {}\n"])
        let result = try sextant(["refs", "", "--project", package.path])
        withKnownIssue("an empty symbol is answered with `not found` and exit 0") {
            #expect(result.code == 2)
        }
    }

    /// An unknown flag is a hard error; an unknown key in `.sextant.json` is silently ignored,
    /// so a whole configuration can be inert while `doctor` reports it as read.
    @Test("unknown keys in .sextant.json are reported")
    func unknownConfigKeysAreReported() throws {
        let package = try makePackage(name: "cfg", files: [
            "Sources/cfg/a.swift": "public struct Thing {}\n",
            ".sextant.json": #"{ "maxfiles": 1, "excludes": ["Sources/**"], "scop": "nope" }"#,
        ])
        let result = try sextant(["doctor", "--project", package.path])
        withKnownIssue("misspelled keys are accepted and the file is reported as read") {
            #expect(result.all.lowercased().contains("unknown") || result.all.contains("maxfiles"))
        }
    }

    // MARK: - Public API

    private static let visibility = """
        public struct TrulyPublic { public let a: Int; public init(a: Int) { self.a = a } }
        struct InternalWithPublicMembers { public let b: Int }
        private struct PrivateWithPublicMembers { public let c: Int }
        """

    /// `api` is sold as the public surface. A type without `public` is not reachable from another
    /// module no matter how its members are marked, so listing it misstates the contract.
    @Test("api lists only types that are public")
    func apiExcludesInternalTypes() throws {
        let package = try makePackage(name: "vis", files: ["Sources/vis/a.swift": Self.visibility])
        let result = try sextant(["api", "--project", package.path, "--scope", "Sources"])
        #expect(result.stdout.contains("TrulyPublic"))
        withKnownIssue("a type with public members is treated as public whatever its own access level") {
            #expect(!result.stdout.contains("InternalWithPublicMembers"))
            #expect(!result.stdout.contains("PrivateWithPublicMembers"))
        }
    }

    /// The same defect reaches the machine contract, where a consumer cannot even see the modifier.
    @Test("api --json lists only types that are public")
    func apiJSONExcludesInternalTypes() throws {
        let package = try makePackage(name: "visj", files: ["Sources/visj/a.swift": Self.visibility])
        let result = try sextant(["api", "--project", package.path, "--scope", "Sources", "--json"])
        withKnownIssue("the JSON surface carries internal and private types too") {
            #expect(!result.stdout.contains("InternalWithPublicMembers"))
        }
    }

    /// A package filter that matches nothing is answered with "there is nothing".
    @Test("api distinguishes an unknown package from an empty one")
    func apiUnknownPackageIsNamed() throws {
        let package = try makePackage(name: "pkg", files: ["Sources/pkg/a.swift": "public struct Thing {}\n"])
        let result = try sextant(["api", "--project", package.path, "--package", "NoSuchPackage"])
        withKnownIssue("an unmatched --package yields `declarations: 0` and exit 0") {
            #expect(result.code != 0 || result.all.lowercased().contains("no such") || result.all.lowercased().contains("unknown package"))
        }
    }

    /// The package name is derived from the first path component, so a project that keeps its
    /// packages anywhere but `Packages/` cannot address any of them by name.
    @Test("a package is addressable by the name in its manifest")
    func packageNameComesFromTheManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-defects-layout-\(UUID().uuidString)")
        let inner = root.appendingPathComponent("LocalPackages/alpha")
        try FileManager.default.createDirectory(at: inner.appendingPathComponent("Sources/Alpha"), withIntermediateDirectories: true)
        try """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "Alpha", products: [.library(name: "Alpha", targets: ["Alpha"])],
                                  targets: [.target(name: "Alpha")])
            """.write(to: inner.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public struct AlphaType {}\n".write(to: inner.appendingPathComponent("Sources/Alpha/a.swift"), atomically: true, encoding: .utf8)

        let result = try sextant(["api", "--project", root.path, "--package", "Alpha"])
        withKnownIssue("the name comes from the path, so `Alpha` addresses nothing") {
            #expect(result.stdout.contains("AlphaType"))
        }
    }

    // MARK: - changed

    /// Removing `public` is a breaking change to the surface; the command promises added, removed
    /// and changed signatures, and reports nothing.
    @Test("changed reports a symbol leaving the public surface")
    func changedSeesAccessLevelChange() throws {
        let package = try makePackage(name: "acc", files: ["Sources/acc/a.swift": "public struct Alpha {}\npublic func topLevel() {}\n"])
        commitAll(package, message: "base")
        try "struct Alpha {}\nprivate func topLevel() {}\n"
            .write(to: package.appendingPathComponent("Sources/acc/a.swift"), atomically: true, encoding: .utf8)
        commitAll(package, message: "narrow the surface")

        let result = try sextant(["changed", "--from", "HEAD~1", "--to", "HEAD", "--project", package.path])
        withKnownIssue("access level is not part of the compared signature") {
            #expect(!result.stdout.contains("No symbol-level changes"))
        }
    }

    /// A file that does not parse yields a partial tree, and the missing half is reported as
    /// deleted symbols. An agent mid-edit produces exactly this state.
    @Test("changed refuses on a file that does not parse")
    func changedRefusesOnUnparsableFile() throws {
        let package = try makePackage(name: "brk", files: ["Sources/brk/a.swift": "public struct Alpha {\n    public func one() {}\n}\npublic func topLevel() {}\n"])
        commitAll(package, message: "base")
        try "public struct Alpha {\n    public func one() {}}}}\npublic func topLevel() {}\n"
            .write(to: package.appendingPathComponent("Sources/brk/a.swift"), atomically: true, encoding: .utf8)

        let result = try sextant(["changed", "--project", package.path])
        withKnownIssue("a recovery tree is diffed as if it were the source") {
            #expect(!result.stdout.contains("− func topLevel()"))
        }
    }

    /// git reports a pure rename as R100; the file list drops the old path, so every declaration
    /// in the new one looks new and nothing looks removed.
    @Test("changed does not report a pure rename as new symbols")
    func changedHandlesRenames() throws {
        let package = try makePackage(name: "ren", files: ["Sources/ren/a.swift": "public struct Alpha {}\n"])
        commitAll(package, message: "base")
        shell("/usr/bin/env", ["git", "mv", "Sources/ren/a.swift", "Sources/ren/b.swift"], in: package)
        commitAll(package, message: "rename")

        let result = try sextant(["changed", "--from", "HEAD~1", "--to", "HEAD", "--project", package.path])
        withKnownIssue("a moved file reads as an added type") {
            #expect(!result.stdout.contains("+ struct Alpha"))
        }
    }
}
