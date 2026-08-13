import Foundation
import Testing

/// The half of the ledger that needs a real index store, so every test here builds a throwaway
/// package first. Same contract as the CLI suite: the assertion states the correct answer, and
/// while a defect was open it sat inside `withKnownIssue` so that fixing it failed the suite
/// rather than passing unnoticed. All of them are fixed; these are regression guards now.
///
/// Prerequisites (a toolchain, `libIndexStore`, a build that succeeds) are treated as "not
/// applicable" rather than failure — the same way the existing integration suite does it.
@Suite("Known defects: index-backed answers", .serialized)
struct KnownDefectsIndexTests {

    // MARK: - Harness

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
        let stdout: String, stderr: String, code: Int32
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

    /// A built package: sources on disk plus the store its build produced. `nil` when the
    /// environment cannot build one, which is a skip, not a failure.
    private struct Fixture {
        let root: URL
        let store: String
    }

    private func buildFixture(name: String, files: [String: String], manifest: String? = nil) -> Fixture? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-idx-\(name)-\(UUID().uuidString)")
        var all = files
        all["Package.swift"] = manifest ?? """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
                                  targets: [.target(name: "\(name)")])
            """
        for (path, contents) in all {
            let file = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: file, atomically: true, encoding: .utf8)
        }
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--enable-index-store", "--package-path", root.path]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try? build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else { return nil }

        let buildDirectory = root.appendingPathComponent(".build")
        for triple in (try? FileManager.default.contentsOfDirectory(atPath: buildDirectory.path)) ?? [] {
            let candidate = buildDirectory.appendingPathComponent("\(triple)/debug/index/store").path
            if FileManager.default.fileExists(atPath: candidate) { return Fixture(root: root, store: candidate) }
        }
        return nil
    }

    private func write(_ contents: String, to path: String, in fixture: Fixture) {
        try? contents.write(to: fixture.root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    // MARK: - Freshness

    /// Deleting a source makes nothing "newer", so the freshness test cannot see it. The answer
    /// itself is the only place it shows: a location whose file is gone is the index describing a
    /// state that no longer exists, and it has to be said rather than served as a fact.
    @Test("a deleted source makes the index stale")
    func deletionMarksTheIndexStale() throws {
        guard let fixture = buildFixture(name: "ghost", files: [
            "Sources/ghost/keep.swift": "public struct Keep {}\n",
            "Sources/ghost/gone.swift": "public struct Gone {}\n",
        ]) else { return }
        try? FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Sources/ghost/gone.swift"))

        let result = try sextant(["defs", "Gone", "--project", fixture.root.path, "--index-store", fixture.store])
        #expect(result.stderr.contains("no longer exist") || !result.stdout.contains("gone.swift"))
    }

    /// Freshness covers every language the index does. Walking `*.swift` alone once left the C
    /// family — half of the Apple environment — outside the signal: an edit to a `.m` or a header
    /// kept the marker saying `fresh`, which is a trust label on a stale answer.
    @Test("an edit to a C-family source makes the index stale")
    func cFamilyEditMarksTheIndexStale() throws {
        guard let fixture = buildFixture(name: "cfam", files: [
            "Sources/cfam/a.swift": "public struct Thing {}\n",
            "Sources/legacy/legacy.c": "int legacy(void) { return 1; }\n",
            "Sources/legacy/include/legacy.h": "int legacy(void);\n",
        ], manifest: """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "cfam", products: [.library(name: "cfam", targets: ["cfam"])],
                                  targets: [.target(name: "legacy"), .target(name: "cfam", dependencies: ["legacy"])])
            """) else { return }
        Thread.sleep(forTimeInterval: 1.1)   // mtime granularity: the edit must land after the build
        write("int legacy(void) { return 2; }\n", to: "Sources/legacy/legacy.c", in: fixture)

        let result = try sextant(["defs", "Thing", "--project", fixture.root.path, "--index-store", fixture.store])
        #expect(result.stderr.contains("STALE"))
    }

    // MARK: - Positions that moved

    /// `body` looks up whatever declaration sits on the recorded line and never checks that it is
    /// the symbol that was asked for, so a shifted file answers with someone else's body.
    @Test("body answers with the requested symbol or refuses")
    func bodyDoesNotAnswerWithAnotherSymbol() throws {
        guard let fixture = buildFixture(name: "body", files: [
            "Sources/body/a.swift": "public func alpha() -> Int { 1 }\npublic func beta() -> Int { 2 }\n",
        ]) else { return }
        write("public func beta() -> Int { 2 }\npublic func alpha() -> Int { 1 }\n", to: "Sources/body/a.swift", in: fixture)

        let result = try sextant(["body", "alpha", "--project", fixture.root.path, "--index-store", fixture.store])
        #expect(!result.stdout.contains("func beta"))
    }

    /// Snippets are read from the current file at the index's positions. After an edit the text no
    /// longer belongs to the symbol, and it is printed as if it did.
    @Test("a snippet either matches the symbol or is not printed")
    func snippetsAreNotPrintedFromMovedPositions() throws {
        guard let fixture = buildFixture(name: "snip", files: [
            "Sources/snip/a.swift": "public struct Widget {}\npublic let one = Widget()\n",
        ]) else { return }
        write("// shifted\n// shifted\npublic struct Widget {}\npublic let one = Widget()\n", to: "Sources/snip/a.swift", in: fixture)

        let result = try sextant(["refs", "Widget", "--project", fixture.root.path, "--index-store", fixture.store, "--full"])
        // The recorded lines now hold the inserted comments. Withholding the text is the answer:
        // the position is what the index knows, the text at it is not the symbol's any more.
        #expect(!result.stdout.contains("// shifted"))
        #expect(result.all.contains("withheld"))
    }

    // MARK: - The machine contract

    /// The text answer degrades to textual occurrences behind an explicit marker; `--json` returns
    /// an empty array instead, so a machine reads "no references" where a human reads a warning.
    @Test("--json carries the textual degradation the text answer shows")
    func jsonCarriesDegradation() throws {
        guard let fixture = buildFixture(name: "deg", files: [
            "Sources/deg/a.swift": "public func f() { let localOnly = 1; _ = localOnly }\n",
        ]) else { return }

        let text = try sextant(["refs", "localOnly", "--project", fixture.root.path, "--index-store", fixture.store])
        let json = try sextant(["refs", "localOnly", "--project", fixture.root.path, "--index-store", fixture.store, "--json"])
        guard text.all.contains("⚠") else { return }   // no degradation to compare against
        // The degraded answer is an object, not the array a resolved answer returns: a consumer
        // that decodes it as references would otherwise read textual matches as semantic ones.
        let parsed = try #require((try? JSONSerialization.jsonObject(with: Data(json.stdout.utf8))) as? [String: Any])
        #expect(parsed["degraded"] as? Bool == true)
        #expect((parsed["textual"] as? [Any])?.isEmpty == false)
        #expect((parsed["semantic"] as? [Any])?.isEmpty == true)
    }

    /// `--json` is a contract. On a symbol that is not in the index these three commands print
    /// prose on stdout, so the consumer gets a parse error instead of an answer.
    @Test("--json always emits JSON, including when nothing was found")
    func jsonIsAlwaysJSON() throws {
        guard let fixture = buildFixture(name: "js", files: ["Sources/js/a.swift": "public struct Thing {}\n"]) else { return }
        for command in ["blast", "hierarchy", "context"] {
            let result = try sextant([command, "NoSuchSymbolXYZ", "--project", fixture.root.path,
                                      "--index-store", fixture.store, "--json"])
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed.isEmpty || trimmed.hasPrefix("[") || trimmed.hasPrefix("{"))
        }
    }

    // MARK: - Counts

    /// The header number reads as "how many there are". Under `--limit` it silently becomes
    /// "how many were shown", so a limited query answers a counting question with the limit.
    @Test("a limited answer does not present the limit as the total")
    func limitIsNotPresentedAsTheTotal() throws {
        guard let fixture = buildFixture(name: "lim", files: [
            "Sources/lim/a.swift": """
                public protocol Shape {}
                public struct A: Shape {}
                public struct B: Shape {}
                public struct C: Shape {}
                """,
        ]) else { return }

        let all = try sextant(["impls", "Shape", "--project", fixture.root.path, "--index-store", fixture.store])
        let limited = try sextant(["impls", "Shape", "--project", fixture.root.path, "--index-store", fixture.store, "--limit", "1"])
        guard all.stdout.contains("Shape: 3") else { return }
        #expect(!limited.stdout.contains("Shape: 1") || limited.stdout.contains("more"))
    }

    /// Two occurrences on one line are two entries in the list and two in the count, so the number
    /// overstates how many places actually construct the type.
    @Test("construct counts a position once")
    func constructCountsAPositionOnce() throws {
        guard let fixture = buildFixture(name: "ctor", files: [
            "Sources/ctor/a.swift": """
                public struct Box { public init() {} }
                public func make(_ x: Box = Box(), _ y: Box = Box()) {}
                """,
        ]) else { return }

        let result = try sextant(["construct", "Box", "--project", fixture.root.path, "--index-store", fixture.store])
        let lines = result.stdout.split(separator: "\n").filter { $0.contains("a.swift:") }
        let positions = Set(lines.map { String($0) })
        #expect(lines.count == positions.count)
    }
}
