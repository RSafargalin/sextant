import Foundation

/// Text search that respects identifier boundaries.
///
/// A plain substring match makes `makeStore(` a construction of `Store`, and `ocFeedOnPhone` an
/// occurrence of `ocFeed`. Wherever this tool falls back to text — construction sites, code the
/// build skipped — it is answering a question it cannot answer structurally, and the least it
/// owes is not to invent hits.
enum WordBoundary {
    /// Whether `needle` occurs in `text` at identifier boundaries.
    ///
    /// A boundary is required on each side where the needle's own edge is part of an identifier:
    /// `ocFeed` must not match inside `ocFeedOnPhone`, while `Store(` and `[Store alloc]` end on
    /// punctuation and need no boundary after them.
    static func contains(_ needle: String, in text: some StringProtocol) -> Bool {
        guard !needle.isEmpty else { return false }
        let checkStart = isIdentifierCharacter(needle.first)
        let checkEnd = isIdentifierCharacter(needle.last)
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, range: searchRange) {
            let preceding = found.lowerBound == text.startIndex
                ? nil
                : text[text.index(before: found.lowerBound)]
            let following = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            let startsCleanly = !checkStart || !isIdentifierCharacter(preceding)
            let endsCleanly = !checkEnd || !isIdentifierCharacter(following)
            if startsCleanly && endsCleanly { return true }
            guard found.upperBound < text.endIndex else { return false }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
