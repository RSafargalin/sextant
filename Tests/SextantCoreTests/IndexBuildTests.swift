import Foundation
import Testing
@testable import SextantCore

/// Building the index executes a foreign Package.swift. Its decisions — which packages join the
/// umbrella, on which platform, what was skipped — used to live in the executable, untestable.
@Suite("Index build preparation")
struct IndexBuildTests {
    private func package(_ identity: String, macOS: String?, path: String? = nil, products: [String] = ["Lib"]) -> IndexBuild.Package {
        IndexBuild.Package(
            reference: .init(path: path ?? "/repo/Packages/\(identity)", identity: identity, products: products),
            macOSVersion: macOS
        )
    }

    @Test("An empty manifest set is a refusal, not an empty umbrella")
    func noManifests() {
        #expect(IndexBuild.umbrellaPlan(packages: []).outcome == .noManifests)
    }

    /// A build without the test targets writes a store that answers about the library alone.
    /// Measured on Alamofire: 43 of 98 files covered, `refs Session` 25 against the 504 the whole
    /// package holds. The usages are in the code either way — only the index forgets them.
    @Test("The index build takes the test targets in by default")
    func swiftBuildIncludesTests() {
        #expect(IndexBuild.swiftBuildArguments(scratchPath: "/pkg/.build/sextant-index")
                == ["build", "--scratch-path", "/pkg/.build/sextant-index", "--enable-index-store", "--build-tests", "-v"])
        #expect(IndexBuild.swiftBuildArguments(scratchPath: "/pkg/.build/sextant-index", buildTests: false)
                == ["build", "--scratch-path", "/pkg/.build/sextant-index", "--enable-index-store", "-v"])
    }

    /// Under SwiftPM's Swift Build system a tree built without an index store counts as up to date
    /// when asked for one, compiles nothing and writes nothing. The tree the index is built in is
    /// therefore one nobody else builds, inside `.build` so it is ignored wherever `.build` is.
    @Test("A package is indexed in a build tree of its own, inside .build")
    func packageIsIndexedInItsOwnBuildTree() {
        let scratch = IndexStoreLocator.indexBuildDirectory(ofPackage: URL(fileURLWithPath: "/pkg", isDirectory: true))
        #expect(scratch.path == "/pkg/.build/sextant-index")
        #expect(IndexBuild.umbrellaBuildDirectory(forRoot: "/Users/x/App").path
                == IndexBuild.umbrellaDirectory(forRoot: "/Users/x/App").appendingPathComponent(".build").path)
    }

    /// The Xcode path cannot be fixed the way the SwiftPM one was: `xcodebuild build-for-testing`
    /// builds the test targets and writes no index store at all — measured twice on Alamofire's own
    /// project under Xcode 26, where a plain `build` of the same scheme wrote one. So the remedy
    /// named here is the scheme's Build action, which was measured to work: 87 of 98 files covered
    /// and 504 references where the scheme's default gives 43 files and 25.
    @Test("A build that indexed no tests says so, and the remedy differs per build system")
    func missingTestsAreNamedWithTheRemedy() throws {
        let xcode = try #require(IndexBuild.missingTestsNote(uncoveredTests: 44, isXcode: true))
        #expect(xcode.contains("44 test file(s)"))
        #expect(xcode.contains("Build action"))
        #expect(xcode.contains("build-for-testing writes no index store") || xcode.contains("writes no index store"))

        let package = try #require(IndexBuild.missingTestsNote(uncoveredTests: 3, isXcode: false))
        #expect(package.contains("--no-tests"))
        #expect(!package.contains("scheme"))

        // Nothing missing, nothing said.
        #expect(IndexBuild.missingTestsNote(uncoveredTests: 0, isXcode: true) == nil)
    }

    @Test("Test files the store was not built from are named in the coverage line")
    func coverageNamesMissingTests() {
        let partial = StoreCoverage.Result(covered: 43, total: 98, foreign: 0, uncoveredTests: 44)
        #expect(partial.summary == "43/98 files (44%), 44 test file(s) outside it")

        // Nothing missing, nothing said: a line that always warns is a line nobody reads.
        let whole = StoreCoverage.Result(covered: 98, total: 98, foreign: 0, uncoveredTests: 0)
        #expect(whole.summary == "98/98 files (100%)")
    }

    @Test("Skipped manifests are reported even on a REFUSAL — the verdict came from an incomplete set")
    func skippedReportedOnRefusals() {
        let duplicates = IndexBuild.umbrellaPlan(
            packages: [package("Core", macOS: "13.0", path: "/a/Core"), package("Core", macOS: "13.0", path: "/b/Core")],
            expected: ["/a/Core", "/b/Core", "/repo/Packages/Broken"]
        )
        #expect(duplicates.outcome == .duplicateIdentities(["Core"]))
        #expect(duplicates.skipped == ["Broken"], "a dropped package must be reported even on a refusal")

        let platform = IndexBuild.umbrellaPlan(
            packages: [package("IOSOnly", macOS: nil, path: "/p/IOSOnly")],
            expected: ["/p/IOSOnly", "/p/Broken"]
        )
        #expect(platform.outcome == .unsupportedPlatform(["IOSOnly"]))
        #expect(platform.skipped == ["Broken"])

        let empty = IndexBuild.umbrellaPlan(packages: [], expected: ["/p/Broken"])
        #expect(empty.outcome == .noManifests)
        #expect(empty.skipped == ["Broken"])
    }

    @Test("Packages with the same identity are refused, and named")
    func duplicateIdentities() {
        let plan = IndexBuild.umbrellaPlan(packages: [
            package("Core", macOS: "13.0", path: "/a/Core"),
            package("Core", macOS: "13.0", path: "/b/Core"),
            package("UI", macOS: "13.0")
        ])
        #expect(plan.outcome == .duplicateIdentities(["Core"]))
    }

    @Test("A package without macOS support is refused — a host build is impossible")
    func unsupportedPlatform() {
        let plan = IndexBuild.umbrellaPlan(packages: [
            package("Core", macOS: "13.0"),
            package("IOSOnly", macOS: nil)
        ])
        #expect(plan.outcome == .unsupportedPlatform(["IOSOnly"]))
    }

    @Test("The umbrella platform is the maximum requirement; the manifest lists every product")
    func readyPlanPicksHighestPlatform() throws {
        let plan = IndexBuild.umbrellaPlan(packages: [
            package("Core", macOS: "13.0", products: ["CoreLib"]),
            package("UI", macOS: "26.0", products: ["UILib"]),
            package("Data", macOS: "14.2", products: ["DataLib"])
        ])
        guard case .ready(let manifest, let macOSVersion, let skipped) = plan.outcome else {
            Issue.record("expected .ready"); return
        }
        #expect(macOSVersion == "26.0")          // not the lexicographic "9 > 26"
        #expect(skipped.isEmpty)
        for product in ["CoreLib", "UILib", "DataLib"] { #expect(manifest.contains(product)) }
        #expect(manifest.contains(".macOS(.v26)") || manifest.contains("26.0"))
    }

    @Test("Unread manifests land in skipped — they will NOT be in the index")
    func reportsSkippedPackages() {
        let plan = IndexBuild.umbrellaPlan(
            packages: [package("Core", macOS: "13.0", path: "/repo/Packages/Core")],
            expected: ["/repo/Packages/Core", "/repo/Packages/Broken"]
        )
        guard case .ready(_, _, let skipped) = plan.outcome else { Issue.record("expected .ready"); return }
        #expect(skipped == ["Broken"])
    }

    @Test("Manifest parsing: only library products and the macOS requirement")
    func parsesManifest() throws {
        let manifest: [String: Any] = [
            "products": [
                ["name": "CoreLib", "type": ["library": ["automatic"]]],
                ["name": "tool", "type": ["executable": NSNull()]]
            ],
            "platforms": [["platformName": "ios", "version": "17.0"], ["platformName": "macos", "version": "14.0"]]
        ]
        #expect(IndexBuild.libraryProducts(in: manifest) == ["CoreLib"])
        #expect(IndexBuild.macOSRequirement(in: manifest) == "14.0")
        #expect(IndexBuild.macOSRequirement(in: ["platforms": [["platformName": "ios", "version": "17.0"]]]) == nil)
    }

    @Test("Schemes from xcodebuild -list output: workspace and project")
    func parsesSchemes() {
        #expect(IndexBuild.schemes(inListing: ["workspace": ["schemes": ["App", "Tests"]]]) == ["App", "Tests"])
        #expect(IndexBuild.schemes(inListing: ["project": ["schemes": ["Lib"]]]) == ["Lib"])
        #expect(IndexBuild.schemes(inListing: [:]).isEmpty)
    }

    @Test("The umbrella directory is outside the project, with no separator collisions in the path")
    func umbrellaDirectoryIsOutsideProject() {
        let directory = IndexBuild.umbrellaDirectory(forRoot: "/Users/x/Projects/App").path
        #expect(directory.contains("Library/Caches/sextant/umbrella"))
        #expect(!directory.hasPrefix("/Users/x/Projects/App"))
    }
}

/// `sextant index` run for real on a package someone already built the ordinary way. Under
/// SwiftPM's Swift Build system that build left the package up to date, and an index build in the
/// same tree compiled nothing and wrote no store; built in a tree of its own, it covers every file.
@Suite("Index build on a package built before", .serialized)
struct IndexBuildRunTests {
    private static var binary: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return BuildProducts.sextantBinary(under: root)
    }

    private static let files = [
        "Package.swift": """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "prebuilt", platforms: [.macOS(.v13)], targets: [
                .target(name: "CLib"),
                .target(name: "Lib", dependencies: ["CLib"]),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ])
            """,
        "Sources/CLib/include/clib.h": "int clib(void);\n",
        "Sources/CLib/clib.c": "#include \"clib.h\"\nint clib(void) { return 1; }\n",
        "Sources/Lib/A.swift": "public struct A { public init() {} }\n",
        "Sources/Lib/B.swift": "import CLib\npublic func b() -> Int32 { _ = A(); return clib() }\n",
        "Tests/LibTests/LibTests.swift": "import XCTest\nimport Lib\nfinal class LibTests: XCTestCase { func testB() { XCTAssertEqual(b(), 1) } }\n",
    ]

    private func run(_ executable: URL, _ arguments: [String]) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    @Test("Indexing a package already built without an index store covers all of its sources",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"))
    func indexesAPackageBuiltWithoutAStore() throws {
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-prebuilt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // Units record real paths, and the temporary directory is reached through a symlink.
        let root = created.resolvingSymlinksInPath()
        defer {
            BuildProducts.removeIndexSnapshots(under: root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: IndexBuild.umbrellaDirectory(forRoot: root.path))
            try? FileManager.default.removeItem(at: CompilationDatabase.path(forRoot: root.path))
        }
        for (path, contents) in Self.files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }

        let env = URL(fileURLWithPath: "/usr/bin/env")
        let ordinary = try run(env, ["swift", "build", "--build-tests", "--package-path", root.path])
        try #require(ordinary.code == 0, "the ordinary build failed:\n\(ordinary.output)")

        let index = try run(try #require(Self.binary), ["index", "--project", root.path])
        #expect(index.code == 0, "\(index.output)")

        let store = try #require(IndexStoreLocator.candidates(under: root).first {
            $0.isUsable && $0.path.hasPrefix(IndexStoreLocator.indexBuildDirectory(ofPackage: root).path + "/")
        }, "no store in sextant's own build tree:\n\(index.output)")
        // Every file that compiles is a main file of some unit; headers and the manifest never are.
        let mainFiles = try IndexStoreUnits.shared(libraryPath: nil).mainFiles(inStore: store.path)
        let compiled = ["Sources/CLib/clib.c", "Sources/Lib/A.swift", "Sources/Lib/B.swift", "Tests/LibTests/LibTests.swift"]
            .map { root.appendingPathComponent($0).path }
        #expect(Set(compiled).subtracting(mainFiles).isEmpty, "missing from the store: \(Set(compiled).subtracting(mainFiles).sorted())")
        #expect(CompilationDatabase.load(forRoot: root.path).map { ($0.file as NSString).lastPathComponent } == ["clib.c"])
    }
}

@Suite("bench measurements")
struct BenchmarkTests {
    @Test("Percentile: bounds, interpolation, empty set")
    func percentile() {
        #expect(Benchmark.percentile([], 50) == 0)
        #expect(Benchmark.percentile([5], 95) == 5)
        #expect(Benchmark.percentile([1, 2, 3, 4], 0) == 1)
        #expect(Benchmark.percentile([1, 2, 3, 4], 100) == 4)
        // rank = 0.5·3 = 1.5 → between 2 and 3.
        #expect(Benchmark.percentile([1, 2, 3, 4], 50) == 2.5)
        // Input order does not matter — the values are sorted.
        #expect(Benchmark.percentile([4, 1, 3, 2], 50) == 2.5)
    }

    @Test("The payload proxy is deterministic regardless of field order")
    func payloadIsDeterministic() {
        struct Pair: Encodable { let b: Int; let a: Int }
        #expect(Benchmark.jsonByteCount(Pair(b: 1, a: 2)) == Benchmark.jsonByteCount(Pair(b: 1, a: 2)))
        #expect(Benchmark.jsonByteCount([String]()) == 2)
    }
}
