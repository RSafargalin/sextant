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
        compileDatabaseRoot: String? = nil,
        fileLimit: Int? = nil
    ) -> [FileSummary] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let store = DeclarationCache.makeStore()
        let parsed = SwiftSources.files(under: root, includeTests: false, limit: fileLimit)
            .filter { $0.lastPathComponent != "Package.swift" }
            .compactMap { url -> FileSummary? in
                let relative = SwiftSources.relativePath(of: url, root: root)
                let packageName = SwiftSources.package(for: relative, root: root)
                if let package, packageName != package { return nil }
                guard let declarations = DeclarationCache.declarations(for: url, parseCache: cache, store: store) else { return nil }
                return FileSummary(relativePath: relative, package: packageName, declarations: declarations)
            }
        // Filter here rather than only when rendering: `--json` serialises these summaries
        // straight through, and a surface that differs between the text and the machine
        // contract is two answers to one question.
        let swift = surface(of: parsed).compactMap { file -> FileSummary? in
            guard let type else { return file }
            let kept = file.declarations.filter { $0.name == type }
            return kept.isEmpty ? nil : FileSummary(relativePath: file.relativePath, package: file.package, declarations: kept)
        }

        let fromIndex = IndexDeclarations.publicHeaderSummaries(root: root, index: index, package: package, fileLimit: fileLimit)
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
        compileDatabaseRoot: String? = nil,
        fileLimit: Int? = nil,
        tokenBudget: Int? = nil
    ) -> String {
        render(summaries(projectRoot: projectRoot, package: package, type: type, cache: cache,
                         index: index, compileDatabaseRoot: compileDatabaseRoot, fileLimit: fileLimit),
               budget: tokenBudget)
    }

    /// `budget` is in tokens, as `map`'s is, and bounds the rendered surface. It has no default:
    /// a public surface is a contract, and cutting one by default would change what every existing
    /// answer says. When it is given, the header states how much was left out — a shorter surface
    /// that says so is an answer; a shorter surface that does not is a wrong one.
    static func render(_ summaries: [FileSummary], budget: Int? = nil) -> String {
        let packages = Dictionary(grouping: summaries, by: \.package)
        let budgetChars = budget.map(TokenBudget.characters)
        var body = ""
        var total = 0
        var omittedFiles = 0
        var omittedDeclarations = 0

        for packageName in packages.keys.sorted() {
            var packageBlock = ""
            for file in (packages[packageName] ?? []).sorted(by: { $0.relativePath < $1.relativePath }) {
                if let budgetChars, body.count + packageBlock.count > budgetChars {
                    omittedFiles += 1
                    omittedDeclarations += count(file.declarations)
                    continue
                }
                var fileBlock = ""
                for declaration in file.declarations where isVisible(declaration) {
                    render(declaration, depth: 1, into: &fileBlock, total: &total)
                }
                if !fileBlock.isEmpty { packageBlock += "\n\(file.relativePath)\n\(fileBlock)" }
            }
            if !packageBlock.isEmpty { body += "\n## \(packageName)\(packageBlock)" }
        }
        var header = "# Public API  •  declarations: \(total)"
        if omittedFiles > 0 {
            header += "  •  ⚠ truncated: \(omittedFiles) file(s) with \(omittedDeclarations) declaration(s) "
                + "left out by --budget \(budget ?? 0) tok — narrow with --package/--type/--scope, or raise it"
        }
        return header + body
    }

    /// A declaration and, for a type, its public members at every level of nesting: a public type
    /// nested two levels down is as much a part of the surface as one at the top.
    private static func render(_ declaration: Declaration, depth: Int, into block: inout String, total: inout Int) {
        block += String(repeating: "  ", count: depth) + "\(declaration.decoratedHeader)\(docSuffix(declaration))\n"
        total += 1
        guard declaration.kind.isType else { return }
        for member in declaration.members where member.access == .public {
            render(member, depth: depth + 1, into: &block, total: &total)
        }
    }

    /// Declarations including members — what a file contributes to the surface.
    private static func count(_ declarations: [Declaration]) -> Int {
        declarations.reduce(0) { $0 + 1 + count($1.members) }
    }

    private static func docSuffix(_ declaration: Declaration) -> String {
        guard let doc = declaration.docSummary else { return "" }
        return "  — " + String(doc.prefix(72))
    }

    /// The public surface of parsed files: what `isVisible` keeps, with only public members inside,
    /// less the conformances of types the files declare but do not make public. Files left with
    /// nothing are dropped.
    static func surface(of files: [FileSummary]) -> [FileSummary] {
        let hidden = nonPublicTypes(in: files)
        return files.compactMap { file in
            let declarations = file.declarations
                .filter { isVisible($0) && !conformsOnlyHidden($0, hidden: hidden) }
                .map(visibleMembers(of:))
            return declarations.isEmpty ? nil
                : FileSummary(relativePath: file.relativePath, package: file.package, declarations: declarations)
        }
    }

    /// Visible when the declaration is public, or is an extension carrying public members or
    /// adding a conformance.
    ///
    /// The rule used to be "a type with public members", which is wrong for every type but an
    /// extension: `struct Box { public let a: Int }` without its own modifier is internal, and
    /// nothing inside it is reachable from another module however its members are marked. An
    /// extension is the exception — it has no meaningful access level of its own, so what it adds
    /// decides. A conformance (`extension Foo: Equatable {}`) cannot carry an access modifier at
    /// all, and is visible wherever the type and the protocol are; `surface` drops the ones whose
    /// type or protocols the scanned files declare non-public.
    static func isVisible(_ declaration: Declaration) -> Bool {
        if declaration.access == .public { return true }
        guard declaration.kind == .extensionKind, declaration.access != .private else { return false }
        return declaration.members.contains { $0.access == .public } || !declaration.extensionParts.conformances.isEmpty
    }

    /// An extension whose only contribution is a conformance that cannot leave the module: of a
    /// type the files declare and never make public, or to protocols that all are.
    private static func conformsOnlyHidden(_ declaration: Declaration, hidden: Set<String>) -> Bool {
        guard declaration.kind == .extensionKind, declaration.access != .public,
              !declaration.members.contains(where: { $0.access == .public }) else { return false }
        let parts = declaration.extensionParts
        if hidden.contains(typePath(parts.extendedType)) { return true }
        return !parts.conformances.isEmpty && parts.conformances.allSatisfy { hidden.contains(typePath($0)) }
    }

    /// Qualified names (`Outer.Inner`) of the types the files declare, none of whose declarations
    /// is reachable from another module.
    private static func nonPublicTypes(in files: [FileSummary]) -> Set<String> {
        var reachable: [String: Bool] = [:]
        func visit(_ declarations: [Declaration], prefix: String, parentPublic: Bool) {
            for declaration in declarations where declaration.kind.isType && declaration.kind != .extensionKind {
                let path = prefix.isEmpty ? declaration.name : "\(prefix).\(declaration.name)"
                let isPublic = parentPublic && declaration.access == .public
                reachable[path] = (reachable[path] ?? false) || isPublic
                visit(declaration.members, prefix: path, parentPublic: isPublic)
            }
        }
        for file in files { visit(file.declarations, prefix: "", parentPublic: true) }
        return Set(reachable.filter { !$0.value }.keys)
    }

    /// A type as written (`Foo<Int>`, `Outer.Inner`) reduced to its qualified name.
    private static func typePath(_ written: String) -> String {
        Declaration.topLevelPrefix(of: written, endingAt: "<").trimmingCharacters(in: .whitespaces)
    }

    /// The same rule applied inside a declaration. Without it the text answer and `--json` state
    /// two different surfaces: the renderer drops an internal method of a public type, and the
    /// machine contract carried it through — measured on Alamofire, where `--json` listed internal
    /// initialisers and helpers as public API.
    ///
    /// A member is part of the surface only if it is public itself: a nested type declared
    /// internal inside a public one is unreachable from another module whatever its own members
    /// say, which is why the extension exception does not apply here.
    static func visibleMembers(of declaration: Declaration) -> Declaration {
        guard !declaration.members.isEmpty else { return declaration }
        return declaration.with(members: declaration.members.filter { $0.access == .public }.map(visibleMembers(of:)))
    }
}
