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
        #expect(initialize["protocolVersion"] as? String == "2025-06-18")
        let instructions = initialize["instructions"] as? String ?? ""
        for name in MCPTools.names { #expect(instructions.contains(name), "initialize does not mention \(name)") }

        let listed = ((responses[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        #expect(Set(listed.compactMap { $0["name"] as? String }) == Set(MCPTools.names))

        #expect(responses[2]["result"] != nil)
        #expect((responses[3]["error"] as? [String: Any])?["code"] as? Int == -32601)
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
            #expect(!text(of: response).contains("unknown tool"), "\(name) is not handled in callMCPTool")
        }
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
