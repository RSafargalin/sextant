import Foundation
import Testing

/// The file limit and the surface budget. Both exist because four commands are minutes of work on
/// a large project — measured on a 12 351-file one: `search` 335s, `api` 139s and 3.75 MB, `lint`
/// over six minutes. What is pinned here is not the numbers but the shape of the answer: a bounded
/// walk answers, and says what it did not read. A refusal (the old behaviour) answered a question
/// about the first four thousand files with nothing at all.
@Suite("Scale: a bounded answer, not a refusal", .serialized)
struct ScaleDegradationTests {

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

    private struct Output { let stdout: String, stderr: String, code: Int32; var all: String { stdout + stderr } }

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
        return Output(stdout: stdout, stderr: stderr, code: process.terminationStatus)
    }

    /// Twelve files, each with a distinct type and a `print` to find.
    private func makePackage(name: String, count: Int = 12) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-scale-\(name)-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources/\(name)")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
                                  targets: [.target(name: "\(name)")])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for index in 1...count {
            let padded = String(format: "%02d", index)
            try "public struct Type\(padded) { public func run() { print(\(index)) } }\n"
                .write(to: sources.appendingPathComponent("file\(padded).swift"), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("search answers within the limit and names what it did not read")
    func searchDegradesInsteadOfRefusing() throws {
        let package = try makePackage(name: "sea")
        defer { try? FileManager.default.removeItem(at: package) }

        // The walk counts every Swift file, `Package.swift` included, and it sorts first — so a
        // limit of four reads the manifest and three sources. The note is about the walk, which is
        // what the limit bounds; the answer below it is whatever those files held.
        let bounded = try sextant(["search", "print($$$)", "--project", package.path, "--max-files", "4"])
        #expect(bounded.code == 0, "a bounded walk is an answer, not a failure")
        #expect(bounded.stdout.contains("total: 3"))
        #expect(bounded.all.contains("covered 4 of 13"))
        #expect(bounded.all.contains("--max-files"))

        // And the same command with room for everything says nothing about limits.
        let full = try sextant(["search", "print($$$)", "--project", package.path])
        #expect(full.stdout.contains("total: 12"))
        #expect(!full.all.contains("covered"))
    }

    /// The prefix has to be the same prefix every time, or two runs cover different halves of the
    /// project and both call themselves "4 of 12".
    @Test("the bounded walk covers the same files on every run")
    func boundedWalkIsReproducible() throws {
        let package = try makePackage(name: "rep")
        defer { try? FileManager.default.removeItem(at: package) }

        let first = try sextant(["search", "print($$$)", "--project", package.path, "--max-files", "5"])
        let second = try sextant(["search", "print($$$)", "--project", package.path, "--max-files", "5"])
        let files: (String) -> [String] = { output in
            output.split(separator: "\n").filter { $0.contains(".swift:") }.map(String.init).sorted()
        }
        #expect(files(first.stdout) == files(second.stdout))
        #expect(files(first.stdout).count == 4)   // five walked, the manifest holds no matches
    }

    @Test("map and lint answer under the limit too")
    func mapAndLintDegrade() throws {
        let package = try makePackage(name: "ml")
        defer { try? FileManager.default.removeItem(at: package) }

        let map = try sextant(["map", "--project", package.path, "--max-files", "3"])
        #expect(map.code == 0)
        #expect(map.stdout.contains("files: 2"))   // the manifest is walked and then left out of the map
        #expect(map.all.contains("covered 3 of 13"))

        let lint = try sextant(["lint", "--project", package.path, "--max-files", "3"])
        #expect(lint.all.contains("covered 3 of 13"))
    }

    /// `api` is a contract, so it is not cut unless asked. When it is, the header says by how much.
    @Test("api is unbounded by default and states its truncation when a budget is given")
    func apiBudgetIsExplicit() throws {
        let package = try makePackage(name: "sur", count: 40)
        defer { try? FileManager.default.removeItem(at: package) }

        let full = try sextant(["api", "--project", package.path])
        #expect(full.stdout.contains("Type40"), "no budget: the whole surface")
        #expect(!full.stdout.contains("truncated"))

        let bounded = try sextant(["api", "--project", package.path, "--budget", "200"])
        #expect(bounded.stdout.contains("⚠ truncated"))
        #expect(bounded.stdout.contains("left out by --budget"))
        #expect(bounded.stdout.count < full.stdout.count)
        // The count in the header is of the whole surface, not of the part that fit.
        #expect(bounded.stdout.contains("declaration(s) left out"))
    }
}
