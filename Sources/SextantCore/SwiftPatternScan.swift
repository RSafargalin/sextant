import Foundation
import SwiftSyntax

/// One structural pattern over a list of Swift files: the matches, and every file the answer does
/// not fully cover.
///
/// A file that could not be read is named as not scanned. A file searched through the parser's
/// recovery from syntax errors, or with an operator expression that could not be folded, is named
/// as read with reservations — its matches are kept, but they are not a complete answer about it. The CLI and MCP both search through here, so they cannot
/// disagree about what was covered.
public enum SwiftPatternScan {
    /// The persistent cache namespace for per-file results.
    public static let cacheNamespace = CacheNamespace.search

    /// What one file gave: its matches, and whether its tree was a recovery from errors.
    public struct FileResult: Codable, Sendable {
        public let matches: [Hit]
        public let hasSyntaxErrors: Bool
        /// Operators that kept an expression in the file unfolded.
        public let unknownOperators: [String]

        public struct Hit: Codable, Sendable {
            public let line: Int
            public let column: Int
            public let text: String
        }
    }

    public struct Outcome: Sendable {
        public var hits: [StructuralHit] = []
        /// Files that could not be read, with the reason.
        public var unscanned: [UnscannedFile] = []
        /// Files read with reservations: through a recovered tree, or with an expression that could
        /// not be folded.
        public var recovered: [UnscannedFile] = []
        /// Files actually parsed and matched.
        public var scannedCount = 0

        public init() {}
    }

    /// Searches the files. `resultCache` keeps per-file results keyed by content and pattern, so
    /// an unchanged file is not parsed again.
    public static func run(_ engine: PatternSearch, pattern: String, files: [URL], root: URL,
                           cache: SourceParseCache,
                           resultCache: PersistentCache<FileResult>? = nil) -> Outcome {
        let patternHash = ContentHash.of(pattern)
        let folding = OperatorFolding.Session(files: files, cache: cache)
        var outcome = Outcome()
        for file in files {
            let relative = SwiftSources.relativePath(of: file, root: root)
            let key = ContentHash.ofFile(file.path).map { "\($0)-\(patternHash)" }
            let result: FileResult
            if let key, let cached = resultCache?.value(forKey: key) {
                result = cached
            } else {
                let read = cache.read(atPath: file.path)
                guard case .parsed(let tree) = read else {
                    if let unscanned = StructuralCoverage.unscanned(read, file: relative) {
                        outcome.unscanned.append(unscanned)
                    }
                    continue
                }
                let (folded, usedDeclaredOperators) = folding.fold(tree)
                result = FileResult(
                    matches: engine.search(inFolded: folded.tree, fileName: relative)
                        .map { FileResult.Hit(line: $0.line, column: $0.column, text: $0.text) },
                    hasSyntaxErrors: tree.hasError, unknownOperators: folded.unknownOperators)
                // A result that relied on operators declared elsewhere is not this file's alone.
                if let key, !usedDeclaredOperators { resultCache?.set(result, forKey: key) }
            }
            outcome.scannedCount += 1
            if result.hasSyntaxErrors {
                outcome.recovered.append(UnscannedFile(file: relative, reason: StructuralCoverage.syntaxErrorReason))
            }
            if !result.unknownOperators.isEmpty {
                outcome.recovered.append(UnscannedFile(file: relative,
                                                       reason: OperatorFolding.reservation(result.unknownOperators)))
            }
            outcome.hits += result.matches.map {
                StructuralHit(file: relative, line: $0.line, column: $0.column, text: $0.text)
            }
        }
        return outcome
    }
}
