import Foundation
import SwiftParser
import SwiftSyntax

/// Extracts the full source text of a declaration (signature and body) from a definition position.
/// It closes a gap: `defs` and `api` give the signature but not the body, which previously meant
/// falling back to grep or reading the file.
public enum SourceBody {
    /// Full text of the declaration starting on the given line, body included. nil when there is
    /// no declaration on that line, or the file cannot be read.
    ///
    /// Swift is parsed; everything else is delimited. The index already supplies the exact
    /// definition line, so for C-family sources the remaining question is only where the
    /// declaration ends — and answering it with SwiftParser silently mis-handled them: an
    /// Objective-C `@implementation` produced nothing, a C function produced nothing, and a C++
    /// struct happened to parse as Swift and came back missing its trailing `;`.
    /// `named` is the symbol the caller asked about. The index records a line, the file moves, and
    /// whatever declaration now starts on that line is not necessarily the one that was asked for —
    /// so the text is returned only when the name is still there. Without the check, an edit that
    /// shifts a file turns `body alpha` into someone else's body, printed as the answer.
    public static func declaration(atLine line: Int, inFile path: String, named: String? = nil) -> String? {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let text = path.hasSuffix(".swift")
            ? swiftDeclaration(atLine: line, inFile: path, source: source, named: named)
            : delimitedDeclaration(atLine: line, source: source)
        guard let text, let named else { return text }
        return declaresName(named, in: text) ? text : nil
    }

    /// A declaration's text and the position the index recorded for it.
    public struct Extracted: Sendable, Encodable {
        public let file: String
        public let line: Int
        public let text: String
    }

    /// The declarations of `symbol` at the definitions the index recorded for it — the one path
    /// the CLI and MCP both take. A definition whose recorded line no longer starts a declaration
    /// of that name is left out: the file has changed since it was indexed, and the text found on
    /// that line belongs to something else.
    public static func bodies(of symbol: String, at definitions: [SourceLocation]) -> [Extracted] {
        definitions.compactMap { definition in
            declaration(atLine: definition.line, inFile: definition.path, named: symbol)
                .map { Extracted(file: definition.path, line: definition.line, text: $0) }
        }
    }

    /// Why `bodies(of:at:)` is empty although the index has definitions for the symbol.
    public static let unextractableReason =
        "no declaration of that name on the recorded line — the file has changed since it was indexed. "
        + "Rebuild the project or run `sextant index`."

    /// Whether the extracted text declares that name — a word match on the line that states what
    /// the declaration is called. Attributes on lines of their own (`@MainActor`, `@objc`) come
    /// first in the text and are read past, up to the first line that is not an attribute.
    static func declaresName(_ name: String, in text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if WordBoundary.contains(name, in: String(line)) { return true }
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("@") else { return false }
        }
        return false
    }

    private static func swiftDeclaration(atLine line: Int, inFile path: String, source: String, named: String?) -> String? {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        var candidates: [DeclSyntax] = []
        find(in: Syntax(tree), targetLine: line, converter: converter, into: &candidates)
        // The innermost declaration on that line; of those, one that declares the name asked for.
        let ordered = candidates.sorted { $0.description.utf8.count < $1.description.utf8.count }
        let named = named.flatMap { name in ordered.first { declaresName(name, in: $0.trimmedDescription) } }
        return (named ?? ordered.first)?.trimmedDescription
    }

    /// Declarations whose head spans targetLine: from the first attribute to the keyword after the
    /// attributes and modifiers. The index records the line of the name, which is below an
    /// attribute written on a line of its own.
    private static func find(in node: Syntax, targetLine: Int, converter: SourceLocationConverter,
                             into candidates: inout [DeclSyntax]) {
        if let decl = node.as(DeclSyntax.self) {
            let startLine = converter.location(for: decl.positionAfterSkippingLeadingTrivia).line
            let keyword = introducer(of: decl)
            let keywordLine = keyword.map { converter.location(for: $0.positionAfterSkippingLeadingTrivia).line } ?? startLine
            if startLine <= targetLine, targetLine <= max(startLine, keywordLine) { candidates.append(decl) }
        }
        for child in node.children(viewMode: .sourceAccurate) {
            find(in: child, targetLine: targetLine, converter: converter, into: &candidates)
        }
    }

    /// The first token of a declaration after its attributes and modifiers.
    private static func introducer(of decl: DeclSyntax) -> TokenSyntax? {
        let modifiers = decl.asProtocol(WithModifiersSyntax.self)?.modifiers
        let attributes = decl.asProtocol(WithAttributesSyntax.self)?.attributes
        if let last = modifiers?.lastToken(viewMode: .sourceAccurate) ?? attributes?.lastToken(viewMode: .sourceAccurate) {
            return last.nextToken(viewMode: .sourceAccurate)
        }
        return decl.firstToken(viewMode: .sourceAccurate)
    }

    // MARK: - C family

    /// Objective-C containers that are terminated by `@end` rather than a brace.
    private static let objcContainers = ["@implementation", "@interface", "@protocol"]

    /// Delimits a C-family declaration starting at `line`. Objective-C containers run to `@end`;
    /// anything else runs to the brace that closes its body, or to the `;` of a prototype that has
    /// no body at all.
    static func delimitedDeclaration(atLine line: Int, source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        let start = line - 1
        guard start >= 0, start < lines.count else { return nil }

        let head = lines[start].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return nil }

        if objcContainers.contains(where: head.hasPrefix) {
            guard let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "@end" })
            else { return nil }
            return lines[start...end].joined(separator: "\n")
        }
        return bracedDeclaration(from: start, lines: lines)
    }

    /// Scans forward balancing braces. String literals, character literals and comments are
    /// skipped: a `{` inside one would unbalance the count and truncate the result at the wrong
    /// place, which reads as a correct answer.
    private static func bracedDeclaration(from start: Int, lines: [String]) -> String? {
        var depth = 0
        var opened = false
        var inBlockComment = false

        for index in start..<lines.count {
            var inString = false
            var inChar = false
            var escaped = false
            var previous: Character = " "

            for character in lines[index] {
                if inBlockComment {
                    if previous == "*" && character == "/" { inBlockComment = false }
                    previous = character
                    continue
                }
                if inString || inChar {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if inString && character == "\"" { inString = false }
                    else if inChar && character == "'" { inChar = false }
                    previous = character
                    continue
                }
                if previous == "/" && character == "/" { break }                 // line comment
                if previous == "/" && character == "*" { inBlockComment = true; previous = character; continue }
                switch character {
                case "\"": inString = true
                case "'": inChar = true
                case "{": depth += 1; opened = true
                case "}":
                    depth -= 1
                    if opened && depth == 0 {
                        // Whole lines are taken, so a trailing `;` on the closing line — as in
                        // `struct S { ... };` — comes along without special handling.
                        return lines[start...index].joined(separator: "\n")
                    }
                case ";":
                    // A prototype with no body — the declaration ends here.
                    if !opened { return lines[start...index].joined(separator: "\n") }
                default: break
                }
                previous = character
            }
        }
        return nil
    }
}
