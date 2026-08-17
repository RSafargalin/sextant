import Foundation
import Testing

/// The snippet `hook --install` prints is meant to be pasted into `settings.json` as it stands, so
/// the binary it names has to exist. It used to be built from `argv[0]`, which is the bare name
/// `sextant` when the tool is launched through `PATH` — resolved against the current directory,
/// that produced `/Users/…/tea/sextant hook` for a run inside another project. A hook naming a
/// missing binary records nothing while looking installed, which is how the adoption signal stayed
/// empty for ten days while the roadmap said it was recording.
///
/// The existing unit test could not catch this: it checks the snippet builder, and the builder was
/// given the wrong path by its caller.
@Suite("Hook installation snippet")
struct HookInstallationTests {

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

    /// Runs `hook --install` with the working directory somewhere else entirely, which is what
    /// exposed the defect: the answer must not depend on where the command was run.
    private func snippetCommand(runIn directory: URL) throws -> String {
        let binary = try #require(Self.binary, "sextant is not built — run `swift build` first")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["hook", "--install"]
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        let line = try #require(text.split(separator: "\n").first { $0.contains("\"command\"") },
                                "the snippet must carry a command")
        let parts = line.split(separator: "\"").map(String.init)
        return try #require(parts.last { $0.contains("sextant") }, "the command must name the binary")
    }

    @Test("the command names a binary that exists, wherever the command was run")
    func snippetNamesAnExistingBinary() throws {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-hook-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let command = try snippetCommand(runIn: elsewhere)
        let path = String(command.dropLast(" hook".count))
        #expect(command.hasSuffix(" hook"))
        #expect(FileManager.default.isExecutableFile(atPath: path),
                "the snippet names \(path), which is not an executable file")
        #expect(!path.hasPrefix(elsewhere.path), "the path must not be composed from the working directory")
    }

    /// Two runs from two different directories must name the same binary — the answer is about the
    /// tool, not about where it was invoked.
    @Test("the same binary is named from any directory")
    func snippetIsIndependentOfTheWorkingDirectory() throws {
        let first = FileManager.default.temporaryDirectory
        let second = URL(fileURLWithPath: "/")
        #expect(try snippetCommand(runIn: first) == snippetCommand(runIn: second))
    }
}
