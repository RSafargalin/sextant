import Foundation

/// Symbol-level diff for Objective-C, C and C++.
///
/// A revision exists as text, not as a build, so its flags are unknowable. What is knowable is
/// how the file is compiled **now**, and that turns out to be enough: parsing the text of an
/// older revision with the current file's flags gives a complete tree (measured on the fixture:
/// no errors, the declaration list exact). It is the same trick the structural search uses — the
/// text comes from memory, the flags from the build.
///
/// The two ways this can fail are both reported rather than answered around: a file with no
/// compile flags at all (never built, or added since the last build), and one whose text does not
/// parse cleanly, where a diff would be computed from a broken tree.
public enum CFamilyDiff {
    public struct Outcome: Sendable {
        public let files: [(file: String, result: DeclarationDiff.Result)]
        public let notDiffed: [UnscannedFile]
        /// Files compared only in part: code under a preprocessor branch the build does not
        /// compile changed, and clang — which sees only the active branches — could not compare it.
        public let partiallyDiffed: [UnscannedFile]
    }

    /// `files` are paths relative to the repository root, as git reports them; `renamedFrom` maps
    /// a renamed file to its previous path, where its old text is read. `commands` are the compile
    /// flags to parse with; by default the project's captured database.
    public static func changes(files: [String], topLevel: String, projectRoot: String,
                               from: String, to: String?, renamedFrom: [String: String] = [:],
                               commands: [CompileCommand]? = nil) -> Outcome {
        guard !files.isEmpty else { return Outcome(files: [], notDiffed: [], partiallyDiffed: []) }

        var commandByFile: [String: CompileCommand] = [:]
        for command in commands ?? CompilationDatabase.commands(forFilesUnder: projectRoot) {
            commandByFile[URL(fileURLWithPath: command.file).resolvingSymlinksInPath().path] = command
        }
        guard !commandByFile.isEmpty else {
            return Outcome(files: [], notDiffed: files.map {
                UnscannedFile(file: $0, reason: "no compile flags — build the index: `sextant index`")
            }, partiallyDiffed: [])
        }
        guard let library = try? ClangLibrary.shared() else {
            return Outcome(files: [], notDiffed: files.map {
                UnscannedFile(file: $0, reason: "libclang is unavailable — install an Xcode toolchain")
            }, partiallyDiffed: [])
        }

        var diffed: [(file: String, result: DeclarationDiff.Result)] = []
        var notDiffed: [UnscannedFile] = []
        var partial: [UnscannedFile] = []
        for relative in files {
            let absolute = URL(fileURLWithPath: "\(topLevel)/\(relative)").resolvingSymlinksInPath().path
            guard let command = commandByFile[absolute] else {
                notDiffed.append(UnscannedFile(file: relative,
                                               reason: "no compile flags — build the index: `sextant index`"))
                continue
            }
            let arguments = CompilationDatabase.parseArguments(of: command)

            // A file missing at a revision was added or removed; an empty side is the right answer
            // there, not a failure. A renamed one is read at its previous path, so a pure move
            // changes no symbol.
            let previous = renamedFrom[relative] ?? relative
            let label = previous == relative ? relative : "\(relative) (renamed from \(previous))"
            let oldSource = SwiftSources.fileContent(root: topLevel, revision: from, relativePath: previous) ?? ""
            let newSource = to.map { SwiftSources.fileContent(root: topLevel, revision: $0, relativePath: relative) ?? "" }
                ?? (try? String(contentsOfFile: "\(topLevel)/\(relative)", encoding: .utf8)) ?? ""

            do {
                let comparison = try compare(old: oldSource, new: newSource, file: command.file,
                                             arguments: arguments, library: library, from: from)
                if !comparison.result.isEmpty { diffed.append((label, comparison.result)) }
                if let unanalysed = comparison.unanalysed { partial.append(UnscannedFile(file: label, reason: unanalysed)) }
            } catch {
                notDiffed.append(UnscannedFile(file: label, reason: "\(error)"))
            }
        }
        return Outcome(files: diffed, notDiffed: notDiffed, partiallyDiffed: partial)
    }

    /// The declaration diff of two texts of one file, and — when code under an inactive
    /// preprocessor branch differs between them — which lines of it went uncompared.
    static func compare(old oldSource: String, new newSource: String, file: String, arguments: [String],
                        library: ClangLibrary, from: String) throws
        -> (result: DeclarationDiff.Result, unanalysed: String?) {
        let old = try parse(oldSource, file: file, arguments: arguments, library: library)
        let new = try parse(newSource, file: file, arguments: arguments, library: library)
        let result = DeclarationDiff.compare(old: old.declarations, new: new.declarations)

        // The preprocessor drops inactive branches before clang builds the tree, so a declaration
        // there changes invisibly. Comparing the skipped text itself is what tells whether the
        // diff above is the whole answer.
        let oldSkipped = old.skipped.map(\.text), newSkipped = new.skipped.map(\.text)
        let changedNew = new.skipped.filter { !oldSkipped.contains($0.text) }
        let changedOld = old.skipped.filter { !newSkipped.contains($0.text) }
        let lines: String
        if !changedNew.isEmpty {
            lines = lineList(changedNew.map(\.lines))
        } else if !changedOld.isEmpty {
            lines = lineList(changedOld.map(\.lines)) + " at \(from)"
        } else {
            return (result, nil)
        }
        return (result, "\(lines) under an inactive #if branch changed, and were not compared — "
                       + "not part of the build the flags describe")
    }

    private static func lineList(_ ranges: [ClosedRange<Int>]) -> String {
        let spelled = ranges.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }
        return (ranges.count == 1 && ranges[0].count == 1 ? "line " : "lines ") + spelled.joined(separator: ", ")
    }

    private enum Failure: Error, CustomStringConvertible {
        case didNotParse(String)
        var description: String {
            switch self {
            case .didNotParse(let reason): return "this revision of the file does not parse: \(reason)"
            }
        }
    }

    /// A region the preprocessor skipped: its text with whitespace collapsed, and its lines.
    private struct SkippedRegion {
        let text: String
        let lines: ClosedRange<Int>
    }

    /// Declarations of one revision's text, parsed with the flags the file is built with today,
    /// and the regions of it the preprocessor skipped.
    private static func parse(_ source: String, file: String, arguments: [String],
                              library: ClangLibrary) throws -> (declarations: [Declaration], skipped: [SkippedRegion]) {
        guard !source.isEmpty else { return ([], []) }
        let unit = try ClangTranslationUnit.parse(file: file, arguments: arguments, library: library, overlay: source)
        // A tree built from errors would produce a diff nobody can trust — say so instead.
        guard unit.isComplete else {
            throw Failure.didNotParse(unit.errors.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        let bytes = Data(source.utf8)
        let skipped = unit.skippedRanges.compactMap { range -> SkippedRegion? in
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
            let text = String(decoding: bytes[range], as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let first = bytes[..<range.lowerBound].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
            let last = first + bytes[range].reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            return SkippedRegion(text: text, lines: first...last)
        }
        return (ClangDeclarations.declarations(of: unit.root.children, source: bytes,
                                               publicOnly: false, access: .internal), skipped)
    }
}
