import Foundation

/// Declarations for source files the Swift parser does not handle, read from the compiler index
/// rather than from a second parser. The index store is written by the whole clang family, so
/// Objective-C, C and C++ declarations are already in it — putting them on the repository map
/// costs a lookup, not a grammar.
///
/// This deliberately does **not** replace the Swift path. The index carries no visibility
/// information (`SymbolProperty` describes generics and unit tests, not `public`), while the map
/// filters on access level, so SwiftSyntax stays the source of truth for Swift. Index-derived
/// declarations are marked `.internal`: that puts them on the map, and keeps them out of `api`,
/// which promises a verified public surface and must not be handed a guess.
public enum IndexDeclarations {
    /// Extensions the Swift parser does not cover but the compiler index does.
    public static let clangExtensions = ["m", "mm", "c", "cc", "cpp", "cxx", "h", "hpp", "hh"]

    /// Header extensions. A declaration is normally repeated in the header and the file that
    /// implements it; listing both doubles the map for no new information.
    static let headerExtensions: Set<String> = ["h", "hpp", "hh"]

    /// Per-file summaries for non-Swift sources under the root. Empty without an index — the
    /// syntactic commands must keep working on a machine with no toolchain at all.
    public static func summaries(root: URL, index: FileSymbolIndex?, includeTests: Bool) -> [FileSummary] {
        guard let index else { return [] }
        let summaries = SwiftSources.files(under: root, includeTests: includeTests, extensions: clangExtensions)
            .compactMap { url -> FileSummary? in
                let declarations = index.declarations(inFile: url.path)
                guard !declarations.isEmpty else { return nil }
                let relative = SwiftSources.relativePath(of: url, root: root)
                return FileSummary(
                    relativePath: relative,
                    package: SwiftSources.package(for: relative),
                    declarations: declarations
                )
            }
        return withoutHeaderDuplicates(summaries)
    }

    /// Drops from headers whatever an implementation file already shows. A declaration that
    /// exists only in a header — a C API implemented elsewhere, or none at all — is kept: it is
    /// the only place the reader could learn about it.
    static func withoutHeaderDuplicates(_ summaries: [FileSummary]) -> [FileSummary] {
        let implemented = Set(
            summaries
                .filter { !headerExtensions.contains(URL(fileURLWithPath: $0.relativePath).pathExtension) }
                .flatMap { $0.declarations.map { "\($0.kind.rawValue):\($0.header)" } }
        )
        return summaries.compactMap { summary in
            guard headerExtensions.contains(URL(fileURLWithPath: summary.relativePath).pathExtension) else { return summary }
            let kept = summary.declarations.filter { !implemented.contains("\($0.kind.rawValue):\($0.header)") }
            return kept.isEmpty ? nil : FileSummary(relativePath: summary.relativePath, package: summary.package, declarations: kept)
        }
    }
}

/// Reading a file's declarations out of the index. Separate from `SemanticIndex` because this
/// asks about a file rather than a symbol, and only the map needs it.
public protocol FileSymbolIndex {
    /// Declarations a file contributes. `languages`, when given, keeps only symbols the compiler
    /// recorded as coming from those languages — the index knows which, so `api` need not guess
    /// from a file extension.
    func declarations(inFile path: String, languages: Set<SourceLanguage>?) -> [Declaration]
}

public extension FileSymbolIndex {
    func declarations(inFile path: String) -> [Declaration] { declarations(inFile: path, languages: nil) }
}

/// The languages the compiler index distinguishes.
public enum SourceLanguage: String, Sendable, Hashable {
    case c, cxx, objc, swift
}

// MARK: - Reading declarations out of a store

extension IndexStore: FileSymbolIndex {
    /// Declarations a file contributes, as the compiler recorded them. Locals are dropped, and a
    /// symbol appearing both as a header declaration and as a definition is counted once.
    public func declarations(inFile path: String, languages: Set<SourceLanguage>? = nil) -> [Declaration] {
        var seen = Set<String>()
        var result: [Declaration] = []
        for symbol in database.symbols(inFilePath: path) where !symbol.properties.contains(.local) {
            if let languages, let language = SourceLanguage(rawValue: "\(symbol.language)"), !languages.contains(language) { continue }
            guard let kind = IndexDeclarations.declarationKind(for: "\(symbol.kind)") else { continue }
            guard seen.insert("\(kind.rawValue):\(symbol.name)").inserted else { continue }
            result.append(Declaration(kind: kind, header: "\(kind.rawValue) \(symbol.name)", access: .internal))
        }
        return result.sorted { $0.header < $1.header }
    }
}

extension IndexStoreSet: FileSymbolIndex {
    /// The union across stores: a file can be compiled by more than one of them.
    public func declarations(inFile path: String, languages: Set<SourceLanguage>? = nil) -> [Declaration] {
        var seen = Set<String>()
        var result: [Declaration] = []
        for declaration in stores.flatMap({ $0.declarations(inFile: path, languages: languages) })
        where seen.insert("\(declaration.kind.rawValue):\(declaration.header)").inserted {
            result.append(declaration)
        }
        return result.sorted { $0.header < $1.header }
    }
}

extension IndexDeclarations {
    /// Public surface of the non-Swift targets: whatever their public headers declare.
    ///
    /// In SwiftPM a target's public headers live in `include/`, and that directory *is* the
    /// module map's answer to "what does this target expose" — so this is the layout's own
    /// definition of public, not a guess about where headers happen to sit.
    ///
    /// C++ is deliberately excluded. A C++ header declares private members alongside public
    /// ones, and the index carries no access level, so listing them would present private
    /// members as public API — a confident wrong answer, which is worse than an absent one.
    /// `skippedCxxHeaders` reports how many were left out so the omission is never silent.
    public static func publicHeaderSummaries(
        root: URL,
        index: FileSymbolIndex?,
        package: String?
    ) -> (summaries: [FileSummary], skippedCxxHeaders: Int) {
        guard let index else { return ([], 0) }
        var summaries: [FileSummary] = []
        var skipped = 0
        for url in SwiftSources.files(under: root, includeTests: false, extensions: Array(headerExtensions)) {
            guard url.pathComponents.contains("include") else { continue }
            let relative = SwiftSources.relativePath(of: url, root: root)
            let packageName = SwiftSources.package(for: relative)
            if let package, packageName != package { continue }

            if !index.declarations(inFile: url.path, languages: [.cxx]).isEmpty,
               index.declarations(inFile: url.path, languages: [.c, .objc]).isEmpty {
                skipped += 1
                continue
            }
            let declarations = index.declarations(inFile: url.path, languages: [.c, .objc])
                .map { Declaration(kind: $0.kind, header: $0.header, access: .public) }
            guard !declarations.isEmpty else { continue }
            summaries.append(FileSummary(relativePath: relative, package: packageName, declarations: declarations))
        }
        return (summaries, skipped)
    }

    /// Maps an index symbol kind onto the declaration model. Kinds with no counterpart — modules,
    /// namespaces, parameters — are dropped rather than forced into one.
    static func declarationKind(for indexKind: String) -> DeclarationKind? {
        switch indexKind {
        case "class": return .classKind
        case "struct": return .structKind
        case "enum": return .enumKind
        case "protocol": return .protocolKind
        case "typealias": return .typealiasKind
        case "enumConstant": return .caseKind
        case "function", "instanceMethod", "classMethod", "staticMethod", "constructor":
            return .function
        case "variable", "field", "instanceProperty", "classProperty", "staticProperty":
            return .property
        default: return nil
        }
    }
}
