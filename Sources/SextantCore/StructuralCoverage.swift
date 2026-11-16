import Foundation

/// What a structural command did not read.
///
/// Left unsaid, a partial scan turns into a confident wrong answer: a command that walks `.swift`
/// only reports "no matches" and "no violations" for files it never opened. Every structural
/// surface names what it skipped, in one shared form so the CLI and MCP cannot drift apart.
public enum StructuralCoverage {
    /// The reason a command that reads Swift only gives for every other file.
    public static let swiftOnlyReason = "the rules run on Swift only"

    /// Why a file that could not be opened is not part of the answer.
    public static let unreadableReason = "could not be read (permissions?)"

    /// Why a Swift file that is not UTF-8 text is not part of the answer.
    public static let notUTF8Reason = "is not valid UTF-8 text, which the Swift parser cannot read"

    /// The heading for files read with reservations: through the parser's recovery from errors, or
    /// with an expression that could not be given its structure.
    public static let recoveredHeading = "read with reservations"

    /// Why the matches in such a file are not a complete answer about it.
    public static let syntaxErrorReason = "the file has syntax errors and the parser recovered from them, so a match in it may be missing or wrong"

    /// Why a directory the walk skips is not part of the answer.
    public static let skippedDirectoryReason =
        "a directory the walk skips as vendored, build output or a submodule — narrow the scope to it (--scope) to search it"

    /// A Swift file the parser could not be given, named with its reason.
    public static func unscanned(_ read: SourceParseCache.Read, file: String) -> UnscannedFile? {
        switch read {
        case .parsed: return nil
        case .unreadable: return UnscannedFile(file: file, reason: unreadableReason)
        case .notUTF8: return UnscannedFile(file: file, reason: notUTF8Reason)
        }
    }

    /// Directories under the root that the walks skipped although they hold sources, one entry each.
    /// Read after the command's walks: it reports what those walks left out.
    public static func skippedDirectories(projectRoot: String) -> [UnscannedFile] {
        SwiftSources.skippedSourceDirectories(under: URL(fileURLWithPath: projectRoot, isDirectory: true))
            .map { UnscannedFile(file: $0 + "/", reason: skippedDirectoryReason) }
    }

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
    /// What a structural command answers when the area holds no source in any language it reads —
    /// nil when it holds one. "No matches." or a clean lint over nothing would read as a finding.
    public static func nothingToRead(under root: String, includeTests: Bool) -> String? {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        guard SwiftSources.files(under: url, includeTests: includeTests,
                                 extensions: ["swift"] + IndexDeclarations.clangExtensions).isEmpty else { return nil }
        return "No source files here (Swift, Objective-C, C or C++) — nothing was read."
    }

    public static func exclusionNote() -> [String] {
        guard let effect = SwiftSources.exclusionsInEffect() else { return [] }
        return ["ℹ at least \(effect.removed) file(s) excluded by: \(effect.patterns.joined(separator: ", ")) — "
                + "the answer does not cover them."]
    }

    public static func report(_ files: [UnscannedFile], limit: Int = 10, heading: String = "not scanned") -> [String] {
        guard !files.isEmpty else { return [] }
        var lines: [String] = []
        for reason in orderedReasons(of: files) {
            let group = files.filter { $0.reason == reason }
            lines.append("⚠ \(heading) (\(group.count)) — \(reason):")
            lines += group.prefix(limit).map { "  \($0.file)" }
            if group.count > limit { lines.append("  … and \(group.count - limit) more") }
        }
        return lines
    }

    /// Report lines naming the files read with reservations; empty when there were none.
    public static func recoveredReport(_ files: [UnscannedFile], limit: Int = 10) -> [String] {
        report(files, limit: limit, heading: recoveredHeading)
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
