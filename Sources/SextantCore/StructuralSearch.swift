import Foundation
import SwiftParser
import SwiftSyntax

/// A structural pattern match.
public struct StructuralMatch: Sendable, Codable {
    public let line: Int
    /// 1-based, in UTF-16 code units (`SourceColumn`).
    public let column: Int
    public let text: String
}

/// Structural search over the AST (SwiftSyntax).
///
/// Metavariables:
/// - `$Name` is a single hole: it matches any subtree in that position; repeating a name
///   requires the bound text to match, whatever kind of position each occurrence is in.
///   A hole stands for an expression, a type (`as! $T`, `Array<$T>`, `-> $R`), a binding
///   pattern (`let $X =`, `for $X in`, `catch $P`), a name (`func $F`, `class $C`, a closure or
///   argument label), or one whole parameter (`func $F($P)`).
/// - `$$$` (or `$$$Name`) is variadic: inside a list (arguments, elements, statements,
///   parameters) it absorbs any number of elements, and `{ $$$ }` as a type's body absorbs any
///   members. One variadic per list.
///
/// A metavariable the matcher would never bind — inside a string literal or a comment, or a
/// second variadic in one list — is refused when the pattern is compiled, never left to match
/// nothing.
public struct PatternSearch {
    public enum Failure: Error, Sendable, CustomStringConvertible {
        case emptyPattern
        case notAnExpression
        case tooBroad
        /// The parser recovered from the text instead of rejecting it — an unbalanced bracket, for
        /// example. The recovered tree matches nothing, so the answer would be "No matches."
        case unparsable
        /// More than one statement: the matcher compares one node with one node, so everything
        /// after the first statement would be ignored without a word.
        case severalStatements
        /// A metavariable written inside a string literal is text, not a hole.
        case metavariableInStringLiteral(String)
        /// A metavariable the matcher never reaches as a hole, with where it is.
        case unbindableMetavariable(String, reason: String)
        /// An operator whose precedence is not known, so the pattern's structure cannot be decided.
        case unknownOperator(String)

        /// Whether clang might still be able to use this pattern. `[self feed]` is not Swift and
        /// is a perfectly good Objective-C pattern; an empty or bare-metavariable pattern is
        /// wrong in every language.
        public var mayBeCFamily: Bool {
            switch self {
            case .emptyPattern, .tooBroad: return false
            case .notAnExpression, .unparsable, .severalStatements, .metavariableInStringLiteral,
                 .unbindableMetavariable, .unknownOperator: return true
            }
        }

        public var description: String {
            switch self {
            case .emptyPattern: return "the pattern is empty"
            case .notAnExpression: return "the pattern is not an expression, statement or declaration"
            case .tooBroad: return "the pattern is a bare metavariable, which matches everything"
            case .unparsable: return "the pattern does not parse — check for an unbalanced bracket or quote"
            case .severalStatements:
                return "the pattern is several statements, and a pattern matches one expression, statement or "
                    + "declaration — search for each statement separately"
            case .metavariableInStringLiteral(let name):
                return "the metavariable \(name) is inside a string literal, where it is plain text and cannot be "
                    + "bound — an interpolation \"\\(\(name))\" matches an interpolated expression"
            case .unbindableMetavariable(let name, let reason):
                return "the metavariable \(name) cannot be bound: \(reason)"
            case .unknownOperator(let name):
                return "the pattern uses \(name), whose precedence is not known (only the standard operators are), "
                    + "so how its expression is grouped cannot be decided"
            }
        }
    }

    private let patternRoot: Syntax
    /// The same pattern read as a type, for a generic specialization (`Array<$T>`): written in an
    /// expression it is an expression, and in `let xs: Array<Int>` the same text is a type.
    private let typeRoot: Syntax?
    private let sentinelToName: [String: String]
    private let variadicSentinels: Set<String>

    public init(pattern: String) throws {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyPattern }

        // A catch clause cannot stand alone, so it is parsed after an empty `do {}` and taken back
        // out; without a body of its own it accepts any body.
        let isCatchClause = trimmed.hasPrefix("catch") && !(trimmed.dropFirst(5).first.map(Metavariable.isIdentifierPart) ?? false)
        let text = isCatchClause ? "do {} " + trimmed + (trimmed.hasSuffix("}") ? "" : " { $$$ }") : pattern

        let substitution = Metavariable.substitute(text)
        let sentinelToName = substitution.singleByName
        let variadicSentinels = substitution.variadic

        let parsed = Parser.parse(source: substitution.text)
        if parsed.hasError {
            guard Self.isRecognisedRecovery(parsed, single: sentinelToName, variadic: variadicSentinels) else {
                throw Failure.unparsable
            }
        }
        // The pattern is matched against folded sources, so it is folded the same way.
        let folded = OperatorFolding.fold(parsed)
        if !folded.unknownOperators.isEmpty {
            throw Failure.unknownOperator(folded.unknownOperators.joined(separator: ", "))
        }
        let tree = folded.tree
        guard tree.statements.count <= 1 else { throw Failure.severalStatements }
        guard let item = tree.statements.first?.item else { throw Failure.notAnExpression }
        let root: Syntax
        if isCatchClause {
            guard let clause = item.as(DoStmtSyntax.self)?.catchClauses.first else { throw Failure.unparsable }
            root = Syntax(clause)
        } else if let expression = item.as(ExprSyntax.self) {
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
        self.typeRoot = root.kind == .genericSpecializationExpr ? Self.typeReading(of: substitution.text) : nil
        self.sentinelToName = sentinelToName
        self.variadicSentinels = variadicSentinels
        try checkEveryMetavariableIsBound(in: tree)
    }

    /// The pattern text parsed as a type annotation's type; nil when it does not parse as one.
    private static func typeReading(of text: String) -> Syntax? {
        let parsed = Parser.parse(source: "let _: " + text)
        guard !parsed.hasError,
              let binding = parsed.statements.first?.item.as(VariableDeclSyntax.self)?.bindings.first,
              let type = binding.typeAnnotation?.type, binding.initializer == nil else { return nil }
        return Syntax(type)
    }

    /// The roots the pattern is matched with, each against nodes of its own kind.
    private var roots: [Syntax] { [patternRoot] + (typeRoot.map { [$0] } ?? []) }

    /// Matches in a source file.
    public func search(source: String, fileName: String) -> [StructuralMatch] {
        search(in: Parser.parse(source: source), fileName: fileName)
    }

    /// Matches in an already parsed tree, without parsing it again. Operator sequences are folded
    /// with the standard operators first.
    public func search(in tree: SourceFileSyntax, fileName: String) -> [StructuralMatch] {
        search(inFolded: OperatorFolding.fold(tree).tree, fileName: fileName)
    }

    /// Matches in a tree `OperatorFolding` has already folded.
    public func search(inFolded tree: SourceFileSyntax, fileName: String) -> [StructuralMatch] {
        let columns = SwiftColumns(tree: tree)
        var results: [StructuralMatch] = []
        walk(Syntax(tree), columns: columns, into: &results)
        return results
    }

    /// A single tree walk for several patterns (used by lint, instead of N separate walks).
    /// Returns the pattern index along with the match.
    public static func searchAll(_ searches: [PatternSearch], in tree: SourceFileSyntax, fileName: String) -> [(index: Int, match: StructuralMatch)] {
        searchAll(searches, inFolded: OperatorFolding.fold(tree).tree, fileName: fileName)
    }

    /// `searchAll` over a tree `OperatorFolding` has already folded.
    public static func searchAll(_ searches: [PatternSearch], inFolded tree: SourceFileSyntax,
                                 fileName: String) -> [(index: Int, match: StructuralMatch)] {
        let columns = SwiftColumns(tree: tree)
        var results: [(index: Int, match: StructuralMatch)] = []
        func visit(_ node: Syntax) {
            let nodeKind = node.kind
            for (index, search) in searches.enumerated() {
                guard let root = search.roots.first(where: { $0.kind == nodeKind }) else { continue }
                var bindings: [String: String] = [:]
                if search.matchNode(root, node, &bindings) {
                    let location = columns.position(of: node.positionAfterSkippingLeadingTrivia)
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

    private func walk(_ node: Syntax, columns: SwiftColumns, into results: inout [StructuralMatch]) {
        if let root = roots.first(where: { $0.kind == node.kind }) {
            var bindings: [String: String] = [:]
            if matchNode(root, node, &bindings) {
                let location = columns.position(of: node.positionAfterSkippingLeadingTrivia)
                let firstLine = node.trimmedDescription.split(separator: "\n").first.map(String.init) ?? ""
                results.append(StructuralMatch(line: location.line, column: location.column, text: firstLine))
            }
        }
        for child in node.children(viewMode: .sourceAccurate) {
            walk(child, columns: columns, into: &results)
        }
    }

    private func matchNode(_ pattern: Syntax, _ candidate: Syntax, _ bindings: inout [String: String]) -> Bool {
        if let sentinel = holeSentinel(of: pattern) {
            let text: String
            if pattern.is(TokenSyntax.self) {
                // A name hole stands for a name: it binds a token, never a whole subtree.
                guard let token = candidate.as(TokenSyntax.self) else { return false }
                text = token.text
            } else {
                text = Self.coreText(of: candidate)
            }
            if let previous = bindings[sentinel] { return previous == text }
            bindings[sentinel] = text
            return true
        }
        if isMemberWildcard(pattern) { return candidate.is(MemberBlockSyntax.self) }
        guard pattern.kind == candidate.kind else { return false }
        if let patternToken = pattern.as(TokenSyntax.self) {
            return patternToken.text == candidate.as(TokenSyntax.self)?.text
        }
        var candidateChildren = meaningfulChildren(candidate)
        // A function or initializer written without a body matches whatever body the declaration
        // has, or none — the way a catch clause without a body does.
        if Self.canHaveBody(pattern), Self.body(of: pattern) == nil, let body = Self.body(of: candidate) {
            candidateChildren.removeAll { $0.id == body.id }
        }
        return matchChildren(meaningfulChildren(pattern), candidateChildren, &bindings)
    }

    private static func body(of node: Syntax) -> Syntax? {
        if let function = node.as(FunctionDeclSyntax.self) { return function.body.map(Syntax.init) }
        if let initializer = node.as(InitializerDeclSyntax.self) { return initializer.body.map(Syntax.init) }
        return nil
    }

    /// Whether the node is a declaration that can have a body, so a missing one means "any body".
    private static func canHaveBody(_ node: Syntax) -> Bool {
        node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self)
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

    // MARK: - Holes

    /// The sentinel of a single hole, when the node is one.
    ///
    /// The outermost form of a hole is what binds, so it takes in its whole position: an
    /// expression (a bare reference), a type (a bare type name), a binding pattern, one whole
    /// parameter, or — for a name that is a token of a declaration, a closure parameter or a
    /// label — the token itself.
    private func holeSentinel(of node: Syntax) -> String? {
        switch node.kind {
        case .declReferenceExpr:
            let reference = node.cast(DeclReferenceExprSyntax.self)
            guard reference.argumentNames == nil else { return nil }
            return single(reference.baseName)
        case .identifierType:
            let type = node.cast(IdentifierTypeSyntax.self)
            guard type.genericArgumentClause == nil else { return nil }
            return single(type.name)
        case .identifierPattern:
            return single(node.cast(IdentifierPatternSyntax.self).identifier)
        case .expressionPattern:
            // `catch $P`, `case $P:` — the hole stands for whatever pattern is written there.
            return holeSentinel(of: Syntax(node.cast(ExpressionPatternSyntax.self).expression))
        case .functionParameter:
            guard let type = Self.parameterHoleType(node.cast(FunctionParameterSyntax.self)) else { return nil }
            return single(type.name)
        case .token:
            return single(node.cast(TokenSyntax.self))
        default:
            return nil
        }
    }

    private func single(_ token: TokenSyntax) -> String? {
        guard case .identifier(let text) = token.tokenKind, sentinelToName[text] != nil else { return nil }
        return text
    }

    /// The type of a parameter written as a bare metavariable, `func f($P)` or `func f($$$)`. The
    /// parser reads it as a type with the label and colon missing; nothing else in it may be there.
    private static func parameterHoleType(_ parameter: FunctionParameterSyntax) -> IdentifierTypeSyntax? {
        guard parameter.firstName.presence == .missing, parameter.colon.presence == .missing,
              parameter.secondName == nil, parameter.ellipsis == nil, parameter.defaultValue == nil,
              parameter.attributes.isEmpty, parameter.modifiers.isEmpty,
              let type = parameter.type.as(IdentifierTypeSyntax.self), type.genericArgumentClause == nil
        else { return nil }
        return type
    }

    /// `{ $$$ }` as the body of a type: the parser leaves the sentinel as unexpected text in an
    /// otherwise empty member block.
    private func isMemberWildcard(_ node: Syntax) -> Bool {
        guard let block = node.as(MemberBlockSyntax.self) else { return false }
        return Self.memberWildcardSentinel(block).map(variadicSentinels.contains) ?? false
    }

    private static func memberWildcardSentinel(_ block: MemberBlockSyntax) -> String? {
        guard block.members.isEmpty, let unexpected = block.unexpectedBetweenMembersAndRightBrace,
              unexpected.count == 1, let token = unexpected.first?.as(TokenSyntax.self),
              case .identifier(let text) = token.tokenKind else { return nil }
        return text
    }

    private func isVariadic(_ node: Syntax) -> Bool {
        // String content is text: a `$$$` there is not a hole.
        guard !node.is(StringSegmentSyntax.self), !node.is(StringLiteralSegmentListSyntax.self) else { return false }
        if let token = node.as(TokenSyntax.self), case .stringSegment = token.tokenKind { return false }
        return variadicSentinels.contains(Self.coreText(of: node))
    }

    // MARK: - Compiling

    /// Whether every error in a recovered tree is one of the shapes a metavariable leaves behind:
    /// a parameter written as a bare metavariable, or `{ $$$ }` as a type's body.
    private static func isRecognisedRecovery(_ tree: SourceFileSyntax, single: [String: String],
                                             variadic: Set<String>) -> Bool {
        let sentinels = Set(single.keys).union(variadic)
        final class Check: SyntaxVisitor {
            let sentinels: Set<String>
            var recognised = true
            init(sentinels: Set<String>) {
                self.sentinels = sentinels
                super.init(viewMode: .all)
            }
            override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
                if let type = PatternSearch.parameterHoleType(node), sentinels.contains(type.name.text) {
                    return .skipChildren
                }
                return .visitChildren
            }
            override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
                guard let sentinel = PatternSearch.memberWildcardSentinel(node) else { return .visitChildren }
                if !sentinels.contains(sentinel) { recognised = false }
                return .skipChildren
            }
            override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
                recognised = false
                return .skipChildren
            }
            override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
                if token.presence == .missing { recognised = false }
                return .skipChildren
            }
        }
        let check = Check(sentinels: sentinels)
        check.walk(tree)
        return check.recognised
    }

    /// Refuses a pattern with a metavariable the matcher would never reach as a hole. It walks the
    /// pattern the way matching does, so a position nobody anticipated fails here, loudly, instead
    /// of producing an empty answer.
    private func checkEveryMetavariableIsBound(in tree: SourceFileSyntax) throws {
        var bound = Set<String>()
        try collectBound(patternRoot, into: &bound)
        let sentinels = Array(sentinelToName.keys) + Array(variadicSentinels)
        for sentinel in sentinels.sorted() where !bound.contains(sentinel) {
            let name = sentinelToName[sentinel].map { "$\($0)" }
                ?? variadicSentinels.first { $0 == sentinel }.map(Self.variadicSpelling) ?? sentinel
            let tokens = tree.tokens(viewMode: .sourceAccurate).filter { $0.text.contains(sentinel) }
            if tokens.contains(where: { $0.ancestorOrSelf(mapping: { $0.as(StringLiteralExprSyntax.self) }) != nil }) {
                throw Failure.metavariableInStringLiteral(name)
            }
            if tokens.isEmpty {
                throw Failure.unbindableMetavariable(name, reason: "it is inside a comment")
            }
            throw Failure.unbindableMetavariable(
                name, reason: "the matcher does not reach it as a hole in this position, so the pattern would match nothing")
        }
    }

    private func collectBound(_ node: Syntax, into bound: inout Set<String>) throws {
        if let sentinel = holeSentinel(of: node) { bound.insert(sentinel); return }
        if isMemberWildcard(node), let block = node.as(MemberBlockSyntax.self),
           let sentinel = Self.memberWildcardSentinel(block) {
            bound.insert(sentinel); return
        }
        let children = meaningfulChildren(node)
        let variadics = children.filter(isVariadic)
        if variadics.count > 1 {
            let spelled = Self.variadicSpelling(Self.coreText(of: variadics[1]))
            throw Failure.unbindableMetavariable(
                spelled, reason: "only one variadic is supported in one list, and a second one makes the pattern match nothing")
        }
        for child in children {
            if isVariadic(child) { bound.insert(Self.coreText(of: child)); continue }
            try collectBound(child, into: &bound)
        }
    }

    /// `$$$` or `$$$Name`, from its sentinel.
    private static func variadicSpelling(_ sentinel: String) -> String {
        guard let separator = sentinel.firstIndex(of: "_") else { return "$$$" }
        return "$$$" + sentinel[sentinel.index(after: separator)...]
    }

    /// A node's text without surrounding commas or spaces — used to recognise sentinels.
    private static func coreText(of node: Syntax) -> String {
        node.trimmedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ", \n\t"))
    }
}
