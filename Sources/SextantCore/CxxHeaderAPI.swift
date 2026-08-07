import Foundation

/// The public surface of a C++ header.
///
/// The compiler index cannot answer this: it records no access level, so a C++ header read from
/// the index would present its private members as public API — which is why `api` refused those
/// headers outright. clang does know, and a header's declarations are reachable through any
/// translation unit that includes it, with the flags that unit was built with. No flags are
/// invented for the header itself; a header no compiled source includes stays unanswered.
public enum CxxHeaderAPI {
    /// Cursor kinds worth listing in a public surface, and the declaration kind each becomes.
    /// Anything absent — template parameters, base specifiers, access specifiers themselves —
    /// is not a declaration a caller can use.
    private static let listedKinds: [String: DeclarationKind] = [
        "StructDecl": .structKind, "UnionDecl": .structKind,
        "ClassDecl": .classKind, "ClassTemplate": .classKind,
        "EnumDecl": .enumKind, "EnumConstantDecl": .caseKind,
        "TypedefDecl": .typealiasKind, "TypeAliasDecl": .typealiasKind,
        "FunctionDecl": .function, "FunctionTemplate": .function, "CXXMethod": .function,
        "Constructor": .initializer, "CXXConstructor": .initializer,
        "FieldDecl": .property, "VarDecl": .property
    ]

    /// Public declarations per header, keyed by header path. Headers with no answer are simply
    /// absent — the caller reports them, rather than this pretending they are empty.
    public static func declarations(headers: Set<String>, commands: [CompileCommand],
                                    library: ClangLibrary) -> [String: [Declaration]] {
        guard !headers.isEmpty else { return [:] }
        var byHeader: [String: [Declaration]] = [:]
        for command in commands {
            guard byHeader.count < headers.count else { break }
            let remaining = headers.filter { byHeader[$0] == nil }
            guard let unit = try? ClangTranslationUnit.parse(
                file: command.file,
                arguments: CompilationDatabase.parseArguments(of: command),
                library: library,
                keepingHeaders: remaining
            ) else { continue }

            for child in unit.root.children where remaining.contains(child.file) {
                let declarations = declarationsOf(child, source: sourceText(of: child.file))
                guard !declarations.isEmpty else { continue }
                byHeader[child.file, default: []] += declarations
            }
        }
        return byHeader
    }

    /// Declarations of one top-level node, with its public members nested underneath. Private and
    /// protected members are left out — that is the whole reason this goes through clang rather
    /// than the index.
    private static func declarationsOf(_ node: ClangNode, source: Data?) -> [Declaration] {
        // A namespace has no surface of its own, but what it holds does.
        if node.kindName == "Namespace" {
            return node.children.flatMap { declarationsOf($0, source: source) }
        }
        guard node.isPublic, !node.spelling.isEmpty, let kind = listedKinds[node.kindName] else { return [] }
        return [Declaration(
            kind: kind,
            header: header(of: node, source: source),
            access: .public,
            members: node.children.flatMap { declarationsOf($0, source: source) }
        )]
    }

    /// The declaration's signature: its source up to the body, on one line. Taking the first line
    /// instead would report a template as `template <typename T>` and lose the type it declares.
    private static func header(of node: ClangNode, source: Data?) -> String {
        let fallback = "\(listedKinds[node.kindName]?.rawValue ?? "") \(node.spelling)"
            .trimmingCharacters(in: .whitespaces)
        guard let source, node.startOffset < node.endOffset, node.endOffset <= source.count else { return fallback }

        let text = String(decoding: source[node.startOffset..<node.endOffset], as: UTF8.self)
        let signature = text.prefix { $0 != "{" }
        let collapsed = signature
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        return collapsed.isEmpty ? fallback : collapsed
    }

    private static func sourceText(of path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }
}
