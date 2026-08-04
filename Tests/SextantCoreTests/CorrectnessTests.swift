import Foundation
import Testing
@testable import SextantCore

@Suite("Argument parsing")
struct ArgumentParsingTests {
    let valueFlags: Set<String> = ["--project", "--limit"]

    @Test("A value-flag's value is not positional (option before the symbol)")
    func optionBeforePositional() {
        let positionals = ArgumentParsing.positionals(["--project", "/some/path", "Event"], valueFlags: valueFlags)
        #expect(positionals == ["Event"])
    }

    @Test("Symbol before the option")
    func positionalBeforeOption() {
        let positionals = ArgumentParsing.positionals(["Event", "--project", "/some/path"], valueFlags: valueFlags)
        #expect(positionals == ["Event"])
    }

    @Test("A boolean flag does not swallow the next argument")
    func booleanFlagKeepsPositional() {
        let positionals = ArgumentParsing.positionals(["--include-tests", "Event"], valueFlags: valueFlags)
        #expect(positionals == ["Event"])
    }

    @Test("A missing option value (the next token is a flag) gives nil")
    func missingValueIsNil() {
        #expect(ArgumentParsing.value(of: "--scope", in: ["--scope", "--project", "/x"]) == nil)
        #expect(ArgumentParsing.value(of: "--project", in: ["--project", "/x"]) == "/x")
    }
}

@Suite("Signatures: generics, effects, subscript, case")
struct SignatureExtractionTests {
    let source = """
    public enum Color { case red, green; case custom(Int) }
    public struct Box<T: Equatable> {
        public subscript(i: Int) -> T { fatalError() }
        public static func make() -> Box<T> { fatalError() }
        public func run() async throws -> Int { 0 }
        public func endpoint(url: String = "https://x/y") {}
    }
    """

    private func declarations() -> [Declaration] {
        SwiftDeclarationExtractor.declarations(source: source)
    }

    @Test("Enum cases are extracted and inherit the enum's access")
    func enumCasesInheritAccess() {
        let color = declarations().first { $0.header.hasPrefix("enum Color") }
        let cases = color?.members.filter { $0.kind == .caseKind } ?? []
        #expect(cases.contains { $0.header.contains("red, green") })
        #expect(cases.contains { $0.header.contains("custom(Int)") })
        #expect(cases.allSatisfy { $0.access == .public })
    }

    @Test("A type's generic parameters are preserved")
    func genericsPreserved() {
        #expect(declarations().contains { $0.header == "struct Box<T: Equatable>" })
    }

    @Test("Subscript is present")
    func subscriptPresent() {
        let box = declarations().first { $0.header.hasPrefix("struct Box") }
        #expect(box?.members.contains { $0.kind == .subscriptKind && $0.header.contains("subscript(i: Int) -> T") } == true)
    }

    @Test("static and async throws are preserved")
    func staticAndEffectsPreserved() {
        let box = declarations().first { $0.header.hasPrefix("struct Box") }
        #expect(box?.members.contains { $0.header.contains("static func make") } == true)
        #expect(box?.members.contains { $0.header.contains("async throws -> Int") } == true)
    }

    @Test("A // inside a string literal does not truncate the signature")
    func urlInStringNotTruncated() {
        let box = declarations().first { $0.header.hasPrefix("struct Box") }
        #expect(box?.members.contains { $0.header.contains("\"https://x/y\"") } == true)
    }
}

@Suite("WorkspacePath resolution")
struct WorkspaceMatchTests {
    @Test("A workspace inside the project root matches")
    func matchesInsideRoot() {
        #expect(DerivedDataLocator.workspace("/Users/x/myapp/MyApp.xcodeproj", isInProjectRoot: "/Users/x/myapp"))
    }

    @Test("A sibling sharing a prefix does not match (foobar ≠ foo)")
    func rejectsSiblingPrefix() {
        #expect(!DerivedDataLocator.workspace("/Users/x/foobar/A.xcodeproj", isInProjectRoot: "/Users/x/foo"))
    }

    @Test("A different root does not match")
    func rejectsDifferentRoot() {
        #expect(!DerivedDataLocator.workspace("/Users/x/other/A.xcodeproj", isInProjectRoot: "/Users/x/myapp"))
    }
}

@Suite("MCP tool contract")
struct MCPToolsTests {
    @Test("Tools have names and schemas")
    func contractStable() {
        let tools = MCPTools.definitions()
        let names = tools.compactMap { $0["name"] as? String }
        #expect(Set(names) == ["context", "blast_radius", "body", "who_defines", "find_references", "find_callers", "list_implementations", "call_hierarchy", "repo_map", "structural_search", "lint", "api", "changed"])
        for tool in tools {
            #expect(tool["description"] is String)
            #expect(tool["inputSchema"] is [String: Any])
            #expect((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        }
        // symbol tools require the symbol parameter
        let context = tools.first { $0["name"] as? String == "context" }
        let schema = context?["inputSchema"] as? [String: Any]
        #expect((schema?["required"] as? [String])?.contains("symbol") == true)

        // api and changed have no required parameters — they work over the whole project.
        for name in ["api", "changed"] {
            let tool = tools.first { $0["name"] as? String == name }
            let toolSchema = tool?["inputSchema"] as? [String: Any]
            #expect(toolSchema?["required"] == nil, "\(name): must not have required parameters")
        }
    }

    @Test("Server instructions are assembled from definitions, so the lists cannot drift")
    func instructionsListEveryTool() {
        let instructions = MCPTools.instructions()
        for name in MCPTools.names {
            #expect(instructions.contains(name), "the instructions do not mention \(name)")
        }
    }
}

@Suite("Scope resolution")
struct ProjectScopeTests {
    @Test("Subdirectory, escape from the project, missing directory")
    func validatesScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-scope-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(ProjectScope.resolve(root: root.path, scope: nil) == .resolved(resolvedRoot))
        #expect(ProjectScope.resolve(root: root.path, scope: "") == .resolved(resolvedRoot))
        #expect(ProjectScope.resolve(root: root.path, scope: "Sources/Feature") == .resolved(nested.resolvingSymlinksInPath().standardizedFileURL.path))
        #expect(ProjectScope.resolve(root: root.path, scope: "../..") == .outsideProject)
        #expect(ProjectScope.resolve(root: root.path, scope: "Sources/Missing") == .missingDirectory)
    }
}

@Suite("SemanticVersion")
struct SemanticVersionTests {
    @Test("Component-wise version comparison")
    func compares() {
        #expect(SemanticVersion.atLeast("26.1", "26.0"))
        #expect(SemanticVersion.atLeast("26.0", "26.0"))
        #expect(!SemanticVersion.atLeast("26.0", "26.1"))
        #expect(SemanticVersion.atLeast("26.0.1", "26"))     // missing components count as zero
        #expect(!SemanticVersion.atLeast("9", "10"))         // numeric, not lexicographic
    }
}

@Suite("PageRank")
struct PageRankTests {
    @Test("A central node, widely referenced, ranks higher")
    func ranksCentralNode() {
        let scores = PageRank.scores(
            nodes: ["A", "B", "C", "Core"],
            edges: [("A", "Core"), ("B", "Core"), ("C", "Core")]
        )
        #expect(scores["Core"]! > scores["A"]!)
        #expect(scores["Core"]! > scores["B"]!)
    }

    @Test("An empty graph gives an empty result")
    func emptyGraph() {
        #expect(PageRank.scores(nodes: [], edges: []).isEmpty)
    }
}

@Suite("Umbrella manifest")
struct UmbrellaManifestTests {
    @Test("Generates a valid structure with the platform taken from the manifests")
    func generatesValidStructure() {
        let packages = [
            UmbrellaManifest.PackageReference(path: "/p/Core", identity: "Core", products: ["Core"]),
            UmbrellaManifest.PackageReference(path: "/p/UI", identity: "UI", products: ["UI"])
        ]
        let manifest = UmbrellaManifest.manifest(packages: packages, macOSVersion: "26.0")
        #expect(manifest.contains("swift-tools-version: 6.2"))
        #expect(manifest.contains(".macOS(\"26.0\")"))
        #expect(manifest.contains(".package(path: \"/p/Core\")"))
        #expect(manifest.contains(".product(name: \"UI\", package: \"UI\")"))
    }

    @Test("Escapes quotes and backslashes in a path")
    func escapesSpecialCharacters() {
        let manifest = UmbrellaManifest.manifest(
            packages: [.init(path: "/a/\"b\"/c", identity: "c", products: ["c"])],
            macOSVersion: "26.0"
        )
        #expect(manifest.contains("/a/\\\"b\\\"/c"))
        #expect(!manifest.contains("path: \"/a/\"b\""))
    }
}

@Suite("Project config")
struct ProjectConfigTests {
    @Test("Reads .sextant.json")
    func loadsConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"{"budget":1234,"scope":"Sub","maxFiles":50}"#
            .write(to: directory.appendingPathComponent(".sextant.json"), atomically: true, encoding: .utf8)

        let config = ProjectConfig.load(projectRoot: directory.path)
        #expect(config?.budget == 1234)
        #expect(config?.scope == "Sub")
        #expect(config?.maxFiles == 50)
        #expect(config?.rules == nil)
    }

    @Test("No file gives nil")
    func missingConfigIsNil() {
        #expect(ProjectConfig.load(projectRoot: "/tmp/sextant-nonexistent-\(UUID().uuidString)") == nil)
    }

    @Test("No file, valid, and broken are three distinct outcomes")
    func distinguishesOutcomes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".sextant.json")

        if case .missing = ProjectConfig.read(projectRoot: directory.path) {} else {
            Issue.record("with no file, .missing is expected")
        }

        try #"{"budget": 1234}"#.write(to: file, atomically: true, encoding: .utf8)
        guard case .loaded(let loaded) = ProjectConfig.read(projectRoot: directory.path) else {
            Issue.record("a valid config is expected to be .loaded"); return
        }
        #expect(loaded.budget == 1234)

        // A broken config is .invalid, not "as if absent": otherwise a typo silently changes behaviour.
        try "{ budget: ".write(to: file, atomically: true, encoding: .utf8)
        if case .invalid = ProjectConfig.read(projectRoot: directory.path) {} else {
            Issue.record("a broken config is expected to be .invalid")
        }
        #expect(ProjectConfig.load(projectRoot: directory.path) == nil)
    }
}

@Suite("gitignore scoping")
struct GitignoreScopingTests {
    @Test("Parses directory patterns from .gitignore plus the usual vendored ones")
    func parsesGitignoreDirs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-gi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ".build\nGenerated/\n/Vendored\n*.log\nSources/X/\n# comment\n!keep\nWeird\n"
            .write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let ignored = SwiftSources.ignoredDirectoryNames(under: directory)
        #expect(ignored.contains("Generated"))       // trailing / stripped
        #expect(ignored.contains("Vendored"))         // leading / stripped
        #expect(ignored.contains("Weird"))
        #expect(ignored.contains("Pods"))             // vendored by default
        #expect(!ignored.contains("Sources/X"))       // a path containing / is skipped
        #expect(!ignored.contains("*.log"))           // a glob is skipped
    }
}

@Suite("Walking under a hidden ancestor (worktree)")
struct HiddenAncestorTraversalTests {
    @Test("Finds sources when the root sits under a hidden directory")
    func findsSourcesUnderHiddenAncestor() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-hidden-\(UUID().uuidString)")
        // A root inside a hidden ancestor, like `.claude/worktrees/<name>`.
        let root = base.appendingPathComponent(".host/worktrees/wt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try "struct Visible {}".write(to: root.appendingPathComponent("Visible.swift"), atomically: true, encoding: .utf8)
        let hiddenDir = root.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try "struct Buried {}".write(to: hiddenDir.appendingPathComponent("Buried.swift"), atomically: true, encoding: .utf8)
        try "struct Dot {}".write(to: root.appendingPathComponent(".Dot.swift"), atomically: true, encoding: .utf8)

        let files = SwiftSources.files(under: root, includeTests: false)
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.contains("Visible.swift"))   // an ordinary source under a hidden ancestor
        #expect(!names.contains("Buried.swift"))    // the hidden .build directory is skipped
        #expect(!names.contains(".Dot.swift"))      // a hidden file is skipped
    }
}

@Suite("Multi-store dedup")
struct MultiStoreDedupTests {
    @Test("locationKey canonicalises symlinked paths: the real path and one via a symlink share a key")
    func locationKeyResolvesSymlinks() throws {
        // resolvingSymlinksInPath resolves existing path components. The same file addressed
        // through a symlinked directory and directly must yield one key, or merging stores
        // duplicates it. Non-existent paths are not resolved, so the test builds a real symlink.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sextant-dedup-\(UUID().uuidString)")
        let realDir = base.appendingPathComponent("real")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let file = realDir.appendingPathComponent("Code.swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let linkDir = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let viaReal = SourceLocation(path: file.path, line: 10, column: 5, isDefinition: false)
        let viaLink = SourceLocation(path: linkDir.appendingPathComponent("Code.swift").path, line: 10, column: 5, isDefinition: false)
        #expect(IndexStoreSet.locationKey(usr: "U", viaReal) == IndexStoreSet.locationKey(usr: "U", viaLink))
        // A different USR or position means a different key — dedup does not collapse distinct symbols.
        #expect(IndexStoreSet.locationKey(usr: "U", viaReal) != IndexStoreSet.locationKey(usr: "V", viaReal))
        let otherLine = SourceLocation(path: file.path, line: 11, column: 5, isDefinition: false)
        #expect(IndexStoreSet.locationKey(usr: "U", viaReal) != IndexStoreSet.locationKey(usr: "U", otherLine))
    }
}

@Suite("Declaration.name (api --type)")
struct DeclarationNameTests {
    @Test("Extracts a name from a header: generics, extension, method, init/subscript/case")
    func extractsName() {
        #expect(Declaration(kind: .structKind, header: "public struct Box<T>: Foo", access: .public).name == "Box")
        #expect(Declaration(kind: .extensionKind, header: "extension A.B", access: .internal).name == "B")
        #expect(Declaration(kind: .function, header: "func parse(_ x: Int) -> Int", access: .internal).name == "parse")
        // init and subscript are glued to `(` and are special; case comes with a list.
        #expect(Declaration(kind: .initializer, header: "init(x: Int)", access: .public).name == "init")
        #expect(Declaration(kind: .subscriptKind, header: "subscript(index: Int) -> Int", access: .public).name == "subscript")
        #expect(Declaration(kind: .caseKind, header: "case a, b", access: .public).name == "a")
    }
}

@Suite("Symbol-level diff (changed)")
struct DeclarationDiffTests {
    @Test("added/removed/changed by declaration, not by line")
    func compare() {
        let old = DeclarationDiff.declarations(fromSource: "struct A {}\nfunc f() {}\nstruct C {}")
        let new = DeclarationDiff.declarations(fromSource: "struct A {}\nfunc f(x: Int) {}\nstruct B {}")
        let result = DeclarationDiff.compare(old: old, new: new)
        #expect(result.added.map { $0.name } == ["B"])
        #expect(result.removed.map { $0.name } == ["C"])
        #expect(result.changed.map { $0.new.name } == ["f"])   // the signature of f changed
        #expect(!result.isEmpty)
    }

    @Test("Overloads: an added overload is visible, with no false changed")
    func overloads() {
        let old = DeclarationDiff.declarations(fromSource: "func f() {}\nfunc f(x: Int) {}")
        let new = DeclarationDiff.declarations(fromSource: "func f(x: Int) {}\nfunc f(y: String) {}")
        let result = DeclarationDiff.compare(old: old, new: new)
        #expect(result.added.map { $0.header } == ["func f(y: String)"])   // the added overload
        #expect(result.removed.map { $0.header } == ["func f()"])          // the removed overload
        #expect(result.changed.isEmpty)                                    // NOT a false changed
    }

    @Test("An empty source (a new file) makes everything added")
    func emptySource() {
        let result = DeclarationDiff.compare(
            old: DeclarationDiff.declarations(fromSource: ""),
            new: DeclarationDiff.declarations(fromSource: "struct Z {}")
        )
        #expect(result.added.map { $0.name } == ["Z"])
        #expect(result.removed.isEmpty)
    }
}

@Suite("SourceBody (declaration body)")
struct SourceBodyTests {
    @Test("Extracts the declaration on a line together with its body; nil when there is none")
    func extractsBody() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-body-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("A.swift")
        try "struct X {}\nfunc foo() -> Int {\n  return 42\n}\n".write(to: file, atomically: true, encoding: .utf8)

        let body = SourceBody.declaration(atLine: 2, inFile: file.path)   // func foo is on line 2
        #expect(body?.hasPrefix("func foo") == true)
        #expect(body?.contains("return 42") == true)                      // the body is included
        #expect(SourceBody.declaration(atLine: 99, inFile: file.path) == nil)
    }
}

@Suite("api --type filter")
struct PublicAPITypeFilterTests {
    @Test("summaries(type:) keeps only declarations with that name")
    func typeFilter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "public struct Foo {}\npublic struct Bar {}\n".write(to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)

        #expect(PublicAPI.summaries(projectRoot: dir.path, package: nil).flatMap { $0.declarations }.count == 2)
        let filtered = PublicAPI.summaries(projectRoot: dir.path, package: nil, type: "Foo").flatMap { $0.declarations }
        #expect(filtered.map { $0.name } == ["Foo"])
    }
}

@Suite("Occurrence histogram")
struct ReferenceHistogramTests {
    @Test("Grouped by file, lines deduplicated, deterministic order")
    func byFile() {
        let refs = [
            SourceLocation(path: "/b.swift", line: 5, column: 1, isDefinition: false),
            SourceLocation(path: "/a.swift", line: 10, column: 1, isDefinition: false),
            SourceLocation(path: "/a.swift", line: 10, column: 7, isDefinition: false), // duplicate of line 10
            SourceLocation(path: "/a.swift", line: 3, column: 1, isDefinition: false),
        ]
        let histogram = ReferenceHistogram.byFile(refs) { $0.path }
        #expect(histogram.map(\.file) == ["/a.swift", "/b.swift"])  // files are sorted
        #expect(histogram[0].lines == [3, 10])                       // 10 deduplicated, lines sorted
        #expect(histogram[1].lines == [5])
    }
}

@Suite("Content-hash cache")
struct ContentHashCacheTests {
    @Test("ContentHash is deterministic and distinguishes content")
    func contentHash() {
        #expect(ContentHash.of("abc") == ContentHash.of("abc"))
        #expect(ContentHash.of("abc") != ContentHash.of("abd"))
    }

    @Test("rulesKey is stable within a process and distinguishes sets (guards against JSONEncoder drift)")
    func rulesKeyStable() {
        let base = RuleEngine.builtinRules
        #expect(RuleEngine.rulesKey(base) == RuleEngine.rulesKey(base))
        let extended = base + [Rule(id: "x", message: "m", patterns: ["p"])]
        #expect(RuleEngine.rulesKey(base) != RuleEngine.rulesKey(extended))
    }

    @Test("PersistentCache: set→value, a miss on a new key, and a fresh instance reading from disk")
    func persistentCache() {
        let namespace = "test-\(UUID().uuidString)"
        defer {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/sextant/\(namespace)")
            try? FileManager.default.removeItem(at: dir)
        }
        let cache = PersistentCache<[String]>(namespace: namespace)
        #expect(cache.value(forKey: "k") == nil)
        cache.set(["a", "b"], forKey: "k")
        #expect(cache.value(forKey: "k") == ["a", "b"])
        #expect(cache.value(forKey: "missing") == nil)
        // L2: a new instance sees the entry on disk.
        #expect(PersistentCache<[String]>(namespace: namespace).value(forKey: "k") == ["a", "b"])
    }

    @Test("PersistentCache: FIFO eviction down to 80% of the limit")
    func eviction() throws {
        let namespace = "test-evict-\(UUID().uuidString)"
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/sextant/\(namespace)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = PersistentCache<[String]>(namespace: namespace)
        for i in 0..<20 { cache.set(["v\(i)"], forKey: "k\(i)") }
        PersistentCache<[String]>.prune(dir, cap: 10)
        // 20 > 10 → evict the oldest down to 80% (8).
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).count == 8)
    }
}

@Suite("git-based source walking")
struct GitSwiftFilesTests {
    @Test("In a git repository it returns .swift files; in a non-git directory nil, falling back to FileManager")
    func gitVsFallback() throws {
        // This test file lives in the sextant git repository — walk up to the root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SextantCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // sextant
        let git = SwiftSources.gitSwiftFiles(under: repoRoot, includeTests: true)
        #expect(git != nil)
        #expect(git?.contains { $0.lastPathComponent == "SwiftSources.swift" } == true)
        // No dot directories in the paths, consistently with FileManager mode: .build, .claude, .swiftpm…
        #expect(git?.allSatisfy { url in
            !SwiftSources.relativePath(of: url, root: repoRoot)
                .split(separator: "/").dropLast()
                .contains { $0.hasPrefix(".") }
        } == true)

        // A non-git temporary directory gives nil, so the caller falls back to a FileManager walk.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        #expect(SwiftSources.gitSwiftFiles(under: temp, includeTests: true) == nil)
    }
}

@Suite("Changed Swift files: root is a repository subdirectory")
struct ChangedSwiftFilesTests {
    @discardableResult
    private func git(_ arguments: [String], in directory: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("Paths come from the repository root, the working copy is read from topLevel, and a non-ASCII name survives")
    func subdirectoryRootAndNonASCII() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-changed-\(UUID().uuidString)")
        let sources = repo.appendingPathComponent("Sub/Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        try "struct Foo {}\n".write(to: sources.appendingPathComponent("Foo.swift"), atomically: true, encoding: .utf8)
        try "struct Modèle {}\n".write(to: sources.appendingPathComponent("Modèle.swift"), atomically: true, encoding: .utf8)

        git(["init", "-q"], in: repo.path)
        git(["add", "."], in: repo.path)
        // user.name and email via -c: CI has no global git config, and commit would otherwise fail.
        git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], in: repo.path)

        // Edit both files, including the non-ASCII one — both must appear in the list.
        try "struct Foo { func added() {} }\n".write(to: sources.appendingPathComponent("Foo.swift"), atomically: true, encoding: .utf8)
        try "struct Modèle { let x: Int = 0 }\n".write(to: sources.appendingPathComponent("Modèle.swift"), atomically: true, encoding: .utf8)

        let subRoot = repo.appendingPathComponent("Sub").path
        let result = try #require(SwiftSources.changedSwiftFiles(root: subRoot, from: "HEAD", to: nil))

        // Paths are relative to the repository root, not to the subdirectory.
        #expect(result.files.contains("Sub/Sources/Foo.swift"))
        #expect(result.files.contains("Sub/Sources/Modèle.swift"))   // the non-ASCII name did not drop out

        // The working copy is read from topLevel + relative, not root + relative, which would double the path.
        for relative in result.files {
            let content = (try? String(contentsOfFile: "\(result.topLevel)/\(relative)", encoding: .utf8)) ?? ""
            #expect(!content.isEmpty)
        }
    }
}

@Suite("Cross-worktree scoping")
struct WorktreeScopeTests {
    @Test("Main checkout: nested .claude/worktrees are excluded, other paths pass")
    func mainCheckout() {
        let root = "/u/myapp"
        #expect(IndexStore.inScope(path: "/u/myapp/Sources/A.swift", root: root))
        #expect(!IndexStore.inScope(path: "/u/myapp/.claude/worktrees/x/Sources/A.swift", root: root))
        // A non-worktree path outside the root PASSES — no over-filtering, so a foreign --index-store is not emptied.
        #expect(IndexStore.inScope(path: "/u/other/A.swift", root: root))
    }

    @Test("A worktree as the root: its own files pass, a foreign worktree does not")
    func worktreeRoot() {
        let root = "/u/Cal/.claude/worktrees/bliss"
        #expect(IndexStore.inScope(path: "/u/Cal/.claude/worktrees/bliss/Sources/A.swift", root: root))
        #expect(!IndexStore.inScope(path: "/u/Cal/.claude/worktrees/other/Sources/A.swift", root: root))
        // A main-checkout file (not in a worktree) also passes under a worktree root.
        #expect(IndexStore.inScope(path: "/u/Cal/Sources/A.swift", root: root))
    }
}

@Suite("Cross-check: textual scan")
struct IdentifierScanTests {
    @Test("Counts occurrences on word boundaries, ignoring substrings and case")
    func wholeWord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        let value = Parser()       // occurrence 1
        // Parser in a comment    — occurrence 2
        let helper = ParserHelper() // a substring — NOT counted
        let lower = parser          // different case — NOT counted
        """.write(to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)

        #expect(IdentifierScan.occurrences(of: "Parser", underRoot: dir, includeTests: true).count == 2)
        #expect(IdentifierScan.occurrences(of: "Missing", underRoot: dir, includeTests: true).count == 0)
        // matches: the carrying lines, used for graceful degradation.
        let scan = IdentifierScan.matches(of: "Parser", underRoot: dir, includeTests: true, limit: 40)
        #expect(scan.matches.count == 2)
        #expect(scan.matches.allSatisfy { $0.text.contains("Parser") })
        // An invalid identifier is not scanned.
        #expect(IdentifierScan.occurrences(of: "1bad", underRoot: dir, includeTests: true).count == 0)
        // A small fileLimit with more files than that gives truncated.
        try "let x = Parser()".write(to: dir.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        SwiftSources.clearFileListMemo()   // a file was added mid-process — clear the memo, as MCP does per call
        #expect(IdentifierScan.occurrences(of: "Parser", underRoot: dir, includeTests: true, fileLimit: 1).truncated)
    }
}

@Suite("Index provenance")
struct IndexProvenanceTests {
    @Test("summary reports the source, the store count, and freshness")
    func summary() {
        let fresh = IndexProvenance(source: .spm, storeCount: 2, freshness: .fresh)
        #expect(fresh.summary.contains("spm"))
        #expect(fresh.summary.contains("2"))
        #expect(fresh.summary.contains("fresh"))
        #expect(!fresh.summary.contains("STALE"))

        let stale = IndexProvenance(source: .derivedData, storeCount: 1, freshness: .stale)
        #expect(stale.summary.contains("derivedData"))
        #expect(stale.summary.contains("STALE"))
    }
}

@Suite("Scope guard")
struct ScaleGuardTests {
    @Test("exceedsLimit with an early exit")
    func exceedsLimitEarlyExit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<5 {
            try "struct S\(index) {}".write(to: directory.appendingPathComponent("F\(index).swift"), atomically: true, encoding: .utf8)
        }
        #expect(SwiftSources.exceedsLimit(under: directory, includeTests: false, limit: 3))
        #expect(!SwiftSources.exceedsLimit(under: directory, includeTests: false, limit: 10))
    }
}

@Suite("Rule dedup")
struct RuleDedupTests {
    @Test("Overlapping patterns do not duplicate a violation")
    func overlappingPatternsDeduped() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-dedup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "let x = Calendar.current\n".write(to: directory.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)

        let rule = Rule(id: "dup", message: "m", patterns: ["Calendar.current", "Calendar.current"])
        let violations = RuleEngine.run(rules: [rule], projectRoot: directory.path, includeTests: false)
        #expect(violations.count == 1)
    }
}

@Suite("Store merging: definition fallback")
struct IndexStoreMergeTests {
    private func location(_ path: String, _ line: Int, def: Bool) -> SextantCore.SourceLocation {
        SextantCore.SourceLocation(path: path, line: line, column: 1, isDefinition: def)
    }

    @Test("A nil definition from one store is filled in by a real one from another")
    func mergeFillsDefinition() {
        let withoutDef = SymbolHit(name: "Foo", usr: "u", kind: "struct", definition: nil,
                                   references: [location("/a.swift", 10, def: false)])
        let withDef = SymbolHit(name: "Foo", usr: "u", kind: "struct",
                                definition: location("/a.swift", 1, def: true), references: [])
        let merged = IndexStoreSet.merge([[withoutDef], [withDef]], limit: 1000)
        #expect(merged.count == 1)
        #expect(merged.first?.definition?.line == 1)
    }

    @Test("With no definition in either store it stays nil — a reference is not passed off as one")
    func mergeKeepsNilWhenNoDefinition() {
        let a = SymbolHit(name: "Foo", usr: "u", kind: "struct", definition: nil,
                          references: [location("/a.swift", 10, def: false)])
        let b = SymbolHit(name: "Foo", usr: "u", kind: "struct", definition: nil,
                          references: [location("/b.swift", 20, def: false)])
        let merged = IndexStoreSet.merge([[a], [b]], limit: 1000)
        #expect(merged.count == 1)
        #expect(merged.first?.definition == nil)
    }
}
