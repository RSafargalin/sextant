import Foundation
import Testing
@testable import SextantCore

/// A `.sextant.json` edited while `sextant mcp` runs takes effect on the next message, including
/// the store policy that decides which stores answer. The server is driven one message at a time,
/// so the file can change between two calls of one session.
@Suite("MCP config reload (e2e)", .serialized)
struct MCPConfigReloadTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var binary: URL? { BuildProducts.sextantBinary(under: packageRoot) }
    private static var fixtureStore: String? {
        BuildProducts.indexStore(under: packageRoot.appendingPathComponent("Tests/Fixtures/IndexFixture"))
    }

    /// One running server, answering one message per `send`.
    private final class Session {
        let process = Process()
        private let input = Pipe(), output = Pipe()
        private var buffer = Data()

        init(binary: URL, project: URL, home: URL) throws {
            process.executableURL = binary
            process.arguments = ["mcp", "--project", project.path]
            var environment = ProcessInfo.processInfo.environment
            for name in ["SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA", "CLAUDE_PROJECT_DIR", "SEXTANT_TELEMETRY"] {
                environment[name] = nil
            }
            environment["CFFIXED_USER_HOME"] = home.path
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        /// Sends `message` and returns the response carrying `id`.
        func send(_ message: [String: Any], id: Int) throws -> [String: Any] {
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
            while true {
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    if let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       response["id"] as? Int == id {
                        return response
                    }
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw CocoaError(.fileReadUnknown) }
                buffer.append(chunk)
            }
        }

        func close() {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }

    private func text(_ response: [String: Any]) -> String {
        let result = response["result"] as? [String: Any] ?? [:]
        return ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    @Test("A store policy written mid-session decides the stores of the very next call",
          .enabled(if: binary != nil && fixtureStore != nil, "needs the built binary and the fixture's store — run `make fixture`"),
          .timeLimit(.minutes(2)))
    func policyEditedMidSessionTakesEffectOnTheNextCall() throws {
        let binary = try #require(Self.binary)
        let store = try #require(Self.fixtureStore)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-reload-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("package")
        let home = base.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"reload\")\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // Two ordinary stores and no policy: the server refuses to choose until one is set.
        for layout in ["out/Products/Debug", "arm64-apple-macosx/debug"] {
            let directory = root.appendingPathComponent(".build/\(layout)/index")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: store), to: directory.appendingPathComponent("store"))
        }

        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                         "params": ["protocolVersion": MCPProtocol.revision, "capabilities": [String: Any](),
                                                    "clientInfo": ["name": "reload", "version": "1"]]]
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": ["name": "who_defines", "arguments": ["symbol": "EnglishGreeter"]]]
        let session = try Session(binary: binary, project: root, home: home)
        defer { session.close() }
        _ = try session.send(initialize, id: 0)
        let before = text(try session.send(call, id: 1))
        #expect(before.contains("store policy"), "\(before)")

        try #"{"storePolicy": "recency"}"#.write(to: root.appendingPathComponent(".sextant.json"),
                                                 atomically: true, encoding: .utf8)
        let after = text(try session.send(call, id: 1))
        #expect(!after.contains("store policy"), "\(after)")

        // The same call in a session started after the edit: the edit is all the difference.
        let fresh = try Session(binary: binary, project: root, home: home)
        defer { fresh.close() }
        _ = try fresh.send(initialize, id: 0)
        #expect(after == text(try fresh.send(call, id: 1)))
    }
}
