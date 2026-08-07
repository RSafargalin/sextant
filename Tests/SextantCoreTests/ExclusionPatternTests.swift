import Foundation
import Testing
@testable import SextantCore

/// The syntax is deliberately a small part of glob rather than a subset of gitignore: a partial
/// gitignore is unpredictable, and unpredictable exclusions hide code without the user knowing.
@Suite("Exclusion patterns")
struct ExclusionPatternTests {
    private func excluded(_ pattern: String, _ path: String) -> Bool {
        ExclusionPattern(pattern).matches(relativePath: path)
    }

    @Test("A pattern without a separator matches the name at any depth")
    func nameOnly() {
        #expect(excluded("*.pb.swift", "Sources/Api/user.pb.swift"))
        #expect(excluded("*.pb.swift", "user.pb.swift"))
        #expect(!excluded("*.pb.swift", "Sources/Api/user.swift"))
        // The name, not a fragment of the path: a directory called `Generated` is not a file.
        #expect(!excluded("Generated.swift", "Generated.swift/inner.swift"))
    }

    @Test("`**` crosses path components, `*` stays inside one")
    func wildcards() {
        #expect(excluded("Generated/**", "Generated/Api/user.swift"))
        #expect(excluded("Sources/**/Legacy/*.swift", "Sources/App/Deep/Legacy/old.swift"))
        #expect(!excluded("Sources/*/Legacy", "Sources/App/Deep/Legacy/old.swift"))   // `*` is one component
        #expect(excluded("Sources/*/Legacy", "Sources/App/Legacy/old.swift"))
    }

    @Test("A directory pattern takes the tree with it")
    func directoryTakesItsContents() {
        // `Sources/Legacy` means the folder, not one entry named exactly that.
        #expect(excluded("Sources/Legacy", "Sources/Legacy/Old.swift"))
        #expect(excluded("Sources/Legacy", "Sources/Legacy/Deep/Older.swift"))
        #expect(!excluded("Sources/Legacy", "Sources/LegacyHelpers/Old.swift"))
    }

    @Test("A path that matches nothing is kept")
    func keepsWhatDoesNotMatch() {
        let patterns = ["Generated/**", "*.pb.swift"].map(ExclusionPattern.init)
        #expect(patterns.exclude(relativePath: "Generated/x.swift"))
        #expect(patterns.exclude(relativePath: "Sources/user.pb.swift"))
        #expect(!patterns.exclude(relativePath: "Sources/Core/Session.swift"))
        #expect(![ExclusionPattern]().exclude(relativePath: "anything.swift"))
    }

    @Test("Exclusions apply the same way whether the project is under git or not")
    func sameInBothWalks() throws {
        // The filter sits after both discovery paths, so a directory that is not a repository
        // behaves like one that is — the case issue #3 is about.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-exclude-\(UUID().uuidString)")
        let generated = root.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try "struct A {}".write(to: root.appendingPathComponent("Keep.swift"), atomically: true, encoding: .utf8)
        try "struct B {}".write(to: generated.appendingPathComponent("Drop.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root); SwiftSources.setExclusions([]) }

        SwiftSources.setExclusions([])
        #expect(SwiftSources.files(under: root, includeTests: true).count == 2)

        SwiftSources.setExclusions(["Generated/**"])
        let kept = SwiftSources.files(under: root, includeTests: true)
        #expect(kept.map { $0.lastPathComponent } == ["Keep.swift"])
    }
}
