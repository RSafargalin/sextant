import Foundation
import Testing
@testable import SextantCore

/// Which stores and files an index answer is drawn from, and whether it says what it left out —
/// the decisions themselves, without a build.
@Suite("Index layer: stores and files")
struct IndexLayerDecisionTests {
    private func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-layer-\(name)-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Build trees and checkouts

    @Test("A build tree is recognised below the project root, not by a substring anywhere in the path")
    func buildTreesAreJudgedBelowTheRoot() {
        let root = "/work/.build/checkouts/project"
        #expect(!IndexStore.isBuildProduct(path: "\(root)/Sources/App/a.swift", root: root))
        #expect(!IndexStore.isBuildProduct(path: "/work/app/Sources/checkouts/Cart.swift", root: "/work/app"))
        #expect(IndexStore.isBuildProduct(path: "\(root)/.build/checkouts/Dep/Sources/d.swift", root: root))
        #expect(IndexStore.isBuildProduct(path: "/work/app/Tests/Fixtures/Pkg/.build/x.swift", root: "/work/app"))
        #expect(IndexStore.isBuildProduct(
            path: "/Users/u/Library/Developer/Xcode/DerivedData/App-x/SourcePackages/checkouts/Dep/a.swift", root: "/work/app"))
    }

    // MARK: Empty stores

    @Test("A store whose units directory is empty is not usable, and its freshness is unknown")
    func emptyUnitsDirectoryIsNotUsable() throws {
        let package = try temporaryDirectory("empty")
        defer { try? FileManager.default.removeItem(at: package) }
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"empty\")\n"
            .write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "struct A {}\n".write(to: package.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        let store = package.appendingPathComponent(".build/out/Products/Debug/index/store")
        try FileManager.default.createDirectory(at: store.appendingPathComponent("v5/units"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.appendingPathComponent("v5/records/ab"), withIntermediateDirectories: true)
        try Data().write(to: store.appendingPathComponent("v5/records/ab/record"))

        #expect(IndexFreshness.timestamp(ofStore: store.path) == nil)
        let candidates = IndexStoreLocator.candidates(under: package)
        #expect(candidates.count == 1)
        #expect(candidates.first?.isUsable == false)
        #expect(candidates.first?.rejection == "no units — nothing to read")
        #expect(IndexFreshness.report(storePaths: [store.path], projectRoot: package.path).state == .unknown)

        try Data().write(to: store.appendingPathComponent("v5/units/unit"))
        #expect(IndexStoreLocator.candidates(under: package).first?.isUsable == true)
    }

    // MARK: Policy and the configuration filter

    @Test("An explicit policy sees every candidate: the configuration filter does not remove its choice")
    func explicitPolicySeesEveryConfiguration() {
        let debug = StoreCandidate(path: "/pkg/.build/out/Products/Debug/index/store", origin: "/pkg", unitCount: 90,
                                   modified: Date().addingTimeInterval(-3600),
                                   coverage: StoreCoverage.Result(covered: 90, total: 100, foreign: 0))
        let release = StoreCandidate(path: "/pkg/.build/out/Products/Release/index/store", origin: "/pkg", unitCount: 40,
                                     modified: Date(),
                                     coverage: StoreCoverage.Result(covered: 40, total: 100, foreign: 0))
        let coverage = StoreSelection.resolve([debug, release], policy: .coverage)
        #expect(coverage.chosen.map(\.path) == [debug.path])
        #expect(coverage.candidates.allSatisfy { $0.isUsable })
        #expect(Set(StoreSelection.resolve([debug, release], policy: .union).chosen.map(\.path)) == [debug.path, release.path])

        // With no policy the filter still keeps one configuration, and names the other.
        let unset = StoreSelection.resolve([debug, release], policy: nil)
        #expect(unset.chosen.map(\.path) == [release.path])
        #expect(unset.candidates.first { $0.path == debug.path }?.rejection?.contains("another configuration") == true)
    }

    // MARK: The umbrella

    private var umbrellaStore: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sextant/umbrella/_work_app/.build/out/Products/Debug/index/store").path
    }

    @Test("The umbrella is a store sextant built: with no policy it answers by the rule, and a policy weighs it")
    func umbrellaTakesPartInTheDecision() {
        let umbrella = StoreCandidate(path: umbrellaStore, unitCount: 100, modified: Date().addingTimeInterval(-3600))
        let ordinary = StoreCandidate(path: "/work/app/Packages/A/.build/out/Products/Debug/index/store",
                                      origin: "/work/app/Packages/A", unitCount: 30, modified: Date())
        #expect(IndexStoreLocator.isBuiltBySextant(storePath: umbrellaStore))
        #expect(IndexProvenance.Source.of(storePath: umbrellaStore) == .umbrella)

        let unset = StoreSelection.resolve([umbrella, ordinary], policy: nil)
        #expect(unset.chosen.map(\.path) == [umbrellaStore])
        #expect(unset.decidedByOwnStoreRule)
        #expect(unset.candidates.first { $0.path == ordinary.path }?.rejection == StoreSelection.ownStoreRuleReason)
        let explanation = StoreSelection.explanation(of: unset, shorten: { $0 }).joined(separator: "\n")
        #expect(explanation.contains("umbrella of the project's packages"))

        #expect(StoreSelection.resolve([umbrella, ordinary], policy: .recency).chosen.map(\.path) == [ordinary.path])
    }

    /// The umbrella's store used to be picked as the freshest across layouts and configurations
    /// before the selection ever saw it — a second selection path. The selection now sees every
    /// store in the tree and keeps the one written last, by a rule it names.
    @Test("Of the stores in one tree `sextant index` builds, the selection keeps the one written last, whatever the policy")
    func ownTreeKeepsItsLastStore() {
        let tree = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sextant/umbrella/_work_app/.build").path
        let older = StoreCandidate(path: tree + "/arm64-apple-macosx/debug/index/store", origin: "/u",
                                   unitCount: 80, modified: Date().addingTimeInterval(-7200))
        let newer = StoreCandidate(path: tree + "/out/Products/Debug/index/store", origin: "/u",
                                   unitCount: 90, modified: Date().addingTimeInterval(-60))
        for policy in [nil, StorePolicy.union, .recency, .coverage] {
            let resolution = StoreSelection.resolve([older, newer], policy: policy)
            #expect(resolution.chosen.map(\.path) == [newer.path], "\(String(describing: policy))")
            #expect(resolution.candidates.first { $0.path == older.path }?.rejection == StoreSelection.earlierOwnBuildReason)
        }
        // A package's own index tree follows the same rule; an ordinary build's stores do not.
        let own = "/work/pkg/.build/sextant-index"
        let ownOlder = StoreCandidate(path: own + "/arm64-apple-macosx/debug/index/store", origin: "/work/pkg",
                                      unitCount: 10, modified: Date().addingTimeInterval(-7200))
        let ownNewer = StoreCandidate(path: own + "/out/Products/Debug/index/store", origin: "/work/pkg",
                                      unitCount: 10, modified: Date())
        let ordinaryNative = StoreCandidate(path: "/work/pkg/.build/arm64-apple-macosx/debug/index/store", origin: "/work/pkg",
                                            unitCount: 10, modified: Date().addingTimeInterval(-30))
        let ordinaryBuild = StoreCandidate(path: "/work/pkg/.build/out/Products/Debug/index/store", origin: "/work/pkg",
                                           unitCount: 10, modified: Date().addingTimeInterval(-10))
        let union = StoreSelection.resolve([ownOlder, ownNewer, ordinaryNative, ordinaryBuild], policy: .union)
        #expect(Set(union.chosen.map(\.path)) == [ownNewer.path, ordinaryNative.path, ordinaryBuild.path])
        #expect(StoreSelection.ownBuildTree(ofStorePath: ordinaryBuild.path) == nil)
        #expect(StoreSelection.ownBuildTree(ofStorePath: ownOlder.path) == own + "/")
    }

    // MARK: Keys

    @Test("Coverage measured for one project is not served for another with as many files",
          .enabled(if: IndexLayerRunTests.fixtureStore != nil, "needs the fixture's store — run `make fixture`"))
    func coverageIsKeyedByProject() throws {
        let store = try #require(IndexLayerRunTests.fixtureStore)
        let fixture = IndexLayerRunTests.repositoryRoot.appendingPathComponent("Tests/Fixtures/IndexFixture")
        let extensions = ["swift"] + IndexDeclarations.clangExtensions
        let count = SwiftSources.files(under: fixture, includeTests: true, extensions: extensions).count
        let other = try temporaryDirectory("coverage")
        defer { try? FileManager.default.removeItem(at: other) }
        for number in 0..<count {
            try "struct Other\(number) {}\n".write(to: other.appendingPathComponent("Other\(number).swift"),
                                                   atomically: true, encoding: .utf8)
        }
        #expect(SwiftSources.files(under: other, includeTests: true, extensions: extensions).count == count)

        let own = try #require(StoreCoverage.measure(store: store, projectRoot: fixture))
        #expect(own.covered > 0)
        // The store `sextant index` built covers every source; a manifest and the headers are not
        // what a unit is built from, so they do not keep it short of 100%.
        #expect(own.covered == own.total, "\(own.summary)")
        let foreign = try #require(StoreCoverage.measure(store: store, projectRoot: other))
        #expect(foreign.covered == 0)
        let files = SwiftSources.files(under: other, includeTests: true, extensions: extensions)
        #expect(StoreCoverage.cacheKey(store: store, projectRoot: other, includeTests: true, files: files)
                != StoreCoverage.cacheKey(store: store, projectRoot: other, includeTests: false, files: files))
    }

    @Test("Several stores cover what any of them covers: a union of file sets, not a sum of counts")
    func coverageOfSeveralStoresIsTheirUnion() {
        let one = StoreCoverage.Result(covered: 2, total: 4, foreign: 0, uncoveredSources: ["/p/C.swift", "/p/DTests.swift"])
        let other = StoreCoverage.Result(covered: 3, total: 4, foreign: 1, uncoveredSources: ["/p/DTests.swift"])
        let union = StoreCoverage.union([one, other])
        #expect(union?.covered == 3)
        #expect(union?.total == 4)
        #expect(union?.uncoveredTests == 1)
        #expect(union?.summary == "3/4 files (75%), 1 test file(s) outside it")
        #expect(StoreCoverage.union([one]) == one)
        #expect(StoreCoverage.union([]) == nil)
        #expect(StoreCoverage.union([one, StoreCoverage.Result(covered: 1, total: 5, foreign: 0)]) == nil)
    }

    @Test("Coverage is not served from the cache for a different file set of the same size")
    func coverageIsKeyedByTheFileSet() throws {
        let root = try temporaryDirectory("coverage-rename")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store").path
        let before = [root.appendingPathComponent("Sources/A.swift"), root.appendingPathComponent("Tests/Renamed.swift")]
        let renamed = [root.appendingPathComponent("Sources/A.swift"), root.appendingPathComponent("Tests/Again.swift")]
        #expect(StoreCoverage.cacheKey(store: store, projectRoot: root, includeTests: true, files: before)
                != StoreCoverage.cacheKey(store: store, projectRoot: root, includeTests: true, files: renamed))
        // The order a walk lists the files in is not part of the identity.
        #expect(StoreCoverage.cacheKey(store: store, projectRoot: root, includeTests: true, files: before)
                == StoreCoverage.cacheKey(store: store, projectRoot: root, includeTests: true, files: before.reversed()))
    }

    @Test("One project spelled two ways has one umbrella and one build log")
    func umbrellaIsKeyedByTheCanonicalRoot() throws {
        let root = try temporaryDirectory("umbrella")
        defer { try? FileManager.default.removeItem(at: root) }
        let spelled = root.path + "/../" + root.lastPathComponent + "/"
        #expect(IndexBuild.umbrellaDirectory(forRoot: spelled) == IndexBuild.umbrellaDirectory(forRoot: root.path))
        #expect(IndexBuild.buildLog(forRoot: spelled) == IndexBuild.buildLog(forRoot: root.path))

        let current = FileManager.default.currentDirectoryPath
        let relative = IndexBuild.buildLog(forRoot: ".")
        #expect(relative == IndexBuild.buildLog(forRoot: current))
        #expect(!relative.path.contains("/./") && !relative.deletingLastPathComponent().lastPathComponent.hasPrefix("."))
    }

    @Test("Flags stored for a nested package are found from the root around it", .enabled(if: (try? ClangLibrary.shared()) != nil, "needs libclang"))
    func flagsOfANestedRootAreFound() throws {
        let root = try temporaryDirectory("flags")
        let nested = root.appendingPathComponent("Fixtures/Pkg")
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("Sources/C"), withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("Sources/C/c.c")
        try "int answer(void) { return 42; }\n".write(to: file, atomically: true, encoding: .utf8)
        try CompilationDatabase.save([CompileCommand(directory: nested.path, file: file.path,
                                                     arguments: ["clang", "-c", file.path])], forRoot: nested.path)
        defer {
            try? FileManager.default.removeItem(at: CompilationDatabase.entry(forRoot: nested.path))
            try? FileManager.default.removeItem(at: root)
        }

        let search = CFamilySearch.run(pattern: "answer()", searchRoot: root.path, projectRoot: root.path, includeTests: true)
        #expect(!search.unscanned.contains { $0.reason.contains("no compile flags") }, "\(search.unscanned)")
        #expect(search.scannedCount == 1)
        #expect(CompilationDatabase.commands(forFilesUnder: root.path).map(\.file) == [file.path])
        // A sibling outside the root asked about is not offered.
        #expect(CompilationDatabase.commands(forFilesUnder: root.appendingPathComponent("Elsewhere").path).isEmpty)
    }

    @Test("A file no rule pattern compiles in is reported with the pattern that failed, not as a fault of the file",
          .enabled(if: (try? ClangLibrary.shared()) != nil, "needs libclang"))
    func ruleFailureNamesThePattern() throws {
        let root = try temporaryDirectory("lint")
        let file = root.appendingPathComponent("Empty.c")
        try "".write(to: file, atomically: true, encoding: .utf8)
        try CompilationDatabase.save([CompileCommand(directory: root.path, file: file.path,
                                                     arguments: ["clang", "-c", file.path])], forRoot: root.path)
        defer {
            try? FileManager.default.removeItem(at: CompilationDatabase.entry(forRoot: root.path))
            try? FileManager.default.removeItem(at: root)
        }
        let rule = Rule(id: "system-state", message: "global state", patterns: ["Calendar.current"])
        let outcome = CFamilyLint.run(rules: [rule], lintRoot: root.path, projectRoot: root.path, includeTests: true)
        let reason = try #require(outcome.unscanned.first { $0.file == "Empty.c" }?.reason)
        #expect(reason.contains("`Calendar.current`"), "\(reason)")
        #expect(reason.contains("no rule pattern compiles"), "\(reason)")
    }

    // MARK: Advice on a stale index

    @Test("Advice on refreshing names the writer of the store the answer came from")
    func refreshAdviceFollowsTheWriter() {
        let own = "/pkg/.build/sextant-index/out/Products/Debug/index/store"
        let ordinary = "/pkg/.build/out/Products/Debug/index/store"
        let xcode = "/Users/u/Library/Developer/Xcode/DerivedData/App-x/Index.noindex/DataStore"
        #expect(StoreSelection.refreshAdvice(forStores: [own]) == "run `sextant index`")
        #expect(StoreSelection.refreshAdvice(forStores: [umbrellaStore]) == "run `sextant index`")
        #expect(StoreSelection.refreshAdvice(forStores: [xcode]).hasPrefix("rebuild the project"))
        #expect(StoreSelection.refreshAdvice(forStores: [ordinary]).contains("rebuild whatever wrote this store"))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-advice-\(UUID().uuidString).swift")
        try? "let unrelated = 1\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let hit = SymbolHit(name: "Widget", usr: "s:6Widget", kind: "struct",
                            definition: nil, references: [SourceLocation(path: file.path, line: 1, column: 5, isDefinition: false)])
        let rendering = SymbolReport.lookup(symbol: "Widget", hits: [hit], query: .references,
                                            style: .cli(compact: false, referenceLimit: 10), path: { $0 },
                                            snippet: { _ in "let unrelated = 1" },
                                            refresh: StoreSelection.refreshAdvice(forStores: [own]))
        let advisory = rendering.advisory ?? ""
        #expect(advisory.contains("To refresh the index: run `sextant index`."), "\(advisory)")
        #expect(!advisory.contains("Rebuild the project"))
        #expect(SourceBody.unextractableReason(refresh: "run `sextant index`").hasSuffix("To refresh the index: run `sextant index`."))

        let label = IndexProvenance(source: .spm, storeCount: 1, report: IndexFreshness.Report(state: .stale, basis: .buildTime),
                                    storePaths: [own]).freshnessLabel
        #expect(label.contains("sources are newer: run `sextant index` (compared by build time)"), "\(label)")
    }

    // MARK: A definition the index lacks for some symbols of a name

    @Test("A symbol with no definition in the index is answered beside the defined ones, and says so")
    func undefinedSymbolIsLabelled() {
        let hits = [
            SymbolHit(name: "shared_name()", usr: "s:5big11shared_nameSiyF", kind: "function",
                      definition: SourceLocation(path: "/p/a.swift", line: 1, column: 13, isDefinition: true), references: []),
            SymbolHit(name: "shared_name", usr: "c:@F@shared_name", kind: "function", definition: nil,
                      references: [SourceLocation(path: "/p/c.c", line: 2, column: 30, isDefinition: false)]),
        ]
        let text = SymbolReport.lookup(symbol: "shared_name", hits: hits, query: .references,
                                       style: .cli(compact: true, referenceLimit: 10), path: { $0 }, snippet: { _ in nil })
            .lines.joined(separator: "\n")
        #expect(text.contains("def: not in the index (an external symbol, or one only declared here)"), "\(text)")
        #expect(text.contains("def: /p/a.swift:1:13"), "\(text)")
    }
}

/// The same questions through the real binary, over a package built once: it lives under a
/// directory named `checkouts`, holds more than a thousand of everything a list is capped at, and
/// a C function with the name of a Swift one that only a header declares.
@Suite("Index layer through the binary", .serialized)
struct IndexLayerRunTests {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var binary: URL? { BuildProducts.sextantBinary(under: repositoryRoot) }
    static var fixtureStore: String? {
        BuildProducts.indexStore(under: repositoryRoot.appendingPathComponent("Tests/Fixtures/IndexFixture"))
    }

    /// More than the cap of 1000 every list used to stop at.
    static let count = 1050

    final class Package: @unchecked Sendable {
        let base: URL
        let root: URL
        let home: URL
        let store: String

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("sextant-layer-run-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
            root = base.appendingPathComponent("checkouts/big")
            home = base.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let n = IndexLayerRunTests.count
            var swift = "public protocol P {}\npublic final class Widget { public init() {} }\n"
            swift += (0..<n).map { "public struct S\($0): P {}" }.joined(separator: "\n") + "\n"
            swift += (0..<n).map { "public func f\($0)() {}" }.joined(separator: "\n") + "\n"
            swift += "public func caller() {\n" + (0..<n).map { "    f\($0)()" }.joined(separator: "\n") + "\n}\n"
            swift += "public func build() {\n" + (0..<n).map { _ in "    _ = Widget()" }.joined(separator: "\n") + "\n}\n"
            swift += "public func shared_name() -> Int { 1 }\npublic func callShared() -> Int { shared_name() }\n"
            let files = [
                "Package.swift": """
                    // swift-tools-version: 5.9
                    import PackageDescription
                    let package = Package(name: "big", targets: [.target(name: "big"), .target(name: "cside")])

                    """,
                "Sources/big/big.swift": swift,
                "Sources/cside/include/cside.h": "int shared_name(void);\n",
                "Sources/cside/cside.c": "#include \"cside.h\"\nint use_shared(void) { return shared_name(); }\n",
            ]
            for (path, contents) in files {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file, atomically: true, encoding: .utf8)
            }
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            build.arguments = ["swift", "build", "--enable-index-store", "--package-path", root.path]
            build.standardOutput = FileHandle.nullDevice
            build.standardError = FileHandle.nullDevice
            try build.run()
            build.waitUntilExit()
            guard build.terminationStatus == 0, let store = BuildProducts.indexStore(under: root) else {
                throw Failure(description: "swift build of the test package failed (\(build.terminationStatus))")
            }
            self.store = store
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        struct Failure: Error, CustomStringConvertible { let description: String }

        func sextant(_ arguments: [String], input: String? = nil) throws -> (code: Int32, output: String, errors: String) {
            let process = Process()
            process.executableURL = IndexLayerRunTests.binary
            process.arguments = arguments + ["--project", root.path, "--index-store", store]
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
    }

    private static let shared = Result { try Package() }

    private func package() throws -> Package { try Self.shared.get() }

    @Test("A project under a directory named `checkouts` keeps its own sources",
          .enabled(if: binary != nil, "needs the built binary"), .timeLimit(.minutes(5)))
    func projectUnderCheckoutsKeepsItsSources() throws {
        let result = try package().sextant(["refs", "Widget", "--json"])
        let hits = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]],
                                "\(result.output)\n\(result.errors)")
        #expect(hits.reduce(0) { $0 + ($1["totalReferences"] as? Int ?? 0) } >= Self.count, "\(result.errors)")
    }

    @Test("impls and callees count every related symbol, not the first thousand",
          .enabled(if: binary != nil, "needs the built binary"), .timeLimit(.minutes(5)))
    func relatedListsAreNotCapped() throws {
        let impls = try package().sextant(["impls", "P"])
        #expect(impls.output.contains("── P: \(Self.count)"), "\(impls.output.prefix(300))")
        #expect(impls.output.contains("… \(Self.count - 1000) more (--limit 1000)"))
        let callees = try package().sextant(["callees", "caller"])
        #expect(callees.output.contains("── caller: \(Self.count)"), "\(callees.output.prefix(300))")

        let json = try package().sextant(["impls", "P", "--json"])
        #expect(json.errors.contains("first 1000 of \(Self.count) shown"), "\(json.errors)")
    }

    @Test("construct, blast and --verify count from the real totals",
          .enabled(if: binary != nil, "needs the built binary"), .timeLimit(.minutes(5)))
    func countsComeFromTheTotals() throws {
        let construct = try package().sextant(["construct", "Widget"])
        #expect(construct.output.contains(", \(Self.count):"), "\(construct.output.prefix(300))")

        let blast = try package().sextant(["blast", "P", "--json"])
        let radius = try #require(try JSONSerialization.jsonObject(with: Data(blast.output.utf8)) as? [String: Any])
        #expect((radius["implementations"] as? [String])?.count == Self.count)

        let verify = try package().sextant(["refs", "Widget", "--verify"])
        let semantic = verify.errors.components(separatedBy: "[cross-check: semantic ").dropFirst().first
            .flatMap { Int($0.prefix { $0.isNumber }) }
        #expect((semantic ?? 0) >= Self.count, "\(verify.errors)")
    }

    @Test("A symbol only a header declares is answered beside the defined one with the same name",
          .enabled(if: binary != nil, "needs the built binary"), .timeLimit(.minutes(5)))
    func declaredOnlySymbolIsAdded() throws {
        let result = try package().sextant(["refs", "shared_name", "--json"])
        let hits = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]],
                                "\(result.output)\n\(result.errors)")
        #expect(hits.count == 2, "\(hits)")
        #expect(hits.filter { $0["definition"] == nil }.count == 1, "\(hits)")
        let text = try package().sextant(["refs", "shared_name"])
        #expect(text.output.contains("def: not in the index"), "\(text.output)")
    }

    @Test("A resource read from the index carries the trust label a tool answer carries",
          .enabled(if: binary != nil, "needs the built binary"), .timeLimit(.minutes(5)))
    func resourceCarriesProvenance() throws {
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 0, "method": "initialize",
             "params": ["protocolVersion": MCPProtocol.revision, "capabilities": [String: Any](),
                        "clientInfo": ["name": "layer", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": ["uri": "sextant://symbol/Widget"]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "context", "arguments": ["symbol": "Widget"]]],
        ]
        let input = try messages.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let output = try package().sextant(["mcp"], input: input)
        var results: [Int: [String: Any]] = [:]
        for line in output.output.split(separator: "\n") {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = message["id"] as? Int, let result = message["result"] as? [String: Any] else { continue }
            results[id] = result
        }
        let contents = try #require(results[1]?["contents"] as? [[String: Any]], "\(output.output)\n\(output.errors)")
        let resource = try #require(contents.first?["text"] as? String)
        let tool = ((results[2]?["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        #expect(resource.contains("[index: explicit"), "\(resource.suffix(300))")
        #expect(resource == tool)
    }

    @Test("`sextant store` lists the umbrella beside the other stores and says which answers",
          .enabled(if: binary != nil && fixtureStore != nil, "needs the built binary and the fixture's store — run `make fixture`"),
          .timeLimit(.minutes(3)))
    func umbrellaIsListedBesideOtherStores() throws {
        let store = try #require(Self.fixtureStore)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-umbrella-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("project")
        let home = base.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"project\")\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let ordinary = root.appendingPathComponent(".build/out/Products/Debug/index")
        let umbrella = home.appendingPathComponent("Library/Caches/sextant/umbrella/\(CanonicalPath.entryName(of: root.path))")
            .appendingPathComponent(".build/out/Products/Debug/index")
        for directory in [ordinary, umbrella] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: store), to: directory.appendingPathComponent("store"))
        }

        let process = Process()
        process.executableURL = Self.binary
        process.arguments = ["store", "--project", root.path]
        var environment = ProcessInfo.processInfo.environment
        for name in ["SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA", "CLAUDE_PROJECT_DIR", "SEXTANT_TELEMETRY"] {
            environment[name] = nil
        }
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SEXTANT_NO_DAEMON"] = "1"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let collected = OutputCapture.collect(from: [out, err]) { process.waitUntilExit() }
        let screen = collected[0]
        #expect(screen.contains(".build/out/Products/Debug/index/store"), "\(screen)")
        #expect(screen.contains("umbrella of the project's packages"), "\(screen)")
        #expect(screen.contains("the rule decides"), "\(screen)")
        #expect(screen.contains("found by: spm, umbrella"), "\(screen)")
    }
}
