import Foundation

/// Runs structural hygiene rules over a project — an exact AST replacement for regex checks.
public enum RuleEngine {
    /// The built-in rules are a **starting point, not a safe default for every project**.
    ///
    /// There is no such thing as a universal set: `print-call` is wrong for a command-line tool,
    /// where printing is the output, and `force-unwrap` is noise in interop-heavy code where the
    /// C API guarantees non-nil. sextant's own `sextant-rules.json` therefore takes two of these
    /// and leaves the rest — deliberately, not by drift. What they are *for* is to show what the
    /// format expresses, and to give a project something to copy and edit.
    public static let builtinRules: [Rule] = [
        Rule(
            id: "system-state",
            message: "Global state (.current) — inject the dependency instead",
            patterns: ["Calendar.current", "TimeZone.current", "Locale.current"]
        ),
        Rule(
            id: "force-try",
            message: "Forced try! — handle the error explicitly",
            patterns: ["try! $X"]
        ),
        Rule(
            id: "print-call",
            message: "print(...) in production code — use a logger",
            patterns: ["print($$$)"]
        ),
        Rule(
            id: "force-unwrap",
            message: "Forced unwrap — bind it, or say why it cannot be nil",
            patterns: ["$X!"]
        )
    ]

    /// A rule set and where it came from. `lint` says which was used: a report of "no violations"
    /// means something different when it came from two rules than from five.
    public struct RuleSet: Sendable {
        public let rules: [Rule]
        public let origin: String

        public init(rules: [Rule], origin: String) {
            self.rules = rules
            self.origin = origin
        }
    }

    /// A violation without its path: the cacheable, path-independent part (content hash + rules hash → this).
    private struct CachedViolation: Codable {
        let ruleID: String
        let line: Int
        let column: Int
        let text: String
        let message: String
    }

    /// What a lint run found, and what it could not look at. The second half is not a detail: a
    /// clean report over files that were never opened is a clean bill of health for unexamined code.
    public struct Outcome: Sendable {
        public let violations: [RuleViolation]
        public let unscanned: [UnscannedFile]
        /// Possible violations in `#if` branches the build does not contain — textual, unverified.
        public let inactive: [StructuralHit]
        public let targets: Set<String>
    }

    /// Runs the rules over a project: Swift through its own parser, then Objective-C, C and C++
    /// through clang. `projectRoot` is where the compile flags are looked up, which is not always
    /// the directory being linted (`--scope` narrows the second, not the first).
    public static func run(rules: [Rule], projectRoot: String, lintRoot: String, includeTests: Bool,
                           cache: SourceParseCache = SourceParseCache()) -> Outcome {
        let violations = run(rules: rules, projectRoot: lintRoot, includeTests: includeTests, cache: cache)
        let cFamily = CFamilyLint.run(rules: rules, lintRoot: lintRoot, projectRoot: projectRoot, includeTests: includeTests)
        return Outcome(violations: violations + cFamily.violations, unscanned: cFamily.unscanned,
                       inactive: cFamily.inactive, targets: cFamily.targets)
    }

    /// Runs the rules over every Swift file in the project. A file is parsed once for all patterns.
    /// Result cache keyed by (file content hash + rules hash): on an unchanged file with the same
    /// rules, parsing and matching are skipped — linting a whole project on a warm cache is sub-second.
    public static func run(rules: [Rule], projectRoot: String, includeTests: Bool, cache: SourceParseCache = SourceParseCache()) -> [RuleViolation] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let compiled: [(rule: Rule, search: PatternSearch)] = rules.flatMap { rule in
            rule.patterns.compactMap { pattern in
                (try? PatternSearch(pattern: pattern)).map { (rule, $0) }
            }
        }
        let engines = compiled.map { $0.search }

        let rulesHash = rulesKey(rules)
        let resultCache = PersistentCache<[CachedViolation]>(namespace: "lint-v1")

        var violations: [RuleViolation] = []
        for file in SwiftSources.files(under: root, includeTests: includeTests) {
            let relative = SwiftSources.relativePath(of: file, root: root)
            guard let contentHash = ContentHash.ofFile(file.path) else { continue }
            let key = "\(contentHash)-\(rulesHash)"

            let fileViolations: [CachedViolation]
            if let cached = resultCache.value(forKey: key) {
                fileViolations = cached
            } else {
                guard let tree = cache.tree(atPath: file.path) else { continue }
                // One tree walk for every pattern, instead of N walks.
                var found: [CachedViolation] = []
                for (index, match) in PatternSearch.searchAll(engines, in: tree, fileName: relative) {
                    let rule = compiled[index].rule
                    found.append(CachedViolation(ruleID: rule.id, line: match.line, column: match.column, text: match.text, message: rule.message))
                }
                resultCache.set(found, forKey: key)
                fileViolations = found
            }

            for violation in fileViolations {
                violations.append(RuleViolation(ruleID: violation.ruleID, file: relative, line: violation.line, column: violation.column, text: violation.text, message: violation.message))
            }
        }
        var seen = Set<String>()
        return violations.filter { seen.insert("\($0.ruleID)|\($0.file)|\($0.line)|\($0.column)").inserted }
    }

    /// Deterministic cache key for a rule set: a canonical string form, NOT JSONEncoder — its output
    /// is not byte-stable across processes, so the key drifted and every run missed the cache.
    static func rulesKey(_ rules: [Rule]) -> String {
        let canonical = rules
            .map { "\($0.id)\u{1}\($0.message)\u{1}\($0.patterns.joined(separator: "\u{2}"))" }
            .joined(separator: "\u{3}")
        return ContentHash.of(canonical)
    }

    /// Loads rules from a JSON file.
    ///
    /// Two shapes, and the difference is deliberate. A bare array **replaces** the built-in set,
    /// which is what `--rules` has always done and what a project wanting exactly its own rules
    /// expects. An object with `"extends": "builtin"` adds to them instead — the answer to
    /// "I want the defaults plus two of mine", which previously meant copying the defaults by hand
    /// and losing them at the next release.
    ///
    /// ```json
    /// [ { "id": "...", "message": "...", "patterns": ["..."] } ]
    /// { "extends": "builtin", "rules": [ … ] }
    /// ```
    public static func loadRules(fromJSONAt path: String) throws -> RuleSet {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let name = (path as NSString).lastPathComponent
        if let array = try? JSONDecoder().decode([Rule].self, from: data) {
            return RuleSet(rules: array, origin: "\(array.count) from \(name) (the built-in set is replaced)")
        }
        let file = try JSONDecoder().decode(RulesFile.self, from: data)
        guard file.extends == "builtin" else {
            return RuleSet(rules: file.rules, origin: "\(file.rules.count) from \(name) (the built-in set is replaced)")
        }
        let combined = builtinRules + file.rules
        return RuleSet(rules: combined,
                       origin: "\(combined.count): \(builtinRules.count) built-in extended by \(file.rules.count) from \(name)")
    }

    /// The object form of a rules file.
    private struct RulesFile: Decodable {
        let extends: String?
        let rules: [Rule]
    }

    /// The built-in set, with its provenance stated — it is a starting point, and a report should
    /// not let that pass for a considered project rule set.
    public static var builtinSet: RuleSet {
        RuleSet(rules: builtinRules, origin: "\(builtinRules.count) built-in (a starting point — copy them into .sextant.json rules and edit)")
    }
}
