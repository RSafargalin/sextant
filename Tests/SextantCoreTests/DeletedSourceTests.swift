import Foundation
import Testing
@testable import SextantCore

/// A source deleted before a build: the build leaves the file's unit in the store, and an answer
/// read from it counted a file that does not exist under a label that said "fresh". One package,
/// indexed by the real `sextant index` in a home of its own, with one file deleted afterwards.
@Suite("Deleted sources", .serialized)
struct DeletedSourceTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var binary: URL? { BuildProducts.sextantBinary(under: repositoryRoot) }

    private static let sources: [String: String] = [
        "Package.swift": """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "gone", targets: [.target(name: "gone")])

            """,
        "Sources/gone/A.swift": "public protocol Shape {}\npublic func target() {}\n",
        "Sources/gone/B.swift": "public struct Square: Shape {}\npublic func b() { target() }\n",
        "Sources/gone/C.swift": "public struct Circle: Shape {}\npublic func c() {\n    target()\n}\n",
    ]

    private final class Package {
        let base: URL
        let root: URL
        let home: URL

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("sextant-gone-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
            root = base.appendingPathComponent("package")
            home = base.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for (path, contents) in DeletedSourceTests.sources {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        var deleted: URL { root.appendingPathComponent("Sources/gone/C.swift") }

        func run(_ arguments: [String], input: String? = nil) throws -> (code: Int32, output: String, errors: String) {
            let process = Process()
            process.executableURL = try #require(DeletedSourceTests.binary)
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

        func index() throws -> String {
            let result = try run(["index", "--project", root.path])
            try #require(result.code == 0, "sextant index failed:\n\(result.output)\n\(result.errors)")
            return result.output
        }

        var store: String {
            get throws {
                try #require(BuildProducts.indexStore(under: root))
            }
        }

        func unitNames(ofStore store: String) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: store).filter { $0.hasPrefix("v") }.flatMap {
                try FileManager.default.contentsOfDirectory(atPath: "\(store)/\($0)/units")
            }
        }
    }

    private static func object(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// A store nothing of sextant's builds — named with `--index-store`, judged by build time —
    /// keeps the unit of the deleted file; the answers leave its positions out of every count and
    /// list, and name the file instead.
    @Test("Answers over a store that still holds a deleted file leave the file out and name it",
          .enabled(if: DeletedSourceTests.binary != nil, "sextant is not built"),
          .timeLimit(.minutes(5)))
    func answersLeaveOutADeletedFile() throws {
        let package = try Package()
        _ = try package.index()
        // A copy, so that no snapshot describes it and nothing of sextant's rebuilds it.
        let copy = package.base.appendingPathComponent("elsewhere/store").path
        try FileManager.default.createDirectory(atPath: (copy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: try package.store, toPath: copy)
        try FileManager.default.removeItem(at: package.deleted)
        func ask(_ arguments: String...) throws -> (code: Int32, output: String, errors: String) {
            try package.run(arguments + ["--project", package.root.path, "--index-store", copy])
        }
        let deletedName = "Sources/gone/C.swift"

        let callers = try ask("callers", "target")
        #expect(callers.code == 0)
        #expect(callers.output.contains("calls: 1 in 1 file(s)"), "\(callers.output)")
        #expect(!callers.output.contains(deletedName), "\(callers.output)")
        #expect(callers.errors.contains("left out of this answer: 1 position(s) in 1 file(s)")
                && callers.errors.contains(deletedName), "\(callers.errors)")

        let json = try ask("callers", "target", "--json")
        let hits = try #require(Self.object(json.output) as? [[String: Any]], "\(json.output)")
        #expect(hits.first?["totalReferences"] as? Int == 1)
        #expect(!json.output.contains(deletedName))
        #expect(json.errors.contains("left out of this answer") && json.errors.contains(deletedName), "\(json.errors)")

        for arguments in [["refs", "target", "--json"], ["impls", "Shape", "--json"], ["callees", "c", "--json"],
                          ["defs", "c", "--json"], ["defs", "Circle"], ["hierarchy", "target", "--callers"]] {
            let answer = try package.run(arguments + ["--project", package.root.path, "--index-store", copy])
            #expect(answer.code == 0, "\(arguments): \(answer.errors)")
            #expect(!answer.output.contains(deletedName), "\(arguments): \(answer.output)")
            #expect(answer.errors.contains("left out of this answer") && answer.errors.contains(deletedName),
                    "\(arguments): \(answer.errors)")
        }
        let impls = try ask("impls", "Shape")
        #expect(impls.output.contains("Square") && !impls.output.contains("Circle"), "\(impls.output)")

        let context = try #require(Self.object(try ask("context", "target", "--json").output) as? [String: Any])
        #expect(context["callerCount"] as? Int == 1 && context["referenceCount"] as? Int == 1, "\(context)")
        let blast = try #require(Self.object(try ask("blast", "target", "--json").output) as? [String: Any])
        #expect((blast["affectedFiles"] as? [String])?.contains { $0.hasSuffix(deletedName) } == false, "\(blast)")
        #expect(blast["callerCount"] as? Int == 1, "\(blast)")

        // The MCP tools answer from the same layer, and say it in the answer itself.
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"find_callers","arguments":{"symbol":"target"}}}"#
        let mcp = try package.run(["mcp", "--project", package.root.path, "--index-store", copy], input: request + "\n")
        let response = try #require(Self.object(mcp.output.split(separator: "\n").first.map(String.init) ?? "") as? [String: Any])
        let text = try #require((((response["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)?["text"] as? String)
        #expect(text.contains("calls: 1 in 1 file(s)") && text.contains("left out of this answer"), "\(text)")
    }

    @Test("Only a missing file under the project root is left out, each position counted once")
    func onlyMissingProjectFilesAreLeftOut() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-absent-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base.appendingPathComponent("project/Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let present = base.appendingPathComponent("project/Sources/Here.swift")
        try "func here() {}\n".write(to: present, atomically: true, encoding: .utf8)
        let missing = base.appendingPathComponent("project/Sources/Gone.swift").path
        let outside = base.appendingPathComponent("sdk/Gone.swift").path
        func at(_ path: String, _ line: Int) -> SextantCore.SourceLocation {
            SextantCore.SourceLocation(path: path, line: line, column: 1, isDefinition: false)
        }

        let absent = AbsentSources(projectRoot: base.appendingPathComponent("project").path, drift: nil)
        #expect(absent.summary == nil)
        #expect(!absent.leavesOut(at(present.path, 1)))
        #expect(!absent.leavesOut(at(outside, 1)), "a file outside the project is not the project's to rule on")
        #expect(!absent.leavesOut(at("", 1)))
        #expect(absent.leavesOut(at(missing, 3)))
        #expect(absent.leavesOut(at(missing, 3)))
        #expect(absent.leavesOut(at(missing, 7)))
        #expect(absent.summary == AbsentSources.Summary(files: [missing], positions: 2))

        // Without a project root nothing is judged.
        #expect(!AbsentSources(projectRoot: nil, drift: nil).leavesOut(at(missing, 3)))
    }

    /// Where every file exists the layer adds nothing: the answers are the stores' own.
    @Test("Over a store whose files all exist, answers are the stores' own and nothing is left out",
          .enabled(if: IndexDatabaseTests.ready, "needs the fixture's index store — run `make fixture`"),
          .timeLimit(.minutes(3)))
    func nothingMissingChangesNothing() throws {
        let fixture = Self.repositoryRoot.appendingPathComponent("Tests/Fixtures/IndexFixture")
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-absent-db-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let set = try IndexStoreSet(storePaths: [try #require(IndexDatabaseTests.fixtureStore)],
                                    libraryPath: try #require(BuildProducts.indexStoreLibrary),
                                    databaseRoot: base.path, projectRoot: fixture.path)
        let translated = TranslatedIndex(set, drift: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for name in ["EnglishGreeter", "greet", "c_fixture_double", "OCGreeter", "Greeter"] {
            for query in [SymbolQuery.definitions, .references, .callers] {
                for limit in [1, 1000] {
                    #expect(try encoder.encode(translated.lookup(name: name, query: query, limit: limit))
                            == encoder.encode(set.lookup(name: name, query: query, limit: limit).map { hit in
                                SymbolHit(name: hit.name, usr: hit.usr, kind: hit.kind,
                                          definition: hit.definition.map { IndexColumns(drift: nil).restate($0) },
                                          references: hit.references.map { IndexColumns(drift: nil).restate($0) },
                                          totalReferences: hit.totalReferences)
                            }), "\(name) \(query) \(limit)")
                }
            }
            for query in [RelationQuery.callees, .implementations, .supertypes] {
                #expect(translated.related(toName: name, query: query, limit: 1).map(\.usr)
                        == set.related(toName: name, query: query, limit: 1).map(\.usr))
            }
        }
        #expect(translated.leftOut == nil)
    }

    /// `sextant index` builds the package in a tree of its own, and there it removes the unit of a
    /// source that no longer exists: the label that says "fresh" is then true of the answer.
    @Test("`sextant index` removes the unit of a deleted source from the store it builds",
          .enabled(if: DeletedSourceTests.binary != nil, "sextant is not built"),
          .timeLimit(.minutes(5)))
    func indexRemovesTheUnitOfADeletedSource() throws {
        let package = try Package()
        _ = try package.index()
        let store = try package.store
        let before = try package.unitNames(ofStore: store)
        try #require(before.contains { $0.hasPrefix("C.") }, "\(before)")
        try FileManager.default.removeItem(at: package.deleted)

        let output = try package.index()
        #expect(output.contains("removed the index units of 1 deleted source(s)"), "\(output)")
        let after = try package.unitNames(ofStore: store)
        #expect(!after.contains { $0.hasPrefix("C.") }, "\(after)")
        #expect(Set(after) == Set(before.filter { !$0.hasPrefix("C.") }), "only the deleted source's unit goes")

        let callers = try package.run(["callers", "target", "--project", package.root.path])
        #expect(callers.output.contains("calls: 1 in 1 file(s)") && !callers.output.contains("C.swift"), "\(callers.output)")
        #expect(callers.errors.contains("fresh") && !callers.errors.contains("left out"), "\(callers.errors)")
    }
}
