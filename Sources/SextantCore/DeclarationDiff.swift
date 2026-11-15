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
        /// Files compared only in part, each with the lines that were not compared.
        public let partiallyDiffed: [UnscannedFile]

        /// The lines that name the files compared only in part.
        public var partialReport: [String] {
            guard !partiallyDiffed.isEmpty else { return [] }
            return ["⚠ compared in part (\(partiallyDiffed.count)) — code the build does not compile changed:"]
                + partiallyDiffed.map { "  \($0.file): \($0.reason)" }
        }
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
        let cFamily = CFamilyDiff.changes(files: clang, topLevel: topLevel, projectRoot: root, from: from, to: to,
                                          renamedFrom: renamedFrom)
        return Changes(files: (files + cFamily.files).sorted { $0.file < $1.file },
                       notDiffed: cFamily.notDiffed + unparsable,
                       partiallyDiffed: cFamily.partiallyDiffed)
    }

    /// Matching declarations across two versions, then comparing each matched pair.
    ///
    /// Declarations are grouped by kind and name. A name unique on both sides is one declaration
    /// whatever its header says, so a different header is a change. Where a name is shared — two
    /// `extension Foo` blocks, overloads — declarations are matched in three passes: identical
    /// signatures first (among several identical ones, the pair sharing the most members, so a
    /// block inserted before another does not take its place); then callables with the same
    /// argument labels, when that pairing is unambiguous; then types by the members they share.
    /// Whatever is left is added or removed — a guess at a pairing would be a false "changed".
    ///
    /// Type members are compared recursively for every matched pair, including one whose own
    /// header changed: a type gaining a conformance does not make the methods it lost in the same
    /// edit any less removed. Member headers are qualified by their type (`A.func b()`).
    ///
    /// A case list is compared case by case, so `case a, b` rewritten as two lines is no change,
    /// and each case keeps the condition it is compiled under.
    public static func compare(old: [Declaration], new: [Declaration], qualifier: String = "") -> Result {
        func key(_ declaration: Declaration) -> String { "\(declaration.kind.rawValue):\(declaration.name)" }
        func qualified(_ declaration: Declaration) -> Declaration {
            guard !qualifier.isEmpty else { return declaration }
            return declaration.with(header: "\(qualifier).\(declaration.header)")
        }
        let old = splittingCaseLists(old), new = splittingCaseLists(new)
        let oldByName = Dictionary(grouping: old, by: key)
        let newByName = Dictionary(grouping: new, by: key)

        var added: [Declaration] = [], removed: [Declaration] = [], changed: [(Declaration, Declaration)] = []
        for name in Set(oldByName.keys).union(newByName.keys) {
            let matching = match(oldByName[name] ?? [], newByName[name] ?? [])
            added += matching.added.map(qualified)
            removed += matching.removed.map(qualified)
            for (before, after) in matching.pairs {
                if before.signature != after.signature {
                    changed.append((qualified(before), qualified(after)))
                }
                guard !before.members.isEmpty || !after.members.isEmpty else { continue }
                let inner = compare(old: before.members, new: after.members,
                                    qualifier: qualifier.isEmpty ? after.name : "\(qualifier).\(after.name)")
                added += inner.added
                removed += inner.removed
                changed += inner.changed.map { ($0.old, $0.new) }
            }
        }
        func order(_ lhs: Declaration, _ rhs: Declaration) -> Bool {
            (lhs.name, lhs.header, lhs.signature) < (rhs.name, rhs.header, rhs.signature)
        }
        // An extension that appears or disappears whole adds or removes its members: its own
        // header names only the type it extends, so its members follow it, qualified by that type.
        func expanded(_ declaration: Declaration) -> [Declaration] {
            guard declaration.kind == .extensionKind else { return [declaration] }
            return [declaration] + declaration.members.map { $0.with(header: "\(declaration.name).\($0.header)") }
        }
        return Result(
            added: added.sorted(by: order).flatMap(expanded),
            removed: removed.sorted(by: order).flatMap(expanded),
            changed: changed.sorted { order($0.1, $1.1) }
        )
    }

    /// Pairs declarations that share a kind and a name; see `compare`.
    private static func match(_ olds: [Declaration], _ news: [Declaration])
        -> (pairs: [(Declaration, Declaration)], added: [Declaration], removed: [Declaration]) {
        if olds.count == 1, news.count == 1 { return ([(olds[0], news[0])], [], []) }
        var remainingOld = Array(olds.indices), remainingNew = Array(news.indices)
        var pairs: [(Declaration, Declaration)] = []

        func take(_ oldIndex: Int, _ newIndex: Int) {
            pairs.append((olds[oldIndex], news[newIndex]))
            remainingOld.removeAll { $0 == oldIndex }
            remainingNew.removeAll { $0 == newIndex }
        }
        func sharedMembers(_ lhs: Declaration, _ rhs: Declaration) -> Int {
            Set(lhs.members.map(\.signature)).intersection(rhs.members.map(\.signature)).count
        }

        // Identical signatures.
        for oldIndex in remainingOld {
            let candidates = remainingNew.filter { news[$0].signature == olds[oldIndex].signature }
            guard let best = candidates.max(by: { first, second in
                // `max` keeps the last of equal elements; prefer the earliest.
                sharedMembers(olds[oldIndex], news[first]) < sharedMembers(olds[oldIndex], news[second])
                    || (sharedMembers(olds[oldIndex], news[first]) == sharedMembers(olds[oldIndex], news[second]) && first > second)
            }) else { continue }
            take(oldIndex, best)
        }

        // Callables with the same labels, when exactly one on each side has them.
        for oldIndex in remainingOld {
            guard let labels = argumentLabels(olds[oldIndex]) else { continue }
            let sameOld = remainingOld.filter { argumentLabels(olds[$0]) == labels }
            let sameNew = remainingNew.filter { argumentLabels(news[$0]) == labels }
            if sameOld.count == 1, sameNew.count == 1 { take(oldIndex, sameNew[0]) }
        }

        // Types by the members they share.
        for oldIndex in remainingOld where olds[oldIndex].kind.isType {
            let scored = remainingNew.map { ($0, sharedMembers(olds[oldIndex], news[$0])) }.filter { $0.1 > 0 }
            guard let best = scored.max(by: { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 > $1.0) }) else { continue }
            take(oldIndex, best.0)
        }
        return (pairs, remainingNew.map { news[$0] }, remainingOld.map { olds[$0] })
    }

    /// The argument labels of a function, initializer or subscript (`f(x:_:)` → `["x", "_"]`),
    /// read from its header; nil for any other declaration.
    static func argumentLabels(_ declaration: Declaration) -> [String]? {
        guard [.function, .initializer, .subscriptKind, .macroKind].contains(declaration.kind) else { return nil }
        let header = declaration.header
        // The parameter list is the first top-level parenthesis after the name and generics.
        guard let open = Declaration.topLevelIndex(of: "(", in: header.replacingOccurrences(of: "(set)", with: "_set_"))
        else { return nil }
        let rest = String(header[header.index(after: open)...])
        guard let close = Declaration.topLevelIndex(of: ")", in: rest) else { return nil }
        let list = String(rest[..<close])
        guard !list.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Declaration.splitTopLevel(list, separator: ",").map { parameter in
            let beforeType = Declaration.splitTopLevel(parameter, separator: ":").first ?? parameter
            return beforeType.split(separator: " ").first.map(String.init) ?? ""
        }
    }

    /// A `case a, b(x: Int)` declaration as one declaration per case, each with the attributes
    /// and condition of the line it came from. Other declarations pass through.
    static func splittingCaseLists(_ declarations: [Declaration]) -> [Declaration] {
        declarations.flatMap { declaration -> [Declaration] in
            guard declaration.kind == .caseKind, declaration.header.hasPrefix("case ") else { return [declaration] }
            let elements = Declaration.splitTopLevel(String(declaration.header.dropFirst("case ".count)), separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard elements.count > 1 else { return [declaration] }
            return elements.map { element in
                let header = "case \(element)"
                return declaration.with(header: header, name: Declaration.name(kind: .caseKind, header: header))
            }
        }
    }
}
