import Foundation
import Testing
@testable import SextantCore

/// Two documented install routes land in two directories, and whichever comes first in `PATH`
/// wins. A build from source shadowing a Homebrew one is the case that costs a user an hour:
/// `brew upgrade` reports success and the tool keeps answering with the old version.
@Suite("Installation check")
struct InstallationCheckTests {
    /// A PATH with `count` directories, each holding an executable named `sextant`.
    private func makePath(_ count: Int) throws -> (path: String, binaries: [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-path-\(UUID().uuidString)")
        var directories: [String] = []
        var binaries: [String] = []
        for index in 0..<count {
            let directory = root.appendingPathComponent("bin\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let binary = directory.appendingPathComponent("sextant")
            FileManager.default.createFile(atPath: binary.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
            directories.append(directory.path)
            binaries.append(binary.path)
        }
        return (directories.joined(separator: ":"), binaries)
    }

    @Test("Binaries come back in the order a shell would try them")
    func findsInPathOrder() throws {
        let (path, binaries) = try makePath(2)
        defer { try? FileManager.default.removeItem(atPath: (binaries[0] as NSString).deletingLastPathComponent) }
        #expect(InstallationCheck.binaries(inPath: path) == binaries)

        // A directory that has no sextant, and an empty entry, are simply not there.
        #expect(InstallationCheck.binaries(inPath: "/nowhere::\(path)") == binaries)
    }

    @Test("One binary is not a problem and says nothing")
    func silentWhenSingle() throws {
        let (path, _) = try makePath(1)
        let binaries = InstallationCheck.binaries(inPath: path)
        #expect(binaries.count == 1)
        #expect(InstallationCheck.report(binaries: binaries, running: binaries[0]).isEmpty)
    }

    @Test("With several, the report names which one wins and which one is speaking")
    func namesTheWinnerAndTheRunner() throws {
        let (path, binaries) = try makePath(2)
        // The interesting case: the Homebrew binary is answering while the other one wins.
        let report = InstallationCheck.report(binaries: InstallationCheck.binaries(inPath: path),
                                              running: binaries[1])
        #expect(report.first?.contains("2 sextant binaries") == true)
        #expect(report.contains { $0.contains(binaries[0]) && $0.contains("wins") })
        #expect(report.contains { $0.contains(binaries[1]) && $0.contains("this one is running") })
        #expect(report.last?.contains("`brew upgrade` cannot replace it") == true)
    }

    @Test("A symlink to the same binary is the same binary")
    func resolvesSymlinks() throws {
        let (path, binaries) = try makePath(2)
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: binaries[0])
        defer { try? FileManager.default.removeItem(at: link) }

        // Homebrew's `bin/sextant` is a symlink into `Cellar`; comparing paths as strings would
        // report the running binary as a third, unrelated one.
        let report = InstallationCheck.report(binaries: InstallationCheck.binaries(inPath: path), running: link.path)
        #expect(report.contains { $0.contains(binaries[0]) && $0.contains("this one is running") })
    }
}
