import Foundation
import SwiftParser
import SwiftSyntax

/// Extracts declarations from Swift source syntactically, with no build, via SwiftSyntax.
public enum SwiftDeclarationExtractor {
    /// Top-level declarations for a source text.
    public static func declarations(source: String) -> [Declaration] {
        declarations(tree: Parser.parse(source: source))
    }

    /// Top-level declarations for an already parsed tree.
    public static func declarations(tree: SourceFileSyntax) -> [Declaration] {
        tree.statements.flatMap { item in
            item.item.as(DeclSyntax.self).map { declarations(from: $0, default: .internal) } ?? []
        }
    }

    /// Declarations a single syntax item contributes. A `#if` contributes what its branches hold,
    /// each marked with the condition guarding it — dropping them (which is what happens when a
    /// walk only looks for declarations) makes an iOS-only public method invisible on a Mac,
    /// with nothing said about it.
    private static func declarations(from decl: DeclSyntax, default defaultAccess: Access) -> [Declaration] {
        guard let ifConfig = decl.as(IfConfigDeclSyntax.self) else {
            return declaration(from: decl, default: defaultAccess).map { [$0] } ?? []
        }
        return ifConfig.clauses.flatMap { clause -> [Declaration] in
            let marker = clause.condition.map { "\(clause.poundKeyword.text) \($0.trimmedDescription)" }
                ?? clause.poundKeyword.text
            // The branch body is a statement list at file scope and a member list inside a type;
            // walking the children covers both without spelling out the syntax enum.
            var elements: [DeclSyntax] = []
            for child in clause.children(viewMode: .sourceAccurate) {
                if let statements = child.as(CodeBlockItemListSyntax.self) {
                    elements += statements.compactMap { $0.item.as(DeclSyntax.self) }
                } else if let members = child.as(MemberBlockItemListSyntax.self) {
                    elements += members.map { $0.decl }
                }
            }
            return elements.flatMap { declarations(from: $0, default: defaultAccess) }
                .map { guarded($0, by: marker) }
        }
    }

    /// Marks a declaration and everything inside it with the condition it is compiled under.
    private static func guarded(_ declaration: Declaration, by condition: String) -> Declaration {
        Declaration(kind: declaration.kind, header: declaration.header, access: declaration.access,
                    attributes: declaration.attributes, docSummary: declaration.docSummary,
                    members: declaration.members, condition: declaration.condition ?? condition)
    }

    /// Decorates a base declaration with attributes (`@MainActor`) and a doc summary.
    /// `defaultAccess` is the context's access level, used when a declaration has no explicit modifier.
    private static func declaration(from decl: DeclSyntax, default defaultAccess: Access) -> Declaration? {
        guard let base = baseDeclaration(from: decl, default: defaultAccess) else { return nil }
        return Declaration(
            kind: base.kind,
            header: base.header,
            access: base.access,
            attributes: attributes(of: decl),
            docSummary: docSummary(of: decl),
            members: base.members
        )
    }

    private static func attributes(of decl: DeclSyntax) -> [String] {
        guard let withAttributes = decl.asProtocol(WithAttributesSyntax.self) else { return [] }
        return withAttributes.attributes.map { $0.trimmedDescription }.filter { !$0.isEmpty }
    }

    private static func docSummary(of decl: DeclSyntax) -> String? {
        for piece in decl.leadingTrivia {
            switch piece {
            case .docLineComment(let text):
                let line = text.drop(while: { $0 == "/" }).trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { return line }
            case .docBlockComment(let text):
                let inner = text.dropFirst(3).dropLast(2)
                for raw in inner.split(separator: "\n") {
                    let line = raw.drop(while: { $0 == " " || $0 == "*" || $0 == "\t" }).trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty { return line }
                }
            default:
                continue
            }
        }
        return nil
    }

    private static func baseDeclaration(from decl: DeclSyntax, default defaultAccess: Access) -> Declaration? {
        if let node = decl.as(StructDeclSyntax.self) {
            return makeType(.structKind, header: typeHeader("struct", node.name.text, node.genericParameterClause, node.inheritanceClause, node.genericWhereClause), modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(ClassDeclSyntax.self) {
            return makeType(.classKind, header: typeHeader("class", node.name.text, node.genericParameterClause, node.inheritanceClause, node.genericWhereClause), modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(EnumDeclSyntax.self) {
            return makeType(.enumKind, header: typeHeader("enum", node.name.text, node.genericParameterClause, node.inheritanceClause, node.genericWhereClause), modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(ActorDeclSyntax.self) {
            return makeType(.actorKind, header: typeHeader("actor", node.name.text, node.genericParameterClause, node.inheritanceClause, node.genericWhereClause), modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(ProtocolDeclSyntax.self) {
            return makeType(.protocolKind, header: typeHeader("protocol", node.name.text, nil, node.inheritanceClause, node.genericWhereClause), modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(ExtensionDeclSyntax.self) {
            return makeType(.extensionKind, header: typeHeader("extension", node.extendedType.trimmedDescription, nil, node.inheritanceClause, node.genericWhereClause), modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(FunctionDeclSyntax.self) {
            var header = "\(staticPrefix(node.modifiers))func \(node.name.text)"
            if let generics = node.genericParameterClause { header += clean(generics) }
            header += clean(node.signature)
            if let whereClause = node.genericWhereClause { header += " " + clean(whereClause) }
            return Declaration(kind: .function, header: header, access: explicitAccess(node.modifiers) ?? defaultAccess)
        }
        if let node = decl.as(InitializerDeclSyntax.self) {
            var header = "init"
            if let optionalMark = node.optionalMark { header += optionalMark.text }
            if let generics = node.genericParameterClause { header += clean(generics) }
            header += clean(node.signature)
            return Declaration(kind: .initializer, header: header, access: explicitAccess(node.modifiers) ?? defaultAccess)
        }
        if let node = decl.as(SubscriptDeclSyntax.self) {
            var header = "\(staticPrefix(node.modifiers))subscript"
            if let generics = node.genericParameterClause { header += clean(generics) }
            header += clean(node.parameterClause) + " " + clean(node.returnClause)
            return Declaration(kind: .subscriptKind, header: header, access: explicitAccess(node.modifiers) ?? defaultAccess)
        }
        if let node = decl.as(VariableDeclSyntax.self) {
            let bindings = node.bindings.map { binding -> String in
                let name = binding.pattern.trimmedDescription
                if let type = binding.typeAnnotation { return name + clean(type) }
                return name
            }
            guard !bindings.isEmpty else { return nil }
            let header = "\(staticPrefix(node.modifiers))\(node.bindingSpecifier.text) \(bindings.joined(separator: ", "))"
            return Declaration(kind: .property, header: header, access: explicitAccess(node.modifiers) ?? defaultAccess)
        }
        if let node = decl.as(EnumCaseDeclSyntax.self) {
            let elements = node.elements.map { element -> String in
                element.parameterClause.map { element.name.text + clean($0) } ?? element.name.text
            }
            return Declaration(kind: .caseKind, header: "case " + elements.joined(separator: ", "), access: explicitAccess(node.modifiers) ?? defaultAccess)
        }
        if let node = decl.as(TypeAliasDeclSyntax.self) {
            return Declaration(kind: .typealiasKind, header: "typealias \(node.name.text)", access: explicitAccess(node.modifiers) ?? defaultAccess)
        }
        return nil
    }

    private static func typeHeader(
        _ keyword: String,
        _ name: String,
        _ generics: GenericParameterClauseSyntax?,
        _ inheritance: InheritanceClauseSyntax?,
        _ whereClause: GenericWhereClauseSyntax?
    ) -> String {
        var header = "\(keyword) \(name)"
        if let generics { header += clean(generics) }
        if let inheritance {
            let conformances = inheritance.inheritedTypes.map { $0.type.trimmedDescription }
            if !conformances.isEmpty { header += ": \(conformances.joined(separator: ", "))" }
        }
        if let whereClause { header += " " + clean(whereClause) }
        return header
    }

    /// Builds a type with its members. Members of an `extension` or `protocol` inherit the
    /// container's access (in Swift, members of a `public extension` are public and the
    /// requirements of a `public protocol` are visible); in struct/class/enum/actor members default
    /// to internal. Enum cases inherit the type's access.
    private static func makeType(
        _ kind: DeclarationKind,
        header: String,
        modifiers: DeclModifierListSyntax,
        memberBlock: MemberBlockSyntax,
        default defaultAccess: Access
    ) -> Declaration {
        let typeAccess = explicitAccess(modifiers) ?? defaultAccess
        let memberDefault: Access = (kind == .extensionKind || kind == .protocolKind) ? typeAccess : .internal
        let members = memberBlock.members.flatMap { declarations(from: $0.decl, default: memberDefault) }.map { member in
            member.kind == .caseKind
                ? Declaration(kind: .caseKind, header: member.header, access: typeAccess, members: member.members)
                : member
        }
        return Declaration(kind: kind, header: header, access: typeAccess, members: members)
    }

    private static func staticPrefix(_ modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers where modifier.name.text == "static" || modifier.name.text == "class" {
            return "\(modifier.name.text) "
        }
        return ""
    }

    /// The explicit access modifier; nil means there is none and access comes from the context.
    private static func explicitAccess(_ modifiers: DeclModifierListSyntax) -> Access? {
        for modifier in modifiers {
            switch modifier.name.text {
            case "public", "open": return .public
            case "private", "fileprivate": return .private
            case "internal", "package": return .internal
            default: continue
            }
        }
        return nil
    }

    /// A one-line signature for a node, without comments or redundant whitespace.
    /// Comments are stripped at the trivia level rather than textually, so string literals containing `//` survive.
    private static func clean(_ node: some SyntaxProtocol) -> String {
        let hasComment = node.tokens(viewMode: .sourceAccurate).contains { token in
            token.leadingTrivia.contains(where: \.isComment) || token.trailingTrivia.contains(where: \.isComment)
        }
        if hasComment {
            return node.tokens(viewMode: .sourceAccurate).map(\.text).joined(separator: " ")
        }
        return node.trimmedDescription.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private extension TriviaPiece {
    var isComment: Bool {
        switch self {
        case .lineComment, .blockComment, .docLineComment, .docBlockComment: return true
        default: return false
        }
    }
}
