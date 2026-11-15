import Darwin
import Foundation
import Testing
@testable import SextantCore

/// What the cache directory keeps and what it lets go: every namespace is bounded or pruned, and
/// nothing outside the directory is ever touched. Every test runs against a home of its own.
@Suite("Cache eviction")
struct CacheEvictionTests {
    private final class Home {
        let base: URL
        let home: URL
        let cache: URL
        /// A directory beside the home, standing for everything that is not sextant's.
        let outside: URL

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("sextant-evict-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
            home = base.appendingPathComponent("home")
            cache = CacheEviction.root(home: home)
            outside = base.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) }

        @discardableResult
        func file(_ relativePath: String, _ contents: String = "x") throws -> URL {
            let url = cache.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func exists(_ relativePath: String) -> Bool {
            FileManager.default.fileExists(atPath: cache.appendingPathComponent(relativePath).path)
        }

        func owned(_ relativePath: String, by owner: String) throws {
            let directory = cache.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            CacheEviction.recordOwner(owner, in: directory)
        }
    }

    @Test("Superseded versions of a cache go; the version in use and unknown directories stay")
    func supersededVersionsAreRemoved() throws {
        let home = try Home()
        for name in ["declarations-v3", "declarations-v4", CacheNamespace.declarations, "lint-v1", CacheNamespace.lint,
                     "search-v2", "store-coverage-v2", "drift-declarations-v1", "mine-v1", "notes"] {
            try home.file("\(name)/entry.json")
        }
        let report = CacheEviction.run(home: home.home)
        for gone in ["declarations-v3", "declarations-v4", "lint-v1", "search-v2", "store-coverage-v2", "drift-declarations-v1"] {
            #expect(!home.exists(gone), "\(gone) was kept")
        }
        for kept in [CacheNamespace.declarations, CacheNamespace.lint, "mine-v1", "notes"] {
            #expect(home.exists(kept), "\(kept) was removed")
        }
        #expect(report.removed.contains("declarations-v3"))
        #expect(report.summary?.contains("removed 6 obsolete entries") == true, "\(report.summary ?? "nil")")
    }

    @Test("A namespace in use is bounded to the cache limit, oldest entries first")
    func namespaceInUseIsBounded() throws {
        let home = try Home()
        for index in 0..<12 {
            let url = try home.file("\(CacheNamespace.search)/\(index).json")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + index))],
                                                  ofItemAtPath: url.path)
        }
        CacheEviction.run(home: home.home, cap: 10)
        let left = try FileManager.default.contentsOfDirectory(atPath: home.cache.appendingPathComponent(CacheNamespace.search).path)
        #expect(left.count == 8)
        #expect(!left.contains("0.json") && !left.contains("3.json") && left.contains("4.json"))
    }

    @Test("Entries for stores and projects that are gone are removed; live ones stay")
    func entriesOfGoneOwnersAreRemoved() throws {
        let home = try Home()
        let liveStore = home.outside.appendingPathComponent("live/index/store")
        let liveProject = home.outside.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: liveStore, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: liveProject, withIntermediateDirectories: true)
        let goneStore = home.outside.appendingPathComponent("gone/index/store").path
        let goneProject = home.outside.appendingPathComponent("gone-project").path

        try home.owned("index-db/aaaaaaaaaaaaaaaaaaaaaaaa", by: liveStore.path)
        try home.owned("index-db/bbbbbbbbbbbbbbbbbbbbbbbb", by: goneStore)
        try home.file("index-db/_Users_someone_.build_index_store/v13/saved/data.mdb")   // the earlier naming
        try home.owned("gitdir/1111111111111111.git", by: liveProject.path)
        try home.owned("gitdir/2222222222222222.git", by: goneProject)
        try home.file("gitdir/3333333333333333.git/HEAD")                                  // no owner recorded
        try home.owned("umbrella/cccccccccccccccccccccccc", by: liveProject.path)
        try home.owned("umbrella/dddddddddddddddddddddddd", by: goneProject)
        try home.file("umbrella/eeeeeeeeeeeeeeeeeeeeeeee/swift-build.log")                // no owner recorded
        // The earlier naming — the root with `/` turned into `_` — even for a project that exists.
        try home.owned("umbrella/\(liveProject.path.replacingOccurrences(of: "/", with: "_"))", by: liveProject.path)
        try home.file("umbrella/_Users_someone_old/Package.swift", ".package(path: \"\(goneProject)/A\")")
        let liveSource = liveProject.appendingPathComponent("a.c")
        try "int a;".write(to: liveSource, atomically: true, encoding: .utf8)
        try home.owned("compile-db/111111111111111111111111", by: liveProject.path)
        try home.file("compile-db/111111111111111111111111/compile_commands.json",
                      #"[{"directory":"/","file":"\#(liveSource.path)","arguments":[]}]"#)
        try home.owned("compile-db/222222222222222222222222", by: goneProject)
        try home.file("compile-db/222222222222222222222222/compile_commands.json", "[]")
        try home.owned("compile-db/333333333333333333333333", by: liveProject.path)
        try home.file("compile-db/333333333333333333333333/compile_commands.json",
                      #"[{"directory":"/","file":"\#(goneProject)/a.c","arguments":[]}]"#)
        try home.owned("compile-db/444444444444444444444444", by: liveProject.path)
        try home.file("compile-db/444444444444444444444444/compile_commands.json", "[]")
        // The earlier naming, a file per root, for a project that exists as for one that does not.
        try home.file("compile-db/\(liveProject.path.replacingOccurrences(of: "/", with: "_")).json",
                      #"[{"directory":"/","file":"\#(liveSource.path)","arguments":[]}]"#)
        try home.file("compile-db/gone.json", #"[{"directory":"/","file":"\#(goneProject)/a.c","arguments":[]}]"#)
        try home.file("index-snapshot/live.json", #"{"storePath":"\#(liveStore.path)","format":1}"#)
        try home.file("index-snapshot/gone.json", #"{"storePath":"\#(goneStore)","format":1}"#)

        CacheEviction.run(home: home.home)
        for kept in ["index-db/aaaaaaaaaaaaaaaaaaaaaaaa", "gitdir/1111111111111111.git",
                     "umbrella/cccccccccccccccccccccccc", "umbrella/eeeeeeeeeeeeeeeeeeeeeeee",
                     "compile-db/111111111111111111111111", "compile-db/444444444444444444444444",
                     "index-snapshot/live.json"] {
            #expect(home.exists(kept), "\(kept) was removed")
        }
        for gone in ["index-db/bbbbbbbbbbbbbbbbbbbbbbbb", "index-db/_Users_someone_.build_index_store",
                     "gitdir/2222222222222222.git", "gitdir/3333333333333333.git",
                     "umbrella/dddddddddddddddddddddddd", "umbrella/_Users_someone_old",
                     "umbrella/\(liveProject.path.replacingOccurrences(of: "/", with: "_"))",
                     "compile-db/222222222222222222222222", "compile-db/333333333333333333333333",
                     "compile-db/\(liveProject.path.replacingOccurrences(of: "/", with: "_")).json",
                     "compile-db/gone.json", "index-snapshot/gone.json"] {
            #expect(!home.exists(gone), "\(gone) was kept")
        }
    }

    @Test("A socket no daemon holds goes once it is old; one a daemon holds stays")
    func orphanedSocketsAreRemoved() throws {
        let home = try Home()
        let orphan = try home.file("serve/orphan.sock")
        try home.file("serve/orphan.sock.lock")
        let held = try home.file("serve/held.sock")
        let heldLock = try home.file("serve/held.sock.lock")
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        for url in [orphan, held] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        let descriptor = open(heldLock.path, O_RDWR)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

        CacheEviction.run(home: home.home)
        #expect(!home.exists("serve/orphan.sock") && !home.exists("serve/orphan.sock.lock"))
        #expect(home.exists("serve/held.sock") && home.exists("serve/held.sock.lock"))
    }

    // MARK: The path guard

    @Test("The guard admits only paths strictly inside the cache directory")
    func guardRejectsEscapes() {
        let root = URL(fileURLWithPath: "/h/Library/Caches/sextant", isDirectory: true)
        #expect(CacheEviction.isInside(root.appendingPathComponent("index-db/x"), root: root))
        #expect(!CacheEviction.isInside(root, root: root))
        #expect(!CacheEviction.isInside(URL(fileURLWithPath: "/h/Library/Caches/sextant-other/x"), root: root))
        #expect(!CacheEviction.isInside(URL(fileURLWithPath: "/h/Library/Caches/sextant/../important"), root: root))
        #expect(!CacheEviction.isInside(URL(fileURLWithPath: "/h/Library/Caches/sextant/index-db/../../x"), root: root))
        #expect(!CacheEviction.isInside(URL(fileURLWithPath: "/elsewhere"), root: root))
    }

    @Test("A link inside the cache is removed as a link; what it points at is untouched")
    func linksAreNotFollowed() throws {
        let home = try Home()
        let precious = home.outside.appendingPathComponent("precious")
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try "keep".write(to: precious.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        // A superseded namespace, an index database and a gitdir that are links to someone else's data.
        for name in ["lint-v1", "index-db/cccccccccccccccccccccccc", "gitdir/4444444444444444.git"] {
            let link = home.cache.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious)
        }
        // A namespace in use that is itself a link is not walked.
        try FileManager.default.createSymbolicLink(at: home.cache.appendingPathComponent(CacheNamespace.search),
                                                   withDestinationURL: precious)

        CacheEviction.run(home: home.home, cap: 0)
        CacheEviction.run(home: home.home, cap: 1)
        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("file.txt").path))
        #expect(!home.exists("lint-v1"))
        #expect(home.exists(CacheNamespace.search))
    }

    @Test("Nothing happens without a cache directory")
    func missingCacheIsFine() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-evict-none-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(CacheEviction.run(home: base).removed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }
}
