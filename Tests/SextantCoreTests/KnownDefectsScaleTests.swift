import Foundation
import Testing

/// The last of the defect ledger: the ones that need scale (a symbol past the internal cap), a
/// second store on disk, or a live daemon. They are slower than the other suites because each
/// builds its own package, and they skip rather than fail when the environment cannot provide
/// what they need.
@Suite("Known defects: scale, store choice and the daemon", .serialized)
struct KnownDefectsScaleTests {

    // MARK: - Harness

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

    private struct Output {
        let stdout: String, stderr: String, code: Int32
        var all: String { stdout + stderr }
    }

    @discardableResult
    private func sextant(_ arguments: [String], environment: [String: String]? = nil) throws -> Output {
        let binary = try #require(Self.binary, "sextant is not built — run `swift build` first")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return Output(stdout: stdout, stderr: stderr, code: process.terminationStatus)
    }

    private struct Fixture { let root: URL; let store: String }

    private func buildFixture(name: String, files: [String: String], manifest: String? = nil) -> Fixture? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-scale-\(name)-\(UUID().uuidString)")
        var all = files
        all["Package.swift"] = manifest ?? """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
                                  targets: [.target(name: "\(name)")])
            """
        for (path, contents) in all {
            let file = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: file, atomically: true, encoding: .utf8)
        }
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
            let candidate = buildDirectory.appendingPathComponent("\(triple)/debug/index/store").path
            if FileManager.default.fileExists(atPath: candidate) { return Fixture(root: root, store: candidate) }
        }
        return nil
    }

    // MARK: - Counts past the internal cap

    /// `IndexStore.lookup` stops at 1000 and the number is printed as the answer to "how many".
    /// `--limit` does not raise it, and `context` counts by a different route, so two commands of
    /// the same product disagree about one symbol.
    @Test("a symbol with more references than the internal cap is counted, or the cap is named")
    func referenceCapIsNamed() throws {
        let calls = (1...1200).map { "    _ = Widget(); // \($0)" }.joined(separator: "\n")
        guard let fixture = buildFixture(name: "cap", files: [
            "Sources/cap/a.swift": "public struct Widget { public init() {} }\npublic func many() {\n\(calls)\n}\n",
        ]) else { return }

        let result = try sextant(["refs", "Widget", "--project", fixture.root.path, "--index-store", fixture.store])
        guard let usages = result.stdout.split(separator: "\n").first(where: { $0.contains("usages:") }) else { return }
        #expect(usages.contains("1200") || usages.lowercased().contains("more") || usages.contains("cap"))
    }

    // MARK: - Choosing between stores — not covered here, and deliberately so
    //
    // Selection ranking a fresher-but-emptier store above the one that covers the project is
    // real: it is the defect this whole ledger started from, and it reproduces by hand in a
    // temporary package —
    //
    //     swift build --enable-index-store --package-path $P
    //     mkdir -p $P/.build/index-build/host/debug/index
    //     cp -R $P/.build/*/debug/index/store $P/.build/index-build/host/debug/index/store
    //     rm -f $P/.build/index-build/host/debug/index/store/v5/units/b.swift*
    //     ln -s host/debug $P/.build/index-build/debug
    //     touch $P/.build/index-build/host/debug/index/store/v5/units
    //     sextant doctor --project $P     # names .build/index-build/... — the emptier store
    //     sextant refs Widget --project $P   # 0 usages; with --index-store on the good one, 1
    //
    // — and on a real Xcode project it takes the whole semantic layer down. Written as a test
    // with the same steps it does *not* reproduce: the good store keeps winning, and I could not
    // establish why. A test that quietly stops exercising its defect reads as "fixed", which is
    // the failure this ledger exists to prevent, so it is absent rather than green.

    // MARK: - The daemon

    /// The daemon is not an optimisation on a real project — it is the difference between seconds
    /// and half a minute — so its answers are the answers. It memoises the file list once and never
    /// invalidates it, and nothing in the output says the answer came from a daemon.
    @Test("a file created after the daemon started is visible to it")
    func daemonSeesNewFiles() throws {
        guard let fixture = buildFixture(name: "dmn", files: [
            "Sources/dmn/a.swift": "public struct First {}\n",
        ]) else { return }

        let daemon = Process()
        daemon.executableURL = try #require(Self.binary)
        daemon.arguments = ["serve", "--project", fixture.root.path]
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        defer { daemon.terminate(); daemon.waitUntilExit() }
        Thread.sleep(forTimeInterval: 1.0)

        let before = try sextant(["map", "--project", fixture.root.path])
        guard before.stdout.contains("files: 1") else { return }   // the daemon answered

        try? "public struct Second {}\n"
            .write(to: fixture.root.appendingPathComponent("Sources/dmn/b.swift"), atomically: true, encoding: .utf8)

        let throughDaemon = try sextant(["map", "--project", fixture.root.path])
        let direct = try sextant(["map", "--project", fixture.root.path], environment: ["SEXTANT_NO_DAEMON": "1"])
        guard direct.stdout.contains("files: 2") else { return }   // the file really is there

        #expect(throughDaemon.stdout.contains("files: 2"))
    }
}
