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
        #expect(IndexBuild.swiftBuildArguments() == ["build", "--enable-index-store", "--build-tests"])
        #expect(IndexBuild.swiftBuildArguments(buildTests: false) == ["build", "--enable-index-store"])
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
