import Foundation
import SextantCore

// MARK: - MCP server (stdio, JSON-RPC 2.0)

private let indexUnavailable =
    "Index unavailable. Run `sextant index` (or `index --app`) — the semantic tools need an index store."

/// Why the index is unavailable, in the answer itself. Several usable stores with no policy set is
/// not a missing index — it is a decision nobody has made — and telling an agent to run
/// `sextant index` there sends it to build a third store instead of surfacing the choice.
private func indexUnavailableReason(_ arguments: [String]) -> String {
    let (resolution, _) = resolveStores(in: arguments)
    guard resolution.needsPolicy else { return indexUnavailable }
    return StoreSelection.unsetPolicyRefusal(candidates: resolution.candidates, shorten: shorten).joined(separator: "\n")
}

/// Runs the MCP server over stdio. A single client (Claude Code) means a sequential loop with
/// no concurrency hazards: the index is opened once and reused, keeping the cache warm.
/// stdout carries only JSON-RPC messages (newline-delimited); logs go to stderr.
private let indexNeedingMethods: Set<String> = ["tools/call", "resources/read", "completion/complete"]

func runMCP(arguments: [String]) -> Int32 {
    let project = projectRoot(in: arguments)
    // A client that ends the session with a signal rather than by closing stdin gets the same
    // exit as an end of input: the index is closed, after the message in progress is answered.
    // The session's reference to it is dropped first, or closing would leave it open.
    let answering = NSLock()
    let held = HeldIndex()
    let interrupts = exitCleanlyOnSignals(waitingFor: answering) { held.set = nil }
    defer { interrupts.forEach { $0.cancel() } }
    var index: IndexStoreSet? {
        get { held.set }
        set { held.set = newValue }
    }
    answering.lock()
    index = openIndex(arguments, label: "mcp", listen: true)
    if index == nil {
        logMCP("index unavailable at start-up — will try again once a store appears (build one with `sextant index`).")
    }
    // The state the open index stands on: which stores were chosen and when their units were last
    // written. Both can change while a session runs — a rebuild into another configuration, a
    // second checkout appearing, a policy written to `.sextant.json` — and a server that only ever
    // looked once keeps answering from the store it happened to pick at start-up.
    var openedSignature: String? = index == nil ? nil : storeSignature(in: arguments)
    var lastOpenSignature: String? = openedSignature   // avoids retrying a broken store every call
    var configWarned = false         // a broken .sextant.json is reported once per session
    answering.unlock()

    while let line = readLine(strippingNewline: true) {
        answering.lock()
        defer { answering.unlock() }
        if line.isEmpty { continue }
        // A line that is not a request is answered with the error that says why, never dropped:
        // a client waiting on a dropped request waits forever, with nothing in its log.
        let method: String, id: Any?, params: [String: Any]
        switch MCPMessage.parse(line) {
        case .response:
            continue
        case .invalid(let invalidID, let code, let message):
            emitMCP(["jsonrpc": "2.0", "id": invalidID ?? NSNull(), "error": ["code": code, "message": message]])
            continue
        case .notification(let name, let given):
            (method, id, params) = (name, nil, given)
        case .request(let given, let name, let arguments):
            (method, id, params) = (name, given, arguments)
        }

        // The stores this call is answered from, decided once per call: the signature below and
        // the trust label of the answer are read from the same decision.
        let resolution = CallResolution { resolveStores(in: arguments) }

        // Checked on every call that needs the index, not only while there is none. The signature
        // covers the chosen store paths and their unit times, so it moves when the project is
        // rebuilt, when the policy changes which store is read, and when a store appears.
        if indexNeedingMethods.contains(method) {
            let signature = IndexFreshness.signature(ofStores: resolution.value.resolution.chosen.map(\.path))
            if index == nil, let signature, signature != lastOpenSignature {
                lastOpenSignature = signature
                index = openIndex(arguments, label: "mcp", listen: true)
                openedSignature = index == nil ? nil : signature
                if index != nil { logMCP("index appeared — opened, semantics available.") }
            } else if index != nil, signature != openedSignature {
                logMCP("the index changed (rebuilt, or another store is in force) — reopening.")
                index = openIndex(arguments, label: "mcp", listen: true)
                openedSignature = index == nil ? nil : signature
                lastOpenSignature = signature
            }
        }

        let opened = index
        // One freshness report per call: the label appended to the answer and the mapping of the
        // answer onto the current text come from the same one.
        let provenance = CallProvenance {
            guard opened != nil else { return nil }
            let (decision, source) = resolution.value
            guard !decision.chosen.isEmpty else { return nil }
            return indexProvenance(decision, source: source, arguments: arguments)
        }
        let translated = index.map { set in
            LazyTranslatedIndex { TranslatedIndex(set, drift: provenance.value?.report.flatMap { IndexDrift(report: $0, projectRoot: project) }) }
        }
        let context = makeToolContext(project: project, index: index, translated: translated,
                                      provenance: { provenance.value?.summary },
                                      indexProblem: { indexUnavailableReason(arguments) }, warnedInvalidConfig: &configWarned)
        handleMCP(method: method, id: id, params: params, context: context)
    }
    return 0
}

/// The index a session answers from, held where a signal handler can let go of it.
private final class HeldIndex: @unchecked Sendable {
    var set: IndexStoreSet?
}

/// The store decision of one call, made on first use.
private final class CallResolution {
    private let make: () -> (resolution: StoreResolution, source: IndexProvenance.Source)
    private lazy var stored = make()

    init(_ make: @escaping () -> (resolution: StoreResolution, source: IndexProvenance.Source)) { self.make = make }

    var value: (resolution: StoreResolution, source: IndexProvenance.Source) { stored }
}

/// Computed once, on first use, within one call.
private final class CallProvenance {
    private let make: () -> IndexProvenance?
    private var computed = false
    private var stored: IndexProvenance?

    init(_ make: @escaping () -> IndexProvenance?) { self.make = make }

    var value: IndexProvenance? {
        if !computed { stored = make(); computed = true }
        return stored
    }
}

/// The translated index of one call, built on first use: a tool that does not read the index
/// does not pay for the freshness report.
private final class LazyTranslatedIndex {
    private let make: () -> TranslatedIndex
    private var stored: TranslatedIndex?

    init(_ make: @escaping () -> TranslatedIndex) { self.make = make }

    var value: TranslatedIndex {
        if let stored { return stored }
        let made = make()
        stored = made
        return made
    }

    /// What the answers of this call left out because their files no longer exist, said in the
    /// answer itself; nil when the call never read the index or nothing was left out.
    var leftOutNote: String? { SymbolReport.leftOut(stored?.leftOut, path: shorten) }
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
    /// The index the symbol tools answer from: the same stores, stated against the current text.
    let translated: LazyTranslatedIndex?
    let reader: SourceLineReader
    /// The trust label the CLI prints on stderr. An MCP client logs stderr at best, so without
    /// this the agent — the main consumer — never sees where the answer came from or that the
    /// index is stale. Computed on demand: freshness walks the sources.
    let provenance: () -> String?
    /// What to say when there is no index to answer from — computed per call, because "several
    /// usable stores and no policy" is a different problem from "no store at all", and telling an
    /// agent to run `sextant index` there sends it to build a third store instead of surfacing
    /// the choice nobody has made.
    let indexProblem: () -> String
}

private func makeToolContext(project: String, index: IndexStoreSet?, translated: LazyTranslatedIndex?,
                             provenance: @escaping () -> String?,
                             indexProblem: @escaping () -> String,
                             warnedInvalidConfig: inout Bool) -> ToolContext {
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

    // Per call, not once at start-up: `.sextant.json` may have been edited since the last one,
    // and an exclusion the user just added must take effect without restarting the server.
    SwiftSources.setExclusions(config?.exclude ?? [])

    return ToolContext(project: scoped, projectRoot: project, scopeProblem: scopeProblem,
                       config: config, index: index, translated: translated, reader: SourceLineReader(),
                       provenance: provenance,
                       indexProblem: indexProblem)
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
        // The revision this server actually implements — not the one the client hoped for. Echoing
        // the request confirmed support for anything a client cared to name, including revisions
        // written after this build; the protocol expects the server's own version back when it
        // cannot meet the request, and the client decides whether to go on.
        let requested = params["protocolVersion"] as? String
        if let requested, requested != MCPProtocol.revision {
            logMCP("client asked for protocol \(requested); answering with \(MCPProtocol.revision), which is what this build implements.")
        }
        resultMCP(id: id, [
            "protocolVersion": MCPProtocol.revision,
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
        var resource = readResource(uri: uri, context: context)
        // The same trust label a tool answer carries: a resource read from the index is the same
        // answer asked another way, and an agent cannot see stderr either way.
        if resource.ok, let note = context.translated?.leftOutNote { resource.text += "\n\n\(note)" }
        if resource.ok, let provenance = context.provenance() {
            resource.text += "\n\n\(provenance)"
        }
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
        clearConfigMemo()                    // and a `.sextant.json` edited mid-session takes effect
        // An undeclared tool or arguments its schema does not admit are refused before anything
        // runs: a value of the wrong type used to be replaced by the default, and the answer did
        // not say so.
        if let problem = MCPTools.callProblem(params) {
            errorMCP(id: id, code: JSONRPCErrorCode.invalidParams, problem)
            break
        }
        let name = params["name"] as? String ?? ""
        let toolArgs = params["arguments"] as? [String: Any] ?? [:]
        let started = DispatchTime.now()
        var (text, isError) = callMCPTool(name: name, args: toolArgs, context: context)
        // The same label the CLI prints, inside the answer: an agent that cannot see it has no way
        // to tell a fresh answer from one describing yesterday's code.
        if !isError, let note = context.translated?.leftOutNote { text += "\n\n\(note)" }
        if !isError, indexBackedTools.contains(name), let provenance = context.provenance() {
            text += "\n\n\(provenance)"
        }
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
        errorMCP(id: id, code: JSONRPCErrorCode.methodNotFound, "Method not supported: \(method)")
    }
}

// MARK: - Tool dispatch

/// How many files an area tool may read, and the line that says what it did not. An agent never
/// sees stderr, so on a large project the bound has to travel inside the answer or the answer
/// reads as complete.
private func fileLimit(_ context: ToolContext) -> Int { max(1, context.config?.maxFiles ?? 4000) }

private func scaleNoteMCP(_ context: ToolContext, includeTests: Bool = false) -> [String] {
    let limit = fileLimit(context)
    let total = SwiftSources.count(under: URL(fileURLWithPath: context.project, isDirectory: true),
                                   includeTests: includeTests)
    guard total > limit else { return [] }
    return ["⚠ covered \(limit) of \(total) file(s) — the walk stops at maxFiles \(limit) "
            + "(.sextant.json). Narrow with scope, or raise it."]
}

/// Tools that work over an area of the project rather than a symbol — they need a valid scope.
private let areaTools: Set<String> = ["repo_map", "structural_search", "lint", "api", "changed"]

/// Tools whose answer comes from the index, and which therefore carry its trust label.
private let indexBackedTools: Set<String> = [
    "context", "body", "blast_radius", "who_defines", "find_references", "find_callers",
    "list_implementations", "call_hierarchy", "api", "repo_map",
]

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
        return contextText(symbol, context.translated?.value, reader: context.reader, problem: context.indexProblem)

    case "body":
        guard let symbol = symbol() else { return ("the symbol parameter is required", true) }
        guard let set = context.translated?.value else { return (context.indexProblem(), true) }
        let hits = set.lookup(name: symbol, query: .definitions)
        let definitions = hits.compactMap { $0.definition }
        guard !definitions.isEmpty else { return ("definition not found: \(symbol) (symbol outside the index? try find_references)", true) }
        let bodies = SourceBody.bodies(of: symbol, at: definitions.filter(\.isConfirmed))
        let staleness = SymbolReport.staleness(
            hits.first?.staleness, locations: definitions, symbol: symbol, style: .mcp, path: shorten,
            extra: definitions.filter { !$0.isConfirmed }.map {
                "definition at \(shorten($0.path)):\($0.line)\($0.marker) — not extracted"
            })
        guard !bodies.isEmpty else {
            guard !staleness.isEmpty else {
                return ("could not extract the body of '\(symbol)': \(SourceBody.unextractableReason(refresh: StoreSelection.refreshAdvice(forStores: set.base.storePaths)))", true)
            }
            return ((["could not extract the body of '\(symbol)' from the current text"] + staleness).joined(separator: "\n"), false)
        }
        return ((bodies.map { "── \(shorten($0.file)):\($0.line)\n\($0.text)" } + (staleness.isEmpty ? [] : [staleness.joined(separator: "\n")]))
                    .joined(separator: "\n\n"), false)

    case "blast_radius":
        guard let symbol = symbol() else { return ("the symbol parameter is required", true) }
        guard let set = context.translated?.value else { return (context.indexProblem(), true) }
        guard let radius = set.blastRadius(forName: symbol) else { return ("symbol not found: \(symbol)", true) }
        var lines = ["blast radius: \(radius.symbol) [\(radius.kind)]",
                     "touches: \(radius.affectedFiles.count) files · \(radius.referenceCount) usages · \(radius.callerCount) calls"]
        if let note = radius.mergeNote { lines.append(note) }
        if !radius.implementations.isEmpty { lines.append("implementations: " + radius.implementations.joined(separator: ", ")) }
        let unconfirmed = Set(radius.unconfirmedFiles ?? [])
        radius.affectedFiles.forEach {
            lines.append("  \(shorten($0))\(unconfirmed.contains($0) ? "  [unconfirmed: nothing recorded here can be confirmed against the current text]" : "")")
        }
        lines += SymbolReport.staleness(radius.staleness, locations: radius.definitions, symbol: symbol, style: .mcp, path: shorten,
                                        extra: unconfirmed.isEmpty ? [] : ["\(unconfirmed.count) affected file(s) hold only unconfirmed occurrences, marked [unconfirmed]"])
        return (lines.joined(separator: "\n"), false)

    case "who_defines":
        return lookupText(symbol(), context.translated?.value, query: .definitions, project: context.project, reader: context.reader, problem: context.indexProblem)
    case "find_references":
        return lookupText(symbol(), context.translated?.value, query: .references, project: context.project, reader: context.reader, problem: context.indexProblem)
    case "find_callers":
        return lookupText(symbol(), context.translated?.value, query: .callers, project: context.project, reader: context.reader, problem: context.indexProblem)

    case "list_implementations":
        guard let symbol = symbol() else { return ("the symbol parameter is required", true) }
        guard let set = context.translated?.value else { return (context.indexProblem(), true) }
        // "No implementations" is a statement about a symbol that exists. For one the index has
        // never heard of, it is a made-up answer — the other six symbol tools say so.
        guard !set.resolveSymbols(forName: symbol).isEmpty else { return ("symbol not found: \(symbol)", true) }
        let related = set.related(toName: symbol, query: .implementations, limit: .max)
        let staleness = SymbolReport.staleness(set.staleness(forName: symbol, query: .references),
                                               locations: related.map(\.location), symbol: symbol, style: .mcp, path: shorten)
        guard !related.isEmpty else {
            return ((["no implementations found: \(symbol)"] + staleness).joined(separator: "\n"), false)
        }
        let shownLimit = 1000
        var lines = related.prefix(shownLimit).map { "\($0.name) [\($0.kind)]  \(shorten($0.location.path)):\($0.location.line)\($0.location.marker)" }
        if related.count > shownLimit { lines.append("… (first \(shownLimit) of \(related.count) shown)") }
        return ((lines + staleness).joined(separator: "\n"), false)

    case "call_hierarchy":
        guard let symbol = symbol() else { return ("the symbol parameter is required", true) }
        guard let set = context.translated?.value else { return (context.indexProblem(), true) }
        let direction: CallDirection = (args["direction"] as? String) == "callers" ? .callers : .callees
        let depth = max(1, (args["depth"] as? Int) ?? 3)
        let roots = set.resolveSymbols(forName: symbol)
        guard !roots.isEmpty else { return ("symbol not found: \(symbol)", true) }
        var visited = Set<String>()
        var lines: [String] = []
        var positions: [SourceLocation] = []
        // As in the CLI: where the symbol is defined and where the call was written are two facts,
        // and the answer states which is which.
        func walk(_ usr: String, _ label: String, _ location: SourceLocation, _ callSite: SourceLocation?,
                  _ definitionKnown: Bool, _ remaining: Int, _ indent: Int) {
            positions += [location] + [callSite].compactMap { $0 }
            var line = String(repeating: "  ", count: indent) + "\(label)  \(shorten(location.path)):\(location.line)\(location.marker)"
            if !definitionKnown {
                line += " — that is the call site; the index has no definition for it (external or system symbol)"
            } else if let callSite {
                line += "  · called at \(shorten(callSite.path)):\(callSite.line)\(callSite.marker)"
            }
            lines.append(line)
            guard remaining > 0, visited.insert(usr).inserted else { return }
            let children = set.calls(ofUSR: usr, direction: direction)
            for child in children.prefix(CallHierarchy.breadth) {
                walk(child.usr, "\(child.name) [\(child.kind)]", child.location, child.callSite,
                     child.definitionKnown, remaining - 1, indent + 1)
            }
            if let note = CallHierarchy.omissionNote(total: children.count, direction: direction) {
                lines.append(String(repeating: "  ", count: indent + 1) + note)
            }
        }
        for root in roots { walk(root.usr, "\(root.name) [\(root.kind)]", root.location, nil, true, depth, 0) }
        lines += SymbolReport.staleness(set.staleness(forName: symbol, query: .references), locations: positions,
                                        symbol: symbol, style: .mcp, path: shorten)
        return (lines.joined(separator: "\n"), false)

    case "repo_map":
        return (repoMapText(budget: args["budget"] as? Int, context: context), false)

    case "structural_search":
        guard let pattern = (args["pattern"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return ("the pattern parameter is required", true) }
        // As in the CLI: a pattern the Swift parser rejects may still be a C-family one.
        var engine: PatternSearch?
        var swiftRejection: String?
        do { engine = try PatternSearch(pattern: pattern) }
        catch let failure as PatternSearch.Failure where failure.mayBeCFamily { swiftRejection = failure.description }
        catch { return ("invalid pattern: \(error)", true) }
        let root = URL(fileURLWithPath: context.project, isDirectory: true)
        let scanLimit = max(1, context.config?.maxFiles ?? 8000)   // clamped: 0 or negative would disable search
        let shownLimit = 200
        var lines: [String] = []
        // Matches past the first 200 are counted, not printed: the answer states the total it cut.
        let files = SwiftSources.files(under: root, includeTests: false)
        let stopped = engine != nil && files.count > scanLimit
        let swift = engine.map {
            SwiftPatternScan.run($0, pattern: pattern, files: Array(files.prefix(scanLimit)), root: root,
                                 cache: SourceParseCache())
        } ?? SwiftPatternScan.Outcome()
        lines += swift.hits.prefix(shownLimit).map { "\($0.file):\($0.line):\($0.column): \($0.text)" }
        if swift.hits.count > shownLimit {
            lines.append("… (first \(shownLimit) of \(swift.hits.count)\(stopped ? "+" : "") Swift matches shown)")
        }
        if stopped { lines.append("… (scanned \(scanLimit) files, search stopped — narrow the scope)") }
        // Objective-C, C and C++ go through clang, with the flags each file was built with.
        let cFamily = CFamilySearch.run(pattern: pattern, searchRoot: context.project,
                                        projectRoot: context.projectRoot, includeTests: false)
        lines += cFamily.hits.prefix(shownLimit).map { "\($0.file):\($0.line):\($0.column): \($0.text)" }
        if cFamily.hits.count > shownLimit {
            lines.append("… (first \(shownLimit) of \(cFamily.hits.count) C-family matches shown)")
        }
        let unscanned = swift.unscanned + cFamily.unscanned
            + StructuralCoverage.skippedDirectories(projectRoot: context.project)
        if let swiftRejection {
            // As in the CLI: only a C-family file actually searched shows the pattern reached
            // anything. Without one, the pattern is refused, and whatever was not read is named.
            guard cFamily.scannedCount > 0 else {
                return ((["invalid pattern: \(swiftRejection)"] + StructuralCoverage.report(cFamily.unscanned))
                    .joined(separator: "\n"), true)
            }
            lines.append("⚠ the pattern does not parse as Swift (\(swiftRejection)) — \(cFamily.scannedCount) "
                         + "C-family file(s) were searched, the Swift ones were not.")
        }
        if lines.isEmpty { lines.append("no matches") }
        lines += StructuralCoverage.inactiveReport(cFamily.inactive, targets: cFamily.targets)
        if cFamily.inactive.isEmpty { lines += StructuralCoverage.configurationNote(targets: cFamily.targets) }
        lines += StructuralCoverage.recoveredReport(swift.recovered + cFamily.recovered)
        lines += StructuralCoverage.report(unscanned)
        return (lines.joined(separator: "\n"), false)

    case "lint":
        // Rules from .sextant.json, as in the CLI (MCP used to know only the built-in set).
        let ruleSet: RuleEngine.RuleSet
        if let path = context.config?.rulesPath(projectRoot: context.projectRoot) {
            do { ruleSet = try RuleEngine.loadRules(fromJSONAt: path) }
            catch { return ("could not load rules from .sextant.json (\(path)): \(error)", true) }
        } else {
            ruleSet = RuleEngine.builtinSet
        }
        let rules = ruleSet.rules
        let outcome = RuleEngine.run(rules: rules, projectRoot: context.projectRoot, lintRoot: context.project,
                                     includeTests: false, fileLimit: fileLimit(context))
        let violations = outcome.violations
        let unscanned = StructuralCoverage.inactiveReport(outcome.inactive, targets: outcome.targets,
                                                          noun: "possible violation(s)")
            + StructuralCoverage.recoveredReport(outcome.recovered)
            + StructuralCoverage.report(outcome.unscanned)
            + RuleEngine.brokenReport(outcome.broken)
            + scaleNoteMCP(context)
        guard !violations.isEmpty else {
            return ((["✅ no violations found — rules: \(ruleSet.origin)"] + unscanned).joined(separator: "\n"), false)
        }
        let shownLimit = 200
        var lines = violations
            .sorted { ($0.ruleID, $0.file, $0.line) < ($1.ruleID, $1.file, $1.line) }
            .prefix(shownLimit)
            .map { "[\($0.ruleID)] \($0.file):\($0.line):\($0.column)  \($0.text)" }
        if violations.count > shownLimit { lines.append("… (first \(shownLimit) of \(violations.count) violations shown)") }
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
            compileDatabaseRoot: context.projectRoot,
            fileLimit: fileLimit(context),
            // The MCP surface is read by an agent with a context window, so here the budget has a
            // default: the CLI can afford to hand a person three megabytes, a tool call cannot.
            tokenBudget: max(500, (args["budget"] as? Int) ?? context.config?.budget ?? 8000)
        )
        let bounded = scaleNoteMCP(context)
        let cxxHeaders = IndexDeclarations.publicHeaderSummaries(root: rootURL, index: index, package: package).cxxHeaders
        let unanswered = IndexDeclarations.cxxHeaderSummaries(cxxHeaders, root: rootURL,
                                                              compileDatabaseRoot: context.projectRoot).unanswered
        let answer = ([capped(surface, hint: "narrow it with package, type, or scope")]
                      + (index == nil ? [] : IndexDeclarations.conditionalHeaderNote(root: rootURL, package: package))
                      + StructuralCoverage.report(unanswered) + bounded).joined(separator: "\n")
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
            change.result.added.forEach { lines.append("  + \($0.diffHeader)") }
            change.result.removed.forEach { lines.append("  − \($0.diffHeader)") }
            change.result.changed.forEach { lines.append("  ~ \($0.old.diffHeader)  →  \($0.new.diffHeader)") }
        }
        lines += changes.partialReport
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

/// The repository map, for the `repo_map` tool and the `sextant://repo_map` resource alike — one
/// answer, whichever way it is asked for.
private func repoMapText(budget requested: Int?, context: ToolContext) -> String {
    // The token budget is honoured (a field report found it being ignored); the default
    // comes from .sextant.json, as in the CLI. Clamped: a budget of 0 would collapse the map.
    let budget = max(500, requested ?? context.config?.budget ?? 4000)
    // The index is passed here as it is in the CLI: without it the map covers Swift only,
    // while the same command in a terminal covers Objective-C, C and C++ as well. What is
    // missing is named, because a map that looks complete is worse than a short one.
    let mapRoot = URL(fileURLWithPath: context.project, isDirectory: true)
    let foreign = SwiftSources.files(under: mapRoot, includeTests: false,
                                     extensions: IndexDeclarations.clangExtensions)
    var map = RepoMap.generate(projectRoot: context.project,
                               options: .init(tokenBudget: budget, includeTests: false,
                                              fileLimit: fileLimit(context)),
                               index: context.index)
    scaleNoteMCP(context).forEach { map += "\n\n\($0)" }
    if !foreign.isEmpty, context.index == nil {
        map += "\n\n⚠ \(foreign.count) non-Swift file(s) are missing from the map: no index store. "
             + "Build one with `sextant index`."
    }
    return map
}

/// Symbol summary text (for the `context` tool and the `sextant://symbol/{name}` resource).
private func contextText(_ symbol: String, _ index: TranslatedIndex?, reader: SourceLineReader,
                         problem: () -> String) -> (String, Bool) {
    guard let set = index else { return (problem(), true) }
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
        return (repoMapText(budget: nil, context: context), true)
    }
    let prefix = "sextant://symbol/"
    if uri.hasPrefix(prefix) {
        let raw = String(uri.dropFirst(prefix.count))
        let name = raw.removingPercentEncoding ?? raw
        guard !name.isEmpty else { return ("empty symbol name", false) }
        let (text, isError) = contextText(name, context.translated?.value, reader: context.reader, problem: context.indexProblem)
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

private func lookupText(_ symbol: String?, _ index: TranslatedIndex?, query: SymbolQuery, project: String,
                        reader: SourceLineReader, problem: () -> String) -> (String, Bool) {
    guard let symbol, !symbol.isEmpty else { return ("the symbol parameter is required", true) }
    guard let set = index else { return (problem(), true) }
    let hits = set.lookup(name: symbol, query: query)
    guard !hits.isEmpty else { return textualFallback(symbol, project: project) }

    let rendering = SymbolReport.lookup(
        symbol: symbol,
        hits: hits,
        query: query,
        style: .mcp,
        path: shorten,
        snippet: { reader.line($0.line, inFile: $0.path) },
        refresh: StoreSelection.refreshAdvice(forStores: set.base.storePaths)
    )
    // The agent reads the advisory as part of the answer (isError is often ignored).
    let lines = rendering.lines + (rendering.advisory.map { [$0] } ?? [])
    return (lines.joined(separator: "\n"), false)
}
