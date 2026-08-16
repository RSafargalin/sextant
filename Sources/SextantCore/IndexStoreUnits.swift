import CIndexStoreShim
import Darwin
import Foundation

/// The units of an index store: one per compiled file, each naming the source it came from, the
/// object file it produced, its target and its configuration.
///
/// IndexStoreDB is the wrong tool for this question. It answers about symbols, and a symbol query
/// cannot distinguish "this store does not cover the file" from "the file has no such symbol" —
/// the two look identical and only one of them is about the code. The unit list answers directly:
/// this is the set of files the store was built from.
public final class IndexStoreUnits: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case libraryNotFound
        case couldNotOpen(String)
        case symbolMissing(String)
        case storeUnreadable(String)

        public var description: String {
            switch self {
            case .libraryNotFound:
                return "libIndexStore.dylib not found — install an Xcode toolchain (xcode-select) or pass --index-lib"
            case .couldNotOpen(let reason):
                return "libIndexStore.dylib could not be opened: \(reason)"
            case .symbolMissing(let name):
                return "libIndexStore.dylib has no symbol \(name) — the toolchain is older than expected"
            case .storeUnreadable(let reason):
                return "the index store could not be read: \(reason)"
            }
        }
    }

    /// What one unit says about itself.
    public struct Unit: Sendable, Equatable {
        /// The source file it was compiled from, as the compiler saw it. Empty for a module unit,
        /// which stands for a whole module rather than for a compiled file.
        public let mainFile: String
        public let moduleName: String
        /// A unit for SDK or toolchain code, which is in every store and says nothing about a project.
        public let isSystem: Bool
        /// The object file it produced; its directory identifies the build that wrote the unit.
        public let outFile: String
        public let target: String
        public let isDebug: Bool
    }

    private let handle: UnsafeMutableRawPointer
    private let storeCreate: sx_indexstore_store_create
    private let storeDispose: sx_indexstore_store_dispose
    private let errorDescription: sx_indexstore_error_get_description
    private let errorDispose: sx_indexstore_error_dispose
    private let unitsApply: sx_indexstore_store_units_apply_f
    private let readerCreate: sx_indexstore_unit_reader_create
    private let readerDispose: sx_indexstore_unit_reader_dispose
    private let readerMainFile: sx_indexstore_unit_reader_get_main_file
    private let readerOutFile: sx_indexstore_unit_reader_get_output_file
    private let readerHasMainFile: sx_indexstore_unit_reader_has_main_file
    private let readerIsSystem: sx_indexstore_unit_reader_is_system_unit
    private let readerModuleName: sx_indexstore_unit_reader_get_module_name
    private let readerTarget: sx_indexstore_unit_reader_get_target
    private let readerIsDebug: sx_indexstore_unit_reader_is_debug_compilation

    public init(libraryPath: String) throws {
        guard let handle = dlopen(libraryPath, RTLD_LAZY | RTLD_LOCAL) else {
            throw Failure.couldNotOpen(dlerror().map { String(cString: $0) } ?? "unknown")
        }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else { throw Failure.symbolMissing(name) }
            return unsafeBitCast(raw, to: type)
        }
        self.handle = handle
        storeCreate = try symbol("indexstore_store_create", sx_indexstore_store_create.self)
        storeDispose = try symbol("indexstore_store_dispose", sx_indexstore_store_dispose.self)
        errorDescription = try symbol("indexstore_error_get_description", sx_indexstore_error_get_description.self)
        errorDispose = try symbol("indexstore_error_dispose", sx_indexstore_error_dispose.self)
        unitsApply = try symbol("indexstore_store_units_apply_f", sx_indexstore_store_units_apply_f.self)
        readerCreate = try symbol("indexstore_unit_reader_create", sx_indexstore_unit_reader_create.self)
        readerDispose = try symbol("indexstore_unit_reader_dispose", sx_indexstore_unit_reader_dispose.self)
        readerMainFile = try symbol("indexstore_unit_reader_get_main_file", sx_indexstore_unit_reader_get_main_file.self)
        readerOutFile = try symbol("indexstore_unit_reader_get_output_file",
                                   sx_indexstore_unit_reader_get_output_file.self)
        readerHasMainFile = try symbol("indexstore_unit_reader_has_main_file",
                                       sx_indexstore_unit_reader_has_main_file.self)
        readerIsSystem = try symbol("indexstore_unit_reader_is_system_unit",
                                    sx_indexstore_unit_reader_is_system_unit.self)
        readerModuleName = try symbol("indexstore_unit_reader_get_module_name",
                                      sx_indexstore_unit_reader_get_module_name.self)
        readerTarget = try symbol("indexstore_unit_reader_get_target", sx_indexstore_unit_reader_get_target.self)
        readerIsDebug = try symbol("indexstore_unit_reader_is_debug_compilation",
                                   sx_indexstore_unit_reader_is_debug_compilation.self)
    }

    /// Every unit in a store. The order is the store's own.
    public func units(inStore storePath: String) throws -> [Unit] {
        var error: SXIndexStoreError?
        guard let store = storeCreate(storePath, &error) else {
            let reason = error.map { failure -> String in
                let text = errorDescription(failure).map { String(cString: $0) } ?? "unknown"
                errorDispose(failure)
                return text
            } ?? "unknown"
            throw Failure.storeUnreadable(reason)
        }
        defer { storeDispose(store) }

        // The applier is a C function pointer, so the collected names travel through a context
        // pointer rather than a capture.
        final class Collector { var names: [String] = [] }
        let collector = Collector()
        let applied = unitsApply(store, 0, Unmanaged.passUnretained(collector).toOpaque()) { context, name in
            guard let context else { return false }
            Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue().names.append(string(name))
            return true
        }
        guard applied else { throw Failure.storeUnreadable("the unit list could not be walked") }

        return collector.names.compactMap { name in
            var readerError: SXIndexStoreError?
            guard let reader = readerCreate(store, name, &readerError) else {
                if let readerError { errorDispose(readerError) }
                // One unreadable unit is not a reason to lose the other ten thousand; what it
                // costs is one file's worth of coverage, and coverage is reported as a count.
                return nil
            }
            defer { readerDispose(reader) }
            return Unit(mainFile: readerHasMainFile(reader) ? string(readerMainFile(reader)) : "",
                        moduleName: string(readerModuleName(reader)),
                        isSystem: readerIsSystem(reader),
                        outFile: string(readerOutFile(reader)),
                        target: string(readerTarget(reader)),
                        isDebug: readerIsDebug(reader))
        }
    }

    /// The source files a store was built from, symlink-resolved so they compare against a project
    /// walk. Empty main files (a unit for a module rather than a file) are left out.
    public func mainFiles(inStore storePath: String) throws -> Set<String> {
        Set(try units(inStore: storePath)
            .filter { !$0.isSystem }
            .map(\.mainFile)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    }

    /// libIndexStore from the active toolchain — the same copy IndexStoreDB is given.
    public static func discoverLibrary() -> String? {
        guard let swiftc = Command.output("/usr/bin/xcrun", ["--find", "swiftc"]) else { return nil }
        let path = (swiftc as NSString).deletingLastPathComponent
            .replacingOccurrences(of: "/bin", with: "/lib") + "/libIndexStore.dylib"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    public static func shared(libraryPath: String? = nil) throws -> IndexStoreUnits {
        guard let path = libraryPath ?? discoverLibrary() else { throw Failure.libraryNotFound }
        return try memo.instance(forPath: path)
    }

    /// One handle per library path per process: dlopen is cheap on a warm cache but the symbol
    /// lookups are not free, and every command that asks about coverage asks several times.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var byPath: [String: IndexStoreUnits] = [:]
        func instance(forPath path: String) throws -> IndexStoreUnits {
            if let existing = lock.withLock({ byPath[path] }) { return existing }
            let created = try IndexStoreUnits(libraryPath: path)
            lock.withLock { byPath[path] = created }
            return created
        }
    }
    private static let memo = Memo()
}

/// A library string is not NUL-terminated — the length is the only safe end of it.
private func string(_ raw: SXIndexStoreString) -> String {
    guard let data = raw.data, raw.length > 0 else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: data, count: raw.length), as: UTF8.self)
}
