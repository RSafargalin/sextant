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

    /// One file's cacheable result: its violations, and whether its tree was a recovery from errors.
    private struct CachedFile: Codable {
        let violations: [CachedViolation]
        let hasSyntaxErrors: Bool
        let unknownOperators: [String]
    }

    /// What a lint run found, and what it could not look at. The second half is not a detail: a
    /// clean report over files that were never opened is a clean bill of health for unexamined code.
    public struct Outcome: Sendable {
        public let violations: [RuleViolation]
        public let unscanned: [UnscannedFile]
        /// Possible violations in `#if` branches the build does not contain — textual, unverified.
        public let inactive: [StructuralHit]
        public let targets: Set<String>
        /// Patterns that never compiled. They match nothing, so without naming them a clean report
        /// is produced by a rule set that partly did not run.
        public let broken: [BrokenPattern]
        /// Files checked with reservations — through the parser's recovery from errors, or with an
        /// operator expression that could not be folded: a violation in them may be missed.
        public var recovered: [UnscannedFile] = []
    }

    /// A rule pattern the structural parser rejected.
    public struct BrokenPattern: Sendable {
        public let ruleID: String
        public let pattern: String
        public let reason: String
    }

    /// The patterns in a rule set that no engine can use.
    ///
    /// A pattern is broken when Swift rejects it and the C family cannot use it either: a rule
    /// written for one language rightly does not compile in the other. Without `cFamily` — no
    /// C-family run — only what is knowable from the text counts: the C engine refusing it
    /// outright. With it, a pattern clang compiled in some file is not broken, and one it never
    /// got to try is named as such rather than declared broken or usable.
    public static func brokenPatterns(in rules: [Rule], cFamily: CFamilyLint.Outcome? = nil) -> [BrokenPattern] {
        rules.flatMap { rule in
            rule.patterns.compactMap { pattern -> BrokenPattern? in
                let swiftReason: String
                do { _ = try PatternSearch(pattern: pattern); return nil }
                catch { swiftReason = "\(error)" }
                let key = CFamilyLint.patternKey(ruleID: rule.id, pattern: pattern)
                let cReason: String
                do {
                    _ = try ClangPatternSearch(pattern: pattern)
                    guard let cFamily else { return BrokenPattern(ruleID: rule.id, pattern: pattern, reason: swiftReason) }
                    if cFamily.compiledPatterns.contains(key) { return nil }
                    cReason = cFamily.failedPatterns[key] ?? "no Objective-C, C or C++ file was checked with it"
                } catch {
                    cReason = "\(error)"
                }
                return BrokenPattern(ruleID: rule.id, pattern: pattern,
                                     reason: "Swift: \(swiftReason); Objective-C, C and C++: \(cReason)")
            }
        }
    }

    /// One line per pattern that never ran, for the surfaces that print warnings.
    public static func brokenReport(_ broken: [BrokenPattern]) -> [String] {
        broken.map { "⚠ rule '\($0.ruleID)': pattern \($0.pattern) could not be compiled (\($0.reason)) — it matched nothing." }
    }

    /// Runs the rules over a project: Swift through its own parser, then Objective-C, C and C++
    /// through clang. `projectRoot` is where the compile flags are looked up, which is not always
    /// the directory being linted (`--scope` narrows the second, not the first).
    public static func run(rules: [Rule], projectRoot: String, lintRoot: String, includeTests: Bool,
                           cache: SourceParseCache = SourceParseCache(), fileLimit: Int? = nil) -> Outcome {
        let swift = runSwift(rules: rules, projectRoot: lintRoot, includeTests: includeTests, cache: cache,
                             fileLimit: fileLimit)
        let cFamily = CFamilyLint.run(rules: rules, lintRoot: lintRoot, projectRoot: projectRoot, includeTests: includeTests)
        var outcome = Outcome(violations: swift.violations + cFamily.violations,
                              unscanned: swift.unscanned + cFamily.unscanned
                                + StructuralCoverage.skippedDirectories(projectRoot: lintRoot),
                              inactive: cFamily.inactive, targets: cFamily.targets,
                              broken: brokenPatterns(in: rules, cFamily: cFamily))
        outcome.recovered = swift.recovered + cFamily.recovered
        return outcome
    }

    /// Runs the rules over every Swift file in the project. A file is parsed once for all patterns.
    /// Result cache keyed by (file content hash + rules hash): on an unchanged file with the same
    /// rules, parsing and matching are skipped — linting a whole project on a warm cache is sub-second.
    public static func run(rules: [Rule], projectRoot: String, includeTests: Bool,
                           cache: SourceParseCache = SourceParseCache(), fileLimit: Int? = nil) -> [RuleViolation] {
        runSwift(rules: rules, projectRoot: projectRoot, includeTests: includeTests, cache: cache,
                 fileLimit: fileLimit).violations
    }

    /// The Swift half of a run, with the files it could not read and those it read through errors.
    static func runSwift(rules: [Rule], projectRoot: String, includeTests: Bool, cache: SourceParseCache,
                         fileLimit: Int?) -> (violations: [RuleViolation], unscanned: [UnscannedFile],
                                              recovered: [UnscannedFile]) {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let compiled: [(rule: Rule, search: PatternSearch)] = rules.flatMap { rule in
            rule.patterns.compactMap { pattern in
                (try? PatternSearch(pattern: pattern)).map { (rule, $0) }
            }
        }
        let engines = compiled.map { $0.search }

        let rulesHash = rulesKey(rules)
        let resultCache = PersistentCache<CachedFile>(namespace: "lint-v3")

        var violations: [RuleViolation] = []
        var unscanned: [UnscannedFile] = []
        var recovered: [UnscannedFile] = []
        let files = SwiftSources.files(under: root, includeTests: includeTests, limit: fileLimit)
        let folding = OperatorFolding.Session(files: files, cache: cache)
        for file in files {
            let relative = SwiftSources.relativePath(of: file, root: root)
            let key = ContentHash.ofFile(file.path).map { "\($0)-\(rulesHash)" }

            let fileResult: CachedFile
            if let key, let cached = resultCache.value(forKey: key) {
                fileResult = cached
            } else {
                let read = cache.read(atPath: file.path)
                guard case .parsed(let tree) = read else {
                    if let file = StructuralCoverage.unscanned(read, file: relative) { unscanned.append(file) }
                    continue
                }
                // One tree walk for every pattern, instead of N walks.
                var found: [CachedViolation] = []
                let (folded, usedDeclaredOperators) = folding.fold(tree)
                for (index, match) in PatternSearch.searchAll(engines, inFolded: folded.tree, fileName: relative) {
                    let rule = compiled[index].rule
                    found.append(CachedViolation(ruleID: rule.id, line: match.line, column: match.column, text: match.text, message: rule.message))
                }
                fileResult = CachedFile(violations: found, hasSyntaxErrors: tree.hasError,
                                        unknownOperators: folded.unknownOperators)
                // A result that relied on operators declared elsewhere is not this file's alone.
                if let key, !usedDeclaredOperators { resultCache.set(fileResult, forKey: key) }
            }
            if fileResult.hasSyntaxErrors {
                recovered.append(UnscannedFile(file: relative, reason: StructuralCoverage.syntaxErrorReason))
            }
            if !fileResult.unknownOperators.isEmpty {
                recovered.append(UnscannedFile(file: relative, reason: OperatorFolding.reservation(fileResult.unknownOperators)))
            }
            for violation in fileResult.violations {
                violations.append(RuleViolation(ruleID: violation.ruleID, file: relative, line: violation.line, column: violation.column, text: violation.text, message: violation.message))
            }
        }
        var seen = Set<String>()
        return (violations.filter { seen.insert("\($0.ruleID)|\($0.file)|\($0.line)|\($0.column)").inserted },
                unscanned, recovered)
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
