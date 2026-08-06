import CClangShim
import Foundation

/// A node of a clang AST, copied out of the translation unit.
///
/// The tree is materialised rather than walked live: a libclang cursor is only valid while its
/// translation unit is, and a plain value tree keeps matching pure and testable.
public struct ClangNode: Sendable {
    public let kind: Int32
    public let kindName: String
    public let spelling: String
    public let line: Int
    public let column: Int
    /// Byte range of the node in the file, for showing what matched.
    public let startOffset: Int
    public let endOffset: Int
    public let children: [ClangNode]
}

/// A parsed C-family file.
///
/// Parsing needs the exact flags the file was built with; see `CompilationDatabase`. With
/// approximate flags clang builds a tree for roughly a third of the files and fails outright on
/// the rest, so a file with no flags is refused rather than parsed with a guess.
public struct ClangTranslationUnit {
    public enum Failure: Error, CustomStringConvertible {
        case notParsed(file: String)

        public var description: String {
            switch self {
            case .notParsed(let file): return "clang built no AST for \(file) — the flags do not match the file"
            }
        }
    }

    /// The file's own top-level declarations. Cursors from included headers are left out: they
    /// belong to the header, and every file including it would report them again.
    public let root: ClangNode
    /// Formatted error and fatal diagnostics. An empty list means the tree is complete.
    public let errors: [String]

    public var isComplete: Bool { errors.isEmpty }

    /// Parses a file with the flags it was compiled with.
    public static func parse(file: String, arguments: [String], library: ClangLibrary) throws -> ClangTranslationUnit {
        let index = library.createIndex(1, 0)   // no declarations from PCH, no diagnostics on stderr
        defer { library.disposeIndex(index) }

        var argumentStrings: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { argumentStrings.forEach { free($0) } }

        let unit: SXTranslationUnit? = argumentStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
                library.parseTranslationUnit(index, file, rebound.baseAddress, Int32(arguments.count), nil, 0, 0)
            }
        }
        guard let unit else { throw Failure.notParsed(file: file) }
        defer { library.disposeTranslationUnit(unit) }

        var errors: [String] = []
        for position in 0..<library.numberOfDiagnostics(unit) {
            let diagnostic = library.diagnostic(unit, position)
            if library.diagnosticSeverity(diagnostic) >= 3 {   // error and fatal
                errors.append(library.text(library.formatDiagnostic(diagnostic, 0)))
            }
            library.disposeDiagnostic(diagnostic)
        }

        let root = node(of: library.translationUnitCursor(unit), library: library, includeChildrenOutsideMainFile: false)
        return ClangTranslationUnit(root: root, errors: errors)
    }

    // MARK: - Copying the tree out

    private static func node(of cursor: SXCursor, library: ClangLibrary, includeChildrenOutsideMainFile: Bool) -> ClangNode {
        var line: UInt32 = 0, column: UInt32 = 0, offset: UInt32 = 0
        library.spellingLocation(library.cursorLocation(cursor), nil, &line, &column, &offset)

        let extent = library.cursorExtent(cursor)
        var startOffset: UInt32 = 0, endOffset: UInt32 = 0
        var startLine: UInt32 = 0, startColumn: UInt32 = 0, endLine: UInt32 = 0, endColumn: UInt32 = 0
        library.spellingLocation(library.rangeStart(extent), nil, &startLine, &startColumn, &startOffset)
        library.spellingLocation(library.rangeEnd(extent), nil, &endLine, &endColumn, &endOffset)

        let childCursors = children(of: cursor, library: library)
            .filter { includeChildrenOutsideMainFile || library.isFromMainFile(library.cursorLocation($0)) != 0 }

        return ClangNode(
            kind: cursor.kind,
            kindName: library.text(library.cursorKindSpelling(cursor.kind)),
            spelling: library.text(library.cursorSpelling(cursor)),
            line: Int(line),
            column: Int(column),
            startOffset: Int(startOffset),
            endOffset: Int(endOffset),
            children: childCursors.map { node(of: $0, library: library, includeChildrenOutsideMainFile: true) }
        )
    }

    /// Immediate children of a cursor. The visitor is a C function pointer, so it captures
    /// nothing and the collector travels through the client-data pointer.
    private static func children(of cursor: SXCursor, library: ClangLibrary) -> [SXCursor] {
        final class Collector { var cursors: [SXCursor] = [] }
        let collector = Collector()
        let visitor: SXCursorVisitor = { child, _, clientData in
            Unmanaged<Collector>.fromOpaque(clientData!).takeUnretainedValue().cursors.append(child)
            return SXChildVisitContinue
        }
        _ = library.visitChildren(cursor, visitor, Unmanaged.passUnretained(collector).toOpaque())
        return collector.cursors
    }
}
