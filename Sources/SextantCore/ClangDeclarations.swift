import Foundation

/// Declarations read out of a clang tree.
///
/// One walk serves both callers that need it: the public surface of a C++ header, and the
/// symbol-level diff of a C-family file. They differ only in what they keep — a surface keeps
/// public members, a diff keeps everything — so the rule lives in one place rather than twice.
public enum ClangDeclarations {
    /// Cursor kinds worth reporting, and the declaration kind each becomes. Anything absent —
    /// template parameters, base specifiers, access specifiers — is not a declaration a reader
    /// asks about.
    static let listedKinds: [String: DeclarationKind] = [
        "StructDecl": .structKind, "UnionDecl": .structKind,
        "ClassDecl": .classKind, "ClassTemplate": .classKind,
        "EnumDecl": .enumKind, "EnumConstantDecl": .caseKind,
        "TypedefDecl": .typealiasKind, "TypeAliasDecl": .typealiasKind,
        "FunctionDecl": .function, "FunctionTemplate": .function, "CXXMethod": .function,
        "Constructor": .initializer, "CXXConstructor": .initializer,
        "FieldDecl": .property, "VarDecl": .property,
        "ObjCInterfaceDecl": .classKind, "ObjCImplementationDecl": .classKind,
        "ObjCProtocolDecl": .protocolKind,
        "ObjCCategoryDecl": .extensionKind, "ObjCCategoryImplDecl": .extensionKind,
        "ObjCInstanceMethodDecl": .function, "ObjCClassMethodDecl": .function,
        "ObjCPropertyDecl": .property, "ObjCIvarDecl": .property
    ]

    /// Declarations of the given nodes, with members nested underneath.
    ///
    /// `publicOnly` drops what a caller outside the type cannot use — the point of a public
    /// surface, and the wrong filter for a diff, where a private member changing is still a change.
    public static func declarations(of nodes: [ClangNode], source: Data?,
                                    publicOnly: Bool, access: Access) -> [Declaration] {
        nodes.flatMap { declarations(of: $0, source: source, publicOnly: publicOnly, access: access) }
    }

    private static func declarations(of node: ClangNode, source: Data?,
                                     publicOnly: Bool, access: Access) -> [Declaration] {
        // A namespace has no surface of its own, but what it holds does.
        if node.kindName == "Namespace" {
            return declarations(of: node.children, source: source, publicOnly: publicOnly, access: access)
        }
        if publicOnly, !node.isPublic { return [] }
        guard !node.spelling.isEmpty, let kind = listedKinds[node.kindName] else { return [] }
        return [Declaration(
            kind: kind,
            header: header(of: node, source: source),
            access: access,
            members: declarations(of: node.children, source: source, publicOnly: publicOnly, access: access)
        )]
    }

    /// The declaration's signature.
    ///
    /// C and C++ spell it up to the body's brace: taking the first line instead would report a
    /// template as `template <typename T>` and name no type at all. Objective-C needs both
    /// bounds — `@implementation Foo` opens no brace of its own and is followed by its methods,
    /// so the line ends it; a method written on one line does open a brace, and without that
    /// bound its body would land in the signature and every edit to it would read as an API change.
    static func header(of node: ClangNode, source: Data?) -> String {
        let fallback = "\(listedKinds[node.kindName]?.rawValue ?? "") \(node.spelling)"
            .trimmingCharacters(in: .whitespaces)
        guard let source, node.startOffset < node.endOffset, node.endOffset <= source.count else { return fallback }

        let text = String(decoding: source[node.startOffset..<node.endOffset], as: UTF8.self)
        let signature = node.kindName.hasPrefix("ObjC")
            ? text.prefix { $0 != "{" && !$0.isNewline }
            : text.prefix { $0 != "{" }
        let collapsed = signature
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "; {"))
        return collapsed.isEmpty ? fallback : collapsed
    }
}
