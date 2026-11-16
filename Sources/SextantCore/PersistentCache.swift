import Foundation

/// Persistent cache of Codable values keyed by a string, usually a content hash.
/// L1 is memory (per process), L2 is disk (`~/Library/Caches/sextant/<namespace>`).
/// Invalidation is by key: changed content means a new key and a miss; old entries simply remain.
/// The `namespace` is versioned (`-v1`), so changing the value format invalidates the cache.
/// `SEXTANT_DISABLE_CACHE` in the environment restricts it to memory only — for tests and debugging.
/// Thread-safe (NSLock): L1 outlives individual requests in long-lived processes (MCP, `serve`).
public final class PersistentCache<Value: Codable>: @unchecked Sendable {
    private let directory: URL?
    private let lock = NSLock()
    private var memory: [String: Value] = [:]

    public init(namespace: String) {
        if ProcessInfo.processInfo.environment["SEXTANT_DISABLE_CACHE"] != nil {
            directory = nil
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/sextant/\(namespace)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            directory = dir
            Self.prune(dir, cap: PersistentCacheLimit.files)
        }
    }

    /// Bounds namespace growth: past the limit it removes the oldest entries (FIFO by mtime) down
    /// to 80% of the limit. Cheap: below the limit it only lists the names in the directory.
    static func prune(_ directory: URL, cap: Int) {
        guard cap > 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              names.count > cap else { return }
        let files = names.map { directory.appendingPathComponent($0) }
        for url in oldestBeyondLimit(files, cap: cap) { try? FileManager.default.removeItem(at: url) }
    }

    /// The entries pruning removes from a namespace holding `files`: the oldest by modification
    /// time, down to 80% of the limit; none at or below it.
    static func oldestBeyondLimit(_ files: [URL], cap: Int) -> [URL] {
        guard cap > 0, files.count > cap else { return [] }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        let sorted = dated.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.path < $1.0.path }.map(\.0)
        return Array(sorted.prefix(files.count - (cap * 4 / 5)))
    }

    public func value(forKey key: String) -> Value? {
        if let cached = lock.withLock({ memory[key] }) { return cached }
        guard let directory else { return nil }
        let file = directory.appendingPathComponent(key).appendingPathExtension("json")
        // Disk reads happen outside the lock: they are expensive, and repeating work on a race is safe.
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(Value.self, from: data) else { return nil }
        lock.withLock { memory[key] = value }
        return value
    }

    public func set(_ value: Value, forKey key: String) {
        lock.withLock { memory[key] = value }
        guard let directory else { return }
        let file = directory.appendingPathComponent(key).appendingPathExtension("json")
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: file, options: .atomic) }
    }
}

/// The size limit of every persistent cache namespace, in files.
public enum PersistentCacheLimit {
    /// `SEXTANT_CACHE_MAX`, default 10000.
    public static var files: Int { ProcessInfo.processInfo.environment["SEXTANT_CACHE_MAX"].flatMap(Int.init) ?? 10000 }

    /// Why `SEXTANT_CACHE_MAX` is not used as given, or nil when it is unset or a whole number.
    public static func problem(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let raw = environment["SEXTANT_CACHE_MAX"], !raw.isEmpty, Int(raw) == nil else { return nil }
        return "SEXTANT_CACHE_MAX '\(raw)' is not a whole number, so the default of 10000 files is used — correct or unset it"
    }
}
