import Foundation

/// The public surface of a package: only `public` declarations and their `public` members.
/// Computed syntactically with SwiftSyntax, without a build.
public enum PublicAPI {
    /// Structured summaries of the public surface — for `--json`.
    /// `type` filters top-level declarations by name (`api --type X`); it may return several
    /// declarations with that name across different files.
    public static func summaries(projectRoot: String, package: String?, type: String? = nil, cache: SourceParseCache = SourceParseCache()) -> [FileSummary] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let store = DeclarationCache.makeStore()
        return SwiftSources.files(under: root, includeTests: false)
            .filter { $0.lastPathComponent != "Package.swift" }
            .compactMap { url -> FileSummary? in
                let relative = SwiftSources.relativePath(of: url, root: root)
                let packageName = SwiftSources.package(for: relative)
                if let package, packageName != package { return nil }
                guard var declarations = DeclarationCache.declarations(for: url, parseCache: cache, store: store) else { return nil }
                if let type {
                    declarations = declarations.filter { $0.name == type }
                    if declarations.isEmpty { return nil }
                }
                return FileSummary(relativePath: relative, package: packageName, declarations: declarations)
            }
    }

    public static func generate(projectRoot: String, package: String?, type: String? = nil, cache: SourceParseCache = SourceParseCache()) -> String {
        render(summaries(projectRoot: projectRoot, package: package, type: type, cache: cache))
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

    /// Visible when the declaration is public, or is a type with public members (extensions included).
    private static func isVisible(_ declaration: Declaration) -> Bool {
        declaration.access == .public
            || (declaration.kind.isType && declaration.members.contains { $0.access == .public })
    }
}
