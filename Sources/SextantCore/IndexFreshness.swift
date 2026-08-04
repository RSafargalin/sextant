import Foundation

/// The single freshness layer for the index: one implementation shared by provenance, `doctor`,
/// re-opening in MCP, and the daemon. Each of those used to compute freshness its own way, and
///
/// all of them by the mtime of the store directory. That signal is wrong: a build rewrites unit
/// files inside `<store>/v*/units`, and the directory mtime does not move when files are merely
/// overwritten. Hence false "⚠ STALE" on a freshly built index — and the opposite failure, where
/// MCP did not notice an ordinary rebuild. The correct signal is the newest unit file: a plain
/// `swift build` updates it, so no build hook is needed — the index is fresh as a side effect.
public enum IndexFreshness {
    /// Index freshness. `unknown` means there is no data (no store, or an empty units directory);
    /// passing that off as "fresh" would put a trust label on something there is no basis to trust.
    public enum State: Sendable, Equatable {
        case fresh
        case stale
        case unknown
    }

    /// When the store was last updated: the mtime of `<store>/v*/units`. A build writes new unit
    /// files there (the name carries a compilation hash), which moves the directory mtime —
    /// verified both when adding a symbol and when editing an existing file. The signal is O(1):
    /// walking tens of thousands of units would cost hundreds of milliseconds on EVERY query, and
    /// truncating the walk gives a non-deterministically wrong answer (entries are not in time order).
    public static func timestamp(ofStore storePath: String) -> Date? {
        let store = URL(fileURLWithPath: storePath, isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { return nil }

        var newest: Date?
        for version in versions where version.hasPrefix("v") {
            let units = store.appendingPathComponent("\(version)/units")
            guard let modified = (try? units.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if modified > (newest ?? .distantPast) { newest = modified }
        }
        return newest
    }

    /// When the freshest of the stores was last updated.
    public static func timestamp(ofStores storePaths: [String]) -> Date? {
        storePaths.compactMap { timestamp(ofStore: $0) }.max()
    }

    /// Freshness of a set of stores, computed from the OLDEST one: in a multi-package project
    /// building one package does not make the others fresh, and it is safer to err loudly towards
    /// "stale" than quietly towards "fresh".
    public static func state(storePaths: [String], projectRoot: String) -> State {
        let timestamps = storePaths.compactMap { timestamp(ofStore: $0) }
        guard let oldest = timestamps.min() else { return .unknown }
        return SwiftSources.hasSourceNewer(than: oldest, under: URL(fileURLWithPath: projectRoot, isDirectory: true))
            ? .stale : .fresh
    }

    /// Whether the index is stale. `unknown` counts as "not stale" for callers that need a boolean;
    /// where the honesty of the label matters, use `state`.
    public static func isStale(storePaths: [String], projectRoot: String) -> Bool {
        state(storePaths: storePaths, projectRoot: projectRoot) == .stale
    }

    /// Signature of the store state, to detect "appeared" or "rebuilt" without reading contents.
    /// Long-lived processes (MCP, `serve`) re-open the index when it changes. By directory mtime it
    /// did not change on an ordinary rebuild, so the index stayed stale.
    public static func signature(ofStores storePaths: [String]) -> String? {
        guard !storePaths.isEmpty else { return nil }
        let parts = storePaths.sorted().map { path in
            "\(path)@\(timestamp(ofStore: path)?.timeIntervalSince1970 ?? 0)"
        }
        return parts.joined(separator: "|")
    }
}
