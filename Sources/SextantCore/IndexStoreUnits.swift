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
        /// The unit's own name in the store, the name of its file under `<store>/v*/units`.
        public var name: String = ""
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
                        isDebug: readerIsDebug(reader),
                        name: name)
        }
    }

    /// Removes from a store that lies in `buildDirectory` the units whose source file no longer
    /// exists, and nothing else: not their records, not a unit for a module or for SDK code. A
    /// build never removes the unit of a deleted source itself, so without this the store keeps
    /// answering from a file that is gone. Meant only for a build tree `sextant index` owns, where
    /// every unit was written by a build of that tree; a store outside `buildDirectory` is left
    /// as it is. Returns the source files whose units were removed, sorted.
    public func removeUnitsOfMissingSources(inStore storePath: String, builtIn buildDirectory: String) throws -> [String] {
        let tree = CanonicalPath.of(buildDirectory) + "/"
        guard CanonicalPath.of(storePath).hasPrefix(tree) else { return [] }
        let missing = try units(inStore: storePath).filter { unit in
            // A relative path would be judged against the working directory, not the build's.
            !unit.isSystem && unit.mainFile.hasPrefix("/") && !unit.name.isEmpty && !unit.name.contains("/")
                && !FileManager.default.fileExists(atPath: unit.mainFile)
        }
        guard !missing.isEmpty else { return [] }
        let store = URL(fileURLWithPath: storePath, isDirectory: true)
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []).filter { $0.hasPrefix("v") }
        var removed = Set<String>()
        for unit in missing {
            for version in versions {
                let file = store.appendingPathComponent("\(version)/units/\(unit.name)")
                if (try? FileManager.default.removeItem(at: file)) != nil { removed.insert(unit.mainFile) }
            }
        }
        return removed.sorted()
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
        guard let swiftc = Command.output("/usr/bin/xcrun", ["--find", "swiftc"], timeout: Command.toolchainTimeout),
              let path = toolchainLibrary(named: "libIndexStore.dylib", besideTool: swiftc) else { return nil }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Where a toolchain keeps a library beside one of its tools: the tool lives in `<prefix>/bin`,
    /// the library in `<prefix>/lib`. Decided by the tool's directory itself, so a `bin` elsewhere
    /// in the path (`/Users/bin-tools/…`, `/opt/bin/toolchain/usr/bin`) is left as it is. nil when
    /// the tool is not in a `bin` directory.
    public static func toolchainLibrary(named name: String, besideTool tool: String) -> String? {
        let directory = URL(fileURLWithPath: tool.trimmingCharacters(in: .whitespacesAndNewlines)).deletingLastPathComponent()
        guard directory.lastPathComponent == "bin" else { return nil }
        return directory.deletingLastPathComponent().appendingPathComponent("lib").appendingPathComponent(name).path
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
