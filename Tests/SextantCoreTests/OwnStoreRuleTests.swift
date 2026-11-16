import Foundation
import Testing
@testable import SextantCore

/// With no store policy set, the store `sextant index` built answers ahead of the stores an
/// ordinary build left in `.build`; an explicit policy still decides. Before this rule a package
/// with both refused every semantic question until somebody chose a policy.
@Suite("Store built by sextant index answers first")
struct OwnStoreRuleTests {
    private static let own = "/pkg/.build/sextant-index/out/Products/Debug/index/store"
    private static let ordinary = "/pkg/.build/out/Products/Debug/index/store"
    private static let ordinaryRelease = "/pkg/.build/out/Products/Release/index/store"

    private func candidate(_ path: String, minutesAgo: Double) -> StoreCandidate {
        StoreCandidate(path: path, origin: "/pkg", unitCount: 10, modified: Date().addingTimeInterval(-minutesAgo * 60))
    }

    @Test("With no policy, the store sextant built is read and the ordinary one is set aside by name")
    func ownStoreWinsWithoutAPolicy() {
        let resolution = StoreSelection.resolve([candidate(Self.ordinary, minutesAgo: 1), candidate(Self.own, minutesAgo: 60)],
                                                policy: nil)
        #expect(resolution.chosen.map(\.path) == [Self.own])
        #expect(resolution.decidedByOwnStoreRule)
        #expect(!resolution.needsPolicy)
        #expect(resolution.setAsideByOwnStoreRule == 1)
        #expect(resolution.candidates.first { $0.path == Self.ordinary }?.rejection == StoreSelection.ownStoreRuleReason)

        let explanation = StoreSelection.explanation(of: resolution, shorten: { $0 }).joined(separator: "\n")
        #expect(explanation.contains(StoreSelection.ownStoreRule))
        #expect(explanation.contains("→ using \(Self.own)"))
    }

    @Test("An explicit policy overrides the rule")
    func explicitPolicyWins() {
        let resolution = StoreSelection.resolve([candidate(Self.ordinary, minutesAgo: 1), candidate(Self.own, minutesAgo: 60)],
                                                policy: .recency)
        #expect(resolution.chosen.map(\.path) == [Self.ordinary])
        #expect(!resolution.decidedByOwnStoreRule)
        #expect(Set(StoreSelection.resolve([candidate(Self.ordinary, minutesAgo: 1), candidate(Self.own, minutesAgo: 60)],
                                           policy: .union).chosen.map(\.path)) == [Self.ordinary, Self.own])
    }

    /// The configuration filter used to run inside the locator, before any rule: a release build
    /// made after `sextant index` set the store sextant built aside as "another configuration".
    @Test("A release build made later does not push the store sextant built out")
    func laterReleaseBuildDoesNotRejectTheOwnStore() {
        let resolution = StoreSelection.resolve([candidate(Self.ordinaryRelease, minutesAgo: 1), candidate(Self.own, minutesAgo: 60)],
                                                policy: nil)
        #expect(resolution.chosen.map(\.path) == [Self.own])
    }

    @Test("Without a store sextant built, two ordinary stores still need a policy")
    func ordinaryStoresStillNeedAPolicy() {
        let resolution = StoreSelection.resolve([candidate(Self.ordinary, minutesAgo: 1),
                                                 candidate("/pkg/.build/arm64-apple-macosx/debug/index/store", minutesAgo: 60)],
                                                policy: nil)
        #expect(resolution.chosen.isEmpty)
        #expect(resolution.needsPolicy)
        #expect(!resolution.decidedByOwnStoreRule)
    }

    @Test("The provenance line names the rule when it chose")
    func provenanceNamesTheRule() {
        let summary = IndexProvenance(source: .spm, storeCount: 1,
                                      report: IndexFreshness.Report(state: .fresh, basis: .snapshot),
                                      selection: "chosen by rule").summary
        #expect(summary.contains("chosen by rule"))
        #expect(summary.contains("fresh (compared against the snapshot taken by `sextant index`)"))
    }
}

/// The rule through the real binary: a package holding a store from an ordinary build and one
/// `sextant index` built (copies of the fixture's store), in a home of its own.
@Suite("Store rule through the binary", .serialized)
struct OwnStoreRuleRunTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var binary: URL? { BuildProducts.sextantBinary(under: packageRoot) }
    static var fixtureStore: String? {
        BuildProducts.indexStore(under: packageRoot.appendingPathComponent("Tests/Fixtures/IndexFixture"))
    }

    private func run(_ arguments: [String], home: URL, environment extra: [String: String] = [:]) throws
        -> (code: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
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
        try process.run()
        let collected = OutputCapture.collect(from: [out, err]) { process.waitUntilExit() }
        return (process.terminationStatus, collected[0], collected[1])
    }

    @Test("Semantic commands answer from the store sextant built; an explicit policy still wins",
          .enabled(if: binary != nil && fixtureStore != nil, "needs the built binary and the fixture's store — run `make fixture`"),
          .timeLimit(.minutes(3)))
    func answersFromTheOwnStore() throws {
        let store = try #require(Self.fixtureStore)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-rule-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("package")
        let home = base.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"rule\")\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let ordinary = root.appendingPathComponent(".build/out/Products/Debug/index")
        let own = root.appendingPathComponent(".build/sextant-index/out/Products/Debug/index")
        for directory in [ordinary, own] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: store), to: directory.appendingPathComponent("store"))
        }
        // The ordinary build's store is the newer one, so `recency` reads it and the rule does not.
        let later = Date().addingTimeInterval(600)
        let units = try #require(try FileManager.default.contentsOfDirectory(atPath: ordinary.appendingPathComponent("store").path)
            .first { $0.hasPrefix("v") })
        try FileManager.default.setAttributes([.modificationDate: later],
                                              ofItemAtPath: ordinary.appendingPathComponent("store/\(units)/units").path)

        let unset = try run(["defs", "EnglishGreeter", "--project", root.path], home: home)
        #expect(!unset.errors.contains("no store policy is set"), "\(unset.errors)")
        #expect(unset.output.contains("EnglishGreeter"), "\(unset.output)\n\(unset.errors)")
        #expect(unset.errors.contains("the store `sextant index` built"), "\(unset.errors)")
        #expect(unset.errors.contains("→ using .build/sextant-index/") || unset.errors.contains("→ using \(own.path)"),
                "\(unset.errors)")

        let explicit = try run(["defs", "EnglishGreeter", "--project", root.path], home: home,
                               environment: ["SEXTANT_STORE_POLICY": "recency"])
        #expect(explicit.output.contains("EnglishGreeter"), "\(explicit.output)\n\(explicit.errors)")
        #expect(explicit.errors.contains("policy `recency`"), "\(explicit.errors)")
        #expect(!explicit.errors.contains("the store `sextant index` built,"), "\(explicit.errors)")
        let using = explicit.errors.split(separator: "\n").first { $0.contains("→ using") }.map(String.init) ?? ""
        #expect(using.contains(".build/out/Products/Debug/index/store") && !using.contains("sextant-index"), "\(explicit.errors)")

        let screen = try run(["store", "--project", root.path], home: home)
        #expect(screen.output.contains("rule: \(StoreSelection.ownStoreRule)"), "\(screen.output)")
        #expect(screen.output.contains("the rule decides"), "\(screen.output)")

        // Under an explicit policy, the store it does not read carries the reason on this screen
        // too, in the words of the explanation every answer prints.
        for policy in ["recency", "coverage"] {
            let screen = try run(["store", "--project", root.path], home: home, environment: ["SEXTANT_STORE_POLICY": policy])
            let blocks = screen.output.components(separatedBy: "\n\n")
            let ownBlock = try #require(blocks.first { $0.contains("sextant-index/out") && $0.contains("units:") }, "\(screen.output)")
            let explanation = try run(["defs", "EnglishGreeter", "--project", root.path], home: home,
                                      environment: ["SEXTANT_STORE_POLICY": policy])
            let left = try #require(explanation.errors.split(separator: "\n")
                .first { $0.contains("left") && $0.contains("sextant-index") }, "\(explanation.errors)")
            let dash = try #require(left.range(of: "] — "), "\(left)")
            let reason = String(left[dash.upperBound...])
            #expect(ownBlock.contains("not read: \(reason)"), "\(policy): \(screen.output)")
        }
    }
}
