import Foundation
import Testing
@testable import SextantCore

@Suite("Compilation database")
struct CompilationDatabaseTests {
    /// A fragment of a real `.build/debug.yaml`, shortened but keeping the shape: a clang node, a
    /// swiftc node that must not be taken for one, and an auxiliary node with no args at all.
    private let manifest = """
      "/pkg/.build/x86_64-apple-macosx/debug/ObjCFixture.build/ObjCFixture.m.o":
        tool: clang
        inputs: ["/pkg/Sources/ObjCFixture/ObjCFixture.m"]
        outputs: ["/pkg/.build/x86_64-apple-macosx/debug/ObjCFixture.build/ObjCFixture.m.o"]
        description: "Compiling ObjCFixture ObjCFixture.m"
        args: ["/toolchain/usr/bin/clang","-fobjc-arc","-target","x86_64-apple-macosx10.13","-I","/pkg/Sources/ObjCFixture/include","-index-store-path","/pkg/.build/index/store","-MD","-MT","dependencies","-MF","/pkg/.build/ObjCFixture.m.d","-c","/pkg/Sources/ObjCFixture/ObjCFixture.m","-o","/pkg/.build/ObjCFixture.m.o"]
        deps: "/pkg/.build/ObjCFixture.m.d"

      "/pkg/.build/x86_64-apple-macosx/debug/IndexFixture.build/sources":
        tool: write-auxiliary-file
        inputs: ["<sources-file-list>","/pkg/Sources/IndexFixture/Code.swift"]
        outputs: ["/pkg/.build/x86_64-apple-macosx/debug/IndexFixture.build/sources"]

      "C.IndexFixture-x86_64-apple-macosx26.0-debug.module":
        tool: shell
        inputs: ["/pkg/Sources/IndexFixture/Code.swift"]
        description: "Compiling Swift Module 'IndexFixture' (1 sources)"
        args: ["/toolchain/usr/bin/swiftc","-module-name","IndexFixture","-c","/pkg/Sources/IndexFixture/Code.swift"]
      """

    @Test("A clang node yields the file and its arguments")
    func readsClangNode() throws {
        let commands = CompilationDatabase.commands(inManifest: manifest, directory: "/pkg")
        #expect(commands.count == 1)                       // the swiftc and auxiliary nodes are not compile commands
        let command = try #require(commands.first)
        #expect(command.file == "/pkg/Sources/ObjCFixture/ObjCFixture.m")
        #expect(command.directory == "/pkg")
        #expect(command.arguments.contains("-fobjc-arc"))
    }

    @Test("Parse arguments drop the compiler, the output and the dependency bookkeeping")
    func parseArgumentsStripsBuildOnlyFlags() throws {
        let command = try #require(CompilationDatabase.commands(inManifest: manifest, directory: "/pkg").first)
        let arguments = CompilationDatabase.parseArguments(of: command)

        #expect(!arguments.contains { $0.hasSuffix("/clang") })          // the executable is not a flag
        #expect(!arguments.contains("-c"))
        #expect(!arguments.contains("-o"))
        #expect(!arguments.contains("/pkg/.build/ObjCFixture.m.o"))
        #expect(!arguments.contains("-MD"))
        #expect(!arguments.contains("-MF"))
        #expect(!arguments.contains("/pkg/.build/ObjCFixture.m.d"))
        #expect(!arguments.contains("-index-store-path"))
        #expect(!arguments.contains("/pkg/.build/index/store"))
        #expect(!arguments.contains(command.file))                      // libclang is given the file separately

        // What decides whether the AST builds at all is kept, in order.
        #expect(arguments.first == "-fobjc-arc")
        let target = try #require(arguments.firstIndex(of: "-target"))
        #expect(arguments[target + 1] == "x86_64-apple-macosx10.13")
        let include = try #require(arguments.firstIndex(of: "-I"))
        #expect(arguments[include + 1] == "/pkg/Sources/ObjCFixture/include")
    }

    @Test("The manifest sits beside the index store it was built with")
    func findsManifestBesideStore() {
        #expect(CompilationDatabase.manifestPaths(forStore: "/pkg/.build/x86_64-apple-macosx/debug/index/store")
                == ["/pkg/.build/debug.yaml"])
        #expect(CompilationDatabase.manifestPaths(forStore: "/pkg/.build/arm64-apple-macosx/release/index/store")
                == ["/pkg/.build/release.yaml"])
        // A DerivedData store has no manifest beside it: an empty result, not a fabricated path.
        #expect(CompilationDatabase.manifestPaths(forStore: "/Users/x/Library/Developer/Xcode/DerivedData/App-abc/Index.noindex/DataStore").isEmpty)
    }

    @Test("A malformed args line is skipped, not guessed at")
    func skipsMalformedNode() {
        let broken = """
          "/pkg/out.o":
            tool: clang
            inputs: ["/pkg/a.m"]
            args: this is not a json array
          """
        #expect(CompilationDatabase.commands(inManifest: broken, directory: "/pkg").isEmpty)
    }

    @Test("A round trip through the stored file keeps the commands")
    func savesAndLoads() throws {
        let root = "/tmp/sextant-compile-db-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: CompilationDatabase.path(forRoot: root)) }
        let commands = CompilationDatabase.commands(inManifest: manifest, directory: "/pkg")

        try CompilationDatabase.save(commands, forRoot: root)
        #expect(CompilationDatabase.load(forRoot: root) == commands)
    }

    @Test("The same project spelled differently is the same database")
    func keyIsTheCanonicalPath() {
        let canonical = CompilationDatabase.path(forRoot: "/tmp/sextant-project")
        #expect(CompilationDatabase.path(forRoot: "/tmp/./sextant-project") == canonical)
        #expect(CompilationDatabase.path(forRoot: "/tmp/sextant-project/") == canonical)
        // A relative path resolves against the working directory, as every other command does.
        #expect(CompilationDatabase.path(forRoot: ".") == CompilationDatabase.path(forRoot: FileManager.default.currentDirectoryPath))
    }

    @Test("An unknown project has an empty database, not a crash")
    func loadsNothingForUnknownProject() {
        #expect(CompilationDatabase.load(forRoot: "/nowhere-\(UUID().uuidString)").isEmpty)
    }

    // MARK: - Against a real build

    private static var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndexFixture")
    }

    /// The manifest format belongs to SwiftPM, not to us, so a hand-written sample proves nothing
    /// on its own: this reads what the toolchain on this machine actually wrote.
    @Test("A real SwiftPM build yields flags for every C-family source",
          .enabled(if: FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".build").path),
                   "the fixture has not been built"))
    func capturesFromRealBuild() throws {
        let stores = IndexStoreLocator.stores(under: Self.fixture)
        let commands = CompilationDatabase.capture(fromStores: stores)

        let files = Set(commands.map { ($0.file as NSString).lastPathComponent })
        #expect(files.isSuperset(of: ["ObjCFixture.m", "CFixture.c", "CxxFixture.cpp"]))
        #expect(!files.contains { $0.hasSuffix(".swift") })

        let objc = try #require(commands.first { $0.file.hasSuffix("ObjCFixture.m") })
        let arguments = CompilationDatabase.parseArguments(of: objc)
        // The flags that decide whether an AST builds at all: the target, the SDK and the includes.
        #expect(arguments.contains("-target"))
        #expect(arguments.contains("-isysroot"))
        #expect(arguments.contains { $0.hasSuffix("Sources/ObjCFixture/include") })
    }
}
