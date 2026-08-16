import Foundation
import Testing

/// What `--verify` says when the two counts disagree. It used to name one skew and stay silent on
/// the other two: more semantic than textual (which cannot be true of a name that is written where
/// it is used) went unremarked, and the measured `semantic 1, textual 3` fell exactly on the wrong
/// side of a ×3 threshold. A cross-check that prints an impossible pair without comment is worse
/// than no cross-check.
@Suite("Cross-check: naming the skew", .serialized)
struct CrossCheckSkewTests {

    private static var binary: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = root.appendingPathComponent(".build")
        for triple in (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? [] {
            let candidate = build.appendingPathComponent("\(triple)/debug/sextant")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func sextant(_ arguments: [String]) throws -> String {
        let binary = try #require(Self.binary, "sextant is not built — run `swift build` first")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return stdout + stderr
    }

    private func buildFixture(_ source: String) -> (root: URL, store: String)? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-skew-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources/skew")
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try? """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "skew", products: [.library(name: "skew", targets: ["skew"])],
                                  targets: [.target(name: "skew")])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try? source.write(to: sources.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--enable-index-store", "--package-path", root.path]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try? build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else { return nil }
        let buildDirectory = root.appendingPathComponent(".build")
        for triple in (try? FileManager.default.contentsOfDirectory(atPath: buildDirectory.path)) ?? [] {
            let store = buildDirectory.appendingPathComponent("\(triple)/debug/index/store").path
            if FileManager.default.fileExists(atPath: store) { return (root, store) }
        }
        return nil
    }

    /// The measured case: uses inside a branch this build does not contain. The gap has a reason,
    /// and naming it is the difference between "the tool missed something" and "the build did not
    /// include it".
    @Test("occurrences in an unbuilt #if branch are named as the reason for the gap")
    func conditionalOccurrencesAreNamed() throws {
        guard let fixture = buildFixture("""
            public struct Gadget {}
            public func used() { _ = Gadget() }
            #if os(Linux)
            public func linuxOnly() { _ = Gadget(); _ = Gadget() }
            #endif
            """) else { return }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let output = try sextant(["refs", "Gadget", "--project", fixture.root.path,
                                  "--index-store", fixture.store, "--verify"])
        #expect(output.contains("cross-check"))
        #expect(output.contains("#if"))
        #expect(output.contains("this build does not contain"))
    }

    /// A project without conditionals, where the counts line up, must stay quiet — a warning that
    /// prints on every run is one nobody reads.
    @Test("counts that agree say nothing extra")
    func agreeingCountsAreSilent() throws {
        guard let fixture = buildFixture("""
            public struct Plain {}
            public func used() { _ = Plain() }
            """) else { return }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let output = try sextant(["refs", "Plain", "--project", fixture.root.path,
                                  "--index-store", fixture.store, "--verify"])
        #expect(output.contains("cross-check"))
        #expect(!output.contains("#if"))
        #expect(!output.contains("cannot be true"))
    }
}
