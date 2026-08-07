import Foundation

/// Structural search over Objective-C, C and C++, matching clang cursors.
///
/// The pattern is compiled **inside the file being searched**, appended to it through an in-memory
/// overlay. Compiling it on its own does not work: clang resolves an Objective-C message against
/// the selectors it knows, and a selector the pattern's own translation unit has never seen comes
/// back as an error with an empty name — the pattern would lose the very thing it searches for.
/// Inside the file, the selector is known exactly where a match could exist, the flags are the
/// file's own, and one parse serves both sides.
///
/// A pattern that does not compile in a file is reported for that file. It is never counted as
/// "no matches", which would be a confident answer about a question that was never asked.
public struct ClangPatternSearch {
    public enum Failure: Error, CustomStringConvertible {
        case emptyPattern
        case variadicNotSupported
        case patternNotCompiled(file: String, diagnostics: [String])

        public var description: String {
            switch self {
            case .emptyPattern:
                return "empty pattern"
            case .variadicNotSupported:
                return "$$$ is not supported for Objective-C, C and C++ yet — use $X for each argument"
            case .patternNotCompiled(let file, let diagnostics):
                let reason = diagnostics.first.map { ": \($0.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? ""
                return "the pattern does not compile in \(file)\(reason)"
            }
        }
    }

    /// A metavariable has to be given a type before clang will parse the pattern, and no one type
    /// fits every language: `id` does not exist outside Objective-C, `void *` breaks C++ overload
    /// resolution, and `int` cannot stand in for an object. So the pattern is compiled several
    /// times over — once per candidate type — inside a single parse, and the first probe that
    /// yields a usable tree is the pattern. The probes are function-local, so they cannot collide.
    private struct Probe {
        let name: String
        /// The macro that must be defined for this probe to be valid; nil means every language.
        let availability: String?
        let preamble: String
        let type: String
    }

    private static let probes = [
        Probe(name: "objc", availability: "__OBJC__", preamble: "", type: "id"),
        Probe(name: "int", availability: nil, preamble: "", type: "int"),
        Probe(name: "pointer", availability: nil, preamble: "", type: "void *"),
        Probe(name: "cxx", availability: "__cplusplus",
              preamble: "struct SextantAnyValue { template<class T> operator T() const; };",
              type: "SextantAnyValue")
    ]

    private let statement: String
    private let sentinelNames: [String]
    private let sentinels: Set<String>

    public init(pattern: String) throws {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyPattern }

        let substitution = Metavariable.substitute(trimmed)
        guard substitution.variadic.isEmpty else { throw Failure.variadicNotSupported }

        sentinelNames = substitution.singleByName.keys.sorted()
        sentinels = Set(sentinelNames)
        statement = substitution.text.hasSuffix(";") ? substitution.text : substitution.text + ";"
    }

    /// The probe functions for this pattern, named after its position so that several patterns
    /// can share one parse — which is what lets `lint` read a file once for all of its rules.
    private func probeSource(position: Int) -> String {
        Self.probes.map { probe in
            let declarations = sentinelNames.map { "\(probe.type) \($0);" }.joined(separator: " ")
            let body = "static void \(Self.wrapperName(position: position, probe: probe.name))(void) "
                + "{ \(probe.preamble) \(declarations) \(statement) }"
            guard let availability = probe.availability else { return body }
            return "#if defined(\(availability))\n\(body)\n#endif"
        }.joined(separator: "\n")
    }

    private static func wrapperName(position: Int, probe: String) -> String {
        "sextant_probe_\(position)_\(probe)"
    }

    /// Matches in one file, compiled with the flags it was built with.
    public func search(file: String, arguments: [String], library: ClangLibrary) throws -> [StructuralMatch] {
        try Self.searchAll([self], file: file, arguments: arguments, library: library).map { $0.match }
    }

    /// Matches for several patterns in a single parse. Every pattern is appended to the file as
    /// its own set of probes, so reading a file costs one parse regardless of how many patterns
    /// are being looked for.
    ///
    /// A pattern that does not compile in this file is not an error for the others: it is left
    /// out of the results and reported through `notCompiled`.
    public static func searchAll(_ searches: [ClangPatternSearch], file: String, arguments: [String],
                                 library: ClangLibrary) throws -> [(index: Int, match: StructuralMatch)] {
        try searchAll(searches, file: file, arguments: arguments, library: library, notCompiled: nil)
    }

    public static func searchAll(_ searches: [ClangPatternSearch], file: String, arguments: [String],
                                 library: ClangLibrary,
                                 notCompiled: ((Int, [String]) -> Void)?) throws -> [(index: Int, match: StructuralMatch)] {
        guard !searches.isEmpty, let sourceData = FileManager.default.contents(atPath: file) else { return [] }
        let source = String(decoding: sourceData, as: UTF8.self)
        // Appended, never inserted: the file's own offsets stay exactly as they are on disk, so a
        // match reports the position a reader would find.
        let overlay = source + "\n" + searches.enumerated()
            .map { $0.element.probeSource(position: $0.offset) }
            .joined(separator: "\n") + "\n"
        let overlayData = Data(overlay.utf8)

        let unit = try ClangTranslationUnit.parse(file: file, arguments: arguments, library: library, overlay: overlay)
        let wrappers = Self.probeWrappers(in: unit.root)
        // The diagnostics that matter are the ones raised inside the appended text; errors the
        // file already had are the build's business, not the search's.
        let probeErrors = unit.errors(in: sourceData.count..<overlayData.count).map { $0.text }

        var roots: [(index: Int, node: ClangNode)] = []
        for (position, search) in searches.enumerated() {
            if let root = search.patternRoot(position: position, wrappers: wrappers, errors: unit.errors) {
                roots.append((position, root))
            } else {
                notCompiled?(position, probeErrors.isEmpty ? unit.errors.map { $0.text } : probeErrors)
            }
        }
        guard !roots.isEmpty else {
            throw Failure.patternNotCompiled(file: file,
                                             diagnostics: probeErrors.isEmpty ? unit.errors.map { $0.text } : probeErrors)
        }

        let sourceLength = sourceData.count
        var results: [(index: Int, match: StructuralMatch)] = []
        func visit(_ node: ClangNode) {
            // Only the file's own nodes are candidates; the appended patterns are not matches for
            // themselves. A transparent wrapper is skipped as a candidate too: it unwraps to the
            // node below it, and both would report the same source range twice.
            if node.startOffset < sourceLength, !isTransparent(node) {
                for (index, root) in roots {
                    var bindings: [String: String] = [:]
                    if searches[index].matches(pattern: root, candidate: node, patternSource: overlayData,
                                               candidateSource: sourceData, bindings: &bindings) {
                        results.append((index, StructuralMatch(
                            line: node.line,
                            column: node.column,
                            text: text(of: node, in: sourceData).split(separator: "\n").first.map(String.init) ?? ""
                        )))
                    }
                }
            }
            node.children.forEach(visit)
        }
        visit(unit.root)
        return results
    }

    // MARK: - Matching

    /// The pattern expression: the first probe that compiled cleanly and left a usable tree.
    ///
    /// Both conditions are needed. A probe whose type does not fit can still leave a recovery
    /// tree behind, and matching against one would answer "no matches" for a pattern that never
    /// compiled — the exact confident wrong answer this layer exists to avoid. So a probe with an
    /// error anywhere inside it is passed over, as is one whose expression came back as clang's
    /// residue (`UnexposedExpr`, an unresolved overload).
    private func patternRoot(position: Int, wrappers: [String: ClangNode],
                             errors: [ClangTranslationUnit.Diagnostic]) -> ClangNode? {
        for probe in Self.probes {
            guard let wrapper = wrappers[Self.wrapperName(position: position, probe: probe.name)],
                  let body = wrapper.children.last(where: { $0.kindName == "CompoundStmt" }),
                  // The declarations of the metavariables come first; the pattern is the statement.
                  let statement = body.children.last(where: { $0.kindName != "DeclStmt" })
            else { continue }
            let probeRange = wrapper.startOffset..<max(wrapper.endOffset, wrapper.startOffset + 1)
            guard !errors.contains(where: { probeRange.contains($0.offset) }) else { continue }
            let candidate = Self.transparent(statement)
            guard Self.isUsable(candidate) else { continue }
            return candidate
        }
        return nil
    }

    /// Every probe function in the tree, by name.
    private static func probeWrappers(in root: ClangNode) -> [String: ClangNode] {
        var wrappers: [String: ClangNode] = [:]
        func collect(_ node: ClangNode) {
            if node.kindName == "FunctionDecl", node.spelling.hasPrefix("sextant_probe_") {
                wrappers[node.spelling] = node
            }
            node.children.forEach(collect)
        }
        collect(root)
        return wrappers
    }

    /// Whether a probe produced a real expression rather than clang's residue of a failed one.
    private static func isUsable(_ node: ClangNode) -> Bool {
        !["UnexposedExpr", "OverloadedDeclRef", "InvalidFile", "NoDeclFound", "UnexposedDecl"].contains(node.kindName)
            && node.startOffset < node.endOffset
    }

    /// Nodes clang inserts around an expression — implicit casts and parentheses come back as an
    /// `UnexposedExpr` with a single child. They differ between the pattern and the file for the
    /// same shape, so both sides are unwrapped before comparison.
    private static func transparent(_ node: ClangNode) -> ClangNode {
        var current = node
        while isTransparent(current) { current = current.children[0] }
        return current
    }

    private static func isTransparent(_ node: ClangNode) -> Bool {
        node.kindName == "UnexposedExpr" && node.children.count == 1
    }

    private func matches(pattern: ClangNode, candidate: ClangNode,
                         patternSource: Data, candidateSource: Data,
                         bindings: inout [String: String]) -> Bool {
        let pattern = Self.transparent(pattern)
        let candidate = Self.transparent(candidate)

        // A metavariable stands for any subtree; repeating a name requires the same text.
        if pattern.kindName == "DeclRefExpr", sentinels.contains(pattern.spelling) {
            let text = Self.text(of: candidate, in: candidateSource).trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous = bindings[pattern.spelling] { return previous == text }
            bindings[pattern.spelling] = text
            return true
        }

        guard pattern.kind == candidate.kind, pattern.spelling == candidate.spelling else { return false }

        // A leaf carries no name of its own — a literal, for instance — so its text decides.
        // Without this, `foo(1)` would match `foo(2)`.
        if pattern.children.isEmpty || candidate.children.isEmpty {
            guard pattern.children.count == candidate.children.count else { return false }
            return Self.text(of: pattern, in: patternSource).trimmingCharacters(in: .whitespacesAndNewlines)
                == Self.text(of: candidate, in: candidateSource).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard pattern.children.count == candidate.children.count else { return false }
        for (patternChild, candidateChild) in zip(pattern.children, candidate.children) {
            if !matches(pattern: patternChild, candidate: candidateChild,
                        patternSource: patternSource, candidateSource: candidateSource,
                        bindings: &bindings) { return false }
        }
        return true
    }

    /// The source text a node spans.
    static func text(of node: ClangNode, in source: Data) -> String {
        guard node.startOffset >= 0, node.endOffset <= source.count, node.startOffset < node.endOffset else { return "" }
        return String(decoding: source[node.startOffset..<node.endOffset], as: UTF8.self)
    }
}
