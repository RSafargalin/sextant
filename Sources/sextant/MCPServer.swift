import Foundation
import SextantCore

// MARK: - MCP server (stdio, JSON-RPC 2.0)

private let indexUnavailable =
    "Index unavailable. Run `sextant index` (or `index --app`) — the semantic tools need an index store."

/// Runs the MCP server over stdio. A single client (Claude Code) means a sequential loop with
/// no concurrency hazards: the index is opened once and reused, keeping the cache warm.
/// stdout carries only JSON-RPC messages (newline-delimited); logs go to stderr.
private let indexNeedingMethods: Set<String> = ["tools/call", "resources/read", "completion/complete"]

func runMCP(arguments: [String]) -> Int32 {
    let project = projectRoot(in: arguments)
    var index = openIndex(arguments, label: "mcp", listen: true)
    if index == nil {
        logMCP("index unavailable at start-up — will try again once a store appears (build one with `sextant index`).")
    }
    var lastOpenSignature: String?   // store state of the last attempt — avoids spamming on a broken store
    var configWarned = false         // a broken .sextant.json is reported once per session

    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else { continue }
        var id = message["id"]
        if id is NSNull { id = nil }

        // The index may have been built DURING the session (the server started before
        // `sextant index`). Re-open when a store appears or is rebuilt — the signature changes.
        // No spamming when the store is broken and openIndex keeps returning nil.
        if index == nil, indexNeedingMethods.contains(method),
           let signature = storeSignature(in: arguments), signature != lastOpenSignature {
            lastOpenSignature = signature
            index = openIndex(arguments, label: "mcp", listen: true)
            if index != nil { logMCP("index appeared — opened, semantics available.") }
        }

        let context = makeToolContext(project: project, index: index, warnedInvalidConfig: &configWarned)
        handleMCP(method: method, id: id, params: message["params"] as? [String: Any] ?? [:], context: context)
    }
    return 0
}

/// Per-call environment: the root with `scope` from the config applied, the config itself, the
/// index, and a line reader. Assembled for EVERY incoming message, so edits to `.sextant.json`
/// and to sources are picked up without a restart, and the line cache does not outlive a
/// request (it would otherwise serve stale snippets and grow without bound).
private struct ToolContext {
    let project: String        // root with scope from the config applied
    let projectRoot: String    // root WITHOUT scope — for the tools' own scope arguments
    let scopeProblem: String?
    let config: ProjectConfig?
    let index: IndexStoreSet?
    let reader: SourceLineReader
}

private func makeToolContext(project: String, index: IndexStoreSet?, warnedInvalidConfig: inout Bool) -> ToolContext {
    var config: ProjectConfig?
    var configProblem: String?
    switch ProjectConfig.read(projectRoot: project) {
    case .missing:
        break
    case .loaded(let value):
        config = value
    case .invalid(let reason):
        // Writing to stderr alone is not enough (the agent does not see it): without the
        // config the scope is silently dropped and answers quietly widen to the whole project.
        configProblem = ".sextant.json could not be parsed (\(reason)) — scope and defaults were not applied"
        if !warnedInvalidConfig {
            logMCP(".sextant.json could not be parsed (\(reason)) — config defaults ignored.")
            warnedInvalidConfig = true
        }
    }

    var scoped = project
    var scopeProblem: String? = configProblem
    switch ProjectScope.resolve(root: project, scope: config?.scope) {
    case .resolved(let path):
        scoped = path
    case .outsideProject:
        scopeProblem = "scope '\(config?.scope ?? "")' from .sextant.json is outside the project"
    case .missingDirectory:
        scopeProblem = "scope '\(config?.scope ?? "")' from .sextant.json — directory does not exist"
    }

    return ToolContext(project: scoped, projectRoot: project, scopeProblem: scopeProblem,
                       config: config, index: index, reader: SourceLineReader())
}

/// Store signature — detects an index appearing or being rebuilt without retry spam.
private func storeSignature(in arguments: [String]) -> String? {
    IndexFreshness.signature(ofStores: resolveStorePaths(in: arguments))
}

private func logMCP(_ message: String) {
    FileHandle.standardError.write(Data("sextant mcp: \(message)\n".utf8))
}

private func emitMCP(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func resultMCP(id: Any?, _ result: [String: Any]) {
    guard let id else { return }
    emitMCP(["jsonrpc": "2.0", "id": id, "result": result])
}

private func errorMCP(id: Any?, code: Int, _ message: String) {
    guard let id else { return }
    emitMCP(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

private func handleMCP(method: String, id: Any?, params: [String: Any], context: ToolContext) {
    let index = context.index
    switch method {
    case "initialize":
        let version = (params["protocolVersion"] as? String) ?? "2025-06-18"
        resultMCP(id: id, [
            "protocolVersion": version,
            "capabilities": ["tools": [String: Any](), "resources": [String: Any](), "completions": [String: Any]()],
            "serverInfo": ["name": "sextant", "version": Sextant.version],
            "instructions": MCPTools.instructions()
        ])
    case "notifications/initialized", "notifications/cancelled":
        break
    case "ping":
        resultMCP(id: id, [:])
    case "tools/list":
        resultMCP(id: id, ["tools": MCPTools.definitions()])
    case "resources/list":
        resultMCP(id: id, ["resources": [
            ["uri": "sextant://repo_map", "name": "repo_map",
             "description": "Repository map: types by file, symbol-level.", "mimeType": "text/plain"]
        ]])
    case "resources/templates/list":
        resultMCP(id: id, ["resourceTemplates": [
            ["uriTemplate": "sextant://symbol/{name}", "name": "symbol_context",
             "description": "Everything about a symbol: definition, usages, callers, hierarchy.", "mimeType": "text/plain"]
        ]])
    case "resources/read":
        let uri = params["uri"] as? String ?? ""
        let resource = readResource(uri: uri, context: context)
        if resource.ok {
            resultMCP(id: id, ["contents": [["uri": uri, "mimeType": "text/plain", "text": resource.text]]])
        } else {
            errorMCP(id: id, code: -32002, resource.text)
        }
    case "completion/complete":
        index?.pollForChanges()
        let ref = params["ref"] as? [String: Any]
        let argument = params["argument"] as? [String: Any]
        // Complete ONLY the symbol name in the resource template; anything else returns empty.
        guard (ref?["type"] as? String) == "ref/resource",
              (ref?["uri"] as? String) == "sextant://symbol/{name}",
              (argument?["name"] as? String) == "name" else {
            resultMCP(id: id, ["completion": ["values": [String](), "hasMore": false]])
            break
        }
        let limit = 100
        let names = index?.symbolNames(matchingPrefix: (argument?["value"] as? String) ?? "", limit: limit) ?? []
        // No lying about completeness: total is omitted (an exact count is expensive), and
        // hasMore is set when the list was truncated.
        resultMCP(id: id, ["completion": ["values": names, "hasMore": names.count >= limit]])
    case "prompts/list":
        resultMCP(id: id, ["prompts": [Any]()])
    case "tools/call":
        index?.pollForChanges()              // pick up reindexing on a hot store
        SwiftSources.clearFileListMemo()     // fresh file list per call, so new files are seen
        let name = params["name"] as? String ?? ""
        let toolArgs = params["arguments"] as? [String: Any] ?? [:]
        let started = DispatchTime.now()
        let (text, isError) = callMCPTool(name: name, args: toolArgs, context: context)
        // Telemetry per CALL: otherwise an entire MCP session is one record, and the main
        // consumer — the agent — stays a blind spot in the usage statistics.
        Telemetry.record(
            command: "mcp:\(name)",
            argument: ["symbol", "type", "package", "pattern", "from"].compactMap { toolArgs[$0] as? String }.first,
            exitCode: isError ? 1 : 0,
            durationMs: Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000,
            timestamp: Date().timeIntervalSince1970
        )
        resultMCP(id: id, ["content": [["type": "text", "text": text]], "isError": isError])
    default:
        errorMCP(id: id, code: -32601, "Method not supported: \(method)")
    }
}

// MARK: - Tool dispatch

/// Tools that work over an area of the project rather than a symbol — they need a valid scope.
private let areaTools: Set<String> = ["repo_map", "structural_search", "lint", "api", "changed"]

/// Output cap: a long surface is truncated with an honest note — narrowing the query is
/// cheaper for the agent than receiving a wall of text.
private func capped(_ text: String, limit: Int = 24_000, hint: String) -> String {
    guard text.count > limit else { return text }
    let head = text.prefix(limit)
    let cut = head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? String(head)
    return cut + "\n… (output truncated at \(limit) characters — \(hint))"
}

private func callMCPTool(name: String, args: [String: Any], context: ToolContext) -> (String, Bool) {
    let index = context.index
    func symbol() -> String? { (args["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    // An invalid scope from the config is a refusal, not a silent count over the whole project.
    if let problem = context.scopeProblem, areaTools.contains(name) {
        return ("config: \(problem)", true)
    }

    switch name {
    case "context":
        guard let symbol = symbol() else { return ("the symbol parameter is required", true) }
        return contextText(symbol, index, reader: context.reader)

    case "body":
        guard let symbol = symbol() else { return ("the symbol parameter is required", true) }
        guard let set = index else { return (indexUnavailable, true) }
        let definitions = set.lookup(name: symbol, query: .definitions).compactMap { $0.definition }
        guard !definitions.isEmpty else { return ("definition not found: \(symbol) (symbol outside the index? try find_references)", true) }
        let blocks = definitions.compactMap { definition -> String? in
            SourceBody.declaration(atLine: definition.line, inFile: definition.path).map { "── \(shorten(definition.path)):\(definition.line)\n\($0)" }
        }
        return (blocks.isEmpty ? "could not extract the body: \(symbol)" : blocks.joined(separator: "\n\n"), false)

    case "blast_radius":
        guard let symbol = symbol() else { return ("the symbol parameter is required", true) }
        guard let set = index else { return (indexUnavailable, true) }
        guard let radius = set.blastRadius(forName: symbol) else { return ("symbol not found: \(symbol)", true) }
        var lines = ["blast radius: \(radius.symbol) [\(radius.kind)]",
                     "touches: \(radius.affectedFiles.count) files · \(radius.referenceCount) usages · \(radius.callerCount) calls"]
        if !radius.implementations.isEmpty { lines.append("implementations: " + radius.implementations.joined(separator: ", ")) }
        radius.affectedFiles.forEach { lines.append("  \(shorten($0))") }
        return (lines.joined(separator: "\n"), false)

    case "who_defines":
        return lookupText(symbol(), index, query: .definitions, project: context.project, reader: context.reader)
    case "find_references":
        return lookupText(symbol(), index, query: .references, project: context.project, reader: context.reader)
    case "find_callers":
        return lookupText(symbol(), index, query: .callers, project: context.project, reader: context.reader)

    case "list_implementations":
        guard let symbol = symbol() else { return ("the symbol parameter is required", true) }
        guard let set = index else { return (indexUnavailable, true) }
        let related = set.related(toName: symbol, query: .implementations, limit: 1000)
        guard !related.isEmpty else { return ("no implementations found: \(symbol)", false) }
        return (related.map { "\($0.name) [\($0.kind)]  \(shorten($0.location.path)):\($0.location.line)" }.joined(separator: "\n"), false)

    case "call_hierarchy":
        guard let symbol = symbol() else { return ("the symbol parameter is required", true) }
        guard let set = index else { return (indexUnavailable, true) }
        let direction: CallDirection = (args["direction"] as? String) == "callers" ? .callers : .callees
        let depth = max(1, (args["depth"] as? Int) ?? 3)
        let roots = set.resolveSymbols(forName: symbol)
        guard !roots.isEmpty else { return ("symbol not found: \(symbol)", true) }
        var visited = Set<String>()
        var lines: [String] = []
        func walk(_ usr: String, _ label: String, _ location: SourceLocation, _ remaining: Int, _ indent: Int) {
            lines.append(String(repeating: "  ", count: indent) + "\(label)  \(shorten(location.path)):\(location.line)")
            guard remaining > 0, visited.insert(usr).inserted else { return }
            for child in set.calls(ofUSR: usr, direction: direction).prefix(40) {
                walk(child.usr, "\(child.name) [\(child.kind)]", child.location, remaining - 1, indent + 1)
            }
        }
        for root in roots { walk(root.usr, "\(root.name) [\(root.kind)]", root.location, depth, 0) }
        return (lines.joined(separator: "\n"), false)

    case "repo_map":
        // The token budget is honoured (a field report found it being ignored); the default
        // comes from .sextant.json, as in the CLI. Clamped: a budget of 0 would collapse the map.
        let budget = max(500, (args["budget"] as? Int) ?? context.config?.budget ?? 4000)
        return (RepoMap.generate(projectRoot: context.project, options: .init(tokenBudget: budget, includeTests: false)), false)

    case "structural_search":
        guard let pattern = (args["pattern"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return ("the pattern parameter is required", true) }
        let engine: PatternSearch
        do { engine = try PatternSearch(pattern: pattern) }
        catch { return ("invalid pattern: \(error)", true) }
        let root = URL(fileURLWithPath: context.project, isDirectory: true)
        let cache = SourceParseCache()
        let scanLimit = max(1, context.config?.maxFiles ?? 8000)   // clamped: 0 or negative would disable search
        var lines: [String] = []
        var scanned = 0
        for file in SwiftSources.files(under: root, includeTests: false) {
            scanned += 1
            if scanned > scanLimit { lines.append("… (scanned \(scanLimit) files, search stopped — narrow the scope)"); break }
            guard let tree = cache.tree(atPath: file.path) else { continue }
            let relative = SwiftSources.relativePath(of: file, root: root)
            for match in engine.search(in: tree, fileName: relative) {
                lines.append("\(relative):\(match.line):\(match.column): \(match.text)")
            }
            if lines.count >= 200 { lines.append("… (first 200 shown)"); break }
        }
        // Objective-C, C and C++ go through clang, with the flags each file was built with.
        let cFamily = CFamilySearch.run(pattern: pattern, searchRoot: context.project,
                                        projectRoot: context.projectRoot, includeTests: false)
        lines += cFamily.hits.prefix(200).map { "\($0.file):\($0.line):\($0.column): \($0.text)" }
        if lines.isEmpty { lines.append("no matches") }
        lines += StructuralCoverage.configurationNote(targets: cFamily.targets)
        lines += StructuralCoverage.report(cFamily.unscanned)
        return (lines.joined(separator: "\n"), false)

    case "lint":
        // Rules from .sextant.json, as in the CLI (MCP used to know only the built-in set).
        let rules: [Rule]
        if let path = context.config?.rulesPath(projectRoot: context.projectRoot) {
            do { rules = try RuleEngine.loadRules(fromJSONAt: path) }
            catch { return ("could not load rules from .sextant.json (\(path)): \(error)", true) }
        } else {
            rules = RuleEngine.builtinRules
        }
        let outcome = RuleEngine.run(rules: rules, projectRoot: context.projectRoot, lintRoot: context.project,
                                     includeTests: false)
        let violations = outcome.violations
        let unscanned = StructuralCoverage.report(outcome.unscanned)
        guard !violations.isEmpty else {
            return ((["✅ no violations found (\(rules.count) rules)"] + unscanned).joined(separator: "\n"), false)
        }
        let lines = violations
            .sorted { ($0.ruleID, $0.file, $0.line) < ($1.ruleID, $1.file, $1.line) }
            .prefix(200)
            .map { "[\($0.ruleID)] \($0.file):\($0.line):\($0.column)  \($0.text)" }
        return ((lines + unscanned).joined(separator: "\n"), false)

    case "api":
        var root = context.project
        // An explicit scope REPLACES the one from the config (like `--scope` in the CLI), so it
        // is resolved from the project root: composing them would give "Sources/Sources" and
        // reject a perfectly valid request.
        if let scope = (args["scope"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            root = context.projectRoot
            switch ProjectScope.resolve(root: root, scope: scope) {
            case .resolved(let path): root = path
            case .outsideProject: return ("scope '\(scope)' is outside the project", true)
            case .missingDirectory: return ("scope '\(scope)' — directory does not exist", true)
            }
        }
        // The index and the compile database are passed here as they are in the CLI: without them
        // the answer would silently cover Swift only, while the same command in a terminal covers
        // Objective-C, C and C++ too.
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let package = (args["package"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let surface = PublicAPI.generate(
            projectRoot: root,
            package: package,
            type: (args["type"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            index: index,
            compileDatabaseRoot: context.projectRoot
        )
        let cxxHeaders = IndexDeclarations.publicHeaderSummaries(root: rootURL, index: index, package: package).cxxHeaders
        let unanswered = IndexDeclarations.cxxHeaderSummaries(cxxHeaders, root: rootURL,
                                                              compileDatabaseRoot: context.projectRoot).unanswered
        let answer = ([capped(surface, hint: "narrow it with package, type, or scope")]
                      + StructuralCoverage.report(unanswered)).joined(separator: "\n")
        return (answer, false)

    case "changed":
        let from = (args["from"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
        let to = (args["to"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let changes = DeclarationDiff.changes(root: context.project, from: from, to: to) else {
            return ("git failed (not a git repository, or an invalid ref: \(from)\(to.map { " / \($0)" } ?? ""))", true)
        }
        var lines: [String] = []
        if changes.files.isEmpty {
            lines.append("no symbol-level changes (\(from) → \(to ?? "working tree"))")
        }
        for change in changes.files {
            lines.append(change.file)
            change.result.added.forEach { lines.append("  + \($0.decoratedHeader)") }
            change.result.removed.forEach { lines.append("  − \($0.decoratedHeader)") }
            change.result.changed.forEach { lines.append("  ~ \($0.old.decoratedHeader)  →  \($0.new.decoratedHeader)") }
        }
        // Named, not dropped: a model reading this must not conclude a file is unchanged when it
        // was never compared.
        if !changes.notDiffed.isEmpty {
            lines += StructuralCoverage.report(changes.notDiffed)
            lines.append("  use `git diff` for these")
        }
        return (capped(lines.joined(separator: "\n"), hint: "narrow the from/to revisions"), false)

    default:
        return ("unknown tool: \(name)", true)
    }
}

/// Symbol summary text (for the `context` tool and the `sextant://symbol/{name}` resource).
private func contextText(_ symbol: String, _ index: IndexStoreSet?, reader: SourceLineReader) -> (String, Bool) {
    guard let set = index else { return (indexUnavailable, true) }
    guard let context = set.context(forName: symbol) else { return ("symbol not found: \(symbol)", true) }
    let lines = SymbolReport.context(
        context,
        sampleLimit: 20,
        style: .mcp,
        path: shorten,
        snippet: { reader.line($0.line, inFile: $0.path) }
    )
    return (lines.joined(separator: "\n"), false)
}

/// Resource read by URI: `sextant://repo_map` is the map, `sextant://symbol/<name>` is a
/// symbol summary.
private func readResource(uri: String, context: ToolContext) -> (text: String, ok: Bool) {
    if uri == "sextant://repo_map" {
        if let problem = context.scopeProblem { return ("config: \(problem)", false) }
        let budget = max(500, context.config?.budget ?? 6000)
        return (RepoMap.generate(projectRoot: context.project, options: .init(tokenBudget: budget, includeTests: false)), true)
    }
    let prefix = "sextant://symbol/"
    if uri.hasPrefix(prefix) {
        let raw = String(uri.dropFirst(prefix.count))
        let name = raw.removingPercentEncoding ?? raw
        guard !name.isEmpty else { return ("empty symbol name", false) }
        let (text, isError) = contextText(name, context.index, reader: context.reader)
        return (text, !isError)
    }
    return ("unknown resource: \(uri)", false)
}

/// Graceful degradation to textual occurrences when semantics find nothing — it removes a
/// round trip through a grep fallback.
private func textualFallback(_ symbol: String, project: String) -> (String, Bool) {
    let scan = IdentifierScan.matches(of: symbol, underRoot: URL(fileURLWithPath: project, isDirectory: true), includeTests: true, limit: 40)
    guard !scan.matches.isEmpty else { return ("symbol not found: \(symbol) (neither in the index nor textually)", true) }
    // The ⚠ marker matters: semantics did not resolve this, it is TEXT. Agents often read the
    // marker rather than isError.
    let lines = SymbolReport.textual(symbol: symbol, matches: scan.matches, truncated: scan.truncated, style: .mcp, path: shorten)
    return (lines.joined(separator: "\n"), false)
}

private func lookupText(_ symbol: String?, _ index: IndexStoreSet?, query: SymbolQuery, project: String, reader: SourceLineReader) -> (String, Bool) {
    guard let symbol, !symbol.isEmpty else { return ("the symbol parameter is required", true) }
    guard let set = index else { return (indexUnavailable, true) }
    let hits = set.lookup(name: symbol, query: query)
    guard !hits.isEmpty else { return textualFallback(symbol, project: project) }

    let rendering = SymbolReport.lookup(
        symbol: symbol,
        hits: hits,
        query: query,
        style: .mcp,
        path: shorten,
        snippet: { reader.line($0.line, inFile: $0.path) }
    )
    // The agent reads the advisory as part of the answer (isError is often ignored).
    let lines = rendering.lines + (rendering.advisory.map { [$0] } ?? [])
    return (lines.joined(separator: "\n"), false)
}
