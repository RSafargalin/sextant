import Foundation
import SwiftParser

/// Declaration diff between two versions of the code at the level of SYMBOLS rather than lines:
/// what was added, removed, or changed signature. For review and for "what changed since last time".
public enum DeclarationDiff {
    public struct Result: Sendable {
        public let added: [Declaration]
        public let removed: [Declaration]
        public let changed: [(old: Declaration, new: Declaration)]

        public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    }

    public static func declarations(fromSource source: String) -> [Declaration] {
        SwiftDeclarationExtractor.declarations(tree: Parser.parse(source: source))
    }

    /// Declarations plus whether the parser had to recover. A recovery tree is missing whatever
    /// followed the broken syntax, and diffing it reports those declarations as removed — which is
    /// exactly the state an agent's half-finished edit leaves behind.
    static func parsed(_ source: String) -> (declarations: [Declaration], recovered: Bool) {
        let tree = Parser.parse(source: source)
        return (SwiftDeclarationExtractor.declarations(tree: tree), tree.hasError)
    }

    /// What a run of `changed` produced: the per-file diffs, and the changed files it could not
    /// diff at all. The second list is part of the answer, not a detail: a report of "nothing
    /// changed" means something different when three `.m` files were left out of it.
    public struct Changes {
        public let files: [(file: String, result: Result)]
        public let notDiffed: [UnscannedFile]
    }

    /// Symbol-level changes across git revisions: file → added, removed, changed signature.
    /// `to == nil` compares against the working tree. nil means not a git repository, or a bad ref.
    /// Files with no symbol-level changes (body edits, reformatting) are omitted.
    ///
    /// Swift is parsed directly; Objective-C, C and C++ are parsed by clang with the flags the
    /// file is built with today, which is the only thing a past revision's text can be read
    /// against. Whatever cannot be read that way is named in `notDiffed`.
    public static func changes(root: String, from: String, to: String?) -> Changes? {
        guard let (topLevel, swift, clang, renamedFrom) = SwiftSources.changedFiles(root: root, from: from, to: to)
        else { return nil }
        var unparsable: [UnscannedFile] = []
        let files = swift.compactMap { relative -> (file: String, result: Result)? in
            // A file missing at a revision (added or removed) is an empty source, not an error.
            // A renamed one is read at its previous path, so a pure move changes no symbol.
            let previous = renamedFrom[relative] ?? relative
            let oldSource = SwiftSources.fileContent(root: root, revision: from, relativePath: previous) ?? ""
            let newSource = to.map { SwiftSources.fileContent(root: root, revision: $0, relativePath: relative) ?? "" }
                ?? (try? String(contentsOfFile: "\(topLevel)/\(relative)", encoding: .utf8)) ?? ""
            let oldSide = parsed(oldSource), newSide = parsed(newSource)
            guard !oldSide.recovered, !newSide.recovered else {
                unparsable.append(UnscannedFile(
                    file: relative,
                    reason: "does not parse at \(newSide.recovered ? (to ?? "the working tree") : from) — "
                          + "the parser recovers by dropping what follows, which a diff would report as removed symbols"))
                return nil
            }
            let result = compare(old: oldSide.declarations, new: newSide.declarations)
            let label = previous == relative ? relative : "\(relative) (renamed from \(previous))"
            return result.isEmpty ? nil : (label, result)
        }
        let cFamily = CFamilyDiff.changes(files: clang, topLevel: topLevel, projectRoot: root, from: from, to: to)
        return Changes(files: (files + cFamily.files).sorted { $0.file < $1.file },
                       notDiffed: cFamily.notDiffed + unparsable)
    }

    /// Matching declarations. Grouped by (kind:name); for a name UNIQUE in both versions, changed
    /// is decided by the header difference. For overloads (several with one name) and for names
    /// appearing or disappearing, header sets are used (added/removed), with no false changed.
    ///
    /// Type members are compared recursively: renaming a method inside a `struct` is the most common
    /// API change, and staying silent about it ("no symbol-level changes") would mean returning a
    /// plausible but incomplete answer. Member names are qualified by their type (`A.func b()`).
    public static func compare(old: [Declaration], new: [Declaration], qualifier: String = "") -> Result {
        func key(_ declaration: Declaration) -> String { "\(declaration.kind.rawValue):\(declaration.name)" }
        func qualified(_ declaration: Declaration) -> Declaration {
            guard !qualifier.isEmpty else { return declaration }
            return Declaration(kind: declaration.kind, header: "\(qualifier).\(declaration.header)",
                               access: declaration.access, attributes: declaration.attributes,
                               docSummary: declaration.docSummary, members: declaration.members,
                               condition: declaration.condition)
        }
        let oldByName = Dictionary(grouping: old, by: key)
        let newByName = Dictionary(grouping: new, by: key)

        var added: [Declaration] = [], removed: [Declaration] = [], changed: [(Declaration, Declaration)] = []
        for name in Set(oldByName.keys).union(newByName.keys) {
            let olds = oldByName[name] ?? [], news = newByName[name] ?? []
            if olds.count == 1, news.count == 1 {
                if olds[0].signature != news[0].signature {
                    changed.append((qualified(olds[0]), qualified(news[0])))
                } else if !olds[0].members.isEmpty || !news[0].members.isEmpty {
                    // The type header is unchanged — look inside.
                    let inner = compare(old: olds[0].members, new: news[0].members,
                                        qualifier: qualifier.isEmpty ? olds[0].name : "\(qualifier).\(olds[0].name)")
                    added += inner.added
                    removed += inner.removed
                    changed += inner.changed.map { ($0.old, $0.new) }
                }
            } else {
                let oldHeaders = Set(olds.map(\.signature)), newHeaders = Set(news.map(\.signature))
                added.append(contentsOf: news.filter { !oldHeaders.contains($0.signature) }.map(qualified))
                removed.append(contentsOf: olds.filter { !newHeaders.contains($0.signature) }.map(qualified))
            }
        }
        return Result(
            added: added.sorted { $0.name < $1.name },
            removed: removed.sorted { $0.name < $1.name },
            changed: changed.sorted { $0.1.name < $1.1.name }
        )
    }
}
