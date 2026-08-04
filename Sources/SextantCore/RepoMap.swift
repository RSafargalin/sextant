import Foundation

/// Builds a compact repository map under a token budget: for each Swift file, its types and
/// their public or internal API, grouped by package.
public enum RepoMap {
    public struct Options: Sendable {
        public var tokenBudget: Int
        public var includeTests: Bool

        public init(tokenBudget: Int = 6000, includeTests: Bool = false) {
            self.tokenBudget = tokenBudget
            self.includeTests = includeTests
        }
    }

    /// Per-file summaries of the project (structured data, not rendered) — for `--json`.
    public static func summaries(projectRoot: String, includeTests: Bool, cache: SourceParseCache = SourceParseCache()) -> [FileSummary] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let store = DeclarationCache.makeStore()
        return SwiftSources.files(under: root, includeTests: includeTests)
            .filter { $0.lastPathComponent != "Package.swift" }
            .compactMap { url -> FileSummary? in
                guard let declarations = DeclarationCache.declarations(for: url, parseCache: cache, store: store),
                      !declarations.isEmpty else { return nil }
                let relative = SwiftSources.relativePath(of: url, root: root)
                return FileSummary(relativePath: relative, package: SwiftSources.package(for: relative), declarations: declarations)
            }
    }

    /// Generates the textual map for a project root.
    public static func generate(projectRoot: String, options: Options = Options(), cache: SourceParseCache = SourceParseCache()) -> String {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let files = summaries(projectRoot: projectRoot, includeTests: options.includeTests, cache: cache)
        return render(files, projectName: root.lastPathComponent, budget: options.tokenBudget)
    }

    // MARK: - Rendering under a budget

    private static func render(_ summaries: [FileSummary], projectName: String, budget: Int) -> String {
        let totalDeclarations = summaries.reduce(0) { $0 + count($1.declarations) }
        let packages = Dictionary(grouping: summaries, by: \.package)
        let budgetChars = budget * 4

        var body = ""
        var compact = false
        var omittedFiles = 0

        for packageName in packages.keys.sorted() {
            let packageFiles = (packages[packageName] ?? []).sorted { $0.relativePath < $1.relativePath }
            body += "\n## \(packageName)\n"
            for file in packageFiles {
                if body.count > budgetChars * 3 / 2 { omittedFiles += 1; continue }
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
            if declaration.kind.isType {
                for member in declaration.members where member.access >= .internal {
                    lines += "    \(member.decoratedHeader)\n"
                }
            }
        }
        return lines
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
