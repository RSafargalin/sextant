import Foundation

/// Hygiene rules over the Objective-C, C and C++ sources of a project.
///
/// Each file is read once for every rule: all the patterns are appended to it as probes in a
/// single parse, the way the Swift engine walks a tree once for all patterns.
///
/// A rule written for another language simply does not compile here, and that is not a gap — a
/// Swift rule has nothing to say about a `.m` file. What would be a gap is a file where **no**
/// rule could run: then nothing was checked, and the file is reported as unscanned.
public enum CFamilyLint {
    public struct Outcome: Sendable {
        public let violations: [RuleViolation]
        public let unscanned: [UnscannedFile]
        /// Lines in `#if` branches the build does not contain that mention what a rule looks for.
        /// Not verified against a tree — that code was never compiled — but a rule report that
        /// stayed silent about them would be clean about code it never checked.
        public let inactive: [StructuralHit]
        /// Target triples the checked files were built for.
        public let targets: Set<String>
        /// Files clang reported errors in: checked, but through its recovery from them.
        public var recovered: [UnscannedFile] = []
        /// Patterns (by `patternKey`) that compiled in at least one file.
        public var compiledPatterns: Set<String> = []
        /// Patterns (by `patternKey`) that failed somewhere, with the first reason.
        public var failedPatterns: [String: String] = [:]
    }

    /// How a rule's pattern is told apart from the same text in another rule.
    public static func patternKey(ruleID: String, pattern: String) -> String { "\(ruleID)\u{1}\(pattern)" }

    public static func run(rules: [Rule], lintRoot: String, projectRoot: String, includeTests: Bool) -> Outcome {
        let root = URL(fileURLWithPath: lintRoot, isDirectory: true)
        let sources = CompilationDatabase.compilableSources(projectRoot: lintRoot, includeTests: includeTests)
        // What a header contains is never matched — only a translation unit's own declarations
        // are — so a header is named whatever happens to the sources.
        let headers = CFamilySearch.unscannedHeaders(root: lintRoot, includeTests: includeTests)
        guard !sources.isEmpty else { return Outcome(violations: [], unscanned: headers, inactive: [], targets: []) }

        // Rule and pattern side by side, so a match knows which rule to report.
        var compiled: [(rule: Rule, search: ClangPatternSearch, key: String)] = []
        var failedPatterns: [String: String] = [:]
        for rule in rules {
            for pattern in rule.patterns {
                let key = patternKey(ruleID: rule.id, pattern: pattern)
                do { compiled.append((rule, try ClangPatternSearch(pattern: pattern), key)) }
                catch { failedPatterns[key] = "\(error)" }
            }
        }
        let engines = compiled.map { $0.search }
        guard !engines.isEmpty else {
            var outcome = Outcome(violations: [], unscanned: headers + sources.map {
                UnscannedFile(file: relative($0, root), reason: "no rule pattern could be compiled for the C family")
            }, inactive: [], targets: [])
            outcome.failedPatterns = failedPatterns
            return outcome
        }

        let library: ClangLibrary
        do {
            library = try ClangLibrary.shared()
        } catch {
            return Outcome(violations: [], unscanned: headers + sources.map {
                UnscannedFile(file: relative($0, root), reason: "\(error)")
            }, inactive: [], targets: [])
        }

        var commandByFile: [String: CompileCommand] = [:]
        for command in CompilationDatabase.commands(forFilesUnder: projectRoot) {
            commandByFile[URL(fileURLWithPath: command.file).resolvingSymlinksInPath().path] = command
        }

        var violations: [RuleViolation] = []
        var unscanned = headers
        var inactive: [StructuralHit] = []
        var targets: Set<String> = []
        var recovered: [UnscannedFile] = []
        var compiledPatterns: Set<String> = []
        for source in sources {
            // A file nobody could open is not a file that was checked. clang reports its own
            // failure as diagnostics and returns an empty unit, which counts as "scanned, clean".
            guard FileManager.default.isReadableFile(atPath: source) else {
                unscanned.append(UnscannedFile(file: relative(source, root),
                                               reason: "could not be read (permissions?)"))
                continue
            }
            guard let command = commandByFile[source] else {
                unscanned.append(UnscannedFile(
                    file: relative(source, root),
                    reason: "no compile flags — build the index: `sextant index`"
                ))
                continue
            }
            var failedHere = Set<Int>()
            do {
                let outcome = try ClangPatternSearch.searchAll(
                    engines, file: source,
                    arguments: CompilationDatabase.parseArguments(of: command),
                    library: library,
                    notCompiled: { index, diagnostics in
                        failedHere.insert(index)
                        let key = compiled[index].key
                        if failedPatterns[key] == nil {
                            failedPatterns[key] = diagnostics.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                                ?? "it does not compile"
                        }
                    }
                )
                for index in compiled.indices where !failedHere.contains(index) { compiledPatterns.insert(compiled[index].key) }
                if !outcome.fileErrors.isEmpty {
                    recovered.append(UnscannedFile(file: relative(source, root), reason: CFamilySearch.compileErrorReason))
                }
                if let target = CompilationDatabase.target(of: command) { targets.insert(target) }
                for (index, match) in outcome.matches {
                    let rule = compiled[index].rule
                    violations.append(RuleViolation(ruleID: rule.id, file: relative(source, root),
                                                    line: match.line, column: match.column,
                                                    text: match.text, message: rule.message))
                }
                // The same rules, looked for textually in the branches this build left out.
                if let raw = FileManager.default.contents(atPath: source),
                   // The same byte sequence clang was given: see ClangPatternSearch.searchAll.
                   case let data = Data(String(decoding: raw, as: UTF8.self).utf8), !outcome.skippedRanges.isEmpty {
                    var seen = Set<String>()
                    for (rule, engine, _) in compiled {
                        for hit in InactiveRegionScan.occurrences(anchors: engine.anchors, source: data,
                                                                  ranges: outcome.skippedRanges)
                        where seen.insert("\(rule.id)|\(hit.line)").inserted {
                            inactive.append(StructuralHit(file: relative(source, root), line: hit.line,
                                                          column: hit.column, text: "[\(rule.id)] \(hit.text)"))
                        }
                    }
                }
            } catch {
                // Not one rule could be compiled here, so nothing was checked in this file. What
                // failed is the patterns, so the reason names the first of them rather than reading
                // as a fault of the file.
                let first = failedHere.min().map { patternText(of: compiled[$0].key) }
                unscanned.append(UnscannedFile(file: relative(source, root), reason: reason(of: error, firstPattern: first)))
            }
        }

        var seen = Set<String>()
        let unique = violations.filter { seen.insert("\($0.ruleID)|\($0.file)|\($0.line)|\($0.column)").inserted }
        var outcome = Outcome(violations: unique, unscanned: unscanned, inactive: inactive, targets: targets)
        outcome.recovered = recovered
        outcome.compiledPatterns = compiledPatterns
        outcome.failedPatterns = failedPatterns
        return outcome
    }

    private static func relative(_ path: String, _ root: URL) -> String {
        SwiftSources.relativePath(of: URL(fileURLWithPath: path), root: root)
    }

    /// Why a file was not checked at all. When no pattern compiled in it, the diagnostic belongs
    /// to a pattern — a rule written for another language — so it is stated as that pattern's.
    private static func reason(of error: Error, firstPattern: String?) -> String {
        guard case ClangPatternSearch.Failure.patternNotCompiled(_, let diagnostics) = error else { return "\(error)" }
        let first = diagnostics.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstPattern else { return "no rule could be checked here" + (first.map { ": \($0)" } ?? "") }
        return "no rule could be checked here: no rule pattern compiles as Objective-C, C or C++ in this file "
            + "(the first, `\(firstPattern)`" + (first.map { ", fails with \"\($0)\"" } ?? "") + ")"
    }

    private static func patternText(of key: String) -> String {
        key.split(separator: "\u{1}", maxSplits: 1).dropFirst().first.map(String.init) ?? key
    }
}
