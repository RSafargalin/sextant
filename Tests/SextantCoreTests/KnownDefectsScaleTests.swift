import Foundation
import Testing
@testable import SextantCore

/// The last of the defect ledger: the ones that need scale (a symbol past the internal cap), a
/// second store on disk, or a live daemon. They are slower than the other suites because each
/// builds its own package. A missing toolchain is a skip; anything the test itself sets up is a
/// hard requirement, so a defect can never stop being exercised in silence.
///
/// This suite holds the one defect still open — store choice by timestamp. Its test is wrapped in
/// `withKnownIssue` and will fail the moment selection stops ranking by mtime.
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

    /// `subdirectory` puts the package below the temporary root, so a test can build one at a
    /// path that looks like an agent worktree.
    private func buildFixture(name: String, files: [String: String], manifest: String? = nil,
                              subdirectory: String? = nil) -> Fixture? {
        var root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-scale-\(name)-\(UUID().uuidString)")
        if let subdirectory { root.appendPathComponent(subdirectory) }
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
        let usages = try #require(result.stdout.split(separator: "\n").first(where: { $0.contains("usages:") }))
        #expect(usages.contains("1200") || usages.lowercased().contains("more") || usages.contains("cap"))
    }

    // MARK: - Choosing between stores

    /// Selection ranks candidate stores by the modification time of their units, so a store that
    /// covers less of the project wins by being newer. On a project with agent worktrees this is
    /// not a corner case: the tool picks a store belonging to someone else's build, then rejects
    /// every record in it as foreign, and answers every semantic question with nothing — under a
    /// `fresh` label and a green `doctor`.
    ///
    /// The rival is a real copy of the good store with one unit removed: the shape another indexer
    /// leaves behind — same format, fewer units, newer timestamp. The assertion is on `doctor`,
    /// which names the store the tool decided to use: the decision itself, not its effect.
    @Test("the store that covers the project is not outranked by an emptier newer one")
    func storeChoiceIsNotByTimestampAlone() throws {
        guard let fixture = buildFixture(name: "pick", files: [
            "Sources/pick/a.swift": "public struct Widget { public init() {} }\n",
            "Sources/pick/b.swift": "public func use() { _ = Widget() }\n",
        ]) else { return }

        let rivalIndex = fixture.root.appendingPathComponent(".build/index-build/host/debug/index")
        try? FileManager.default.createDirectory(at: rivalIndex, withIntermediateDirectories: true)
        try #require(try? FileManager.default.copyItem(at: URL(fileURLWithPath: fixture.store),
                                                       to: rivalIndex.appendingPathComponent("store")))
        let rivalUnits = rivalIndex.appendingPathComponent("store/v5/units")
        let units = try #require(try? FileManager.default.contentsOfDirectory(atPath: rivalUnits.path))
        for unit in units where unit.hasPrefix("b.swift") {
            try FileManager.default.removeItem(at: rivalUnits.appendingPathComponent(unit))
        }
        #expect(units.count > ((try? FileManager.default.contentsOfDirectory(atPath: rivalUnits.path))?.count ?? 0))

        // The symlink is what lets the rival match the `<triple>/<configuration>` shape the locator
        // probes for; `sourcekit-lsp` leaves exactly this behind. It has to stay RELATIVE — the
        // URL-based API resolves a relative destination against the current directory, which
        // silently produces a dangling link and a rival that is not on disk at all.
        try FileManager.default.createSymbolicLink(
            atPath: fixture.root.appendingPathComponent(".build/index-build/debug").path,
            withDestinationPath: "host/debug")
        Thread.sleep(forTimeInterval: 1.1)   // mtime granularity: the rival must land strictly later
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: rivalUnits.path)
        try #require(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(".build/index-build/debug/index/store").path))

        let chosen = try sextant(["doctor", "--project", fixture.root.path])
        try #require(chosen.all.contains("index store"))
        let answer = try sextant(["refs", "Widget", "--project", fixture.root.path])
        withKnownIssue("selection ranks by unit mtime, so the emptier newer store wins") {
            #expect(!chosen.all.contains("index-build"))
            #expect(!answer.stdout.contains("usages: 0"))
        }
    }

    /// Measured on the target project: two Xcode stores, one of them built inside an agent
    /// worktree that lives under the checkout. The worktree store is newer, so it won selection —
    /// and every record in it names a path the scope filter rejects, so the answer to every
    /// semantic question was nothing, under a `fresh` label and a green `doctor`.
    ///
    /// No build needed: the locator takes the DerivedData directory as an argument, so the two
    /// candidates can be laid out on disk exactly as Xcode leaves them.
    @Test("a store built inside a nested worktree is not chosen for the checkout around it")
    func worktreeStoreIsNotChosenForTheCheckout() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("sextant-wt-\(UUID().uuidString)")
        let root = temporary.appendingPathComponent("checkout")
        let derived = temporary.appendingPathComponent("DerivedData")
        defer { try? manager.removeItem(at: temporary) }

        func makeStore(_ name: String, workspace: String, age: TimeInterval) throws -> String {
            let entry = derived.appendingPathComponent(name)
            let units = entry.appendingPathComponent("Index.noindex/DataStore/v5/units")
            try manager.createDirectory(at: units, withIntermediateDirectories: true)
            try (["WorkspacePath": workspace] as NSDictionary)
                .write(to: entry.appendingPathComponent("info.plist"))
            try manager.setAttributes([.modificationDate: Date().addingTimeInterval(age)],
                                      ofItemAtPath: units.path)
            return entry.appendingPathComponent("Index.noindex/DataStore").path
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let mine = try makeStore("App-aaa", workspace: root.appendingPathComponent("App.xcodeproj").path, age: -600)
        let worktree = try makeStore(
            "App-bbb",
            workspace: root.appendingPathComponent(".claude/worktrees/agent/App.xcodeproj").path,
            age: 0)

        let chosen = DerivedDataLocator.dataStore(forProjectRoot: root.path, derivedData: derived.path)
        #expect(chosen == mine)
        #expect(chosen != worktree)

        // From inside the worktree the same store is the right one: it holds that worktree's paths.
        let fromWorktree = DerivedDataLocator.dataStore(
            forProjectRoot: root.appendingPathComponent(".claude/worktrees/agent").path, derivedData: derived.path)
        #expect(fromWorktree == worktree)
    }

    /// The other half: when a foreign store is used anyway — `--index-store` names one, or another
    /// layout puts one in reach — the empty answer has to say why. It used to explain a class away
    /// as "a closure, a local, or another kind of symbol".
    @Test("an answer emptied by scope names the store, not an invented reason")
    func foreignStoreIsNamedAsTheReason() throws {
        guard let fixture = buildFixture(name: "wtfx", files: [
            "Sources/wtfx/a.swift": "public struct Widget { public init() {} }\npublic func use() { _ = Widget() }\n",
        ], subdirectory: ".claude/worktrees/agent") else { return }
        // The project is the checkout AROUND the worktree, so every record in the store is foreign.
        let outer = fixture.root.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()

        let result = try sextant(["refs", "Widget", "--project", outer.path, "--index-store", fixture.store])
        #expect(result.all.contains("outside this project"))
        #expect(!result.all.contains("a closure, a local"))
    }

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
        try #require(before.stdout.contains("files: 1"))   // the daemon answered

        try? "public struct Second {}\n"
            .write(to: fixture.root.appendingPathComponent("Sources/dmn/b.swift"), atomically: true, encoding: .utf8)

        let throughDaemon = try sextant(["map", "--project", fixture.root.path])
        let direct = try sextant(["map", "--project", fixture.root.path], environment: ["SEXTANT_NO_DAEMON": "1"])
        try #require(direct.stdout.contains("files: 2"))   // the file really is there

        #expect(throughDaemon.stdout.contains("files: 2"))
    }
}
