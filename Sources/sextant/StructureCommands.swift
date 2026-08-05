import SextantCore
import Darwin
import Foundation

// MARK: - map / api / search / lint

/// The index, but only when the project actually has sources the Swift parser cannot read.
/// A pure-Swift project pays nothing: `map` stays a no-build command, and on a machine without
/// a toolchain it keeps working exactly as before.
private func clangIndex(root: String, arguments: [String], includeTests: Bool) -> FileSymbolIndex? {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let foreign = SwiftSources.files(under: rootURL, includeTests: includeTests,
                                     extensions: IndexDeclarations.clangExtensions)
    guard !foreign.isEmpty else { return nil }
    guard let index = openIndex(arguments, label: "map") else {
        // Never omit them in silence: a map that looks complete while skipping every
        // Objective-C and C file is exactly the quiet wrongness this tool exists to avoid.
        reportError("⚠ \(foreign.count) non-Swift file(s) are missing from the map: no index store. Build one with `sextant index`.")
        return nil
    }
    return index
}

func runMap(arguments: [String]) -> Int32 {
    let includeTests = arguments.contains("--include-tests")
    guard let root = scopedRoot(in: arguments) else { return 2 }
    guard withinScale(root, includeTests: includeTests, arguments: arguments) else { return 1 }
    if arguments.contains("--semantic") { return runSemanticMap(root: root, arguments: arguments) }
    if arguments.contains("--pagerank") { return runPageRankMap(root: root, arguments: arguments) }
    if arguments.contains("--json") {
        printJSON(RepoMap.summaries(projectRoot: root, includeTests: includeTests,
                                    index: clangIndex(root: root, arguments: arguments, includeTests: includeTests)))
        return 0
    }
    let budget = optionValue("--budget", in: arguments).flatMap(Int.init) ?? loadConfig(arguments)?.budget ?? 6000
    print(RepoMap.generate(projectRoot: root, options: .init(tokenBudget: budget, includeTests: includeTests),
                           index: clangIndex(root: root, arguments: arguments, includeTests: includeTests)))
    return 0
}

/// Type name from a header ("struct Box<T>: Foo"→"Box"; "extension A.B"→"B"; "struct `class`"→"class").
func typeName(fromHeader header: String) -> String {
    let afterKind = header.split(separator: " ", maxSplits: 1).dropFirst().first ?? ""
    let withoutInheritance = afterKind.split(separator: ":").first ?? afterKind     // drop ": Foo"
    let withoutGenerics = withoutInheritance.split(separator: "<").first ?? withoutInheritance
    let lastComponent = withoutGenerics.split(separator: ".").last ?? withoutGenerics // nested → last component
    return lastComponent.trimmingCharacters(in: CharacterSet(charactersIn: "` ")).trimmingCharacters(in: .whitespaces)
}

/// Hybrid map: public types (syntax) plus their usage count (index), in descending order.
func runSemanticMap(root: String, arguments: [String]) -> Int32 {
    guard let set = openIndex(arguments, label: "map --semantic") else { return 1 }

    struct RankedType: Encodable {
        let references: Int
        let kind: String
        let name: String
        let file: String
    }
    var ranked: [RankedType] = []
    for file in RepoMap.summaries(projectRoot: root, includeTests: false) {
        for declaration in file.declarations where declaration.kind.isType && declaration.access == .public {
            let name = typeName(fromHeader: declaration.header)
            guard !name.isEmpty else { continue }
            let references = set.lookup(name: name, query: .references).map { $0.references.count }.max() ?? 0
            ranked.append(RankedType(references: references, kind: declaration.kind.rawValue, name: name, file: file.relativePath))
        }
    }
    ranked.sort { $0.references != $1.references ? $0.references > $1.references : $0.name < $1.name }

    if arguments.contains("--json") { printJSON(ranked); return 0 }
    print("# Semantic map (public types by usage count)")
    for item in ranked {
        print("\(item.references)\t\(item.kind) \(item.name)  — \(item.file)")
    }
    return 0
}

/// PageRank map: files ranked by centrality — whose symbols are referenced the most.
func runPageRankMap(root: String, arguments: [String]) -> Int32 {
    guard let set = openIndex(arguments, label: "map --pagerank") else { return 1 }
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let summaries = RepoMap.summaries(projectRoot: root, includeTests: false)

    var nodes = Set(summaries.map { $0.relativePath })
    var edges: [(from: String, to: String)] = []
    for file in summaries {
        for declaration in file.declarations where declaration.kind.isType && declaration.access == .public {
            let name = typeName(fromHeader: declaration.header)
            guard !name.isEmpty else { continue }
            for hit in set.lookup(name: name, query: .references) {
                for reference in hit.references {
                    let refRelative = SwiftSources.relativePath(of: URL(fileURLWithPath: reference.path), root: rootURL)
                    nodes.insert(refRelative)
                    edges.append((from: refRelative, to: file.relativePath))
                }
            }
        }
    }
    let scores = PageRank.scores(nodes: Array(nodes), edges: edges)
    let ranked = summaries.sorted { (scores[$0.relativePath] ?? 0) > (scores[$1.relativePath] ?? 0) }

    func publicTypes(_ file: FileSummary) -> [String] {
        file.declarations.filter { $0.kind.isType && $0.access >= .internal }.map { $0.decoratedHeader }
    }

    if arguments.contains("--json") {
        struct RankedFile: Encodable { let score: Double; let file: String; let types: [String] }
        printJSON(ranked.map { RankedFile(score: scores[$0.relativePath] ?? 0, file: $0.relativePath, types: publicTypes($0)) })
        return 0
    }

    let budgetChars = (optionValue("--budget", in: arguments).flatMap(Int.init) ?? loadConfig(arguments)?.budget ?? 6000) * 4
    print("# PageRank map (files by centrality)")
    var chars = 0
    for file in ranked {
        let types = publicTypes(file)
        guard !types.isEmpty, chars <= budgetChars else { if chars > budgetChars { break }; continue }
        let block = "\n\(file.relativePath)\n" + types.map { "  \($0)" }.joined(separator: "\n") + "\n"
        print(block, terminator: "")
        chars += block.count
    }
    return 0
}

func runAPI(arguments: [String]) -> Int32 {
    guard let root = scopedRoot(in: arguments) else { return 2 }
    guard withinScale(root, includeTests: false, arguments: arguments) else { return 1 }
    let package = optionValue("--package", in: arguments)
    let type = optionValue("--type", in: arguments)
    let index = clangIndex(root: root, arguments: arguments, includeTests: false)
    // Public headers that only C++ declares are left out on purpose: the index has no access
    // level, so their private members would be presented as public API. Say how many, or the
    // surface looks complete when it is not.
    let skipped = IndexDeclarations.publicHeaderSummaries(
        root: URL(fileURLWithPath: root, isDirectory: true), index: index, package: package
    ).skippedCxxHeaders
    if skipped > 0 {
        reportError("⚠ \(skipped) C++ public header(s) omitted: the index carries no access level, so public and private members cannot be told apart.")
    }
    if arguments.contains("--json") {
        printJSON(PublicAPI.summaries(projectRoot: root, package: package, type: type, index: index))
        return 0
    }
    print(PublicAPI.generate(projectRoot: root, package: package, type: type, index: index))
    return 0
}

func runSearch(arguments: [String]) -> Int32 {
    guard let pattern = firstPositional(arguments) else {
        reportError("sextant search: expected <pattern>, for example sextant search 'try? $X.save()'")
        return 2
    }
    let engine: PatternSearch
    do {
        engine = try PatternSearch(pattern: pattern)
    } catch {
        reportError("sextant search: invalid pattern (\(error)). Supported: an expression using $X and $$$.")
        return 2
    }
    let includeTests = arguments.contains("--include-tests")
    guard let rootPath = scopedRoot(in: arguments) else { return 2 }
    guard withinScale(rootPath, includeTests: includeTests, arguments: arguments) else { return 1 }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let cache = SourceParseCache()
    // Result cache keyed by (file content hash + pattern): on an unchanged file with the same
    // pattern, parsing and matching are skipped. CachedHit holds the path-independent part.
    struct CachedHit: Codable { let line: Int; let column: Int; let text: String }
    let patternHash = ContentHash.of(pattern)
    let resultCache = PersistentCache<[CachedHit]>(namespace: "search-v1")
    var hits: [SearchHit] = []
    for file in SwiftSources.files(under: root, includeTests: includeTests) {
        let relative = SwiftSources.relativePath(of: file, root: root)
        guard let contentHash = ContentHash.ofFile(file.path) else { continue }
        let key = "\(contentHash)-\(patternHash)"

        let fileHits: [CachedHit]
        if let cached = resultCache.value(forKey: key) {
            fileHits = cached
        } else {
            guard let tree = cache.tree(atPath: file.path) else { continue }
            let found = engine.search(in: tree, fileName: relative).map { CachedHit(line: $0.line, column: $0.column, text: $0.text) }
            resultCache.set(found, forKey: key)
            fileHits = found
        }
        for hit in fileHits {
            hits.append(SearchHit(file: relative, line: hit.line, column: hit.column, text: hit.text))
        }
    }
    if arguments.contains("--json") { printJSON(hits); return 0 }
    for hit in hits { print("\(hit.file):\(hit.line):\(hit.column): \(hit.text)") }
    print(hits.isEmpty ? "No matches." : "\ntotal: \(hits.count)")
    return 0
}

func runLint(arguments: [String]) -> Int32 {
    let includeTests = arguments.contains("--include-tests")
    guard let root = scopedRoot(in: arguments) else { return 2 }
    guard withinScale(root, includeTests: includeTests, arguments: arguments) else { return 1 }
    let rules: [Rule]
    if let rulesPath = optionValue("--rules", in: arguments)
        ?? loadConfig(arguments)?.rulesPath(projectRoot: projectRoot(in: arguments)) {
        do { rules = try RuleEngine.loadRules(fromJSONAt: rulesPath) }
        catch { reportError("sextant lint: could not load rules from \(rulesPath): \(error)"); return 2 }
    } else {
        rules = RuleEngine.builtinRules
    }
    let violations = RuleEngine.run(rules: rules, projectRoot: root, includeTests: includeTests)
    if arguments.contains("--json") {
        printJSON(violations)
        return violations.isEmpty ? 0 : 1
    }
    guard !violations.isEmpty else {
        print("✅ No violations found (\(rules.count) rules)")
        return 0
    }
    for violation in violations.sorted(by: { ($0.ruleID, $0.file, $0.line) < ($1.ruleID, $1.file, $1.line) }) {
        print("[\(violation.ruleID)] \(violation.file):\(violation.line):\(violation.column)  \(violation.text)")
    }
    print("\n❌ violations: \(violations.count)")
    return 1
}
