import Foundation

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
            ["name": "structural_search", "description": "Structural search over the AST, replacing grep: metavariables $X, variadic $$$, statement patterns. For example 'try? $X.save()' in Swift or '[$X reloadData]' in Objective-C. Swift is matched by its own parser; Objective-C, C and C++ by clang, which needs the flags from `sextant index`. Files that could not be read are listed with the reason, so 'no matches' never quietly covers them.", "inputSchema": [
                "type": "object",
                "properties": ["pattern": ["type": "string", "description": "Structural pattern: an expression or statement using $X ($$$ is Swift only). Written in the language of the files being searched."]],
                "required": ["pattern"]
            ]],
            ["name": "lint", "description": "Structural code-hygiene rules (the set from .sextant.json, otherwise the built-in one). Covers Swift plus Objective-C, C and C++; a file where no rule could be checked is listed with the reason, so a clean report never covers unread code.", "inputSchema": ["type": "object", "properties": [String: Any]()]],
            ["name": "api", "description": "Public surface of a package or type — signatures plus doc summaries, without reading files. An order of magnitude cheaper than reading the sources. Covers Swift, Objective-C, C and C++ (C++ headers need the flags from `sextant index`). Narrow it with package, type, or scope.", "inputSchema": [
                "type": "object",
                "properties": [
                    "package": ["type": "string", "description": "Package name (for example MyLibrary) — its entire public surface."],
                    "type": ["type": "string", "description": "Type name — only that type, an exact filter rather than grepping the output."],
                    "scope": ["type": "string", "description": "Subdirectory of the project, to narrow the area."]
                ]
            ]],
            ["name": "changed", "description": "Symbol-level git diff: which declarations were added, removed, or changed signature between revisions. Not a line diff. Use for 'what changed' and 'what did I break'. Swift only: changed C, C++ and Objective-C files come back listed as not compared, so an empty result never means they are unchanged.", "inputSchema": [
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

    /// Server instructions sent at `initialize` — assembled from `definitions()`, so they cannot
    /// drift from the actual set of tools.
    public static func instructions() -> String {
        "Navigate Swift code without grep. Prefer context (everything about one symbol) over a series of greps; "
            + "api (public surface of a package or type) over reading sources; "
            + "structural_search (AST pattern) over textual search. "
            + "Tools: " + names.joined(separator: ", ") + "."
    }
}
