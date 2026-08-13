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
    /// Files the user's own exclusions removed from the walk. Without this, an answer emptied by
    /// an exclusion is indistinguishable from an answer that found nothing.
    public static func exclusionNote() -> [String] {
        guard let effect = SwiftSources.exclusionsInEffect() else { return [] }
        return ["ℹ at least \(effect.removed) file(s) excluded by: \(effect.patterns.joined(separator: ", ")) — "
                + "the answer does not cover them."]
    }

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

    /// What the C-family answer covers: the configuration those files were built in.
    ///
    /// clang runs the preprocessor, so a branch that is inactive for the built platform is not in
    /// the tree and cannot be matched — on SDWebImage a search found 15 of the 28 occurrences grep
    /// sees, the other 13 sitting inside `#if SD_UIKIT` on a macOS build. Without this line the
    /// answer looks like it covered the file whole.
    public static func configurationNote(targets: Set<String>) -> [String] {
        guard !targets.isEmpty else { return [] }
        return ["ℹ Objective-C, C and C++ were read as built for \(targets.sorted().joined(separator: ", "))"
                + " — code in inactive #if branches is not part of that build and is not searched."]
    }

    /// Occurrences found only textually, in code the build did not contain. Reported apart from
    /// the matches and labelled, so the two confidence levels are never added into one number.
    public static func inactiveReport(_ hits: [StructuralHit], targets: Set<String>, limit: Int = 10,
                                      noun: String = "more textual occurrence(s)") -> [String] {
        guard !hits.isEmpty else { return [] }
        let configuration = targets.isEmpty ? "this build" : targets.sorted().joined(separator: ", ")
        var lines = ["⚠ \(hits.count) \(noun) inside #if branches not built for \(configuration)"
                     + " — found by text, NOT structurally verified:"]
        lines += hits.prefix(limit).map { "  \($0.file):\($0.line): \($0.text)" }
        if hits.count > limit { lines.append("  … and \(hits.count - limit) more") }
        return lines
    }

    /// Reasons in order of first appearance, so the output is stable rather than hash-ordered.
    private static func orderedReasons(of files: [UnscannedFile]) -> [String] {
        var seen = Set<String>()
        return files.map { $0.reason }.filter { seen.insert($0).inserted }
    }
}
