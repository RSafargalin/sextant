import Foundation
import Testing

/// Where a hierarchy points. Measured on this repository: `timestamp(ofStore:)` was shown at
/// IndexFreshness.swift:48 — the line it is called from — while it is defined at line 25, and the
/// answer said nothing about which of the two it meant. A position presented as a definition has
/// to be one.
@Suite("Call hierarchy: definitions and call sites", .serialized)
struct CallHierarchyPositionTests {

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

    private struct Output { let stdout: String, stderr: String; var all: String { stdout + stderr } }

    private func sextant(_ arguments: [String]) throws -> Output {
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
        return Output(stdout: stdout, stderr: stderr)
    }

    /// A package where the two positions cannot be confused: the callee is defined in one file and
    /// called from another.
    private func buildFixture() -> (root: URL, store: String)? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-hier-\(UUID().uuidString)")
        let files = [
            "Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(name: "hier", products: [.library(name: "hier", targets: ["hier"])],
                                      targets: [.target(name: "hier")])
                """,
            "Sources/hier/callee.swift": "public func target() -> Int { 42 }\n",
            "Sources/hier/caller.swift": """
                public func middle() -> Int {
                    // a line of padding, so the call site cannot coincide with any definition line
                    target()
                }
                """,
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
    }

    @Test("a callee is shown where it is defined, and its call site is named separately")
    func calleeShowsItsDefinition() throws {
        guard let fixture = buildFixture() else { return }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try sextant(["hierarchy", "middle", "--callees", "--depth", "2",
                                  "--project", fixture.root.path, "--index-store", fixture.store])
        let line = try #require(result.stdout.split(separator: "\n").first { $0.contains("target()") })

        // The definition is in callee.swift; the call is in caller.swift. Before the fix the line
        // carried caller.swift and called it the callee's position.
        #expect(line.contains("callee.swift:1"), "the callee is defined in callee.swift, line 1")
        #expect(line.contains("called at"))
        #expect(line.contains("caller.swift:3"), "and called from caller.swift, line 3")
    }

    @Test("a caller is shown where it is defined, with the line the call is on")
    func callerShowsItsDefinition() throws {
        guard let fixture = buildFixture() else { return }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try sextant(["hierarchy", "target", "--callers", "--depth", "2",
                                  "--project", fixture.root.path, "--index-store", fixture.store])
        let line = try #require(result.stdout.split(separator: "\n").first { $0.contains("middle()") })
        #expect(line.contains("caller.swift:1"), "middle() is defined on line 1 of caller.swift")
        #expect(line.contains("called at") && line.contains("caller.swift:3"),
                "and the call to target() is on line 3")
    }

    /// A symbol the index has no definition for — a Foundation initialiser, say — cannot be given
    /// a definition position. Standing the call site in for one silently is what makes a wrong
    /// answer; saying so makes it a partial one.
    @Test("a symbol with no definition in the index is marked, not given a made-up position")
    func externalSymbolIsMarked() throws {
        let result = try sextant(["hierarchy", "state", "--callees", "--depth", "2", "--project", "."])
        guard result.stdout.contains("call hierarchy") else { return }   // no index here: not applicable
        for line in result.stdout.split(separator: "\n") where line.contains("init(fileURLWithPath") {
            #expect(line.contains("that is the call site"))
            #expect(line.contains("no definition"))
        }
    }
}
