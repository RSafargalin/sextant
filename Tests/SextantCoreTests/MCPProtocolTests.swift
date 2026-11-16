import Foundation
import Testing
@testable import SextantCore

/// End-to-end check of the MCP surface: the built binary is run as a stdio server and requests go
/// over JSON-RPC. A black box is the only way to cover a protocol that lives in the executable.
@Suite("MCP protocol (stdio, e2e)")
struct MCPProtocolTests {
    /// Repository root from the test file: Tests/SextantCoreTests/<file> → three levels up.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var binary: URL { repositoryRoot.appendingPathComponent(".build/debug/sextant") }
    private var fixture: URL { repositoryRoot.appendingPathComponent("Tests/Fixtures/IndexFixture") }

    /// Drives a session: writes requests line by line, closes stdin, parses the responses.
    /// Fixture responses are small, so reading after writing cannot overflow the pipe.
    private func session(_ requests: [[String: Any]]) throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp", "--project", fixture.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        for request in requests {
            let data = try JSONSerialization.data(withJSONObject: request)
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
        }
        try input.fileHandleForWriting.close()
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: raw, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func text(of response: [String: Any]) -> String {
        let content = (response["result"] as? [String: Any])?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }

    @Test("initialize / tools-list / ping / unknown method")
    func handshakeAndErrors() throws {
        #expect(FileManager.default.fileExists(atPath: binary.path), "binary not built — run `swift build`")

        let responses = try session([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [String: Any]()],
            ["jsonrpc": "2.0", "id": 3, "method": "ping", "params": [String: Any]()],
            ["jsonrpc": "2.0", "id": 4, "method": "nope/nope", "params": [String: Any]()]
        ])
        #expect(responses.count == 4)

        let initialize = (responses[0]["result"] as? [String: Any]) ?? [:]
        #expect((initialize["serverInfo"] as? [String: Any])?["name"] as? String == "sextant")
        #expect(initialize["protocolVersion"] as? String == MCPProtocol.revision)
        let instructions = initialize["instructions"] as? String ?? ""
        for name in MCPTools.names { #expect(instructions.contains(name), "initialize does not mention \(name)") }

        let listed = ((responses[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        #expect(Set(listed.compactMap { $0["name"] as? String }) == Set(MCPTools.names))

        #expect(responses[2]["result"] != nil)
        #expect((responses[3]["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    /// The handshake is a claim about what this build speaks. Echoing the client's request turned
    /// every guess into a confirmation — a client naming a revision published after this binary was
    /// compiled would be told it was supported, and would then be free to use it.
    @Test("The revision answered is the one this build implements, not the one asked for")
    func answersItsOwnRevision() throws {
        #expect(FileManager.default.fileExists(atPath: binary.path), "binary not built — run `swift build`")

        let responses = try session([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2099-01-01", "capabilities": [String: Any]()]]
        ])
        let initialize = (responses.first?["result"] as? [String: Any]) ?? [:]
        #expect(initialize["protocolVersion"] as? String == MCPProtocol.revision,
                "the server confirmed a revision it was merely told about")
    }

    @Test("Every declared tool is handled by the dispatcher")
    func everyToolIsDispatched() throws {
        var requests: [[String: Any]] = [["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [String: Any]()]]
        for (offset, name) in MCPTools.names.enumerated() {
            requests.append([
                "jsonrpc": "2.0", "id": offset + 2, "method": "tools/call",
                // Every kind of argument at once: a tool either works or honestly asks for its own.
                "params": ["name": name, "arguments": ["symbol": "Greeter", "pattern": "$X.greet()"]]
            ])
        }
        let responses = try session(requests)
        #expect(responses.count == MCPTools.names.count + 1)

        for (name, response) in zip(MCPTools.names, responses.dropFirst()) {
            // A protocol error here would leave the text empty and the check below vacuous.
            #expect(response["result"] != nil, "\(name) was refused before reaching the dispatcher: \(response)")
            #expect(!text(of: response).contains("unknown tool"), "\(name) is not handled in callMCPTool")
        }
    }

    /// An argument a handler reads but the schema does not declare escapes validation: `api` read
    /// `budget` that way, and every bad value was answered as if none had been given. One the
    /// schema declares but no handler reads is a promise the tool does not keep. The arguments
    /// are taken from the dispatcher's own source, one `case` at a time.
    @Test("Every argument a handler reads is declared in its schema, and every declared one is read")
    func handlersReadExactlyTheDeclaredArguments() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/sextant/MCPServer.swift"),
                                encoding: .utf8)
        let start = try #require(source.range(of: "private func callMCPTool("), "the dispatcher was not found")
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let caseLabel = try Regex(#"\n\s*case "([a-z_]+)":"#)
        let argumentRead = try Regex(#"args\["([A-Za-z_]+)"\]"#)
        let labels = body.matches(of: caseLabel)
        var readByTool: [String: Set<String>] = [:]
        for (offset, label) in labels.enumerated() {
            let name = String(try #require(label.output[1].substring))
            let blockEnd = offset + 1 < labels.count ? labels[offset + 1].range.lowerBound : body.endIndex
            let block = body[label.range.upperBound..<blockEnd]
            var read = Set(block.matches(of: argumentRead).compactMap { $0.output[1].substring.map(String.init) })
            if block.contains("symbol()") { read.insert("symbol") }
            readByTool[name] = read
        }
        #expect(Set(readByTool.keys) == Set(MCPTools.names), "could not parse the dispatcher: \(readByTool.keys.sorted())")
        for name in MCPTools.names {
            let schema = MCPTools.definition(named: name)?["inputSchema"] as? [String: Any] ?? [:]
            let declared = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
            let read = readByTool[name] ?? []
            #expect(read.subtracting(declared).isEmpty, "\(name) reads undeclared argument(s): \(read.subtracting(declared).sorted())")
            #expect(declared.subtracting(read).isEmpty, "\(name) declares argument(s) it never reads: \(declared.subtracting(read).sorted())")
        }
    }

    @Test("A structural miss names the files it never opened")
    func structuralSearchNamesUnscannedFiles() throws {
        let responses = try session([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [String: Any]()],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "structural_search", "arguments": ["pattern": "$X.nowhereToBeFound()"]]]
        ])
        let answer = text(of: try #require(responses.last))
        #expect(answer.contains("no matches"))
        // A Swift pattern does not compile in a C-family file. Without this line the agent reads
        // "no matches" as an answer about the whole project.
        #expect(answer.contains("not scanned"))
        #expect(answer.contains("ObjCFixture.m"))
    }

    /// Answering this needs the fixture's compile flags, which come from a build. Without them
    /// the test would fail on a machine that never ran `sextant index` — a real gap, but not this
    /// test's gap, and `make ci` prepares them.
    private static var fixtureIsIndexed: Bool {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndexFixture")
        return !CompilationDatabase.load(forRoot: fixture.path).isEmpty && ClangLibrary.discoverPath() != nil
    }

    @Test("An Objective-C pattern is answered through MCP, not only in the CLI",
          .enabled(if: fixtureIsIndexed, "the fixture has no compile flags — run `make fixture`"))
    func structuralSearchCoversObjectiveC() throws {
        let responses = try session([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [String: Any]()],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "structural_search", "arguments": ["pattern": "[$X ocFeed]"]]]
        ])
        let answer = text(of: try #require(responses.last))
        #expect(answer.contains("ObjCFixture.m:34:12: [self ocFeed]"))
        #expect(answer.contains("ObjCFixture.m:34:28: [self ocFeed]"))
    }

    @Test("api returns the public surface including protocol requirements")
    func apiToolReturnsSurface() throws {
        let responses = try session([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [String: Any]()],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "api", "arguments": ["type": "Greeter"]]]
        ])
        let surface = text(of: try #require(responses.last))
        #expect(surface.contains("protocol Greeter"))
        #expect(surface.contains("greet()"))   // the protocol requirement is visible (access inheritance)
        #expect((responses.last?["result"] as? [String: Any])?["isError"] as? Bool == false)
    }
}
