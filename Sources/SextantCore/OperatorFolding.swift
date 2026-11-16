import Foundation
import SwiftOperators
import SwiftSyntax

/// Gives operator expressions the structure the compiler gives them.
///
/// SwiftParser leaves `a = b as! T + c` as one flat sequence of operands and operators; only
/// precedence decides that it means `a = ((b as! T) + c)`. A structural match against the flat
/// sequence misses every pattern that is part of a larger expression, so both the pattern and the
/// searched file are folded before matching.
///
/// A sequence is folded only when every operator in it has a known precedence — the standard
/// library's, or one declared in the files being searched. One that cannot be folded is left as
/// written, never folded on a guess, and its operator is reported so the caller can name the file:
/// a match inside that expression may be missing.
public enum OperatorFolding {
    /// A folded tree, and the operators that kept some sequence in it flat.
    public struct Folded {
        public let tree: SourceFileSyntax
        /// The operators (or precedence groups) whose precedence is not known, sorted.
        public let unknownOperators: [String]
    }

    /// Folds every sequence in the tree that `operators` can fold.
    public static func fold(_ tree: SourceFileSyntax, operators: OperatorTable = .standardOperators) -> Folded {
        let folder = Folder(operators: operators)
        let folded = folder.rewrite(tree).as(SourceFileSyntax.self) ?? tree
        return Folded(tree: folded, unknownOperators: folder.unknown.sorted())
    }

    /// The standard operators plus every operator and precedence group the files declare.
    /// Declarations that clash with one already known are left out; the first one stays.
    public static func table(declaredIn trees: [SourceFileSyntax]) -> OperatorTable {
        var table = OperatorTable.standardOperators
        for tree in trees { table.addSourceFile(tree) { _ in } }
        return table
    }

    /// Folding for one run over a set of files. The standard operators come first; only a file
    /// they cannot fold makes the run read every file's operator declarations, once.
    public final class Session {
        private let files: [URL]
        private let cache: SourceParseCache
        private var projectTable: OperatorTable?

        public init(files: [URL], cache: SourceParseCache) {
            self.files = files
            self.cache = cache
        }

        /// The folded tree, and whether it needed operators declared in the files — a result that
        /// depends on other files than this one.
        public func fold(_ tree: SourceFileSyntax) -> (folded: Folded, usedDeclaredOperators: Bool) {
            let standard = OperatorFolding.fold(tree)
            guard !standard.unknownOperators.isEmpty else { return (standard, false) }
            return (OperatorFolding.fold(tree, operators: declared), true)
        }

        /// The standard operators plus those every file of the run declares, read once.
        public var declared: OperatorTable {
            if let projectTable { return projectTable }
            let table = OperatorFolding.table(declaredIn: files.compactMap {
                guard case .parsed(let tree) = cache.read(atPath: $0.path) else { return nil }
                return tree
            })
            projectTable = table
            return table
        }
    }

    /// Why a file with a sequence that could not be folded is read with reservations.
    public static func reservation(_ unknownOperators: [String]) -> String {
        "uses \(unknownOperators.joined(separator: ", ")), whose precedence is not known here — expressions with "
            + "it are compared as written, so a match inside them may be missing"
    }

    /// What blocked folding, as the user would name it.
    static func name(of error: OperatorError) -> String {
        switch error {
        case .missingOperator(let name, _): return name
        case .missingGroup(let group, _): return "precedence group \(group)"
        case .incomparableOperators(let left, _, let right, _):
            return "\(left.trimmedDescription) with \(right.trimmedDescription)"
        case .groupAlreadyExists(_, let new): return "precedence group \(new.name)"
        case .operatorAlreadyExists(_, let new): return new.name
        }
    }

    private final class Folder: SyntaxRewriter {
        let operators: OperatorTable
        var unknown: Set<String> = []

        init(operators: OperatorTable) {
            self.operators = operators
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: SequenceExprSyntax) -> ExprSyntax {
            // Inner sequences (in parentheses, arguments, closures) first.
            let inner = super.visit(node)
            guard let sequence = inner.as(SequenceExprSyntax.self) else { return inner }
            do {
                return try operators.foldSingle(sequence)
            } catch let error as OperatorError {
                unknown.insert(OperatorFolding.name(of: error))
                return inner
            } catch {
                return inner
            }
        }
    }
}
