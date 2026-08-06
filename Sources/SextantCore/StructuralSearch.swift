import Foundation
import SwiftParser
import SwiftSyntax

/// A structural pattern match.
public struct StructuralMatch: Sendable, Codable {
    public let line: Int
    public let column: Int
    public let text: String
}

/// Structural search over the AST (SwiftSyntax).
///
/// Metavariables:
/// - `$Name` is a single hole: it matches any subtree in that position; repeating a name
///   requires the bound text to match.
/// - `$$$` (or `$$$Name`) is variadic: inside a list (arguments, elements, members) it absorbs any
///   number of elements. One variadic per list is supported.
public struct PatternSearch {
    public enum Failure: Error, Sendable {
        case emptyPattern
        case notAnExpression
        case tooBroad
    }

    private let patternRoot: Syntax
    private let patternRootKind: SyntaxKind
    private let sentinelToName: [String: String]
    private let variadicSentinels: Set<String>

    public init(pattern: String) throws {
        guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.emptyPattern }

        let substitution = Metavariable.substitute(pattern)
        let sentinelToName = substitution.singleByName
        let variadicSentinels = substitution.variadic

        let tree = Parser.parse(source: substitution.text)
        guard let item = tree.statements.first?.item else { throw Failure.notAnExpression }
        let root: Syntax
        if let expression = item.as(ExprSyntax.self) {
            root = Syntax(expression)
        } else if let statement = item.as(StmtSyntax.self) {
            root = Syntax(statement)
        } else if let declaration = item.as(DeclSyntax.self) {
            root = Syntax(declaration)
        } else {
            throw Failure.notAnExpression
        }
        let rootText = Self.coreText(of: root)
        guard sentinelToName[rootText] == nil, !variadicSentinels.contains(rootText) else {
            throw Failure.tooBroad
        }
        self.patternRoot = root
        self.patternRootKind = root.kind
        self.sentinelToName = sentinelToName
        self.variadicSentinels = variadicSentinels
    }

    /// Matches in a source file.
    public func search(source: String, fileName: String) -> [StructuralMatch] {
        search(in: Parser.parse(source: source), fileName: fileName)
    }

    /// Matches in an already parsed tree, without parsing it again.
    public func search(in tree: SourceFileSyntax, fileName: String) -> [StructuralMatch] {
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        var results: [StructuralMatch] = []
        walk(Syntax(tree), converter: converter, into: &results)
        return results
    }

    /// A single tree walk for several patterns (used by lint, instead of N separate walks).
    /// Returns the pattern index along with the match.
    public static func searchAll(_ searches: [PatternSearch], in tree: SourceFileSyntax, fileName: String) -> [(index: Int, match: StructuralMatch)] {
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        var results: [(index: Int, match: StructuralMatch)] = []
        func visit(_ node: Syntax) {
            let nodeKind = node.kind
            for (index, search) in searches.enumerated() where search.patternRootKind == nodeKind {
                var bindings: [String: String] = [:]
                if search.matchNode(search.patternRoot, node, &bindings) {
                    let location = node.startLocation(converter: converter)
                    let firstLine = node.trimmedDescription.split(separator: "\n").first.map(String.init) ?? ""
                    results.append((index, StructuralMatch(line: location.line, column: location.column, text: firstLine)))
                }
            }
            for child in node.children(viewMode: .sourceAccurate) { visit(child) }
        }
        visit(Syntax(tree))
        return results
    }

    // MARK: - Walking and matching

    private func walk(_ node: Syntax, converter: SourceLocationConverter, into results: inout [StructuralMatch]) {
        if node.kind == patternRootKind {
            var bindings: [String: String] = [:]
            if matchNode(patternRoot, node, &bindings) {
                let location = node.startLocation(converter: converter)
                let firstLine = node.trimmedDescription.split(separator: "\n").first.map(String.init) ?? ""
                results.append(StructuralMatch(line: location.line, column: location.column, text: firstLine))
            }
        }
        for child in node.children(viewMode: .sourceAccurate) {
            walk(child, converter: converter, into: &results)
        }
    }

    private func matchNode(_ pattern: Syntax, _ candidate: Syntax, _ bindings: inout [String: String]) -> Bool {
        if let name = singleMetavariableName(of: pattern) {
            let text = candidate.trimmedDescription
            if let previous = bindings[name] { return previous == text }
            bindings[name] = text
            return true
        }
        guard pattern.kind == candidate.kind else { return false }
        if let patternToken = pattern.as(TokenSyntax.self) {
            return patternToken.text == candidate.as(TokenSyntax.self)?.text
        }
        return matchChildren(meaningfulChildren(pattern), meaningfulChildren(candidate), &bindings)
    }

    /// A node's children without separating commas: a comma is a positional list separator, and
    /// whether one is present (a trailing comma) must not affect a structural match.
    private func meaningfulChildren(_ node: Syntax) -> [Syntax] {
        node.children(viewMode: .sourceAccurate).filter { $0.as(TokenSyntax.self)?.tokenKind != .comma }
    }

    /// Matches child lists with support for a single variadic (prefix + `$$$` + suffix).
    private func matchChildren(_ pattern: [Syntax], _ candidate: [Syntax], _ bindings: inout [String: String]) -> Bool {
        guard let variadicIndex = pattern.firstIndex(where: isVariadic) else {
            guard pattern.count == candidate.count else { return false }
            for (patternChild, candidateChild) in zip(pattern, candidate) {
                if !matchNode(patternChild, candidateChild, &bindings) { return false }
            }
            return true
        }
        let prefix = Array(pattern[..<variadicIndex])
        let suffix = Array(pattern[(variadicIndex + 1)...])
        guard !suffix.contains(where: isVariadic), candidate.count >= prefix.count + suffix.count else {
            return false
        }
        for (patternChild, candidateChild) in zip(prefix, candidate.prefix(prefix.count)) {
            if !matchNode(patternChild, candidateChild, &bindings) { return false }
        }
        for (patternChild, candidateChild) in zip(suffix, candidate.suffix(suffix.count)) {
            if !matchNode(patternChild, candidateChild, &bindings) { return false }
        }
        return true
    }

    private func singleMetavariableName(of node: Syntax) -> String? {
        guard let reference = node.as(DeclReferenceExprSyntax.self) else { return nil }
        return sentinelToName[reference.baseName.text]
    }

    private func isVariadic(_ node: Syntax) -> Bool {
        variadicSentinels.contains(Self.coreText(of: node))
    }

    /// A node's text without surrounding commas or spaces — used to recognise sentinels.
    private static func coreText(of node: Syntax) -> String {
        node.trimmedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ", \n\t"))
    }
}
