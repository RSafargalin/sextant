import Foundation

/// What a structural command did not read.
///
/// Left unsaid, a partial scan turns into a confident wrong answer: a command that walks `.swift`
/// only reports "no matches" and "no violations" for files it never opened. Every structural
/// surface names what it skipped, in one shared form so the CLI and MCP cannot drift apart.
public enum StructuralCoverage {
    /// The reason a command that reads Swift only gives for every other file.
    public static let swiftOnlyReason = "the rules run on Swift only"

    /// Non-Swift sources under the root, with the reason they were skipped.
    public static func unscannedFiles(projectRoot: String, includeTests: Bool,
                                      reason: String = swiftOnlyReason) -> [UnscannedFile] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        return SwiftSources.files(under: root, includeTests: includeTests, extensions: IndexDeclarations.clangExtensions)
            .map { UnscannedFile(file: SwiftSources.relativePath(of: $0, root: root), reason: reason) }
            .sorted { $0.file < $1.file }
    }

    /// Report lines naming what was skipped; empty when nothing was.
    ///
    /// Files are grouped by reason: twenty files skipped for one reason are one line of
    /// explanation and twenty names, not twenty repetitions.
    public static func report(_ files: [UnscannedFile], limit: Int = 10) -> [String] {
        guard !files.isEmpty else { return [] }
        var lines: [String] = []
        for reason in orderedReasons(of: files) {
            let group = files.filter { $0.reason == reason }
            lines.append("⚠ not scanned (\(group.count)) — \(reason):")
            lines += group.prefix(limit).map { "  \($0.file)" }
            if group.count > limit { lines.append("  … and \(group.count - limit) more") }
        }
        return lines
    }

    /// Reasons in order of first appearance, so the output is stable rather than hash-ordered.
    private static func orderedReasons(of files: [UnscannedFile]) -> [String] {
        var seen = Set<String>()
        return files.map { $0.reason }.filter { seen.insert($0).inserted }
    }
}
