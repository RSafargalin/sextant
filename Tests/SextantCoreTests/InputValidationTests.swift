import Foundation
import Testing
@testable import SextantCore

/// An input the tool does not understand is an error that names it, never a silent default.
/// These check the two places that decide it: `CommandCatalog.usageProblems` for the CLI, and
/// `MCPMessage` with `MCPTools.callProblem` for the MCP server.
@Suite("Input validation")
struct InputValidationTests {
    private static let noEnvironment: @Sendable (String) -> String? = { _ in nil }

    private func problems(_ command: String, _ arguments: [String],
                          environment: [String: String] = [:]) throws -> [String] {
        let spec = try #require(CommandCatalog.command(named: command))
        return CommandCatalog.usageProblems(in: arguments, for: spec, environment: { environment[$0] })
    }

    /// `store` took up to two positional arguments whatever the subcommand, so `store show extra`
    /// ran `show` and dropped the word in silence.
    @Test("A subcommand takes its own number of arguments, and an extra one is refused")
    func subcommandArity() throws {
        #expect(try problems("store", []).isEmpty)
        #expect(try problems("store", ["show"]).isEmpty)
        #expect(try problems("store", ["use", "recency"]).isEmpty)
        let show = try problems("store", ["show", "extra"])
        #expect(show.count == 1 && show.first?.contains("'extra'") == true, "\(show)")
        #expect(!(try problems("store", ["use", "recency", "extra"])).isEmpty)
        // Every declared subcommand fits within the command's own bound.
        for spec in CommandCatalog.commands {
            for (name, arity) in spec.subcommands {
                #expect(1 + arity.upperBound <= spec.positionals.upperBound, "\(spec.name) \(name)")
            }
        }
    }

    // MARK: - CLI flags

    /// Walks the catalog, so a flag added later is covered without touching this test.
    @Test("Every value-taking flag in the catalog refuses a garbage value, an empty one, and a missing one")
    func everyValueFlagRefusesGarbage() {
        var checked = 0
        for spec in CommandCatalog.commands {
            for flag in spec.flags where flag.takesValue {
                checked += 1
                let garbage: [[String]]
                switch flag.value {
                case .integer, .choice:
                    garbage = [[flag.name, "garbage-8k"], [flag.name, ""], [flag.name], [flag.name, "--json"]]
                case .text, .path, .directory, .subdirectory, .none:
                    garbage = [[flag.name, ""], [flag.name], [flag.name, "--json"]]
                }
                for arguments in garbage {
                    let found = CommandCatalog.usageProblems(in: arguments, for: spec, environment: Self.noEnvironment)
                    #expect(found.count == 1, "\(spec.name) \(arguments) was accepted")
                    #expect(found.first?.contains(flag.name) == true, "\(spec.name) \(arguments): \(found)")
                }
            }
        }
        #expect(checked > 40, "the walk found only \(checked) value-taking flags")
    }

    @Test("Every value-taking flag accepts a value of its kind")
    func everyValueFlagAcceptsItsKind() {
        for spec in CommandCatalog.commands {
            for flag in spec.flags where flag.takesValue {
                let values: [String]
                switch flag.value {
                case .integer(let minimum): values = [String(minimum), String(minimum + 1000)]
                case .choice(let words): values = words
                case .text, .path, .directory, .subdirectory, .none: values = ["Sources"]
                }
                for value in values {
                    let found = CommandCatalog.usageProblems(in: [flag.name, value], for: spec, environment: Self.noEnvironment)
                    #expect(found.isEmpty, "\(spec.name) \(flag.name) \(value): \(found)")
                }
            }
        }
    }

    /// The kind is declared where the flag is; a numeric flag declared as plain text would take
    /// `8k` without a word.
    @Test("A flag whose help names a numeric default or a count is declared an integer")
    func numericFlagsAreIntegers() {
        for spec in CommandCatalog.commands {
            for flag in spec.flags where flag.takesValue {
                let numeric = flag.summary.range(of: #"default \d"#, options: .regularExpression) != nil
                    || flag.summary.hasPrefix("how many") || flag.summary.hasPrefix("number of")
                    || flag.summary.contains("budget") || flag.summary.contains("depth")
                guard numeric else { continue }
                if case .integer = flag.value { continue }
                Issue.record("\(spec.name) \(flag.name) reads as a number but is declared \(flag.value)")
            }
        }
    }

    @Test("The values the review named are refused with the flag and the value in the message")
    func namedExamples() throws {
        #expect(try problems("map", ["--budget", "8k"]) == ["--budget '8k' is not an integer; expected a positive integer."])
        #expect(try problems("map", ["--max-files", "abc"]).first?.contains("--max-files 'abc'") == true)
        #expect(try problems("search", ["$X", "--limit", "x"]).first?.contains("--limit 'x'") == true)
        #expect(try problems("hierarchy", ["f", "--depth", "x"]).first?.contains("--depth 'x'") == true)
        #expect(try problems("refs", ["f", "--store-policy", "bogus"])
                == ["--store-policy 'bogus' is not recognised; expected one of: recency, union, coverage."])
        #expect(try problems("map", ["--budget"]) == ["--budget expects a positive integer, and none was given."])
        #expect(try problems("refs", ["f", "--project"]) == ["--project expects a path, and none was given."])
    }

    @Test("Zero and negative numbers are refused where they mean nothing, and kept where they do")
    func ranges() throws {
        #expect(!(try problems("map", ["--max-files", "0"])).isEmpty)
        #expect(!(try problems("map", ["--budget", "-1"])).isEmpty)
        #expect(!(try problems("hierarchy", ["f", "--depth", "0"])).isEmpty)
        #expect(!(try problems("bench", ["--iterations", "0"])).isEmpty)
        #expect(!(try problems("context", ["f", "--limit", "0"])).isEmpty)
        #expect(!(try problems("refs", ["f", "--symbols", "0"])).isEmpty)
        #expect(!(try problems("refs", ["f", "--limit", "-5"])).isEmpty)
        // `refs --limit 0` lists no positions and keeps the counts; zero context lines is the default.
        #expect(try problems("refs", ["f", "--limit", "0"]).isEmpty)
        #expect(try problems("body", ["f", "--context-lines", "0"]).isEmpty)
        #expect(!(try problems("body", ["f", "--context-lines", "-3"])).isEmpty)
    }

    @Test("Every occurrence of a repeated flag is checked")
    func repeatedFlags() throws {
        #expect(try problems("map", ["--exclude", "a", "--exclude", ""]).count == 1)
        #expect(try problems("search", ["$X", "--limit", "3", "--limit", "x"]).count == 1)
    }

    @Test("An unknown SEXTANT_STORE_POLICY is refused by every command that reads stores, and only there")
    func storePolicyEnvironment() throws {
        let bogus = ["SEXTANT_STORE_POLICY": "bogus"]
        let refused = try problems("refs", ["f"], environment: bogus)
        #expect(refused.count == 1)
        #expect(refused.first?.contains("SEXTANT_STORE_POLICY 'bogus'") == true)
        #expect(!(try problems("mcp", [], environment: bogus)).isEmpty)
        #expect(!(try problems("serve", [], environment: bogus)).isEmpty)
        // The flag wins over the variable, so the variable does not decide anything there.
        #expect(try problems("refs", ["f", "--store-policy", "union"], environment: bogus).isEmpty)
        // An empty value is the shell's way of unsetting it.
        #expect(try problems("refs", ["f"], environment: ["SEXTANT_STORE_POLICY": ""]).isEmpty)
        #expect(try problems("refs", ["f"], environment: ["SEXTANT_STORE_POLICY": "recency"]).isEmpty)
        // `map` reads no store policy.
        #expect(try problems("map", [], environment: bogus).isEmpty)
    }

    // MARK: - MCP messages

    private func invalid(_ line: String) -> (id: Any?, code: Int)? {
        guard case .invalid(let id, let code, _) = MCPMessage.parse(line) else { return nil }
        return (id, code)
    }

    @Test("A line that is not JSON is a parse error with a null id")
    func parseError() throws {
        let error = try #require(invalid("not json"))
        #expect(error.code == -32700)
        #expect(error.id == nil)
        #expect(invalid("{\"jsonrpc\": \"2.0\", \"id\": 1,")?.code == -32700)
    }

    @Test("JSON that is not a request object is an Invalid Request with a null id")
    func invalidRequest() throws {
        for line in ["42", "\"ping\"", "null", "true"] {
            let error = try #require(invalid(line), "\(line) was taken for a message")
            #expect(error.code == -32600, "\(line)")
            #expect(error.id == nil, "\(line)")
        }
    }

    /// MCP 2025-06-18 removed JSON-RPC batching; JSON-RPC answers an unsupported or empty batch
    /// with one Invalid Request.
    @Test("A batch is an Invalid Request in the revision this server speaks")
    func batchIsInvalid() throws {
        #expect(MCPProtocol.revision == "2025-06-18", "batching rules were checked against 2025-06-18; check them again")
        for line in ["[]", #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#] {
            let error = try #require(invalid(line))
            #expect(error.code == -32600)
            #expect(error.id == nil)
        }
    }

    @Test("A request with a bad id, version, method or params says so, with its id when it has one")
    func malformedRequests() throws {
        for line in [#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#] {
            let error = try #require(invalid(line), "\(line)")
            #expect(error.code == -32600, "\(line)")
            #expect(error.id == nil, "\(line)")
        }
        let method = try #require(invalid(#"{"jsonrpc":"2.0","id":5,"method":5}"#))
        #expect(method.code == -32600)
        #expect((method.id as? NSNumber)?.intValue == 5)
        #expect(invalid(#"{"jsonrpc":"1.0","id":"a","method":"ping"}"#)?.code == -32600)
        #expect(invalid(#"{"id":1,"method":"ping"}"#)?.code == -32600)
        #expect(invalid(#"{"jsonrpc":"2.0","id":1}"#)?.code == -32600)
        #expect(invalid(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":"x"}"#)?.code == -32600)
        #expect(invalid(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[1]}"#)?.code == -32602)
    }

    @Test("Requests, notifications and responses are told apart")
    func validMessages() {
        guard case .request(let id, "ping", _) = MCPMessage.parse(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#) else {
            Issue.record("a request with a string id was not a request")
            return
        }
        #expect(id as? String == "a")
        if case .request = MCPMessage.parse(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}"#) {} else {
            Issue.record("a request with an integer id was not a request")
        }
        if case .notification("notifications/initialized", _) = MCPMessage.parse(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) {} else {
            Issue.record("a notification was not a notification")
        }
        if case .response = MCPMessage.parse(#"{"jsonrpc":"2.0","id":3,"result":{}}"#) {} else {
            Issue.record("a response was not recognised as one")
        }
    }

    // MARK: - MCP tool arguments

    @Test("An undeclared tool, or none, is refused")
    func unknownTool() {
        #expect(MCPTools.callProblem(["name": "nope", "arguments": [String: Any]()]) == "Unknown tool: nope")
        #expect(MCPTools.callProblem(["arguments": [String: Any]()]) != nil)
        #expect(MCPTools.callProblem(["name": 3]) != nil)
    }

    /// Walks the declared schemas, so an argument added later is covered without touching this test.
    @Test("Every declared argument refuses a value of the wrong JSON type, and names itself")
    func everyArgumentRefusesTheWrongType() throws {
        var checked = 0
        for tool in MCPTools.definitions() {
            let name = try #require(tool["name"] as? String)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            let properties = schema["properties"] as? [String: Any] ?? [:]
            var valid: [String: Any] = [:]
            for case let (key, property as [String: Any]) in properties {
                valid[key] = property["type"] as? String == "integer" ? 3 : ((property["enum"] as? [String])?.first ?? "x")
            }
            #expect(MCPTools.callProblem(["name": name, "arguments": valid]) == nil, "\(name) refused \(valid)")
            for case let (key, property as [String: Any]) in properties {
                checked += 1
                let wrong: Any = property["type"] as? String == "string" ? 3 : "8k"
                var arguments = valid
                arguments[key] = wrong
                let problem = MCPTools.callProblem(["name": name, "arguments": arguments])
                #expect(problem?.contains("'\(key)'") == true, "\(name).\(key) = \(wrong) was accepted: \(problem ?? "nil")")
            }
        }
        #expect(checked > 15, "the walk found only \(checked) arguments")
    }

    @Test("Integers, enums, required arguments and the arguments object are checked as the schema says")
    func argumentDetails() {
        func problem(_ arguments: Any) -> String? {
            MCPTools.callProblem(["name": "call_hierarchy", "arguments": arguments])
        }
        #expect(problem(["symbol": "f", "depth": 2]) == nil)
        #expect(problem(["symbol": "f", "depth": 2.0]) == nil)
        #expect(problem(["symbol": "f", "depth": 2.5])?.contains("'depth' must be an integer") == true)
        #expect(problem(["symbol": "f", "depth": true])?.contains("'depth'") == true)
        #expect(problem(["symbol": "f", "depth": NSNull()])?.contains("'depth'") == true)
        #expect(problem(["symbol": "f", "direction": "up"])?.contains("'direction' must be one of: callees, callers") == true)
        #expect(problem(["depth": 2])?.contains("'symbol' is required") == true)
        #expect(problem("symbol")?.contains("arguments must be an object") == true)
        #expect(MCPTools.callProblem(["name": "lint"]) == nil, "no arguments is an empty object")
    }

    /// None of the declared schemas closes its properties, so an extra argument is accepted; a
    /// schema that did close them would be enforced.
    @Test("Extra arguments follow additionalProperties")
    func extraArguments() {
        for tool in MCPTools.definitions() {
            let schema = tool["inputSchema"] as? [String: Any] ?? [:]
            #expect(schema["additionalProperties"] == nil, "\(tool["name"] ?? "?") now declares additionalProperties")
        }
        #expect(MCPTools.callProblem(["name": "lint", "arguments": ["extra": 1]]) == nil)
        let closed: [String: Any] = ["type": "object", "properties": ["a": ["type": "string"]], "additionalProperties": false]
        #expect(MCPTools.argumentProblems(["b": 1], schema: closed) == ["'b' is not an argument of this tool"])
    }
}
