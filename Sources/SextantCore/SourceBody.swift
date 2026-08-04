import Foundation
import SwiftParser
import SwiftSyntax

/// Extracts the full source text of a declaration (signature and body) from a definition position.
/// It closes a gap: `defs` and `api` give the signature but not the body, which previously meant
/// falling back to grep or reading the file.
public enum SourceBody {
    /// Full text of the declaration starting on the given line, body included. nil when there is
    /// no declaration on that line, or the file cannot be read.
    public static func declaration(atLine line: Int, inFile path: String) -> String? {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        var best: DeclSyntax?
        find(in: Syntax(tree), targetLine: line, converter: converter, best: &best)
        return best?.trimmedDescription
    }

    /// The declaration starting exactly on targetLine; if several do, the innermost one.
    private static func find(in node: Syntax, targetLine: Int, converter: SourceLocationConverter, best: inout DeclSyntax?) {
        if let decl = node.as(DeclSyntax.self) {
            let startLine = converter.location(for: decl.positionAfterSkippingLeadingTrivia).line
            if startLine == targetLine {
                if best == nil || decl.description.utf8.count < best!.description.utf8.count { best = decl }
            }
        }
        for child in node.children(viewMode: .sourceAccurate) {
            find(in: child, targetLine: targetLine, converter: converter, best: &best)
        }
    }
}
