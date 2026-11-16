import Foundation
import Testing
@testable import SextantCore

/// Answers that are cut, capped or merged say so, with the true total, and the two ways of asking
/// for one answer give the same text. Most of it lives in the MCP server, so the built binary is
/// driven over stdio; the index-backed cases build a throwaway package first.
@Suite("MCP answers state what they cut", .serialized)
struct MCPAnswerBoundsTests {

    // MARK: - Harness

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static var binary: URL? { BuildProducts.sextantBinary(under: repositoryRoot) }

    private static var hasBinary: Bool { binary != nil }

    private struct Output {
        let stdout: String, stderr: String
    }

    private func sextant(_ arguments: [String], input: String? = nil) throws -> Output {
        let binary = try #require(Self.binary, "sextant is not built — run `swift build` first")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
        }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Output(stdout: stdout, stderr: stderr)
    }

    /// Runs one MCP session against `project` and returns each response's `result` by request id.
    private func session(project: URL, _ requests: [[String: Any]]) throws -> [Int: [String: Any]] {
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 0, "method": "initialize",
             "params": ["protocolVersion": MCPProtocol.revision, "capabilities": [String: Any](),
                        "clientInfo": ["name": "answer-bounds", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ] + requests
        let input = try messages
            .map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let output = try sextant(["mcp", "--project", project.path], input: input)
        var results: [Int: [String: Any]] = [:]
        for line in output.stdout.split(separator: "\n") {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = message["id"] as? Int,
                  let result = message["result"] as? [String: Any] else { continue }
            results[id] = result
        }
        return results
    }

    private func callTool(_ name: String, _ arguments: [String: Any] = [:], project: URL) throws -> (text: String, isError: Bool) {
        let results = try session(project: project, [
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]],
        ])
        let result = try #require(results[1], "no answer to tools/call \(name)")
        return (toolText(result), result["isError"] as? Bool ?? false)
    }

    private func toolText(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func write(_ files: [String: String], name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-bounds-\(name)-\(UUID().uuidString)")
        for (path, contents) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func manifest(_ name: String) -> String {
        """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
                              targets: [.target(name: "\(name)")])
        """
    }

    /// A Swift package built with an index store. The build is a precondition, so a failure to
    /// produce a store fails the test rather than skipping it.
    private func builtPackage(_ name: String, files: [String: String]) throws -> (root: URL, store: String) {
        var all = files
        all["Package.swift"] = manifest(name)
        let root = try write(all, name: name)
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--enable-index-store", "--package-path", root.path]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        let store = try #require(BuildProducts.indexStore(under: root), "the fixture built no index store")
        return (root, store)
    }

    private func remove(_ root: URL) {
        BuildProducts.removeIndexSnapshots(under: root)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - body

    /// The index records a line; the file moves; whatever declaration now starts on that line is
    /// someone else's. The CLI checked the name and MCP did not, so an agent got `beta`'s body as
    /// the answer to `body alpha`, marked as a success.
    @Test("body over MCP refuses a declaration of another name on the recorded line", .enabled(if: hasBinary))
    func mcpBodyChecksTheName() throws {
        let fixture = try builtPackage("staleBody", files: [
            "Sources/staleBody/a.swift": "public func alpha() -> Int { 1 }\npublic func beta() -> Int { 2 }\n",
        ])
        defer { remove(fixture.root) }
        try "public func beta() -> Int { 2 }\npublic func alpha() -> Int { 1 }\n"
            .write(to: fixture.root.appendingPathComponent("Sources/staleBody/a.swift"), atomically: true, encoding: .utf8)

        let answer = try callTool("body", ["symbol": "alpha"], project: fixture.root)

        #expect(!answer.text.contains("beta"), "another declaration's body was returned: \(answer.text)")
        #expect(answer.isError, "a body that could not be extracted is not a successful answer")
        #expect(answer.text.contains("changed since it was indexed"))
    }

    @Test("Extraction keeps a declaration only while it still has the asked name")
    func extractionChecksTheName() throws {
        let root = try write(["a.swift": "public func beta() -> Int { 2 }\npublic func alpha() -> Int { 1 }\n"], name: "extract")
        defer { remove(root) }
        let path = root.appendingPathComponent("a.swift").path
        let recorded = [SextantCore.SourceLocation(path: path, line: 1, column: 13, isDefinition: true)]

        #expect(SourceBody.bodies(of: "alpha", at: recorded).isEmpty)
        #expect(SourceBody.bodies(of: "beta", at: recorded).map(\.text) == ["public func beta() -> Int { 2 }"])
    }

    // MARK: - Cuts that state their total

    /// A budget below the minimum used to be raised to 500 without a word, so the answer did not
    /// match the request and did not say why.
    @Test("A budget below the minimum is raised, and the answer says so", .enabled(if: hasBinary))
    func raisedBudgetIsNamed() throws {
        let root = try write(["Sources/M/A.swift": "public struct A {}\n"], name: "budget")
        defer { remove(root) }

        let small = try callTool("repo_map", ["budget": 10], project: root)
        #expect(small.text.hasSuffix("⚠ budget 10 is below the minimum of 500; 500 was used"), "\(small.text)")
        let usual = try callTool("repo_map", ["budget": 500], project: root)
        #expect(!usual.text.contains("below the minimum"))
        let shallow = try callTool("call_hierarchy", ["symbol": "A", "depth": 0], project: root)
        #expect(shallow.isError || shallow.text.contains("⚠ depth 0 is below the minimum of 1; 1 was used"), "\(shallow.text)")
    }

    @Test("lint over MCP states how many violations it did not print", .enabled(if: hasBinary))
    func lintStatesItsCut() throws {
        let body = (1...250).map { "    let value\($0) = try! make()" }.joined(separator: "\n")
        let root = try write(["Sources/Lint/Many.swift": "func make() throws -> Int { 1 }\nfunc many() {\n\(body)\n}\n"],
                             name: "lint")
        defer { remove(root) }

        let answer = try callTool("lint", project: root)

        #expect(answer.text.components(separatedBy: "\n").filter { $0.hasPrefix("[force-try]") }.count == 200)
        #expect(answer.text.contains("first 200 of 250 violations shown"))
    }

    /// The Swift half used to stop after the file that crossed 200, print every match of that
    /// file, and still say "first 200" — a count that was neither the shown number nor the total.
    @Test("structural_search over MCP states the Swift total it cut", .enabled(if: hasBinary))
    func swiftSearchStatesItsCut() throws {
        func calls(_ range: ClosedRange<Int>) -> String {
            "func run(_ g: G) {\n" + range.map { _ in "    g.greet()" }.joined(separator: "\n") + "\n}\n"
        }
        let root = try write([
            "Sources/Search/G.swift": "struct G { func greet() {} }\n",
            "Sources/Search/A.swift": calls(1...150),
            "Sources/Search/B.swift": calls(151...300),
        ], name: "search")
        defer { remove(root) }

        let answer = try callTool("structural_search", ["pattern": "$X.greet()"], project: root)

        #expect(answer.text.components(separatedBy: "\n").filter { $0.contains(": g.greet()") }.count == 200)
        #expect(answer.text.contains("first 200 of 300 Swift matches shown"))
    }

    @Test("structural_search over MCP states the C-family total it cut", .enabled(if: hasBinary))
    func cFamilySearchStatesItsCut() throws {
        let calls = (1...250).map { _ in "    [self legacyValue];" }.joined(separator: "\n")
        let root = try write([
            "Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(name: "csearch",
                                      products: [.library(name: "csearch", targets: ["csearch"])],
                                      targets: [.target(name: "legacy"), .target(name: "csearch", dependencies: ["legacy"])])
                """,
            "Sources/csearch/a.swift": "public struct Thing {}\n",
            "Sources/legacy/include/legacy.h": "#import <Foundation/Foundation.h>\n@interface Legacy : NSObject\n- (NSInteger)legacyValue;\n- (void)many;\n@end\n",
            "Sources/legacy/legacy.m": "#import \"legacy.h\"\n@implementation Legacy\n- (NSInteger)legacyValue { return 1; }\n- (void)many {\n\(calls)\n}\n@end\n",
        ], name: "csearch")
        defer { remove(root) }
        // The clang layer needs the compile flags `index` captures; without them the file is
        // reported as not scanned and there is nothing to cut.
        let indexed = try sextant(["index", "--project", root.path])
        try #require((indexed.stdout + indexed.stderr).contains("compile database"), "compile flags were not captured")

        let answer = try callTool("structural_search", ["pattern": "[$X legacyValue]"], project: root)

        #expect(answer.text.components(separatedBy: "\n").filter { $0.contains("[self legacyValue]") }.count == 200)
        #expect(answer.text.contains("first 200 of 250 C-family matches shown"))
    }

    @Test("list_implementations over MCP states the total past its cap", .enabled(if: hasBinary))
    func implementationsStateTheirCut() throws {
        let conformers = (1...1005).map { String(format: "public struct Square%04d: Shape {}", $0) }
        let fixture = try builtPackage("impls", files: [
            "Sources/impls/Shapes.swift": "public protocol Shape {}\n" + conformers.joined(separator: "\n") + "\n",
        ])
        defer { remove(fixture.root) }

        let answer = try callTool("list_implementations", ["symbol": "Shape"], project: fixture.root)

        #expect(answer.text.components(separatedBy: "\n").filter { $0.hasPrefix("Square") }.count == 1000)
        #expect(answer.text.contains("first 1000 of 1005 shown"))
    }

    @Test("call_hierarchy states, per node, the callees it did not expand — over MCP and the CLI", .enabled(if: hasBinary))
    func hierarchyStatesItsCut() throws {
        let leaves = (1...45).map { String(format: "func leaf%02d() {}", $0) }.joined(separator: "\n")
        let calls = (1...45).map { String(format: "    leaf%02d()", $0) }.joined(separator: "\n")
        let fixture = try builtPackage("hierarchy", files: [
            "Sources/hierarchy/Calls.swift": "\(leaves)\npublic func hierarchyRoot() {\n\(calls)\n}\n",
        ])
        defer { remove(fixture.root) }

        let mcp = try callTool("call_hierarchy", ["symbol": "hierarchyRoot", "direction": "callees", "depth": 1],
                               project: fixture.root)
        #expect(mcp.text.components(separatedBy: "\n").filter { $0.contains("leaf") }.count == 40)
        #expect(mcp.text.contains("first 40 of 45 callees shown"))

        let cli = try sextant(["hierarchy", "hierarchyRoot", "--callees", "--depth", "1",
                               "--project", fixture.root.path, "--index-store", fixture.store])
        #expect(cli.stdout.contains("first 40 of 45 callees shown"))

        // The JSON shape is under the stability contract: the cut is stated in text only.
        let json = try sextant(["hierarchy", "hierarchyRoot", "--callees", "--depth", "1", "--json",
                                "--project", fixture.root.path, "--index-store", fixture.store])
        let trees = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [[String: Any]])
        let root = try #require(trees.first)
        #expect((root["children"] as? [Any])?.count == 40)
        #expect(Set(root.keys).isSubset(of: ["name", "kind", "file", "line", "calledAtFile", "calledAtLine",
                                             "definitionKnown", "children"]))
    }

    // MARK: - blast

    /// The lookup behind `blast` stopped at 1000 locations: a symbol with more reported 1000 as
    /// its count and listed only the files those first 1000 happened to be in.
    @Test("blast counts every usage and lists every affected file past the internal cap")
    func blastCountsPastTheCap() throws {
        let uses = (1...1001).map { _ in "    _ = Thing()" }.joined(separator: "\n")
        let fixture = try builtPackage("blast", files: [
            "Sources/blast/a.swift": "public struct Thing {}\nfunc many() {\n\(uses)\n}\n",
            "Sources/blast/z.swift": "func last() { _ = Thing() }\n",
        ])
        defer { remove(fixture.root) }
        let library = try #require(IndexStoreUnits.discoverLibrary(), "libIndexStore not found")
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-bounds-db-\(UUID().uuidString)")
        defer { remove(database) }
        let set = try IndexStoreSet(storePaths: [fixture.store], libraryPath: library,
                                    databaseRoot: database.path, projectRoot: fixture.root.path)

        let radius = try #require(set.blastRadius(forName: "Thing"))

        #expect(radius.referenceCount == 1002)
        #expect(radius.affectedFiles.contains { $0.hasSuffix("/z.swift") })
    }

    @Test("blast says when the radius is a sum over several symbols sharing the name", .enabled(if: hasBinary))
    func blastNamesMergedSymbols() throws {
        let fixture = try builtPackage("merged", files: [
            "Sources/merged/a.swift": """
                public struct Alpha { public func launch() {} }
                public struct Beta { public func launch() {} }
                func both() { Alpha().launch(); Beta().launch() }
                """,
        ])
        defer { remove(fixture.root) }

        let mcp = try callTool("blast_radius", ["symbol": "launch"], project: fixture.root)
        #expect(mcp.text.contains("2 distinct symbols"))

        let cli = try sextant(["blast", "launch", "--project", fixture.root.path, "--index-store", fixture.store])
        #expect(cli.stdout.contains("2 distinct symbols"))

        // Text only: the JSON keeps the fields it always had.
        let json = try sextant(["blast", "launch", "--json", "--project", fixture.root.path, "--index-store", fixture.store])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["symbol", "kind", "definitions", "referenceCount", "callerCount",
                                     "affectedFiles", "implementations"])
    }

    // MARK: - repo_map

    /// The resource and the tool are two ways of asking for one map. The resource skipped the
    /// index, the scale note and the note about non-Swift files, so it answered as if complete.
    @Test("The repo_map resource gives the tool's answer, notes included", .enabled(if: hasBinary))
    func repoMapResourceMatchesTool() throws {
        let root = try write([
            ".sextant.json": #"{ "maxFiles": 1 }"#,
            "Sources/Map/A.swift": "public struct Alpha {}\n",
            "Sources/Map/B.swift": "public struct Beta {}\n",
            "Sources/legacy/legacy.m": "int legacy(void) { return 1; }\n",
        ], name: "map")
        defer { remove(root) }

        let results = try session(project: root, [
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "repo_map", "arguments": [String: Any]()]],
            ["jsonrpc": "2.0", "id": 2, "method": "resources/read", "params": ["uri": "sextant://repo_map"]],
        ])
        let tool = toolText(try #require(results[1]))
        let contents = try #require(results[2]?["contents"] as? [[String: Any]])
        let resource = try #require(contents.first?["text"] as? String)

        // The bound counts the Objective-C file as well as the two Swift ones.
        #expect(tool.contains("covered 1 of 3 file(s)"))
        #expect(tool.contains("non-Swift file(s) are missing"))
        #expect(resource == tool)
    }
}
