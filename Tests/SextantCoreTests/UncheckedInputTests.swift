import Foundation
import Testing
@testable import SextantCore

/// What `search` and `lint` could not really check is named, never passed off as "checked, no
/// matches": a Swift file that cannot be read, one read through the parser's recovery, a skipped
/// directory that holds sources, and a pattern that is refused.
@Suite("Unchecked input is named")
struct UncheckedInputTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var binary: URL? { BuildProducts.sextantBinary(under: packageRoot) }

    /// A scratch project; removed when the value goes away.
    private final class Project {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-unchecked-\(UUID().uuidString.prefix(8))", isDirectory: true)

        init(_ files: [String: String]) throws {
            for (path, contents) in files { try write(contents, to: path) }
        }

        func write(_ contents: String, to path: String) throws {
            try write(Data(contents.utf8), to: path)
        }

        func write(_ data: Data, to path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

        deinit {
            // An unreadable file has to be made readable again before it can be removed.
            if let enumerator = FileManager.default.enumerator(atPath: root.path) {
                for case let relative as String in enumerator {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(relative))
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A clean file, a file that is not UTF-8, an unreadable one, and one with syntax errors —
    /// each with an occurrence of `try? $X.save()`.
    private func mixedProject() throws -> Project {
        let project = try Project([
            "Sources/Clean.swift": "func a() { try? x.save() }\n",
            "Sources/Broken.swift": "func b( { try? y.save() }\nlet q = (\n",
            "Sources/Locked.swift": "func c() { try? z.save() }\n",
        ])
        var latin1 = Data("func d() { try? w.save() } // ".utf8)
        latin1.append(contentsOf: [0xFF, 0xFE, 0x0A])
        try project.write(latin1, to: "Sources/Latin1.swift")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: project.path("Sources/Locked.swift"))
        return project
    }

    @Test("search names a Swift file it could not read or decode, and one it read through errors")
    func searchNamesUnreadAndRecoveredFiles() throws {
        let project = try mixedProject()
        let files = SwiftSources.files(under: project.root, includeTests: false)
        let outcome = SwiftPatternScan.run(try PatternSearch(pattern: "try? $X.save()"), pattern: "try? $X.save()",
                                           files: files, root: project.root, cache: SourceParseCache())

        #expect(Set(outcome.hits.map(\.file)) == ["Sources/Clean.swift", "Sources/Broken.swift"])
        let unscanned = Dictionary(uniqueKeysWithValues: outcome.unscanned.map { ($0.file, $0.reason) })
        #expect(unscanned["Sources/Latin1.swift"] == StructuralCoverage.notUTF8Reason)
        #expect(unscanned["Sources/Locked.swift"] == StructuralCoverage.unreadableReason)
        #expect(outcome.recovered.map(\.file) == ["Sources/Broken.swift"])
        #expect(outcome.scannedCount == 2)
        #expect(StructuralCoverage.recoveredReport(outcome.recovered).first?.contains("read with reservations (1)") == true)
    }

    @Test("lint names the same files, and a cached result keeps the syntax-error note")
    func lintNamesUnreadAndRecoveredFiles() throws {
        let project = try mixedProject()
        let rules = [Rule(id: "try-save", message: "m", patterns: ["try? $X.save()"])]
        for _ in 0..<2 {   // the second run is answered from the persistent cache
            let outcome = RuleEngine.run(rules: rules, projectRoot: project.root.path, lintRoot: project.root.path,
                                         includeTests: false)
            #expect(Set(outcome.violations.map(\.file)) == ["Sources/Clean.swift", "Sources/Broken.swift"])
            #expect(Set(outcome.unscanned.map(\.file)).isSuperset(of: ["Sources/Latin1.swift", "Sources/Locked.swift"]))
            #expect(outcome.recovered.map(\.file) == ["Sources/Broken.swift"])
        }
    }

    @Test("A skipped directory that holds sources is named; which directories are walked does not change")
    func namesSkippedDirectories() throws {
        let project = try Project([
            "Sources/App.swift": "struct App {}\n",
            "vendor/Lib.swift": "struct Lib {}\n",
            "Sources/build/Generated.swift": "struct Generated {}\n",
            "Pods/Only.txt": "not a source\n",
        ])
        let files = SwiftSources.files(under: project.root, includeTests: false)
        #expect(files.map { SwiftSources.relativePath(of: $0, root: project.root) } == ["Sources/App.swift"])
        #expect(SwiftSources.skippedSourceDirectories(under: project.root) == ["Sources/build", "vendor"])
        let named = StructuralCoverage.skippedDirectories(projectRoot: project.root.path)
        #expect(named.map(\.file) == ["Sources/build/", "vendor/"])
        #expect(named.allSatisfy { $0.reason == StructuralCoverage.skippedDirectoryReason })
    }

    @Test("A checked-out submodule declared in .gitmodules is named")
    func namesSubmodules() throws {
        let project = try Project([
            ".gitmodules": "[submodule \"lib\"]\n\tpath = External/lib\n\turl = https://example.invalid/lib.git\n",
            "External/lib/Source.swift": "struct S {}\n",
        ])
        #expect(SwiftSources.submodules(under: project.root) == ["External/lib"])
    }

    @Test("A bare name in an exclusion takes a directory of that name at any depth")
    func bareNameExcludesDirectories() {
        func excluded(_ pattern: String, _ path: String) -> Bool { ExclusionPattern(pattern).matches(relativePath: path) }
        #expect(excluded("vendor", "vendor/Lib.swift"))
        #expect(excluded("vendor", "Sources/vendor/Deep/Lib.swift"))
        #expect(!excluded("vendor", "Sources/vendored/Lib.swift"))
        #expect(excluded("Generated", "Sources/Generated/Api.swift"))
        // A trailing slash keeps it to directories.
        #expect(excluded("Generated/", "Sources/Generated/Api.swift"))
        #expect(!excluded("Generated/", "Sources/Generated"))
        // A name pattern still matches a file's name.
        #expect(excluded("*.pb.swift", "Sources/Api/user.pb.swift"))
    }

    @Test("The body of a declaration with an attribute on the line above is found at the name's line")
    func bodyBelowAttribute() throws {
        let project = try Project(["A.swift": """
        struct Holder {
            @MainActor
            func refresh() -> Int {
                return 1
            }

            @objc
            @available(macOS 12, *)
            public func legacy() {}
        }
        """])
        let path = project.path("A.swift")
        let recorded = [
            SextantCore.SourceLocation(path: path, line: 3, column: 10, isDefinition: true),
            SextantCore.SourceLocation(path: path, line: 9, column: 17, isDefinition: true),
        ]
        #expect(SourceBody.bodies(of: "refresh", at: [recorded[0]]).map(\.text)
                == ["@MainActor\n    func refresh() -> Int {\n        return 1\n    }"])
        #expect(SourceBody.bodies(of: "legacy", at: [recorded[1]]).map(\.text)
                == ["@objc\n    @available(macOS 12, *)\n    public func legacy() {}"])
        // The name is still checked: another symbol's line gives nothing.
        #expect(SourceBody.bodies(of: "legacy", at: [recorded[0]]).isEmpty)
    }

    @Test("A pattern valid only for the C family is not reported broken for a Swift-only project, and says why")
    func brokenPatternsAcrossLanguages() {
        let rules = [
            Rule(id: "objc", message: "m", patterns: ["[$X reloadData]"]),
            Rule(id: "swift", message: "m", patterns: ["try! $X"]),
            Rule(id: "neither", message: "m", patterns: ["log($$$"]),
        ]
        let empty = CFamilyLint.Outcome(violations: [], unscanned: [], inactive: [], targets: [])
        let broken = RuleEngine.brokenPatterns(in: rules, cFamily: empty)
        #expect(broken.map(\.ruleID) == ["objc", "neither"])
        #expect(broken.first?.reason.contains("no Objective-C, C or C++ file was checked with it") == true)
        // `$$$` is refused by the C engine outright, so that half of the reason is known without a file.
        #expect(broken.last?.reason.contains("$$$ is not supported") == true)

        var compiledSomewhere = empty
        compiledSomewhere.compiledPatterns = [CFamilyLint.patternKey(ruleID: "objc", pattern: "[$X reloadData]")]
        #expect(RuleEngine.brokenPatterns(in: rules, cFamily: compiledSomewhere).map(\.ruleID) == ["neither"])
    }

    // MARK: - The refusal reaches the surfaces

    private func run(_ arguments: [String], input: String? = nil, home: URL) throws -> (code: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = try #require(Self.binary, "sextant is not built — run `swift build` first")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for name in ["SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA", "CLAUDE_PROJECT_DIR", "SEXTANT_TELEMETRY"] {
            environment[name] = nil
        }
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SEXTANT_NO_DAEMON"] = "1"
        process.environment = environment
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
        }
        let collected = OutputCapture.collect(from: [out, err]) { process.waitUntilExit() }
        return (process.terminationStatus, collected[0], collected[1])
    }

    @Test("A metavariable in a string literal is a usage error in the CLI and an error result in MCP",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(2)))
    func refusalOnBothSurfaces() throws {
        let project = try Project(["A.swift": "func f() { print(\"$X\") }\n"])
        let home = project.root.appendingPathComponent(".home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let cli = try run(["search", "print(\"$X\")", "--project", project.root.path], home: home)
        #expect(cli.code == 2, "\(cli)")
        #expect(cli.err.contains("inside a string literal"), "\(cli.err)")
        #expect(!cli.out.contains("No matches"), "\(cli.out)")

        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "structural_search", "arguments": ["pattern": "print(\"$X\")"]]],
        ]
        let input = try messages.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let mcp = try run(["mcp", "--project", project.root.path], input: input, home: home)
        let answer = try #require(mcp.out.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["id"] as? Int == 2 else { return nil }
            return object["result"] as? [String: Any]
        }.first, "no answer to tools/call: \(mcp.out)")
        #expect(answer["isError"] as? Bool == true, "\(answer)")
        let text = ((answer["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        #expect(text.contains("inside a string literal"), "\(text)")
    }
}
