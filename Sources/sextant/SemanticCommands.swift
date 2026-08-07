import SextantCore
import Darwin
import Foundation

// MARK: - Semantics (refs / defs / callers)

/// Cross-check of semantics against the structural signal. Zero semantic hits with non-zero
/// textual ones means a stale index or a resolver bug — always checked, because it is the most
/// valuable and least noisy case. With `--verify` it prints the comparison and, on a large
/// skew, hints that results may be incomplete. All of it on stderr; stdout and JSON are
/// untouched. When semantics come back empty, degrade to textual occurrences (the grep
/// equivalent) while marking clearly that this is NOT semantics. That removes the round trip
/// through a manual grep fallback: sextant answers instead.
func degradeToTextual(symbol: String, arguments: [String]) -> Int32 {
    let rootPath = projectRoot(in: arguments)
    let scan = IdentifierScan.matches(of: symbol, underRoot: URL(fileURLWithPath: rootPath, isDirectory: true), includeTests: true, limit: 40)
    guard !scan.matches.isEmpty else {
        print("Symbol '\(symbol)' not found (neither in the index nor textually).")
        return 0
    }
    let stale = indexIsStale(paths: resolveStorePaths(in: arguments), root: rootPath)
    let reason = stale ? "the index is stale — run `sextant index`" : "does not resolve semantically (a closure, a local, or another kind of symbol)"
    reportError("⚠ 0 semantic hits → textual occurrences (\(scan.matches.count)\(scan.truncated ? "+" : "")): \(reason)")
    let style = SymbolReport.Style.cli(compact: isCompact(arguments), referenceLimit: 40)
    SymbolReport.textual(symbol: symbol, matches: scan.matches, truncated: scan.truncated, style: style, path: shorten)
        .forEach { print($0) }
    return 0
}

/// `--verify`: prints semantics against the textual occurrence count. The zero-semantics case
/// is handled inline in runSemantic as a graceful degradation to textual occurrences.
func crossCheck(symbol: String, query: SymbolQuery, hits: [SymbolHit], arguments: [String]) {
    guard arguments.contains("--verify") else { return }
    let semanticCount = query == .definitions
        ? hits.filter { $0.definition != nil }.count
        : hits.reduce(0) { $0 + $1.references.count }
    let root = URL(fileURLWithPath: projectRoot(in: arguments), isDirectory: true)
    let scan = IdentifierScan.occurrences(of: symbol, underRoot: root, includeTests: true)
    let truncatedNote = scan.truncated ? " (scan truncated)" : ""
    let skew = scan.count > semanticCount * 3 ? "  (results may be incomplete)" : ""
    reportError("[cross-check: semantic \(semanticCount), textual \(scan.count)\(truncatedNote)]\(skew)")
}

func runSemantic(_ query: SymbolQuery, arguments: [String]) -> Int32 {
    guard let symbol = firstPositional(arguments) else {
        reportError("sextant: expected <symbol>, for example sextant refs MyType")
        return 2
    }
    guard let set = openIndex(arguments, label: "query") else { return 1 }
    let hits = set.lookup(name: symbol, query: query)
    let ordered = hits.sorted { left, right in
        left.references.count != right.references.count
            ? left.references.count > right.references.count
            : left.usr < right.usr
    }

    crossCheck(symbol: symbol, query: query, hits: ordered, arguments: arguments)

    if arguments.contains("--json") { printJSON(ordered); return 0 }
    if ordered.isEmpty { return degradeToTextual(symbol: symbol, arguments: arguments) }

    let fullPaths = arguments.contains("--full-paths")
    let format: (String) -> String = { fullPaths ? $0 : shorten($0) }
    let limit = max(0, optionValue("--limit", in: arguments).flatMap(Int.init) ?? 40)
    let reader = SourceLineReader()

    let rendering = SymbolReport.lookup(
        symbol: symbol,
        hits: ordered,
        query: query,
        style: .cli(compact: isCompact(arguments), referenceLimit: limit),
        path: format,
        snippet: { reader.line($0.line, inFile: $0.path) }
    )
    rendering.lines.forEach { print($0) }
    // The advisory goes to stderr: it is about choosing a command, not part of the answer.
    if let advisory = rendering.advisory { reportError(advisory) }
    return 0
}

// MARK: - context (everything about one symbol)

func runContext(arguments: [String]) -> Int32 {
    guard let symbol = firstPositional(arguments) else {
        reportError("sextant context: expected <symbol>, for example sextant context MyType")
        return 2
    }
    guard let set = openIndex(arguments, label: "context") else { return 1 }
    let sampleLimit = max(1, optionValue("--limit", in: arguments).flatMap(Int.init) ?? 10)
    guard let context = set.context(forName: symbol, sampleLimit: sampleLimit) else {
        print("Symbol '\(symbol)' not found in the index.")
        return 0
    }

    if arguments.contains("--json") { printJSON(context); return 0 }

    let reader = SourceLineReader()
    SymbolReport.context(
        context,
        sampleLimit: sampleLimit,
        style: .cli(compact: isCompact(arguments), referenceLimit: sampleLimit),
        path: shorten,
        snippet: { reader.line($0.line, inFile: $0.path) }
    ).forEach { print($0) }
    return 0
}

// MARK: - blast (impact analysis)

func runBlast(arguments: [String]) -> Int32 {
    guard let symbol = firstPositional(arguments) else {
        reportError("sextant blast: expected <symbol>, for example sextant blast MyRepository")
        return 2
    }
    guard let set = openIndex(arguments, label: "blast") else { return 1 }
    guard let radius = set.blastRadius(forName: symbol) else {
        print("Symbol '\(symbol)' not found in the index.")
        return 0
    }
    if arguments.contains("--json") { printJSON(radius); return 0 }

    print("── blast radius: \(radius.symbol) [\(radius.kind)]")
    print("   a change would touch: \(radius.affectedFiles.count) files · \(radius.referenceCount) usages · \(radius.callerCount) calls")
    if !radius.implementations.isEmpty {
        print("   implementations (also affected): \(radius.implementations.joined(separator: ", "))")
    }
    for file in radius.affectedFiles { print("     \(shorten(file))") }
    return 0
}

// MARK: - body (declaration body)

func runBody(arguments: [String]) -> Int32 {
    guard let symbol = firstPositional(arguments) else {
        reportError("sextant body: expected <symbol>, for example sextant body myFunction")
        return 2
    }
    guard let set = openIndex(arguments, label: "body") else { return 1 }
    let json = arguments.contains("--json")
    let limit = max(1, optionValue("--limit", in: arguments).flatMap(Int.init) ?? 10)
    let definitions = set.lookup(name: symbol, query: .definitions).compactMap { $0.definition }.prefix(limit)

    struct Body: Encodable {
        let file: String
        let line: Int
        let text: String
    }
    let bodies = definitions.compactMap { definition -> Body? in
        SourceBody.declaration(atLine: definition.line, inFile: definition.path)
            .map { Body(file: definition.path, line: definition.line, text: $0) }
    }

    // The JSON branch comes first: a --json consumer gets [] for a missing symbol, not prose.
    if json { printJSON(bodies); return 0 }
    guard !definitions.isEmpty else { print("Definition of '\(symbol)' not found (symbol outside the index? try `refs \(symbol)`)."); return 0 }
    guard !bodies.isEmpty else {
        print("Could not extract the body of '\(symbol)' (no declaration on the definition line).")
        return 0
    }
    for body in bodies {
        print("── \(shorten(body.file)):\(body.line)")
        print(body.text)
        print("")
    }
    return 0
}

// MARK: - construct (construction and injection sites)

func runConstruct(arguments: [String]) -> Int32 {
    guard let symbol = firstPositional(arguments) else {
        reportError("sextant construct: expected <type>, for example sextant construct MyType")
        return 2
    }
    guard let set = openIndex(arguments, label: "construct") else { return 1 }
    let limit = max(1, optionValue("--limit", in: arguments).flatMap(Int.init) ?? 40)
    let references = set.lookup(name: symbol, query: .references).flatMap { $0.references }
    let reader = SourceLineReader()

    struct Site: Encodable {
        let file: String
        let line: Int
        let text: String
        /// Confidence tier: a heuristic over the line text, not index semantics.
        let confidence = "heuristic"
    }
    // The shape of construction depends on the language of the file the reference is in:
    // Objective-C sends `alloc` or `new` to the class rather than calling the type.
    let sites = references.compactMap { location -> Site? in
        guard let text = reader.line(location.line, inFile: location.path),
              ConstructionSite.isConstruction(line: text, of: symbol, inFile: location.path) else { return nil }
        return Site(file: location.path, line: location.line, text: text)
    }.prefix(limit)

    let heuristic = Set(references.map { ConstructionSite.description(of: symbol, inFile: $0.path) })
        .sorted().joined(separator: ", ")
    let shown = heuristic.isEmpty ? ConstructionSite.description(of: symbol, inFile: "x.swift") : heuristic

    if arguments.contains("--json") { printJSON(Array(sites)); return 0 }
    guard !sites.isEmpty else {
        print("No construction sites found for '\(symbol)' (heuristic \(shown)).")
        return 0
    }
    print("── \(symbol): construction and injection (heuristic \(shown)), \(sites.count):")
    for site in sites { print("     \(shorten(site.file)):\(site.line)  \(site.text)") }
    return 0
}

// MARK: - changed (symbol-level git diff)

func runChanged(arguments: [String]) -> Int32 {
    let root = projectRoot(in: arguments)
    let from = optionValue("--from", in: arguments) ?? "HEAD"
    let to = optionValue("--to", in: arguments)

    // changes distinguishes "git failed" (nil → error) from "ran, found nothing" — a failure
    // is never disguised as an empty result.
    guard let changes = DeclarationDiff.changes(root: root, from: from, to: to) else {
        reportError("sextant changed: git failed (not a git repository, or an invalid ref: \(from)\(to.map { " / \($0)" } ?? "")).")
        return 1
    }
    if arguments.contains("--json") {
        struct FileChanges: Encodable {
            let file: String
            let added: [String]
            let removed: [String]
            let changed: [[String: String]]
        }
        struct Report: Encodable {
            let files: [FileChanges]
            let notDiffed: [String]
        }
        printJSON(Report(
            files: changes.files.map { change in
                FileChanges(
                    file: change.file,
                    added: change.result.added.map(\.decoratedHeader),
                    removed: change.result.removed.map(\.decoratedHeader),
                    changed: change.result.changed.map { ["old": $0.old.decoratedHeader, "new": $0.new.decoratedHeader] }
                )
            },
            notDiffed: changes.notDiffed
        ))
        return 0
    }
    if changes.files.isEmpty {
        print("No symbol-level changes (\(from) → \(to ?? "working tree")).")
    }
    for change in changes.files {
        print("\n\(change.file)")
        for declaration in change.result.added { print("  + \(declaration.decoratedHeader)") }
        for declaration in change.result.removed { print("  − \(declaration.decoratedHeader)") }
        for (old, new) in change.result.changed { print("  ~ \(old.decoratedHeader)  →  \(new.decoratedHeader)") }
    }
    printNotDiffed(changes.notDiffed)
    return 0
}

/// Names the changed files the diff could not read, so an answer covering only Swift is never
/// mistaken for an answer covering the whole change.
private func printNotDiffed(_ files: [String]) {
    guard !files.isEmpty else { return }
    print("\n⚠ Not compared (\(files.count)) — the symbol-level diff covers Swift only; C, C++ and Objective-C need the structural layer:")
    for file in files.prefix(10) { print("     \(file)") }
    if files.count > 10 { print("     … and \(files.count - 10) more") }
    print("  Use `git diff` for these.")
}

// MARK: - call hierarchy (transitive call graph)

struct CallNode: Encodable {
    let name: String
    let kind: String
    let file: String
    let line: Int
    let children: [CallNode]
}

func runHierarchy(arguments: [String]) -> Int32 {
    guard let symbol = firstPositional(arguments) else {
        reportError("sextant hierarchy: expected <symbol>, for example sextant hierarchy run --callees")
        return 2
    }
    guard let set = openIndex(arguments, label: "hierarchy") else { return 1 }
    let direction: CallDirection = arguments.contains("--callers") ? .callers : .callees
    let depth = max(1, optionValue("--depth", in: arguments).flatMap(Int.init) ?? 3)
    let breadth = 40

    var visited = Set<String>()
    func build(usr: String, name: String, kind: String, location: SourceLocation, remaining: Int) -> CallNode {
        var children: [CallNode] = []
        if remaining > 0, visited.insert(usr).inserted {
            for child in set.calls(ofUSR: usr, direction: direction).prefix(breadth) {
                children.append(build(usr: child.usr, name: child.name, kind: child.kind, location: child.location, remaining: remaining - 1))
            }
        }
        return CallNode(name: name, kind: kind, file: shorten(location.path), line: location.line, children: children)
    }

    let roots = set.resolveSymbols(forName: symbol)
    guard !roots.isEmpty else { print("Symbol '\(symbol)' not found in the index."); return 0 }
    let trees = roots.map { build(usr: $0.usr, name: $0.name, kind: $0.kind, location: $0.location, remaining: depth) }

    if arguments.contains("--json") { printJSON(trees); return 0 }
    func printNode(_ node: CallNode, indent: Int) {
        print(String(repeating: "  ", count: indent) + "\(node.name) [\(node.kind)]  \(node.file):\(node.line)")
        for child in node.children { printNode(child, indent: indent + 1) }
    }
    print("# call hierarchy (\(direction == .callers ? "← callers" : "→ callees"), depth \(depth))")
    for tree in trees { printNode(tree, indent: 0) }
    return 0
}

// MARK: - Related symbols (callees / impls)

func runRelated(_ query: RelationQuery, label: String, arguments: [String]) -> Int32 {
    guard let symbol = firstPositional(arguments) else {
        reportError("sextant \(label): expected <symbol>, for example sextant \(label) MyType")
        return 2
    }
    guard let set = openIndex(arguments, label: label) else { return 1 }
    let limit = max(1, optionValue("--limit", in: arguments).flatMap(Int.init) ?? 1000)
    let related = Array(set.related(toName: symbol, query: query).prefix(limit))
    if arguments.contains("--json") { printJSON(related); return 0 }
    guard !related.isEmpty else { print("Nothing found for '\(symbol)'."); return 0 }

    // Grouped by symbol, because the count in the header answers "how many callees", not "how
    // many call sites": a method called twice on one line was reported as two callees.
    var order: [String] = []
    var sites: [String: [RelatedSymbol]] = [:]
    for item in related {
        if sites[item.usr] == nil { order.append(item.usr) }
        sites[item.usr, default: []].append(item)
    }

    let reader = SourceLineReader()
    let siteCount = related.count
    let header = siteCount == order.count ? "\(order.count)" : "\(order.count) (\(siteCount) sites)"
    print("── \(symbol): \(header)")
    for usr in order {
        guard let group = sites[usr], let first = group.first else { continue }
        let snippet = reader.line(first.location.line, inFile: first.location.path).map { "  \($0)" } ?? ""
        print("   • \(first.name) [\(first.kind)]  \(shorten(first.location.path)):\(first.location.line)\(snippet)")
        for extra in group.dropFirst() {
            print("     also \(shorten(extra.location.path)):\(extra.location.line):\(extra.location.column)")
        }
    }
    return 0
}
