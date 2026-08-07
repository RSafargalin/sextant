import Foundation

/// A textual look into the code a build left out.
///
/// clang runs the preprocessor, so an `#if` branch that is false for the built configuration is
/// not in the tree and cannot be matched. Reporting only what the tree holds would answer "15
/// usages" where a reader of the sources counts 28 — and an agent about to change that API would
/// miss thirteen call sites and break another platform's build.
///
/// There is no way to answer structurally for code that was never compiled, so this answers
/// textually and says so. It is the same degradation the semantic commands make when the index
/// has nothing: a weaker answer, clearly labelled, beats a confident narrow one.
public enum InactiveRegionScan {
    /// Lines inside skipped ranges that mention every identifier the pattern spells out.
    ///
    /// With no anchors — a pattern made only of metavariables, like `$X * $X` — nothing textual
    /// can be said, and nothing is reported rather than everything.
    public static func occurrences(anchors: [String], source: Data, ranges: [Range<Int>]) -> [StructuralMatch] {
        guard !anchors.isEmpty, !ranges.isEmpty else { return [] }
        let text = String(decoding: source, as: UTF8.self)
        var results: [StructuralMatch] = []
        var line = 1
        var lineStart = text.startIndex
        var index = text.startIndex
        var offset = 0

        func report(_ lineRange: Range<String.Index>, at lineOffset: Int, line: Int) {
            let content = text[lineRange]
            guard ranges.contains(where: { $0.contains(lineOffset) }),
                  anchors.allSatisfy({ WordBoundary.contains($0, in: content) }) else { return }
            results.append(StructuralMatch(line: line, column: 1,
                                           text: content.trimmingCharacters(in: .whitespaces)))
        }

        var lineOffset = 0
        while index < text.endIndex {
            let character = text[index]
            let width = String(character).utf8.count
            if character.isNewline {
                report(lineStart..<index, at: lineOffset, line: line)
                line += 1
                index = text.index(after: index)
                offset += width
                lineStart = index
                lineOffset = offset
                continue
            }
            index = text.index(after: index)
            offset += width
        }
        if lineStart < text.endIndex { report(lineStart..<text.endIndex, at: lineOffset, line: line) }
        return results
    }
}
