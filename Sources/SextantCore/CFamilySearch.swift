import Foundation

/// One structural hit, with the file it is in.
public struct StructuralHit: Codable, Sendable {
    public let file: String
    public let line: Int
    public let column: Int
    public let text: String

    public init(file: String, line: Int, column: Int, text: String) {
        self.file = file
        self.line = line
        self.column = column
        self.text = text
    }
}

/// A file a structural query did not cover, and why. Never a silent omission: a question answered
/// over part of a project has to say which part.
public struct UnscannedFile: Codable, Sendable {
    public let file: String
    public let reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

/// Structural search over the Objective-C, C and C++ sources of a project.
///
/// Each file is parsed by clang with the flags it was built with, taken from `CompilationDatabase`.
/// A file whose flags are unknown is listed as unscanned rather than parsed on a guess: clang
/// builds a complete tree only with the real flags, and a tree built on approximate ones would
/// quietly cover a fraction of the code.
public enum CFamilySearch {
    public struct Outcome: Sendable {
        public let hits: [StructuralHit]
        public let unscanned: [UnscannedFile]
        /// Files actually parsed and matched — what the answer does cover.
        public let scannedCount: Int
        /// Target triples the scanned files were built for; they decide which `#if` branches exist.
        public let targets: Set<String>
        /// Textual occurrences inside `#if` branches this build does not contain. Not structurally
        /// verified — but leaving them out would answer for part of the sources as if it were all.
        public let inactive: [StructuralHit]
    }

    public static func run(pattern: String, searchRoot: String, projectRoot: String, includeTests: Bool) -> Outcome {
        let root = URL(fileURLWithPath: searchRoot, isDirectory: true)
        let sources = CompilationDatabase.compilableSources(projectRoot: searchRoot, includeTests: includeTests)
        let headers = headerFiles(searchRoot: searchRoot, includeTests: includeTests)
            .map { UnscannedFile(file: relative($0, root), reason: "a header is not a compilation unit") }
        guard !sources.isEmpty else { return Outcome(hits: [], unscanned: headers, scannedCount: 0, targets: [], inactive: []) }

        let engine: ClangPatternSearch
        do {
            engine = try ClangPatternSearch(pattern: pattern)
        } catch {
            return Outcome(hits: [], unscanned: headers + sources.map {
                UnscannedFile(file: relative($0, root), reason: "\(error)")
            }, scannedCount: 0, targets: [], inactive: [])
        }

        let library: ClangLibrary
        do {
            library = try ClangLibrary.shared()
        } catch {
            return Outcome(hits: [], unscanned: headers + sources.map {
                UnscannedFile(file: relative($0, root), reason: "\(error)")
            }, scannedCount: 0, targets: [], inactive: [])
        }

        // The database is stored per project, while the search may be narrowed to a subdirectory.
        var commandByFile: [String: CompileCommand] = [:]
        for command in CompilationDatabase.load(forRoot: projectRoot) {
            commandByFile[URL(fileURLWithPath: command.file).resolvingSymlinksInPath().path] = command
        }

        var hits: [StructuralHit] = []
        var unscanned = headers
        var scanned = 0
        var targets: Set<String> = []
        var inactive: [StructuralHit] = []
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
                    [engine], file: source,
                    arguments: CompilationDatabase.parseArguments(of: command),
                    library: library
                )
                scanned += 1
                if let target = CompilationDatabase.target(of: command) { targets.insert(target) }
                hits += outcome.matches.map {
                    StructuralHit(file: relative(source, root), line: $0.match.line,
                                  column: $0.match.column, text: $0.match.text)
                }
                // What the build skipped can only be answered textually, and is kept apart from
                // the matches so the two are never read as one number.
                if let data = FileManager.default.contents(atPath: source) {
                    inactive += InactiveRegionScan
                        .occurrences(anchors: engine.anchors, source: data, ranges: outcome.skippedRanges)
                        .map { StructuralHit(file: relative(source, root), line: $0.line, column: $0.column, text: $0.text) }
                }
            } catch {
                unscanned.append(UnscannedFile(file: relative(source, root), reason: reason(of: error)))
            }
        }
        return Outcome(hits: hits, unscanned: unscanned, scannedCount: scanned, targets: targets, inactive: inactive)
    }

    /// Headers, listed separately: they carry no compile command of their own, so the search
    /// reaches them only through the files that include them.
    private static func headerFiles(searchRoot: String, includeTests: Bool) -> [String] {
        let root = URL(fileURLWithPath: searchRoot, isDirectory: true)
        return SwiftSources.files(under: root, includeTests: includeTests,
                                  extensions: Array(IndexDeclarations.headerExtensions))
            .map { $0.resolvingSymlinksInPath().path }
            .sorted()
    }

    private static func relative(_ path: String, _ root: URL) -> String {
        SwiftSources.relativePath(of: URL(fileURLWithPath: path), root: root)
    }

    /// The reason without the file path, which the caller already reports.
    private static func reason(of error: Error) -> String {
        guard case ClangPatternSearch.Failure.patternNotCompiled(_, let diagnostics) = error else { return "\(error)" }
        let first = diagnostics.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "the pattern does not compile here" + (first.map { ": \($0)" } ?? "")
    }
}
