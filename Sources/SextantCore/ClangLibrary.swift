import CClangShim
import Darwin
import Foundation

/// libclang, resolved from the toolchain at run time.
///
/// It is loaded the way `libIndexStore` is: found through `xcrun`, opened with `dlopen`, and its
/// symbols taken with `dlsym`. Linking against it would make every command fail to start where
/// there is no toolchain, including the Swift-only ones that never need clang.
public final class ClangLibrary: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case libraryNotFound
        case couldNotOpen(String)
        case symbolMissing(String)

        public var description: String {
            switch self {
            case .libraryNotFound:
                return "libclang.dylib not found — install an Xcode toolchain (xcode-select) or pass --clang-lib"
            case .couldNotOpen(let reason):
                return "libclang.dylib could not be opened: \(reason)"
            case .symbolMissing(let name):
                return "libclang.dylib has no symbol \(name) — the toolchain is older than expected"
            }
        }
    }

    public let path: String

    let createIndex: sx_createIndex
    let disposeIndex: sx_disposeIndex
    let parseTranslationUnit: sx_parseTranslationUnit
    let disposeTranslationUnit: sx_disposeTranslationUnit
    let numberOfDiagnostics: sx_getNumDiagnostics
    let diagnostic: sx_getDiagnostic
    let diagnosticSeverity: sx_getDiagnosticSeverity
    let formatDiagnostic: sx_formatDiagnostic
    let diagnosticLocation: sx_getDiagnosticLocation
    let disposeDiagnostic: sx_disposeDiagnostic
    let translationUnitCursor: sx_getTranslationUnitCursor
    let visitChildren: sx_visitChildren
    let cursorSpelling: sx_getCursorSpelling
    let cursorKindSpelling: sx_getCursorKindSpelling
    let cursorLocation: sx_getCursorLocation
    let cursorExtent: sx_getCursorExtent
    let rangeStart: sx_getRangeStart
    let rangeEnd: sx_getRangeEnd
    let isFromMainFile: sx_Location_isFromMainFile
    let accessSpecifier: sx_getCXXAccessSpecifier
    let fileName: sx_getFileName
    let spellingLocation: sx_getSpellingLocation
    let cString: sx_getCString
    let disposeString: sx_disposeString

    private init(path: String, handle: UnsafeMutableRawPointer) throws {
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else { throw Failure.symbolMissing(name) }
            return unsafeBitCast(raw, to: type)
        }
        self.path = path
        createIndex = try symbol("clang_createIndex", sx_createIndex.self)
        disposeIndex = try symbol("clang_disposeIndex", sx_disposeIndex.self)
        parseTranslationUnit = try symbol("clang_parseTranslationUnit", sx_parseTranslationUnit.self)
        disposeTranslationUnit = try symbol("clang_disposeTranslationUnit", sx_disposeTranslationUnit.self)
        numberOfDiagnostics = try symbol("clang_getNumDiagnostics", sx_getNumDiagnostics.self)
        diagnostic = try symbol("clang_getDiagnostic", sx_getDiagnostic.self)
        diagnosticSeverity = try symbol("clang_getDiagnosticSeverity", sx_getDiagnosticSeverity.self)
        formatDiagnostic = try symbol("clang_formatDiagnostic", sx_formatDiagnostic.self)
        diagnosticLocation = try symbol("clang_getDiagnosticLocation", sx_getDiagnosticLocation.self)
        disposeDiagnostic = try symbol("clang_disposeDiagnostic", sx_disposeDiagnostic.self)
        translationUnitCursor = try symbol("clang_getTranslationUnitCursor", sx_getTranslationUnitCursor.self)
        visitChildren = try symbol("clang_visitChildren", sx_visitChildren.self)
        cursorSpelling = try symbol("clang_getCursorSpelling", sx_getCursorSpelling.self)
        cursorKindSpelling = try symbol("clang_getCursorKindSpelling", sx_getCursorKindSpelling.self)
        cursorLocation = try symbol("clang_getCursorLocation", sx_getCursorLocation.self)
        cursorExtent = try symbol("clang_getCursorExtent", sx_getCursorExtent.self)
        rangeStart = try symbol("clang_getRangeStart", sx_getRangeStart.self)
        rangeEnd = try symbol("clang_getRangeEnd", sx_getRangeEnd.self)
        isFromMainFile = try symbol("clang_Location_isFromMainFile", sx_Location_isFromMainFile.self)
        accessSpecifier = try symbol("clang_getCXXAccessSpecifier", sx_getCXXAccessSpecifier.self)
        fileName = try symbol("clang_getFileName", sx_getFileName.self)
        spellingLocation = try symbol("clang_getSpellingLocation", sx_getSpellingLocation.self)
        cString = try symbol("clang_getCString", sx_getCString.self)
        disposeString = try symbol("clang_disposeString", sx_disposeString.self)
    }

    /// A Swift string from a CXString, whose buffer belongs to libclang and is released here.
    func text(_ string: SXString) -> String {
        let result = cString(string).map(String.init(cString:)) ?? ""
        disposeString(string)
        return result
    }

    // MARK: - Loading

    /// The outcome of loading, remembered either way: a missing toolchain must not cost an
    /// `xcrun` call per file. Thread-safe, because a long-lived process serves more than one context.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<ClangLibrary, Failure>?

        func library(_ make: () throws -> ClangLibrary) throws -> ClangLibrary {
            try lock.withLock {
                if let outcome { return try outcome.get() }
                let result = Result { try make() }.mapError { $0 as? Failure ?? .couldNotOpen("\($0)") }
                outcome = result
                return try result.get()
            }
        }
    }

    private static let memo = Memo()

    /// The shared library, loaded on first use.
    public static func shared(path explicitPath: String? = nil) throws -> ClangLibrary {
        try memo.library { try load(path: explicitPath) }
    }

    private static func load(path explicitPath: String?) throws -> ClangLibrary {
        guard let path = explicitPath ?? discoverPath() else { throw Failure.libraryNotFound }
        guard let handle = dlopen(path, RTLD_LAZY) else {
            throw Failure.couldNotOpen(dlerror().map { String(cString: $0) } ?? path)
        }
        return try ClangLibrary(path: path, handle: handle)
    }

    /// libclang beside the active clang, the same route `libIndexStore` is found by.
    public static func discoverPath() -> String? {
        guard let clang = Command.output("/usr/bin/xcrun", ["--find", "clang"]) else { return nil }
        let path = (clang.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .deletingLastPathComponent
            .replacingOccurrences(of: "/bin", with: "/lib") + "/libclang.dylib"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
