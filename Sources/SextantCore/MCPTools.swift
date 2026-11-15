import Foundation

/// The one revision of the Model Context Protocol this build implements.
///
/// It is a claim, so it is written down in one place and answered with as it stands. The server
/// used to reply with whatever revision the client asked for, which made every client's guess come
/// back as confirmation — including a revision published after this binary was compiled.
public enum MCPProtocol {
    public static let revision = "2025-06-18"
}

/// The MCP tool contract: names, descriptions, and input JSON Schema. It lives in Core because
/// this is the stable surface the agent sees; it is covered by a test.
public enum MCPTools {
    public static func definitions() -> [[String: Any]] {
        func symbolSchema(_ extra: [String: Any] = [:]) -> [String: Any] {
            var properties: [String: Any] = ["symbol": ["type": "string", "description": "Name of a symbol: a type, function, or method."]]
            for (key, value) in extra { properties[key] = value }
            return ["type": "object", "properties": properties, "required": ["symbol"]]
        }
        let tools: [[String: Any]] = [
            ["name": "context", "description": "Everything about one symbol in a single call: definition, usages, callers, callees, hierarchy. Prefer this over a series of greps.", "inputSchema": symbolSchema()],
            ["name": "blast_radius", "description": "Impact analysis: what a change to this symbol would touch (affected files, usages, calls, implementations).", "inputSchema": symbolSchema()],
            ["name": "body", "description": "Full source text of a declaration, signature AND body, by name. Use when you need the implementation; defs and context give only the signature.", "inputSchema": symbolSchema()],
            ["name": "who_defines", "description": "Where a symbol is defined (file:line).", "inputSchema": symbolSchema()],
            ["name": "find_references", "description": "Every usage of a symbol.", "inputSchema": symbolSchema()],
            ["name": "find_callers", "description": "Call sites of a function or method, accounting for protocol dispatch. A TYPE has no call sites — use find_references or context for those.", "inputSchema": symbolSchema()],
            ["name": "list_implementations", "description": "Implementations and subtypes of a protocol or class.", "inputSchema": symbolSchema()],
            ["name": "call_hierarchy", "description": "Transitive call graph, rendered as a tree.", "inputSchema": symbolSchema([
                "direction": ["type": "string", "enum": ["callees", "callers"], "description": "Direction of traversal (default: callees)."],
                "depth": ["type": "integer", "description": "Traversal depth (default: 3)."]
            ])],
            ["name": "repo_map", "description": "Repository map: public and internal types by file, symbol-level.", "inputSchema": ["type": "object", "properties": ["budget": ["type": "integer", "description": "Token budget for the map (default 4000, honoured)."]]]],
            ["name": "structural_search", "description": "Structural search over the AST, replacing grep: metavariables $X (expression, type, binding name, declaration name, parameter), variadic $$$, statement patterns; a metavariable that cannot be bound is refused as an error. For example 'try? $X.save()' in Swift or '[$X reloadData]' in Objective-C. Swift is matched by its own parser; Objective-C, C and C++ by clang, which needs the flags from `sextant index`, which RUNS the project's build (its manifest, plugins and macros are code) — so it is the user's call, not an automatic step. Files that could not be read are listed with the reason, so 'no matches' never quietly covers them. Occurrences inside #if branches this build does not contain are reported separately as textual, NOT structurally verified — treat them as leads, not as matches. " + SourceColumn.positionFormat, "inputSchema": [
                "type": "object",
                "properties": ["pattern": ["type": "string", "description": "Structural pattern: an expression or statement using $X ($$$ is Swift only). Written in the language of the files being searched."]],
                "required": ["pattern"]
            ]],
            ["name": "lint", "description": "Structural code-hygiene rules (the set from .sextant.json, otherwise the built-in one). Covers Swift plus Objective-C, C and C++; a file where no rule could be checked is listed with the reason, so a clean report never covers unread code. " + SourceColumn.positionFormat, "inputSchema": ["type": "object", "properties": [String: Any]()]],
            ["name": "api", "description": "Public surface of a package or type — signatures plus doc summaries, without reading files. An order of magnitude cheaper than reading the sources. Covers Swift, Objective-C, C and C++ (C++ headers need the flags from `sextant index`, which RUNS the project's build (its manifest, plugins and macros are code) — so it is the user's call, not an automatic step). Narrow it with package, type, or scope.", "inputSchema": [
                "type": "object",
                "properties": [
                    "package": ["type": "string", "description": "Package name (for example MyLibrary) — its entire public surface."],
                    "type": ["type": "string", "description": "Type name — only that type, an exact filter rather than grepping the output."],
                    "scope": ["type": "string", "description": "Subdirectory of the project, to narrow the area."]
                ]
            ]],
            ["name": "changed", "description": "Symbol-level git diff: which declarations were added, removed, or changed signature between revisions. Not a line diff. Use for 'what changed' and 'what did I break'. Covers Swift, Objective-C, C and C++ (the last three need the flags from `sextant index`, which RUNS the project's build (its manifest, plugins and macros are code) — so it is the user's call, not an automatic step); a file that could not be compared is listed with the reason, so an empty result never means it is unchanged.", "inputSchema": [
                "type": "object",
                "properties": [
                    "from": ["type": "string", "description": "Baseline revision (default HEAD)."],
                    "to": ["type": "string", "description": "Second revision; omit to compare against the working tree."]
                ]
            ]]
        ]
        // readOnlyHint: every tool only reads the index, so a client may auto-approve them.
        return tools.map { tool in
            var annotated = tool
            annotated["annotations"] = ["readOnlyHint": true, "openWorldHint": false]
            return annotated
        }
    }

    /// Tool names — the single source for the server instructions and for the invariant test.
    /// The tool list once drifted between definitions, instructions, and the README.
    public static var names: [String] {
        definitions().compactMap { $0["name"] as? String }
    }

    /// The declaration of one tool, or nil for a name that is not declared.
    public static func definition(named name: String) -> [String: Any]? {
        definitions().first { $0["name"] as? String == name }
    }

    /// Why the `params` of a `tools/call` are not acceptable, or nil when they are: no tool
    /// name, a tool that is not declared, or arguments that do not satisfy the tool's
    /// `inputSchema` — a required argument missing, an argument of the wrong JSON type, a value
    /// outside its `enum`, and an argument the schema does not name only where the schema says
    /// `additionalProperties: false`. The schemas in `definitions()` are the only description of
    /// the arguments; this reads them rather than restating them. In MCP 2025-06-18 each of these
    /// is a protocol error, `-32602` (Invalid params).
    public static func callProblem(_ params: [String: Any]) -> String? {
        guard let name = params["name"] as? String else { return "tools/call: name is required (a string)" }
        guard let tool = definition(named: name) else { return "Unknown tool: \(name)" }
        let arguments: [String: Any]
        switch params["arguments"] {
        case nil: arguments = [:]
        case let object as [String: Any]: arguments = object
        case let other?: return "Invalid arguments for tool '\(name)': arguments must be an object, got \(JSONValue.typeName(of: other))"
        }
        let schema = tool["inputSchema"] as? [String: Any] ?? [:]
        let problems = argumentProblems(arguments, schema: schema)
        guard !problems.isEmpty else { return nil }
        return "Invalid arguments for tool '\(name)': " + problems.joined(separator: "; ")
    }

    /// Every way `arguments` fails the object schema `schema`, one sentence each, in a stable order.
    static func argumentProblems(_ arguments: [String: Any], schema: [String: Any]) -> [String] {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        var problems: [String] = []
        for key in (schema["required"] as? [String] ?? []) where arguments[key] == nil {
            let type = (properties[key] as? [String: Any])?["type"] as? String
            problems.append("'\(key)' is required" + (type.map { " (\($0))" } ?? ""))
        }
        for key in arguments.keys.sorted() {
            let value = arguments[key]!
            guard let property = properties[key] as? [String: Any] else {
                if schema["additionalProperties"] as? Bool == false {
                    problems.append("'\(key)' is not an argument of this tool")
                }
                continue
            }
            if let type = property["type"] as? String, !JSONValue.matches(value, type: type) {
                problems.append("'\(key)' must be \("aeiou".contains(type.prefix(1)) ? "an" : "a") \(type), got \(JSONValue.typeName(of: value))")
                continue
            }
            if let allowed = property["enum"] as? [String], !allowed.contains(where: { $0 == value as? String }) {
                problems.append("'\(key)' must be one of: \(allowed.joined(separator: ", "))")
            }
        }
        return problems
    }

    /// Server instructions sent at `initialize` — assembled from `definitions()`, so they cannot
    /// drift from the actual set of tools.
    public static func instructions() -> String {
        "Navigate Swift code without grep. Prefer context (everything about one symbol) over a series of greps; "
            + "api (public surface of a package or type) over reading sources; "
            + "structural_search (AST pattern) over textual search. "
            + "Tools: " + names.joined(separator: ", ") + ". "
            + SourceColumn.positionFormat
    }
}
