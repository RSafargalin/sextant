import Foundation

/// The public surface of a package: only `public` declarations and their `public` members.
/// Computed syntactically with SwiftSyntax, without a build.
public enum PublicAPI {
    /// Structured summaries of the public surface — for `--json`.
    /// `type` filters top-level declarations by name (`api --type X`); it may return several
    /// declarations with that name across different files.
    /// Public surface. `index`, when given, adds the non-Swift targets: their public headers,
    /// read from the compiler index. Without it the result is exactly what it was before.
    /// `compileDatabaseRoot` is where the C++ compile flags are looked up; it differs from
    /// `projectRoot` when `--scope` narrows the surface to a subdirectory.
    public static func summaries(
        projectRoot: String,
        package: String?,
        type: String? = nil,
        cache: SourceParseCache = SourceParseCache(),
        index: FileSymbolIndex? = nil,
        compileDatabaseRoot: String? = nil
    ) -> [FileSummary] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let store = DeclarationCache.makeStore()
        let swift = SwiftSources.files(under: root, includeTests: false)
            .filter { $0.lastPathComponent != "Package.swift" }
            .compactMap { url -> FileSummary? in
                let relative = SwiftSources.relativePath(of: url, root: root)
                let packageName = SwiftSources.package(for: relative)
                if let package, packageName != package { return nil }
                guard var declarations = DeclarationCache.declarations(for: url, parseCache: cache, store: store) else { return nil }
                // Filter here rather than only when rendering: `--json` serialises these summaries
                // straight through, and a surface that differs between the text and the machine
                // contract is two answers to one question.
                declarations = declarations.filter(isVisible)
                if declarations.isEmpty { return nil }
                if let type {
                    declarations = declarations.filter { $0.name == type }
                    if declarations.isEmpty { return nil }
                }
                return FileSummary(relativePath: relative, package: packageName, declarations: declarations)
            }

        let fromIndex = IndexDeclarations.publicHeaderSummaries(root: root, index: index, package: package)
        var headers = fromIndex.summaries
        // C++ headers carry no access level in the index, so they are read through clang instead.
        headers += IndexDeclarations.cxxHeaderSummaries(fromIndex.cxxHeaders, root: root,
                                                        compileDatabaseRoot: compileDatabaseRoot ?? projectRoot).summaries
        if let type {
            headers = headers.compactMap { summary in
                let kept = summary.declarations.filter { $0.name == type }
                return kept.isEmpty ? nil : FileSummary(relativePath: summary.relativePath, package: summary.package, declarations: kept)
            }
        }
        return swift + headers
    }

    public static func generate(
        projectRoot: String,
        package: String?,
        type: String? = nil,
        cache: SourceParseCache = SourceParseCache(),
        index: FileSymbolIndex? = nil,
        compileDatabaseRoot: String? = nil
    ) -> String {
        render(summaries(projectRoot: projectRoot, package: package, type: type, cache: cache,
                         index: index, compileDatabaseRoot: compileDatabaseRoot))
    }

    static func render(_ summaries: [FileSummary]) -> String {
        let packages = Dictionary(grouping: summaries, by: \.package)
        var body = ""
        var total = 0

        for packageName in packages.keys.sorted() {
            var packageBlock = ""
            for file in (packages[packageName] ?? []).sorted(by: { $0.relativePath < $1.relativePath }) {
                var fileBlock = ""
                for declaration in file.declarations where isVisible(declaration) {
                    fileBlock += "  \(declaration.decoratedHeader)\(docSuffix(declaration))\n"
                    total += 1
                    if declaration.kind.isType {
                        for member in declaration.members where member.access == .public {
                            fileBlock += "    \(member.decoratedHeader)\(docSuffix(member))\n"
                            total += 1
                        }
                    }
                }
                if !fileBlock.isEmpty { packageBlock += "\n\(file.relativePath)\n\(fileBlock)" }
            }
            if !packageBlock.isEmpty { body += "\n## \(packageName)\(packageBlock)" }
        }
        return "# Public API  •  declarations: \(total)\(body)"
    }

    private static func docSuffix(_ declaration: Declaration) -> String {
        guard let doc = declaration.docSummary else { return "" }
        return "  — " + String(doc.prefix(72))
    }

    /// Visible when the declaration is public, or is an extension carrying public members.
    ///
    /// The rule used to be "a type with public members", which is wrong for every type but an
    /// extension: `struct Box { public let a: Int }` without its own modifier is internal, and
    /// nothing inside it is reachable from another module however its members are marked. An
    /// extension is the exception — it has no meaningful access level of its own, so the members
    /// decide. Listing an internal type as public surface misstates the contract in the one
    /// command whose whole purpose is to state it.
    static func isVisible(_ declaration: Declaration) -> Bool {
        if declaration.access == .public { return true }
        return declaration.kind == .extensionKind && declaration.members.contains { $0.access == .public }
    }
}
