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
    }

    /// `files` are paths relative to the repository root, as git reports them.
    public static func changes(files: [String], topLevel: String, projectRoot: String,
                               from: String, to: String?) -> Outcome {
        guard !files.isEmpty else { return Outcome(files: [], notDiffed: []) }

        var commandByFile: [String: CompileCommand] = [:]
        for command in CompilationDatabase.load(forRoot: projectRoot) {
            commandByFile[URL(fileURLWithPath: command.file).resolvingSymlinksInPath().path] = command
        }
        guard !commandByFile.isEmpty else {
            return Outcome(files: [], notDiffed: files.map {
                UnscannedFile(file: $0, reason: "no compile flags — build the index: `sextant index`")
            })
        }
        guard let library = try? ClangLibrary.shared() else {
            return Outcome(files: [], notDiffed: files.map {
                UnscannedFile(file: $0, reason: "libclang is unavailable — install an Xcode toolchain")
            })
        }

        var diffed: [(file: String, result: DeclarationDiff.Result)] = []
        var notDiffed: [UnscannedFile] = []
        for relative in files {
            let absolute = URL(fileURLWithPath: "\(topLevel)/\(relative)").resolvingSymlinksInPath().path
            guard let command = commandByFile[absolute] else {
                notDiffed.append(UnscannedFile(file: relative,
                                               reason: "no compile flags — build the index: `sextant index`"))
                continue
            }
            let arguments = CompilationDatabase.parseArguments(of: command)

            // A file missing at a revision was added or removed; an empty side is the right answer
            // there, not a failure.
            let oldSource = SwiftSources.fileContent(root: topLevel, revision: from, relativePath: relative) ?? ""
            let newSource = to.map { SwiftSources.fileContent(root: topLevel, revision: $0, relativePath: relative) ?? "" }
                ?? (try? String(contentsOfFile: "\(topLevel)/\(relative)", encoding: .utf8)) ?? ""

            do {
                let old = try declarations(of: oldSource, file: command.file, arguments: arguments, library: library)
                let new = try declarations(of: newSource, file: command.file, arguments: arguments, library: library)
                let result = DeclarationDiff.compare(old: old, new: new)
                if !result.isEmpty { diffed.append((relative, result)) }
            } catch {
                notDiffed.append(UnscannedFile(file: relative, reason: "\(error)"))
            }
        }
        return Outcome(files: diffed, notDiffed: notDiffed)
    }

    private enum Failure: Error, CustomStringConvertible {
        case didNotParse(String)
        var description: String {
            switch self {
            case .didNotParse(let reason): return "this revision of the file does not parse: \(reason)"
            }
        }
    }

    /// Declarations of one revision's text, parsed with the flags the file is built with today.
    private static func declarations(of source: String, file: String, arguments: [String],
                                     library: ClangLibrary) throws -> [Declaration] {
        guard !source.isEmpty else { return [] }
        let unit = try ClangTranslationUnit.parse(file: file, arguments: arguments, library: library, overlay: source)
        // A tree built from errors would produce a diff nobody can trust — say so instead.
        guard unit.isComplete else {
            throw Failure.didNotParse(unit.errors.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return ClangDeclarations.declarations(of: unit.root.children, source: Data(source.utf8),
                                              publicOnly: false, access: .internal)
    }
}
