import Foundation
import Testing
@testable import SextantCore

/// Freshness judged against the snapshot `sextant index` takes: by content, per file, and with the
/// manifests and the build as reasons of their own. Every case runs over a real temporary git
/// repository (or a plain directory), a miniature store and a home of its own, so nothing here
/// needs a build and nothing touches the user's cache.
@Suite("Index snapshot")
struct IndexSnapshotTests {
    /// A project with a store and a home, created fresh per test.
    private final class Project {
        let base: URL
        let root: URL
        let home: URL
        let store: URL

        init(git: Bool) throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("sextant-snapshot-\(UUID().uuidString.prefix(8))")
                .resolvingSymlinksInPath()
            root = base.appendingPathComponent("project")
            home = base.appendingPathComponent("home")
            store = root.appendingPathComponent(".build/sextant-index/out/Products/Debug/index/store")
            try FileManager.default.createDirectory(at: store.appendingPathComponent("v5/units"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try write("Package.swift", "// swift-tools-version: 5.9\n")
            try write("Sources/demo/A.swift", "struct A {}\n")
            try write("Sources/demo/B.swift", "struct B {}\n")
            try write("Sources/demo/c.m", "int c(void) { return 0; }\n")
            try "unit".write(to: store.appendingPathComponent("v5/units/A.swift.o-1"), atomically: true, encoding: .utf8)
            if git {
                try write(".gitignore", ".build/\n")
                try self.git("init", "-q")
                try commitAll("initial")
            }
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        func write(_ path: String, _ contents: String) throws {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }

        func remove(_ path: String) throws {
            try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        }

        /// Moves the modification time forward without changing a byte.
        func touch(_ path: String) throws {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)],
                                                  ofItemAtPath: root.appendingPathComponent(path).path)
        }

        @discardableResult
        func git(_ arguments: String...) throws -> String {
            let output = Command.successOutput("/usr/bin/env", ["git", "-C", root.path, "-c", "user.name=t",
                                                                "-c", "user.email=t@example.com",
                                                                "-c", "commit.gpgsign=false"] + arguments)
            return try #require(output, "git \(arguments.joined(separator: " ")) failed")
        }

        func commitAll(_ message: String) throws {
            try git("add", "-A")
            try git("commit", "-q", "-m", message)
        }

        /// What `sextant index` records after a build: the sources now, the store as it is.
        func recordSnapshot(exitStatus: Int32 = 0, testsBuilt: Bool = true, log: String = "") throws {
            let snapshot = try #require(IndexSnapshot.afterBuild(
                store: store.path, projectRoot: root.path, sources: IndexSnapshot.sources(ofProject: root.path).get(),
                exitStatus: exitStatus, testsBuilt: testsBuilt, buildLog: log, toolchain: nil))
            try snapshot.save(home: home)
        }

        func report(toolchain: @escaping () -> ToolchainIdentity? = { nil },
                    git: SourceSnapshot.GitRunner = .system) -> IndexFreshness.Report {
            IndexFreshness.report(storePaths: [store.path], projectRoot: root.path, home: home, toolchain: toolchain, git: git)
        }
    }

    // MARK: - git

    @Test("A touch without a content change stays fresh")
    func touchStaysFresh() throws {
        let project = try Project(git: true)
        try project.recordSnapshot()
        try project.touch("Sources/demo/A.swift")
        try project.touch("Sources/demo/c.m")

        let report = project.report()
        #expect(report.basis == .snapshot)
        #expect(report.state == .fresh, "\(report)")
        #expect(report.changedFiles.isEmpty)
    }

    @Test("An edit makes the index stale and names the file")
    func editIsStale() throws {
        let project = try Project(git: true)
        try project.recordSnapshot()
        try project.write("Sources/demo/B.swift", "struct B { var x = 1 }\n")

        let report = project.report()
        #expect(report.basis == .snapshot)
        #expect(report.state == .stale)
        #expect(report.changedFiles == ["Sources/demo/B.swift"])
        #expect(report.reasons().first?.contains("1 file(s) changed since the index was built: Sources/demo/B.swift") == true)
    }

    @Test("A file dirty when indexed and unchanged since is not a change")
    func dirtyAtIndexTimeUnchangedIsFresh() throws {
        let project = try Project(git: true)
        try project.write("Sources/demo/A.swift", "struct A { let dirty = true }\n")
        try project.recordSnapshot()

        let report = project.report()
        #expect(report.state == .fresh, "\(report)")
        #expect(report.basis == .snapshot)
    }

    @Test("A file reverted to HEAD after being indexed dirty is a change")
    func revertedAfterIndexIsStale() throws {
        let project = try Project(git: true)
        try project.write("Sources/demo/A.swift", "struct A { let dirty = true }\n")
        try project.recordSnapshot()
        try project.git("checkout", "--", "Sources/demo/A.swift")

        let report = project.report()
        #expect(report.state == .stale)
        #expect(report.changedFiles == ["Sources/demo/A.swift"])
    }

    @Test("A new untracked source is a change")
    func untrackedSourceIsStale() throws {
        let project = try Project(git: true)
        try project.recordSnapshot()
        try project.write("Sources/demo/New.swift", "struct New {}\n")

        let report = project.report()
        #expect(report.state == .stale)
        #expect(report.changedFiles == ["Sources/demo/New.swift"])
    }

    @Test("A deleted source is a change")
    func deletedSourceIsStale() throws {
        let project = try Project(git: true)
        try project.recordSnapshot()
        try project.remove("Sources/demo/c.m")

        let report = project.report()
        #expect(report.state == .stale)
        #expect(report.changedFiles == ["Sources/demo/c.m"])
    }

    @Test("A file that is not a source changes nothing")
    func nonSourceIsIgnored() throws {
        let project = try Project(git: true)
        try project.recordSnapshot()
        try project.write("README.md", "notes\n")

        #expect(project.report().state == .fresh)
    }

    @Test("Leaving a branch and coming back stays fresh; a commit that changes a source does not")
    func movingHeadIsComparedByContent() throws {
        let project = try Project(git: true)
        try project.recordSnapshot()
        try project.git("checkout", "-q", "-b", "elsewhere")
        try project.write("Sources/demo/B.swift", "struct B { var y = 2 }\n")
        try project.commitAll("elsewhere")

        let away = project.report()
        #expect(away.state == .stale)
        #expect(away.changedFiles == ["Sources/demo/B.swift"])

        try project.git("checkout", "-q", "-")
        let back = project.report()
        #expect(back.state == .fresh, "\(back)")
        #expect(back.basis == .snapshot)
    }

    @Test("A changed Package.resolved is its own reason, not a changed source")
    func changedResolvedIsItsOwnReason() throws {
        let project = try Project(git: true)
        try project.write("Package.resolved", "{ \"pins\": [] }\n")
        try project.commitAll("pins")
        try project.recordSnapshot()
        try project.write("Package.resolved", "{ \"pins\": [ { \"identity\": \"x\" } ] }\n")

        let report = project.report()
        #expect(report.state == .stale)
        #expect(report.changedFiles.isEmpty)
        #expect(report.changedManifests == ["Package.resolved"])
        #expect(report.reasons() == ["Package.resolved changed since the index was built"])
    }

    @Test("A different toolchain is its own reason")
    func differentToolchainIsItsOwnReason() throws {
        let project = try Project(git: true)
        let recorded = ToolchainIdentity(version: "Swift 6.3", executable: "/old/swift-frontend", size: 1, modified: 1)
        let snapshot = try #require(IndexSnapshot.afterBuild(
            store: project.store.path, projectRoot: project.root.path,
            sources: IndexSnapshot.sources(ofProject: project.root.path).get(), exitStatus: 0, testsBuilt: true,
            buildLog: "", toolchain: recorded))
        try snapshot.save(home: project.home)

        let same = project.report { recorded }
        #expect(same.state == .fresh)
        let other = project.report { ToolchainIdentity(version: "Swift 6.4", executable: "/new/swift-frontend", size: 2, modified: 2) }
        #expect(other.state == .stale)
        #expect(other.changedFiles.isEmpty)
        #expect(other.toolchain == IndexSnapshot.ToolchainChange(recorded: "Swift 6.3", current: "Swift 6.4"))
    }

    @Test("An index from a failed build is stale and says so; one without tests says that")
    func buildRecordIsReported() throws {
        let project = try Project(git: true)
        let log = "error: \(project.root.path)/Sources/demo/B.swift:1:3 expected declaration\n"
        try project.recordSnapshot(exitStatus: 1, testsBuilt: false, log: log)

        let report = project.report()
        #expect(report.state == .stale)
        #expect(report.failedBuildStatus == 1)
        #expect(report.filesWithErrors == ["Sources/demo/B.swift"])
        #expect(report.testsSkipped)
        #expect(report.reasons().contains { $0.contains("failed with code 1") && $0.contains("Sources/demo/B.swift") })
    }

    // MARK: - git failing

    /// The installed git, except that `git status` fails — as it does under lock contention.
    private static let statusFails = SourceSnapshot.GitRunner { arguments in
        arguments.contains("status") ? nil : SourceSnapshot.GitRunner.system.run(arguments)
    }

    @Test("A failed `git status` at query time falls back to build time and says why, rather than reading as no change")
    func failedStatusAtQueryTimeFallsBack() throws {
        let project = try Project(git: true)
        try project.write("Sources/demo/A.swift", "struct A { let dirty = true }\n")
        try project.recordSnapshot()

        let comparison = try #require({ () -> SourceSnapshot.Comparison? in
            guard case .trusted(let snapshot) = IndexSnapshot.lookup(forStore: project.store.path,
                                                                     projectRoot: project.root.path, home: project.home)
            else { return nil }
            return snapshot.sources.changes(projectRoot: project.root, git: Self.statusFails)
        }())
        guard case .incomparable(let reason) = comparison else {
            Issue.record("a failed `git status` was read as a comparison: \(comparison)")
            return
        }
        #expect(reason.contains("git status"))

        let report = project.report(git: Self.statusFails)
        #expect(report.basis == .buildTime)
        #expect(report.snapshotProblem?.contains("git status") == true)
    }

    @Test("A failed `git status` while indexing records no snapshot instead of an empty dirty set")
    func failedStatusAtCaptureRecordsNothing() throws {
        let project = try Project(git: true)
        try project.write("Sources/demo/A.swift", "struct A { let dirty = true }\n")
        guard case .failure(let failure) = IndexSnapshot.sources(ofProject: project.root.path, git: Self.statusFails) else {
            Issue.record("a failed `git status` produced a snapshot")
            return
        }
        #expect(failure.reason.contains("git status"))
    }

    /// `git status` refreshes the index file when its stat cache is out of date — a write into the
    /// user's repository made by a freshness check. Every git command here runs without optional locks.
    @Test("A freshness check does not write the repository's index file")
    func freshnessCheckDoesNotWriteTheIndex() throws {
        let project = try Project(git: true)
        try project.recordSnapshot()
        try project.touch("Sources/demo/A.swift")
        let index = project.root.appendingPathComponent(".git/index").path
        let past = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: index)

        #expect(project.report().state == .fresh)
        _ = IndexSnapshot.sources(ofProject: project.root.path)
        let after = try #require(try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date)
        #expect(abs(after.timeIntervalSince(past)) < 1, "the index file was rewritten at \(after)")
    }

    // MARK: - fallback

    @Test("A store rewritten after the snapshot falls back to build time")
    func fingerprintMismatchFallsBack() throws {
        let project = try Project(git: true)
        try project.recordSnapshot()
        try "unit".write(to: project.store.appendingPathComponent("v5/units/B.swift.o-2"), atomically: true, encoding: .utf8)

        let report = project.report()
        #expect(report.basis == .buildTime)
        #expect(report.snapshotProblem?.contains("rewritten") == true)
        #expect(report.basisDescription == "compared by build time")
    }

    /// The per-query check reads the units timestamp only; the recorded count and names hash are
    /// a record, not something recomputed by listing every unit on every query.
    @Test("Trust rests on the units timestamp, not on re-listing the units")
    func trustRestsOnTheUnitsTimestamp() throws {
        let project = try Project(git: true)
        try project.recordSnapshot()
        let url = IndexSnapshot.location(forStore: project.store.path, home: project.home)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var store = try #require(object["store"] as? [String: Any])
        store["unitNamesHash"] = "not-the-names"
        store["unitCount"] = 999
        object["store"] = store
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        #expect(project.report().basis == .snapshot)
    }

    @Test("No snapshot falls back to build time")
    func noSnapshotFallsBack() throws {
        let project = try Project(git: true)
        let report = project.report()
        #expect(report.basis == .buildTime)
        #expect(report.snapshotProblem == nil)
        #expect(report.state != .unknown)
    }

    @Test("A snapshot in another format is not trusted")
    func otherFormatFallsBack() throws {
        let project = try Project(git: true)
        let url = IndexSnapshot.location(forStore: project.store.path, home: project.home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"format": 0}"#.write(to: url, atomically: true, encoding: .utf8)

        let report = project.report()
        #expect(report.basis == .buildTime)
        #expect(report.snapshotProblem?.contains("another version") == true)
    }

    // MARK: - outside git

    @Test("Outside git: a touch stays fresh; an edit, a new file and a deletion are changes")
    func outsideGit() throws {
        let project = try Project(git: false)
        try project.recordSnapshot()
        let snapshot = try #require({ () -> IndexSnapshot? in
            if case .trusted(let snapshot) = IndexSnapshot.lookup(forStore: project.store.path, projectRoot: project.root.path,
                                                                  home: project.home) { return snapshot }
            return nil
        }())
        #expect(snapshot.sources.git == nil)
        #expect(Set(snapshot.sources.files.keys) == ["Sources/demo/A.swift", "Sources/demo/B.swift", "Sources/demo/c.m"])

        try project.touch("Sources/demo/A.swift")
        #expect(project.report().state == .fresh)
        #expect(project.report().basis == .snapshot)

        try project.write("Sources/demo/A.swift", "struct A { var z = 0 }\n")
        try project.write("Sources/demo/D.swift", "struct D {}\n")
        try project.remove("Sources/demo/B.swift")
        let report = project.report()
        #expect(report.state == .stale)
        #expect(report.changedFiles == ["Sources/demo/A.swift", "Sources/demo/B.swift", "Sources/demo/D.swift"])
    }

    // MARK: - parsing

    @Test("Files with errors are read from either build system's log, inside the project only")
    func filesWithErrorsFromBothLogFormats() {
        let root = URL(fileURLWithPath: "/work/pkg")
        let log = """
            /work/pkg/Sources/A.swift:3:7: error: cannot find 'x' in scope
            error: /work/pkg/Sources/b.m:10:2 expected ';'
            /elsewhere/C.swift:1:1: error: outside the project
            /work/pkg/Sources/D.swift:4:1: warning: not an error
            error: Build failed
            """
        #expect(BuildRecord.filesWithErrors(inBuildLog: log, projectRoot: root) == ["Sources/A.swift", "Sources/b.m"])
    }

    @Test("The snapshot lives in the cache directory, never in the project")
    func locationIsInTheCache() {
        let url = IndexSnapshot.location(forStore: "/work/pkg/.build/sextant-index/out/Products/Debug/index/store",
                                         home: URL(fileURLWithPath: "/Users/x"))
        #expect(url.path.hasPrefix("/Users/x/Library/Caches/sextant/index-snapshot/"))
        #expect(url.pathExtension == "json")
    }
}

/// `sextant index` and a query through the real binary, on a temporary package in a home of its
/// own: the snapshot is recorded, and the label follows the content of the sources.
@Suite("Index snapshot through the binary", .serialized)
struct IndexSnapshotRunTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var binary: URL? { BuildProducts.sextantBinary(under: packageRoot) }

    private func run(_ arguments: [String], home: URL) throws -> (code: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
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
        return (process.terminationStatus, collected[0], collected[1])
    }

    @Test("index, then fresh; an edit is stale and named; a touch alone is fresh",
          .enabled(if: binary != nil, "sextant is not built — run `swift build` first"), .timeLimit(.minutes(5)))
    func labelFollowsContent() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-snapshot-run-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("package")
        let home = base.appendingPathComponent("home")
        defer { try? FileManager.default.removeItem(at: base) }
        let files = [
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"snap\", targets: [.target(name: \"snap\")])\n",
            "Sources/snap/Kept.swift": "public struct Kept {\n    public init() {}\n    public func work() {}\n}\n",
            "Sources/snap/Use.swift": "public func use() { Kept().work() }\n",
        ]
        for (path, contents) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let index = try run(["index", "--project", root.path], home: home)
        try #require(index.code == 0, "\(index.output)\n\(index.errors)")
        let snapshots = try FileManager.default.contentsOfDirectory(
            atPath: home.appendingPathComponent("Library/Caches/sextant/index-snapshot").path)
        #expect(snapshots.count == 1)

        let fresh = try run(["refs", "Kept", "--project", root.path], home: home)
        #expect(fresh.errors.contains("fresh (compared against the snapshot taken by `sextant index`)"), "\(fresh.errors)")

        let use = root.appendingPathComponent("Sources/snap/Use.swift")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: use.path)
        let touched = try run(["refs", "Kept", "--project", root.path], home: home)
        #expect(touched.errors.contains("fresh (compared against the snapshot"), "\(touched.errors)")

        try "public func use() { Kept().work(); Kept().work() }\n".write(to: use, atomically: true, encoding: .utf8)
        let edited = try run(["refs", "Kept", "--project", root.path], home: home)
        #expect(edited.errors.contains("STALE — 1 file(s) changed since the index was built: Sources/snap/Use.swift"),
                "\(edited.errors)")

        try files["Sources/snap/Use.swift"]!.write(to: use, atomically: true, encoding: .utf8)
        let restored = try run(["refs", "Kept", "--project", root.path], home: home)
        #expect(restored.errors.contains("fresh (compared against the snapshot"), "\(restored.errors)")
    }
}
