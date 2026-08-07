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
    }

    public static func run(rules: [Rule], lintRoot: String, projectRoot: String, includeTests: Bool) -> Outcome {
        let root = URL(fileURLWithPath: lintRoot, isDirectory: true)
        let sources = CompilationDatabase.compilableSources(projectRoot: lintRoot, includeTests: includeTests)
        guard !sources.isEmpty else { return Outcome(violations: [], unscanned: [], inactive: [], targets: []) }

        // Rule and pattern side by side, so a match knows which rule to report.
        var compiled: [(rule: Rule, search: ClangPatternSearch)] = []
        for rule in rules {
            for pattern in rule.patterns {
                if let search = try? ClangPatternSearch(pattern: pattern) { compiled.append((rule, search)) }
            }
        }
        let engines = compiled.map { $0.search }
        guard !engines.isEmpty else {
            return Outcome(violations: [], unscanned: sources.map {
                UnscannedFile(file: relative($0, root), reason: "no rule pattern could be compiled for the C family")
            }, inactive: [], targets: [])
        }

        let library: ClangLibrary
        do {
            library = try ClangLibrary.shared()
        } catch {
            return Outcome(violations: [], unscanned: sources.map {
                UnscannedFile(file: relative($0, root), reason: "\(error)")
            }, inactive: [], targets: [])
        }

        var commandByFile: [String: CompileCommand] = [:]
        for command in CompilationDatabase.load(forRoot: projectRoot) {
            commandByFile[URL(fileURLWithPath: command.file).resolvingSymlinksInPath().path] = command
        }

        var violations: [RuleViolation] = []
        var unscanned: [UnscannedFile] = []
        var inactive: [StructuralHit] = []
        var targets: Set<String> = []
        for source in sources {
            guard let command = commandByFile[source] else {
                unscanned.append(UnscannedFile(
                    file: relative(source, root),
                    reason: "no compile flags — build the index: `sextant index`"
                ))
                continue
            }
            do {
                let outcome = try ClangPatternSearch.searchAll(
                    engines, file: source,
                    arguments: CompilationDatabase.parseArguments(of: command),
                    library: library
                )
                if let target = CompilationDatabase.target(of: command) { targets.insert(target) }
                for (index, match) in outcome.matches {
                    let rule = compiled[index].rule
                    violations.append(RuleViolation(ruleID: rule.id, file: relative(source, root),
                                                    line: match.line, column: match.column,
                                                    text: match.text, message: rule.message))
                }
                // The same rules, looked for textually in the branches this build left out.
                if let data = FileManager.default.contents(atPath: source), !outcome.skippedRanges.isEmpty {
                    var seen = Set<String>()
                    for (rule, engine) in compiled {
                        for hit in InactiveRegionScan.occurrences(anchors: engine.anchors, source: data,
                                                                  ranges: outcome.skippedRanges)
                        where seen.insert("\(rule.id)|\(hit.line)").inserted {
                            inactive.append(StructuralHit(file: relative(source, root), line: hit.line,
                                                          column: hit.column, text: "[\(rule.id)] \(hit.text)"))
                        }
                    }
                }
            } catch {
                // Not one rule could be compiled here, so nothing was checked in this file.
                unscanned.append(UnscannedFile(file: relative(source, root), reason: reason(of: error)))
            }
        }

        var seen = Set<String>()
        let unique = violations.filter { seen.insert("\($0.ruleID)|\($0.file)|\($0.line)|\($0.column)").inserted }
        return Outcome(violations: unique, unscanned: unscanned, inactive: inactive, targets: targets)
    }

    private static func relative(_ path: String, _ root: URL) -> String {
        SwiftSources.relativePath(of: URL(fileURLWithPath: path), root: root)
    }

    private static func reason(of error: Error) -> String {
        guard case ClangPatternSearch.Failure.patternNotCompiled(_, let diagnostics) = error else { return "\(error)" }
        let first = diagnostics.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "no rule could be checked here" + (first.map { ": \($0)" } ?? "")
    }
}
