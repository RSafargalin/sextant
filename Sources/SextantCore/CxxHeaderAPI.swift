import Foundation

/// The public surface of a C++ header.
///
/// The compiler index cannot answer this: it records no access level, so a C++ header read from
/// the index would present its private members as public API — which is why `api` refused those
/// headers outright. clang does know, and a header's declarations are reachable through any
/// translation unit that includes it, with the flags that unit was built with. No flags are
/// invented for the header itself; a header no compiled source includes stays unanswered.
public enum CxxHeaderAPI {
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
                let declarations = ClangDeclarations.declarations(of: [child], source: sourceText(of: child.file),
                                                                  publicOnly: true, access: .public)
                guard !declarations.isEmpty else { continue }
                byHeader[child.file, default: []] += declarations
            }
        }
        return byHeader
    }

    private static func sourceText(of path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }
}
