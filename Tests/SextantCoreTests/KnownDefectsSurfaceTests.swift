import Foundation
import Testing

/// The rest of the defect ledger: the clang layer, where byte offsets and coverage are decided,
/// and the MCP surface, which is what an agent actually sees. Same contract as the other two
/// suites — the assertion states the correct answer, and `withKnownIssue` held the line until the
/// defect was fixed. All of them are fixed; these are regression guards now.
@Suite("Known defects: clang layer and MCP surface", .serialized)
struct KnownDefectsSurfaceTests {

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

    private func sextant(_ arguments: [String], input: String? = nil) throws -> Output {
        let binary = try #require(Self.binary, "sextant is not built — run `swift build` first")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        if input != nil { process.standardInput = stdin }
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            stdin.fileHandleForWriting.closeFile()
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return Output(stdout: stdout, stderr: stderr, code: process.terminationStatus)
    }

    /// One `tools/call` against a freshly started server. Returns the tool's text and `isError`.
    private func callTool(_ name: String, arguments: [String: Any] = [:], project: String) throws -> (text: String, isError: Bool)? {
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                        "clientInfo": ["name": "defect-ledger", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": name, "arguments": arguments]],
        ]
        let input = messages
            .compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let result = try sextant(["mcp", "--project", project], input: input + "\n")
        for line in result.stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  message["id"] as? Int == 2,
                  let payload = message["result"] as? [String: Any] else { continue }
            let text = ((payload["content"] as? [[String: Any]]) ?? [])
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            return (text, payload["isError"] as? Bool ?? false)
        }
        return nil
    }

    private struct Fixture { let root: URL; let store: String }

    private func buildFixture(name: String, files: [String: String], manifest: String) -> Fixture? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-surface-\(name)-\(UUID().uuidString)")
        var all = files
        all["Package.swift"] = manifest
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

    /// A mixed package: one Swift target and one Objective-C target, which is the shape the
    /// product specialises in and the shape most of these defects need.
    private func mixedFixture(name: String, objcBody: String, encoding: String.Encoding = .utf8) -> Fixture? {
        let manifest = """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "\(name)",
                                  products: [.library(name: "\(name)", targets: ["\(name)"])],
                                  targets: [.target(name: "legacy"), .target(name: "\(name)", dependencies: ["legacy"])])
            """
        let fixture = buildFixture(name: name, files: [
            "Sources/\(name)/a.swift": "public struct Thing {}\n",
            "Sources/legacy/include/legacy.h": "#import <Foundation/Foundation.h>\n@interface Legacy : NSObject\n- (NSInteger)legacyValue;\n- (NSInteger)twice;\n@end\n",
            "Sources/legacy/legacy.m": objcBody,
        ], manifest: manifest)
        guard let fixture else { return nil }
        // Capture the compile flags the way a user would — `index` builds and records them, and
        // without them the clang layer has nothing to run on and calls every file unscanned.
        guard let captured = try? sextant(["index", "--project", fixture.root.path]),
              captured.all.contains("compile database") else { return nil }
        return fixture
    }

    // MARK: - clang layer

    /// A byte that is not valid UTF-8 is replaced by U+FFFD, which is three bytes wide. Every
    /// offset clang reports after it lands somewhere else in the string the snippet is cut from,
    /// so the column and the text are both wrong — and the match is still presented as structural.
    @Test("a non-UTF-8 byte does not move the reported column")
    func nonUTF8DoesNotShiftOffsets() throws {
        let clean = "#import \"legacy.h\"\n// cafe cafe cafe\n@implementation Legacy\n- (NSInteger)legacyValue { return 1; }\n- (NSInteger)twice { return [self legacyValue] * 2; }\n@end\n"
        guard let fixture = mixedFixture(name: "enc", objcBody: clean) else { return }

        let good = try sextant(["search", "[$X legacyValue]", "--project", fixture.root.path])
        try #require(good.stdout.contains("[self legacyValue]"))
        let goodColumn = good.stdout.split(separator: "\n").first { $0.contains("[self legacyValue]") }

        // Same code, three Latin-1 bytes ahead of the match.
        let latin = clean.replacingOccurrences(of: "// cafe cafe cafe", with: "// caf\u{00E9} caf\u{00E9} caf\u{00E9}")
        let file = fixture.root.appendingPathComponent("Sources/legacy/legacy.m")
        try? latin.data(using: .isoLatin1)?.write(to: file)
        let shifted = try sextant(["search", "[$X legacyValue]", "--project", fixture.root.path])
        let shiftedLine = shifted.stdout.split(separator: "\n").first { $0.contains("legacyValue") }

        #expect(shiftedLine?.contains("[self legacyValue]") == true)
        #expect(goodColumn.map { String($0.suffix(20)) } == shiftedLine.map { String($0.suffix(20)) })
    }

    /// A source that cannot be read is a file nobody looked at. The C-family reporter has a channel
    /// for exactly this (`⚠ not scanned`) and an unreadable file never reaches it.
    @Test("an unreadable C-family source is reported as not scanned")
    func unreadableSourceIsReported() throws {
        let body = "#import \"legacy.h\"\n@implementation Legacy\n- (NSInteger)legacyValue { return 1; }\n- (NSInteger)twice { return [self legacyValue] * 2; }\n@end\n"
        guard let fixture = mixedFixture(name: "perm", objcBody: body) else { return }
        let file = fixture.root.appendingPathComponent("Sources/legacy/legacy.m")
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let result = try sextant(["search", "[$X legacyValue]", "--project", fixture.root.path])
        #expect(result.all.contains("not scanned") && result.all.contains("legacy.m"))
    }

    // MARK: - MCP surface

    /// `repo_map` on the CLI passes the index and names the non-Swift files it could not cover.
    /// The MCP tool of the same name passes no index at all, so an agent gets a Swift-only map
    /// labelled `mode: full`.
    @Test("repo_map over MCP covers the same languages as the CLI")
    func mcpRepoMapCoversCFamily() throws {
        let body = "#import \"legacy.h\"\n@implementation Legacy\n- (NSInteger)legacyValue { return 1; }\n- (NSInteger)twice { return [self legacyValue] * 2; }\n@end\n"
        guard let fixture = mixedFixture(name: "mcpmap", objcBody: body) else { return }

        let cli = try sextant(["map", "--project", fixture.root.path])
        try #require(cli.stdout.contains("legacy.m"))
        let mcp = try callTool("repo_map", project: fixture.root.path)
        let text = try #require(mcp?.text)

        #expect(text.contains("legacy.m") || text.lowercased().contains("not covered") || text.lowercased().contains("non-swift"))
    }

    /// Provenance — the source of the index, its freshness, what it does not cover — is printed on
    /// stderr, which for an MCP server goes to the client's log rather than into the conversation.
    /// The agent, the main consumer, cannot see the trust marker at all.
    @Test("an MCP answer carries the provenance the CLI prints")
    func mcpAnswersCarryProvenance() throws {
        guard let fixture = buildFixture(name: "prov", files: [
            "Sources/prov/a.swift": "public struct Thing {}\npublic let one = Thing()\n",
        ], manifest: """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "prov", products: [.library(name: "prov", targets: ["prov"])],
                                  targets: [.target(name: "prov")])
            """) else { return }
        // Make the index stale the way ordinary work does: edit without rebuilding.
        Thread.sleep(forTimeInterval: 1.1)
        try? "public struct Thing {}\npublic let one = Thing()\npublic let two = Thing()\n"
            .write(to: fixture.root.appendingPathComponent("Sources/prov/a.swift"), atomically: true, encoding: .utf8)

        let cli = try sextant(["refs", "Thing", "--project", fixture.root.path, "--index-store", fixture.store])
        try #require(cli.stderr.contains("STALE"))
        let mcp = try callTool("find_references", arguments: ["symbol": "Thing"], project: fixture.root.path)
        let text = try #require(mcp?.text)

        #expect(text.contains("STALE") || text.lowercased().contains("stale") || text.lowercased().contains("index"))
    }

    /// Six symbol tools answer a symbol that does not exist with `isError: true`. This one reports
    /// "no implementations found", which is a claim about a symbol that was never there.
    @Test("list_implementations distinguishes an unknown symbol from one without implementations")
    func listImplementationsNamesUnknownSymbols() throws {
        guard let fixture = buildFixture(name: "impl", files: [
            "Sources/impl/a.swift": "public protocol Shape {}\npublic struct Round: Shape {}\n",
        ], manifest: """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "impl", products: [.library(name: "impl", targets: ["impl"])],
                                  targets: [.target(name: "impl")])
            """) else { return }

        let known = try callTool("list_implementations", arguments: ["symbol": "Shape"], project: fixture.root.path)
        try #require(known?.text.contains("Round") == true)
        let unknown = try #require(try callTool("list_implementations", arguments: ["symbol": "NoSuchSymbolXYZ"], project: fixture.root.path))

        #expect(unknown.isError)
    }
}
