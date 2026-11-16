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
    /// `access` labels what is declared; where it is `public`, a C++ member declared private or
    /// protected, and whatever it holds, is labelled `private` instead.
    public static func declarations(of nodes: [ClangNode], source: Data?,
                                    publicOnly: Bool, access: Access) -> [Declaration] {
        nodes.flatMap { declarations(of: $0, source: source, publicOnly: publicOnly, access: access) }
    }

    private static func declarations(of node: ClangNode, source: Data?,
                                     publicOnly: Bool, access: Access) -> [Declaration] {
        // A namespace has no surface of its own, but what it holds does; so does an
        // `extern "C" { … }` block, which only changes how its declarations link.
        if node.kindName == "Namespace" || node.kindName == "LinkageSpec" {
            return declarations(of: node.children, source: source, publicOnly: publicOnly, access: access)
        }
        if publicOnly, !node.isPublic { return [] }
        guard let kind = listedKinds[node.kindName], let name = name(of: node) else { return [] }
        let access: Access = access == .public && !node.isPublic ? .private : access
        return [Declaration(
            kind: kind,
            header: header(of: node, source: source),
            access: access,
            members: declarations(of: node.children, source: source, publicOnly: publicOnly, access: access),
            name: kind == .initializer ? nil : name
        )]
    }

    /// The name a declaration is matched and filtered by: its spelling, and for an Objective-C
    /// category the class it extends — a class extension (`@interface Foo ()`) has no spelling of
    /// its own, and a category's members belong to the class, not to the category's label.
    private static func name(of node: ClangNode) -> String? {
        if node.kindName == "ObjCCategoryDecl" || node.kindName == "ObjCCategoryImplDecl" {
            let extended = node.children.first { $0.kindName == "ObjCClassRef" }?.spelling ?? ""
            return extended.isEmpty ? (node.spelling.isEmpty ? nil : node.spelling) : extended
        }
        return node.spelling.isEmpty ? nil : node.spelling
    }

    /// The declaration's signature.
    ///
    /// C and C++ spell it up to the body's brace: taking the first line instead would report a
    /// template as `template <typename T>` and name no type at all. Objective-C needs more bounds
    /// than the brace — `@implementation Foo` opens no brace of its own and is followed by its
    /// methods — so there it ends at the first of: the brace, the first member, `@end`. A header
    /// written over several lines (a protocol list, a method's keywords) is read whole, with its
    /// comments and preprocessor lines left out.
    static func header(of node: ClangNode, source: Data?) -> String {
        let fallback = "\(listedKinds[node.kindName]?.rawValue ?? "") \(node.spelling)"
            .trimmingCharacters(in: .whitespaces)
        guard let source, node.startOffset < node.endOffset, node.endOffset <= source.count else { return fallback }

        var end = node.endOffset
        if node.kindName.hasPrefix("ObjC") {
            let firstMember = node.children
                .filter { listedKinds[$0.kindName] != nil && $0.startOffset > node.startOffset }
                .map(\.startOffset).min()
            if let firstMember, firstMember < end { end = firstMember }
            if let range = source[node.startOffset..<end].firstRange(of: Data("@end".utf8)) {
                end = range.lowerBound
            }
        }
        let text = String(decoding: source[node.startOffset..<end], as: UTF8.self)
        let signature = withoutComments(String(text.prefix { $0 != "{" }))
        let collapsed = signature
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "; {"))
        return collapsed.isEmpty ? fallback : collapsed
    }

    /// Text without `//` and `/* */` comments and without preprocessor lines.
    private static func withoutComments(_ text: String) -> String {
        var result = "", index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("//") {
                index = rest.firstIndex(where: \.isNewline) ?? text.endIndex
            } else if rest.hasPrefix("/*") {
                index = rest.range(of: "*/").map(\.upperBound) ?? text.endIndex
                result.append(" ")
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }
}
