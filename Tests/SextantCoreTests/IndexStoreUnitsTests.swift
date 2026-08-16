import Foundation
import Testing
@testable import SextantCore

/// The units reader against a store a real build produced. Everything here is checked against the
/// files on disk rather than against itself: an ABI declared by hand (the toolchain ships no
/// headers) is exactly the kind of thing that looks plausible and returns rubbish, and a test that
/// only compared the reader to its own output would not notice.
@Suite("Index store units", .serialized)
struct IndexStoreUnitsTests {

    /// A built package, kept for the whole suite: the build is the expensive part.
    private static let fixture: (root: URL, store: String)? = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-units-\(UUID().uuidString)")
        let files = [
            "Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(name: "units", products: [.library(name: "units", targets: ["units"])],
                                      targets: [.target(name: "units")])
                """,
            "Sources/units/alpha.swift": "public struct Alpha {}\n",
            "Sources/units/beta.swift": "public struct Beta { public init() { _ = Alpha() } }\n",
        ]
        for (path, contents) in files {
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
            let store = buildDirectory.appendingPathComponent("\(triple)/debug/index/store").path
            if FileManager.default.fileExists(atPath: store) { return (root, store) }
        }
        return nil
    }()

    private func reader() throws -> IndexStoreUnits? {
        guard IndexStoreUnits.discoverLibrary() != nil else { return nil }   // no toolchain: not applicable
        return try IndexStoreUnits.shared()
    }

    @Test("the units name the source files the build compiled")
    func mainFilesMatchTheSources() throws {
        guard let fixture = Self.fixture, let reader = try reader() else { return }
        let mainFiles = try reader.mainFiles(inStore: fixture.store)

        // Ground truth: the files on disk, not another query to the same library.
        for name in ["alpha.swift", "beta.swift"] {
            let onDisk = fixture.root.appendingPathComponent("Sources/units/\(name)")
                .resolvingSymlinksInPath().path
            #expect(mainFiles.contains(onDisk), "the store was built from \(name) and does not name it")
        }
        // And nothing that was never compiled.
        #expect(!mainFiles.contains { $0.hasSuffix("Package.swift") })
    }

    @Test("a unit carries its target and its configuration")
    func unitsCarryBuildIdentity() throws {
        guard let fixture = Self.fixture, let reader = try reader() else { return }
        let units = try reader.units(inStore: fixture.store).filter { $0.mainFile.hasSuffix(".swift") }
        #expect(!units.isEmpty)
        for unit in units {
            #expect(!unit.target.isEmpty, "a unit with no target would make build identity unknowable")
            #expect(unit.isDebug, "the fixture is built in debug")
            // The object file is what identifies the build that wrote the unit.
            #expect(unit.outFile.contains("/debug/") || unit.outFile.contains(".build"))
        }
    }

    /// The reader's own count against the store's directory listing: a walk that quietly stops
    /// early would still return plausible data.
    @Test("every unit in the store is read")
    func allUnitsAreWalked() throws {
        guard let fixture = Self.fixture, let reader = try reader() else { return }
        let onDisk = StoreCandidate.unitCount(ofStore: fixture.store)
        #expect(try reader.units(inStore: fixture.store).count == onDisk)
    }

    /// A directory that is not a store reads as a store with nothing in it — the library accepts
    /// any path and finds no units there. So an empty unit list means "nothing to say", never
    /// "covers nothing", and a caller must not turn it into a coverage of zero. Selection already
    /// refuses a store without a `v*/units` directory before it ever gets here.
    @Test("a path that is not a store reads as empty, so emptiness is not evidence")
    func nonStoreReadsAsEmpty() throws {
        guard let reader = try reader() else { return }
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-not-a-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(try reader.units(inStore: empty.path).isEmpty)
        #expect(StoreCandidate.unitCount(ofStore: empty.path) == 0)
    }
}
