import Foundation

/// Builds a compact repository map under a token budget: for each Swift file, its types and
/// their public or internal API, grouped by package.
public enum RepoMap {
    public struct Options: Sendable {
        public var tokenBudget: Int
        /// How many files the map may read. Beyond it the answer is a prefix, and the header says so.
        public var fileLimit: Int?
        public var includeTests: Bool

        public init(tokenBudget: Int = 6000, includeTests: Bool = false, fileLimit: Int? = nil) {
            self.tokenBudget = tokenBudget
            self.includeTests = includeTests
            self.fileLimit = fileLimit
        }
    }

    /// Per-file summaries of the project (structured data, not rendered) — for `--json`.
    /// Per-file summaries. `index`, when given, adds files the Swift parser does not read —
    /// Objective-C, C, C++ — from the compiler index. Without it the result is exactly what it
    /// was before: the syntactic commands must keep working with no toolchain at all.
    public static func summaries(
        projectRoot: String,
        includeTests: Bool,
        cache: SourceParseCache = SourceParseCache(),
        index: FileSymbolIndex? = nil,
        fileLimit: Int? = nil
    ) -> [FileSummary] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let store = DeclarationCache.makeStore()
        let swift = SwiftSources.files(under: root, includeTests: includeTests, limit: fileLimit)
            .filter { $0.lastPathComponent != "Package.swift" }
            .compactMap { url -> FileSummary? in
                guard let declarations = DeclarationCache.declarations(for: url, parseCache: cache, store: store),
                      !declarations.isEmpty else { return nil }
                let relative = SwiftSources.relativePath(of: url, root: root)
                return FileSummary(relativePath: relative, package: SwiftSources.package(for: relative, root: root), declarations: declarations)
            }
        return swift + IndexDeclarations.summaries(root: root, index: index, includeTests: includeTests, fileLimit: fileLimit)
    }

    /// A public type as the semantic and PageRank maps rank it: its kind and the name a reference
    /// lookup asks the index for.
    public struct PublicType: Sendable, Equatable {
        public let kind: DeclarationKind
        public let name: String
        public let file: String
    }

    /// The public top-level types of the summaries, named by the declaration's own name — never
    /// recovered from its rendered header, which carries modifiers (`final class Box`) and generic
    /// clauses. A backticked name (`` `class` ``) is looked up as the identifier it spells.
    public static func publicTypes(in summaries: [FileSummary]) -> [PublicType] {
        summaries.flatMap { file in
            file.declarations.compactMap { declaration -> PublicType? in
                guard declaration.kind.isType, declaration.access == .public else { return nil }
                let name = declaration.name.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                return name.isEmpty ? nil : PublicType(kind: declaration.kind, name: name, file: file.relativePath)
            }
        }
    }

    /// Generates the textual map for a project root.
    public static func generate(
        projectRoot: String,
        options: Options = Options(),
        cache: SourceParseCache = SourceParseCache(),
        index: FileSymbolIndex? = nil
    ) -> String {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let files = summaries(projectRoot: projectRoot, includeTests: options.includeTests, cache: cache,
                              index: index, fileLimit: options.fileLimit)
        return render(files, projectName: root.lastPathComponent, budget: options.tokenBudget)
    }

    // MARK: - Rendering under a budget

    private static func render(_ summaries: [FileSummary], projectName: String, budget: Int) -> String {
        let totalDeclarations = summaries.reduce(0) { $0 + count($1.declarations) }
        let packages = Dictionary(grouping: summaries, by: \.package)
        let budgetChars = TokenBudget.characters(budget)
        let collapseLimit = budgetChars / 2 * 3

        var body = ""
        var compact = false
        var omittedFiles = 0

        for packageName in packages.keys.sorted() {
            let packageFiles = (packages[packageName] ?? []).sorted { $0.relativePath < $1.relativePath }
            body += "\n## \(packageName)\n"
            for file in packageFiles {
                if body.count > collapseLimit { omittedFiles += 1; continue }
                body += compact ? renderCompact(file) : renderFull(file)
                if body.count > budgetChars { compact = true }
            }
        }

        let mode = omittedFiles > 0 ? "truncated (\(omittedFiles) files omitted)"
            : compact ? "partial (details collapsed)" : "full"
        let header = """
        # Repository map: \(projectName)
        # packages: \(packages.count)  •  files: \(summaries.count)  •  declarations: \(totalDeclarations)  •  budget: \(budget) tok  •  mode: \(mode)
        """
        return header + body
    }

    private static func renderFull(_ file: FileSummary) -> String {
        var lines = "\n\(file.relativePath)\n"
        for declaration in file.declarations where declaration.access >= .internal {
            lines += "  \(declaration.decoratedHeader)\(docSuffix(declaration))\n"
            if declaration.kind.isType { renderMembers(of: declaration, depth: 2, into: &lines) }
        }
        return lines
    }

    /// The members of a type, and those of the types nested in it at every depth, each level
    /// indented one step further — what `--json` holds, so the text does not stop short of it.
    private static func renderMembers(of declaration: Declaration, depth: Int, into lines: inout String) {
        for member in declaration.members where member.access >= .internal {
            lines += String(repeating: "  ", count: depth) + "\(member.decoratedHeader)\n"
            if member.kind.isType { renderMembers(of: member, depth: depth + 1, into: &lines) }
        }
    }

    private static func renderCompact(_ file: FileSummary) -> String {
        let typeNames = file.declarations
            .filter { $0.kind.isType && $0.access >= .internal }
            .map { $0.decoratedHeader }
        guard !typeNames.isEmpty else { return "" }
        return "  \(file.relativePath): \(typeNames.joined(separator: "; "))\n"
    }

    /// A short doc summary as a trailing comment, truncated so it does not inflate the budget.
    private static func docSuffix(_ declaration: Declaration) -> String {
        guard let doc = declaration.docSummary else { return "" }
        return "  — " + String(doc.prefix(72))
    }

    private static func count(_ declarations: [Declaration]) -> Int {
        declarations.reduce(declarations.count) { $0 + count($1.members) }
    }
}
