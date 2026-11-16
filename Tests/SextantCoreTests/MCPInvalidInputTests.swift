import Foundation
import Testing
@testable import SextantCore

/// The MCP server answers every line that is not a valid request with the JSON-RPC error that
/// says why, refuses an undeclared tool and wrongly typed arguments as Invalid params, and still
/// never answers a notification. Lines are written raw, since most of them are not JSON a
/// serializer would produce.
@Suite("MCP invalid input (stdio, e2e)")
struct MCPInvalidInputTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = packageRoot.appendingPathComponent("Tests/Fixtures/IndexFixture")
    static var binary: URL? { BuildProducts.sextantBinary(under: packageRoot) }

    /// One server, the lines written in order, stdin closed; the responses in the order they came.
    private func session(_ lines: [String]) throws -> [[String: Any]] {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-mcp-invalid-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        let executable: URL = try #require(Self.binary, "sextant is not built — run `swift build` first")
        process.executableURL = executable
        process.arguments = ["mcp", "--project", Self.fixture.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SEXTANT_STORE_POLICY"] = nil
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try String(decoding: raw, as: UTF8.self).split(separator: "\n").map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "not a JSON object: \(line)")
        }
    }

    private func code(_ response: [String: Any]) -> Int? {
        (response["error"] as? [String: Any])?["code"] as? Int
    }

    private func message(_ response: [String: Any]) -> String {
        (response["error"] as? [String: Any])?["message"] as? String ?? ""
    }

    @Test("Malformed lines get Parse error or Invalid Request with a null id; notifications get nothing",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func malformedLines() throws {
        let responses = try session([
            "not json",
            "42",
            "[]",
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#,
            #"{"jsonrpc":"2.0","method":"no/such/notification"}"#,
            #"{"jsonrpc":"2.0","id":5,"method":5}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"ping"}"#,
        ])
        #expect(responses.count == 6, "\(responses)")
        guard responses.count == 6 else {
            Issue.record("cannot compare responses: \(responses)")
            return
        }
        #expect(code(responses[0]) == -32700)
        for response in responses[0...3] {
            #expect(response["id"] is NSNull, "\(response)")
            #expect(response["jsonrpc"] as? String == "2.0")
        }
        #expect(responses[1...3].allSatisfy { code($0) == -32600 }, "\(responses)")
        #expect(message(responses[3]).contains("batch"))
        #expect(code(responses[4]) == -32600)
        #expect(responses[4]["id"] as? Int == 5)
        #expect(responses[5]["id"] as? Int == 6)
        #expect(responses[5]["result"] != nil, "the server stopped answering after bad input")
    }

    @Test("An undeclared tool and wrongly typed arguments are Invalid params naming the problem",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func invalidToolCalls() throws {
        func call(_ id: Int, _ name: String, _ arguments: String) -> String {
            #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
        }
        let responses = try session([
            call(1, "no_such_tool", "{}"),
            call(2, "call_hierarchy", #"{"symbol":"Greeter","depth":"x"}"#),
            call(3, "repo_map", #"{"budget":"8k"}"#),
            call(4, "call_hierarchy", #"{"symbol":"Greeter","direction":"sideways"}"#),
            call(5, "context", "{}"),
            #"{"jsonrpc":"2.0","id":6,"method":"no/such/method"}"#,
            call(7, "repo_map", #"{"budget":1e30}"#),
            call(8, "repo_map", #"{"budget":9223372036854775807}"#),
            #"{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{}}"#,
        ])
        #expect(responses.count == 9, "\(responses)")
        guard responses.count == 9 else {
            Issue.record("cannot compare responses: \(responses)")
            return
        }
        let expected: [(Int, String)] = [(1, "Unknown tool: no_such_tool"), (2, "'depth' must be an integer"),
                                         (3, "'budget' must be an integer"), (4, "'direction' must be one of"),
                                         (5, "'symbol' is required")]
        for (response, (id, text)) in zip(responses, expected) {
            #expect(response["id"] as? Int == id)
            #expect(code(response) == -32602, "\(response)")
            #expect(message(response).contains(text), "\(response)")
            #expect(response["result"] == nil, "\(response)")
        }
        #expect(code(responses[5]) == -32601)
        #expect(code(responses[6]) == -32602, "\(responses[6])")
        #expect(message(responses[6]).contains("'budget' is out of range"), "\(responses[6])")
        let huge = ((responses[7]["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(code(responses[8]) == -32602, "a read without a uri is malformed: \(responses[8])")
        #expect(huge.contains("budget \(Int.max) is above the maximum of \(TokenBudget.maximum)"), "\(responses[7])")
    }

    /// `api` read `budget` without declaring it, so validation never saw it and every bad value
    /// was answered with the default surface and no word about it.
    @Test("A bad api budget is Invalid params, as it is for repo_map",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func apiBudgetIsValidated() throws {
        let values = [#""5""#, "2.5", "1e30", "9223372036854775808"]
        let responses = try session(values.enumerated().map { offset, value in
            #"{"jsonrpc":"2.0","id":\#(offset + 1),"method":"tools/call","params":{"name":"api","arguments":{"budget":\#(value)}}}"#
        })
        #expect(responses.count == values.count, "\(responses)")
        for (value, response) in zip(values, responses) {
            #expect(code(response) == -32602, "budget \(value): \(response)")
            #expect(message(response).contains("'budget'"), "budget \(value): \(response)")
        }
    }
}
