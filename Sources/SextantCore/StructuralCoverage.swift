import Foundation

/// What the structural layer does not read.
///
/// Its engine is SwiftSyntax, so `search` and `lint` see `.swift` files only. Left unsaid, that
/// turns into a confident wrong answer: on a project with Objective-C sources both commands
/// report "no matches" and "no violations" for files they never opened. Every structural surface
/// names the files it skipped, in one shared form so the CLI and MCP cannot drift apart.
public enum StructuralCoverage {
    /// Non-Swift sources under the root, as paths relative to it.
    public static func unscannedFiles(projectRoot: String, includeTests: Bool) -> [String] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        return SwiftSources.files(under: root, includeTests: includeTests, extensions: IndexDeclarations.clangExtensions)
            .map { SwiftSources.relativePath(of: $0, root: root) }
            .sorted()
    }

    /// Report lines naming what was skipped; empty when the project is Swift only.
    public static func report(_ files: [String], limit: Int = 10) -> [String] {
        guard !files.isEmpty else { return [] }
        var lines = ["⚠ not scanned (\(files.count)) — the structural engine reads Swift only; Objective-C, C and C++ are skipped:"]
        lines += files.prefix(limit).map { "  \($0)" }
        if files.count > limit { lines.append("  … and \(files.count - limit) more") }
        return lines
    }
}
