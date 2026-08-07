import Foundation

/// A textual grep signal used to cross-check semantics: how often an identifier occurs on word
/// boundaries across the project's sources. Zero semantic hits with non-zero textual ones
/// means a stale index or an unresolvable symbol. It is deliberately crude — comments and string
/// literals count too — which is enough for the signal "the symbol is there, semantics are silent".
///
/// Every language the tool answers for is scanned, not just Swift: an Objective-C symbol that
/// does not resolve would otherwise fall back to a search that never opens a `.m` file, and
/// report nothing at all.
public enum IdentifierScan {
    /// Scan result. `truncated` means the walk stopped at `fileLimit` and the count is INCOMPLETE:
    /// the caller must not conclude "no such symbol" when truncated && count == 0.
    public struct Result: Sendable {
        public let count: Int
        public let truncated: Bool
    }

    public static func occurrences(of name: String, underRoot root: URL, includeTests: Bool, fileLimit: Int = 4000) -> Result {
        guard isIdentifier(name) else { return Result(count: 0, truncated: false) }
        let files = SwiftSources.files(under: root, includeTests: includeTests,
                                       extensions: ["swift"] + IndexDeclarations.clangExtensions)
        var total = 0
        for file in files.prefix(fileLimit) {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            total += countWholeWord(name, in: content)
        }
        return Result(count: total, truncated: files.count > fileLimit)
    }

    /// A textual occurrence (the line carrying it) — used when degrading from zero semantic hits.
    public struct Match: Sendable, Codable {
        public let path: String
        public let line: Int
        public let text: String
        /// Whether the line sits inside a `#if` block. An index holds one configuration, so a
        /// symbol living only in another branch is missing from it for a knowable reason — and
        /// saying which reason is the difference between "not found" and "not built here".
        public let conditional: Bool

        public init(path: String, line: Int, text: String, conditional: Bool = false) {
            self.path = path
            self.line = line
            self.text = text
            self.conditional = conditional
        }
    }

    /// Lines carrying the identifier (one per source line), capped. For showing the grep
    /// equivalent inline when semantics do not resolve.
    public static func matches(of name: String, underRoot root: URL, includeTests: Bool, limit: Int, fileLimit: Int = 4000) -> (matches: [Match], truncated: Bool) {
        guard isIdentifier(name) else { return ([], false) }
        let files = SwiftSources.files(under: root, includeTests: includeTests,
                                       extensions: ["swift"] + IndexDeclarations.clangExtensions)
        var result: [Match] = []
        for file in files.prefix(fileLimit) {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let conditionalLines = ConditionalRegions.areUsed(inSource: content)
                ? ConditionalRegions.lines(inSource: content)
                : []
            for (index, lineText) in content.components(separatedBy: "\n").enumerated() where countWholeWord(name, in: lineText) > 0 {
                result.append(Match(path: file.path, line: index + 1,
                                    text: lineText.trimmingCharacters(in: .whitespaces),
                                    conditional: conditionalLines.contains(index + 1)))
                if result.count >= limit { return (result, true) }
            }
        }
        return (result, files.count > fileLimit)
    }

    /// Occurrences of a word with identifier boundaries on both sides, not a substring match.
    static func countWholeWord(_ word: String, in text: String) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: word, range: range) {
            let beforeOK = found.lowerBound == text.startIndex || !isIdentifierChar(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex || !isIdentifierChar(text[found.upperBound])
            if beforeOK && afterOK { count += 1 }
            range = found.upperBound..<text.endIndex
        }
        return count
    }

    private static func isIdentifierChar(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// A valid Swift identifier: a letter or `_` first, then letters, digits, or `_`.
    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy(isIdentifierChar)
    }
}
