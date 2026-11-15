import Foundation
@testable import SextantCore

/// Where a SwiftPM build leaves what the tests run and read. Kept in one place because the
/// layout of `.build` belongs to SwiftPM and differs between its build systems.
enum BuildProducts {
    /// The built `sextant` binary of a package, or nil when it has not been built.
    /// `.build/debug` is a symlink into the layout of whichever build system ran last.
    static func sextantBinary(under root: URL) -> URL? {
        let candidate = root.appendingPathComponent(".build/debug/sextant")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// The debug index store of a package, found the way the tool itself finds it: the one
    /// `sextant index` wrote in its own build tree when there is one, otherwise the one a
    /// `swift build --enable-index-store` wrote in `.build`.
    static func indexStore(under root: URL) -> String? {
        let usable = IndexStoreLocator.usableStorePaths(under: root)
        let own = IndexStoreLocator.indexBuildDirectory(ofPackage: root).path + "/"
        return usable.first { $0.hasPrefix(own) } ?? usable.first
    }

    /// libIndexStore of the active toolchain, found the way the tool finds it.
    static var indexStoreLibrary: String? { IndexStoreUnits.discoverLibrary() }

    /// The compile flags of a built and indexed package. The native build system leaves a graph
    /// beside the store; the Swift Build system leaves none, and there the flags are the ones
    /// `sextant index` read from the build's own output and stored.
    static func compileCommands(under root: URL) -> [CompileCommand] {
        let fromGraph = CompilationDatabase.capture(fromStores: IndexStoreLocator.usableStorePaths(under: root))
        return fromGraph.isEmpty ? CompilationDatabase.load(forRoot: root.path) : fromGraph
    }

    /// Runs the built binary with a home of its own (`CFFIXED_USER_HOME`), without a daemon and
    /// without the variables that steer it from outside, and returns its exit code and output.
    static func runSextant(_ arguments: [String], home: URL, environment extra: [String: String] = [:],
                           in directory: URL? = nil) throws -> (code: Int32, output: String, errors: String) {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let binary = sextantBinary(under: repository) else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var environment = ProcessInfo.processInfo.environment
        for name in ["SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA", "CLAUDE_PROJECT_DIR", "SEXTANT_TELEMETRY"] {
            environment[name] = nil
        }
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SEXTANT_NO_DAEMON"] = "1"
        process.environment = environment.merging(extra) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let collected = OutputCapture.collect(from: [out, err]) { process.waitUntilExit() }
        return (process.terminationStatus, collected[0], collected[1])
    }

    /// Calls one MCP tool on `project` through `sextant mcp`, with a home of its own, and returns
    /// the text of the answer and whether it is an error.
    static func callTool(_ name: String, _ arguments: [String: Any], project: URL, home: URL) throws -> (text: String, isError: Bool) {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let binary = sextantBinary(under: repository) else { throw CocoaError(.fileNoSuchFile) }
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 0, "method": "initialize",
             "params": ["protocolVersion": MCPProtocol.revision, "capabilities": [String: Any](),
                        "clientInfo": ["name": "tests", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]],
        ]
        let input = try messages.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp", "--project", project.path]
        var environment = ProcessInfo.processInfo.environment
        for variable in ["SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA", "CLAUDE_PROJECT_DIR", "SEXTANT_TELEMETRY"] {
            environment[variable] = nil
        }
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment
        let stdin = Pipe(), out = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = OutputCapture.collect(from: [out]) { process.waitUntilExit() }[0]
        for line in output.split(separator: "\n") {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  message["id"] as? Int == 1, let result = message["result"] as? [String: Any] else { continue }
            let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return (text, result["isError"] as? Bool ?? false)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// Whether the built binary is there for the end-to-end tests.
    static var hasSextantBinary: Bool {
        sextantBinary(under: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()) != nil
    }

    /// A Swift package written into `root`: a C target `CLib` and a Swift target `App` that
    /// depends on it, with `swift` as the Swift source.
    static func writeCPackage(at root: URL, swift: String) throws {
        let files = [
            "Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(name: "flags", targets: [
                    .target(name: "CLib"),
                    .target(name: "App", dependencies: ["CLib"]),
                ])
                """,
            "Sources/CLib/include/lib.h": "int lib_value(void);\n",
            "Sources/CLib/lib.c": "int lib_value(void) { return 1; }\n",
            "Sources/App/app.swift": swift,
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Removes the snapshots `sextant index` recorded in the real cache for the stores of a
    /// package's own build tree, for tests that run it outside a sandboxed home.
    static func removeIndexSnapshots(under root: URL) {
        for store in IndexStoreLocator.storePaths(inBuildDirectory: IndexStoreLocator.indexBuildDirectory(ofPackage: root)) {
            try? FileManager.default.removeItem(at: IndexSnapshot.location(forStore: store))
        }
    }
}
