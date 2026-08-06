import Foundation

/// A golden spec: a set of assertions of the form "symbol → expected semantic result".
/// It catches silent semantic regressions: a deterministic tier on a fixture in CI, and a field
/// tier of invariants on real projects.
public struct GoldenSpec: Codable, Sendable {
    public let assertions: [GoldenAssertion]
    public init(assertions: [GoldenAssertion]) { self.assertions = assertions }
}

/// One assertion. `query` ∈ defs|refs|callers|callees|impls|supertypes. The checks are optional,
/// and all of those given are applied together (AND).
public struct GoldenAssertion: Codable, Sendable {
    public let query: String
    public let symbol: String
    /// Exact result count: definitions (defs), occurrences (refs/callers), or related symbols.
    public var exactCount: Int?
    /// Minimum count.
    public var minCount: Int?
    /// At least one result path contains this substring.
    public var pathContains: String?
    /// A symbol with this name is among the results (for callees/impls/supertypes).
    public var containsName: String?
    /// No result path contains this substring (a guard against `/.build/` and foreign worktrees).
    public var noPathContains: String?

    public init(query: String, symbol: String, exactCount: Int? = nil, minCount: Int? = nil,
                pathContains: String? = nil, containsName: String? = nil, noPathContains: String? = nil) {
        self.query = query
        self.symbol = symbol
        self.exactCount = exactCount
        self.minCount = minCount
        self.pathContains = pathContains
        self.containsName = containsName
        self.noPathContains = noPathContains
    }
}

public struct GoldenResult: Encodable, Sendable {
    public let query: String
    public let symbol: String
    public let passed: Bool
    public let detail: String
}

public enum Golden {
    public static func evaluate(_ spec: GoldenSpec, against index: IndexStoreSet) -> [GoldenResult] {
        spec.assertions.map { evaluate($0, against: index) }
    }

    static func evaluate(_ assertion: GoldenAssertion, against index: IndexStoreSet) -> GoldenResult {
        let names: [String]
        let paths: [String]
        let count: Int

        switch assertion.query {
        case "defs":
            let hits = index.lookup(name: assertion.symbol, query: .definitions)
            let definitions = hits.compactMap { $0.definition }
            names = hits.map { $0.name }
            paths = definitions.map { $0.path }
            count = definitions.count
        case "refs", "callers":
            let hits = index.lookup(name: assertion.symbol, query: assertion.query == "refs" ? .references : .callers)
            names = hits.map { $0.name }
            let references = hits.flatMap { $0.references }
            paths = references.map { $0.path }
            count = references.count
        case "impls", "supertypes":
            let related = index.related(toName: assertion.symbol, query: assertion.query == "impls" ? .implementations : .supertypes)
            names = related.map { $0.name }
            paths = related.map { $0.location.path }
            count = related.count
        case "callees":
            let related = index.related(toName: assertion.symbol, query: .callees)
            names = related.map { $0.name }
            paths = related.map { $0.location.path }
            // Distinct symbols, matching what the command reports: the same callee invoked twice
            // is one callee.
            count = Set(related.map { $0.usr }).count
        default:
            return GoldenResult(query: assertion.query, symbol: assertion.symbol, passed: false,
                                detail: "unknown query '\(assertion.query)'")
        }

        var failures: [String] = []
        if let exact = assertion.exactCount, count != exact { failures.append("count \(count) ≠ exact \(exact)") }
        if let min = assertion.minCount, count < min { failures.append("count \(count) < min \(min)") }
        if let name = assertion.containsName, !names.contains(name) {
            failures.append("no '\(name)' among [\(names.prefix(5).joined(separator: ", "))]")
        }
        if let sub = assertion.pathContains, !paths.contains(where: { $0.contains(sub) }) {
            failures.append("no path contains '\(sub)'")
        }
        if let sub = assertion.noPathContains, let bad = paths.first(where: { $0.contains(sub) }) {
            failures.append("path contains the forbidden '\(sub)': \(bad)")
        }

        let passed = failures.isEmpty
        return GoldenResult(query: assertion.query, symbol: assertion.symbol, passed: passed,
                            detail: passed ? "ok (count=\(count))" : failures.joined(separator: "; "))
    }
}
