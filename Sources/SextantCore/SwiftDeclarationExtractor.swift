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
        declaration.with(condition: declaration.condition ?? condition)
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
            members: base.members,
            name: base.name
        )
    }

    private static func attributes(of decl: DeclSyntax) -> [String] {
        guard let withAttributes = decl.asProtocol(WithAttributesSyntax.self) else { return [] }
        return withAttributes.attributes.map { clean($0) }.filter { !$0.isEmpty }
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
            return makeType(.structKind, header: typeHeader("struct", node.name.text, node.genericParameterClause.map { clean($0) }, node.inheritanceClause, node.genericWhereClause, node.modifiers), name: node.name.text, modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(ClassDeclSyntax.self) {
            return makeType(.classKind, header: typeHeader("class", node.name.text, node.genericParameterClause.map { clean($0) }, node.inheritanceClause, node.genericWhereClause, node.modifiers), name: node.name.text, modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(EnumDeclSyntax.self) {
            return makeType(.enumKind, header: typeHeader("enum", node.name.text, node.genericParameterClause.map { clean($0) }, node.inheritanceClause, node.genericWhereClause, node.modifiers), name: node.name.text, modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(ActorDeclSyntax.self) {
            return makeType(.actorKind, header: typeHeader("actor", node.name.text, node.genericParameterClause.map { clean($0) }, node.inheritanceClause, node.genericWhereClause, node.modifiers), name: node.name.text, modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(ProtocolDeclSyntax.self) {
            let header = typeHeader("protocol", node.name.text, node.primaryAssociatedTypeClause.map { clean($0) },
                                    node.inheritanceClause, node.genericWhereClause, node.modifiers)
            return makeType(.protocolKind, header: header, name: node.name.text, modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(ExtensionDeclSyntax.self) {
            let header = typeHeader("extension", clean(node.extendedType), nil, node.inheritanceClause, node.genericWhereClause, node.modifiers)
            return makeType(.extensionKind, header: header, name: nil, modifiers: node.modifiers, memberBlock: node.memberBlock, default: defaultAccess)
        }
        if let node = decl.as(FunctionDeclSyntax.self) {
            var header = "\(modifierPrefix(node.modifiers))func \(node.name.text)"
            if let generics = node.genericParameterClause { header += clean(generics) }
            header += clean(node.signature)
            if let whereClause = node.genericWhereClause { header += " " + clean(whereClause) }
            return Declaration(kind: .function, header: header, access: explicitAccess(node.modifiers) ?? defaultAccess,
                               name: node.name.text)
        }
        if let node = decl.as(InitializerDeclSyntax.self) {
            var header = "\(modifierPrefix(node.modifiers))init"
            if let optionalMark = node.optionalMark { header += optionalMark.text }
            if let generics = node.genericParameterClause { header += clean(generics) }
            header += clean(node.signature)
            if let whereClause = node.genericWhereClause { header += " " + clean(whereClause) }
            return Declaration(kind: .initializer, header: header, access: explicitAccess(node.modifiers) ?? defaultAccess)
        }
        if let node = decl.as(SubscriptDeclSyntax.self) {
            var header = "\(modifierPrefix(node.modifiers))subscript"
            if let generics = node.genericParameterClause { header += clean(generics) }
            header += clean(node.parameterClause) + " " + clean(node.returnClause)
            if let whereClause = node.genericWhereClause { header += " " + clean(whereClause) }
            if let accessors = accessorSummary(node.accessorBlock) { header += " " + accessors }
            return Declaration(kind: .subscriptKind, header: header, access: explicitAccess(node.modifiers) ?? defaultAccess)
        }
        if let node = decl.as(VariableDeclSyntax.self) {
            let bindings = node.bindings.map { binding -> String in
                var text = binding.pattern.trimmedDescription
                if let type = binding.typeAnnotation { text += clean(type) }
                if let accessors = accessorSummary(binding.accessorBlock) { text += " " + accessors }
                return text
            }
            guard !bindings.isEmpty else { return nil }
            let header = "\(modifierPrefix(node.modifiers))\(node.bindingSpecifier.text) \(bindings.joined(separator: ", "))"
            let name = node.bindings.first.map { $0.pattern.trimmedDescription }
            return Declaration(kind: .property, header: header, access: explicitAccess(node.modifiers) ?? defaultAccess,
                               name: name)
        }
        if let node = decl.as(EnumCaseDeclSyntax.self) {
            let elements = node.elements.map { element -> String in
                var text = element.name.text
                if let parameters = element.parameterClause { text += clean(parameters) }
                if let rawValue = element.rawValue { text += " " + clean(rawValue) }
                return text
            }
            return Declaration(kind: .caseKind, header: "case " + elements.joined(separator: ", "),
                               access: explicitAccess(node.modifiers) ?? defaultAccess,
                               name: node.elements.first?.name.text)
        }
        if let node = decl.as(TypeAliasDeclSyntax.self) {
            var header = "\(modifierPrefix(node.modifiers))typealias \(node.name.text)"
            if let generics = node.genericParameterClause { header += clean(generics) }
            header += " " + clean(node.initializer)
            if let whereClause = node.genericWhereClause { header += " " + clean(whereClause) }
            return Declaration(kind: .typealiasKind, header: header, access: explicitAccess(node.modifiers) ?? defaultAccess,
                               name: node.name.text)
        }
        if let node = decl.as(AssociatedTypeDeclSyntax.self) {
            var header = "associatedtype \(node.name.text)"
            if let inheritance = node.inheritanceClause { header += clean(inheritance) }
            if let initializer = node.initializer { header += " " + clean(initializer) }
            if let whereClause = node.genericWhereClause { header += " " + clean(whereClause) }
            return Declaration(kind: .associatedtypeKind, header: header,
                               access: explicitAccess(node.modifiers) ?? defaultAccess, name: node.name.text)
        }
        if let node = decl.as(MacroDeclSyntax.self) {
            // The definition (`= #externalMacro(…)`) names the implementation, not the contract.
            var header = "\(modifierPrefix(node.modifiers))macro \(node.name.text)"
            if let generics = node.genericParameterClause { header += clean(generics) }
            header += clean(node.signature)
            if let whereClause = node.genericWhereClause { header += " " + clean(whereClause) }
            return Declaration(kind: .macroKind, header: header, access: explicitAccess(node.modifiers) ?? defaultAccess,
                               name: node.name.text)
        }
        // A deinitializer cannot be called or referred to: adding or removing one changes nothing
        // another declaration can rely on, so it is not part of the surface.
        return nil
    }

    /// What a property or subscript lets a caller do, as a protocol requirement spells it:
    /// `{ get }`, `{ get set }`, with the accessors' effects and `mutating`/`nonmutating`. Bodies
    /// are not part of it, and neither are observers: a stored property with `didSet` is as
    /// settable as one without. nil for a stored property — its getter and setter are implied.
    private static func accessorSummary(_ block: AccessorBlockSyntax?) -> String? {
        guard let block else { return nil }
        switch block.accessors {
        case .getter:
            return "{ get }"
        case .accessors(let list):
            var parts: [(order: Int, text: String)] = []
            for accessor in list {
                let order: Int
                switch accessor.accessorSpecifier.text {
                case "get", "_read", "unsafeAddress": order = 0
                case "set", "_modify", "unsafeMutableAddress": order = 1
                default: continue   // willSet, didSet, init
                }
                let keyword = order == 0 ? "get" : "set"
                var words = (accessor.modifier.map { [$0.trimmedDescription] } ?? []) + [keyword]
                if let effects = accessor.effectSpecifiers { words.append(clean(effects)) }
                let text = words.joined(separator: " ")
                if !parts.contains(where: { $0.order == order }) { parts.append((order, text)) }
            }
            guard !parts.isEmpty else { return nil }
            return "{ " + parts.sorted { $0.order < $1.order }.map(\.text).joined(separator: " ") + " }"
        }
    }

    private static func typeHeader(
        _ keyword: String,
        _ name: String,
        _ generics: String?,
        _ inheritance: InheritanceClauseSyntax?,
        _ whereClause: GenericWhereClauseSyntax?,
        _ modifiers: DeclModifierListSyntax
    ) -> String {
        var header = "\(modifierPrefix(modifiers))\(keyword) \(name)"
        if let generics { header += generics }
        if let inheritance {
            let conformances = inheritance.inheritedTypes.map { clean($0.type) }
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
        name: String?,
        modifiers: DeclModifierListSyntax,
        memberBlock: MemberBlockSyntax,
        default defaultAccess: Access
    ) -> Declaration {
        let typeAccess = explicitAccess(modifiers) ?? defaultAccess
        let memberDefault: Access = (kind == .extensionKind || kind == .protocolKind) ? typeAccess : .internal
        // A case keeps everything but its access, which is the enum's: its condition and its
        // attributes are as much a part of it as its name.
        let members = memberBlock.members.flatMap { declarations(from: $0.decl, default: memberDefault) }.map { member in
            member.kind == .caseKind ? member.with(access: typeAccess) : member
        }
        return Declaration(kind: kind, header: header, access: typeAccess, members: members, name: name)
    }

    /// Modifiers that are part of the contract, in a fixed order so that reordering them in source
    /// is not a change: `open` (which a diff shows instead of `public`), a setter's access
    /// (`private(set)`), then what changes how the declaration may be used (`final`, `required`,
    /// `mutating`, `nonisolated`, …), then `static`/`class`. Left out: the getter's access level,
    /// which is `access`; and `override`, `lazy`, `dynamic` and `indirect`, which say how a
    /// declaration is implemented or dispatched, not what a caller may do with it.
    private static func modifierPrefix(_ modifiers: DeclModifierListSyntax) -> String {
        let order = ["open", "setter", "final", "required", "convenience", "optional", "distributed",
                     "nonisolated", "mutating", "nonmutating", "consuming", "borrowing", "__consuming",
                     "prefix", "postfix", "infix", "weak", "unowned", "static", "class"]
        var found: [(rank: Int, text: String)] = []
        for modifier in modifiers {
            let name = modifier.name.text
            if let detail = modifier.detail, detail.detail.text == "set" {
                found.append((1, "\(name)(set)"))
            } else if let rank = order.firstIndex(of: name), name != "setter" {
                found.append((rank, modifier.detail.map { name + clean($0) } ?? name))
            }
        }
        return found.sorted { $0.rank < $1.rank }.map { $0.text + " " }.joined()
    }

    /// The explicit access modifier; nil means there is none and access comes from the context.
    /// A modifier with a detail — `private(set)` — restricts the setter only; the getter's level,
    /// which decides who can see the declaration, is the one without.
    private static func explicitAccess(_ modifiers: DeclModifierListSyntax) -> Access? {
        for modifier in modifiers where modifier.detail == nil {
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
    /// Rebuilt from tokens: any trivia between two tokens — spaces, newlines, comments — becomes
    /// one space, and nothing before the first token or after the last counts, so a doc comment
    /// attached to a declaration's first attribute stays out. Token text is kept as written, so a
    /// string literal keeps its spaces and its `//`.
    private static func clean(_ node: some SyntaxProtocol) -> String {
        var result = ""
        var pendingSpace = false
        for token in node.tokens(viewMode: .sourceAccurate) where token.presence == .present {
            if !result.isEmpty, pendingSpace || !token.leadingTrivia.isEmpty { result += " " }
            // A multi-line string literal is the one token that spans lines; the signature stays one.
            result += token.text.contains(where: \.isNewline)
                ? token.text.split(whereSeparator: \.isNewline).joined(separator: " ")
                : token.text
            pendingSpace = !token.trailingTrivia.isEmpty
        }
        return result
    }
}
