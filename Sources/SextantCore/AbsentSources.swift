import Foundation

/// The positions an index records in project files that no longer exist, which `TranslatedIndex`
/// leaves out of every answer and names instead.
///
/// A build does not remove the unit of a deleted source from its store, so a store keeps
/// answering from a file that is gone — and a count that includes it is a confident wrong answer.
/// Only files under the project root are judged: a missing file elsewhere (an SDK, a toolchain) is
/// not the project's to rule on. A file the freshness layer already reports as changed since the
/// index was built is left to `IndexDrift`, which states it as deleted since indexing; this covers
/// the files no report names, such as a source deleted before the build whose unit stayed behind.
///
/// One per answer; existence is checked once per file.
public final class AbsentSources: @unchecked Sendable {
    /// What one answer left out: the files, and how many distinct positions in them.
    public struct Summary: Sendable, Equatable {
        /// The files, as the index spells them, sorted.
        public let files: [String]
        public let positions: Int
    }

    private let root: String?
    private let drift: IndexDrift?
    private let lock = NSLock()
    private var absence: [String: Bool] = [:]
    private var leftOut: [String: Set<String>] = [:]

    init(projectRoot: String?, drift: IndexDrift?) {
        self.root = projectRoot.map(CanonicalPath.of)
        self.drift = drift
    }

    /// Whether the position is in a project file that no longer exists; when it is, it is counted
    /// as left out.
    func leavesOut(_ location: SourceLocation) -> Bool {
        guard isAbsent(location.path) else { return false }
        lock.withLock { _ = leftOut[location.path, default: []].insert("\(location.line):\(location.column ?? 0)") }
        return true
    }

    /// Everything left out so far; nil when nothing was.
    public var summary: Summary? {
        lock.withLock {
            guard !leftOut.isEmpty else { return nil }
            return Summary(files: leftOut.keys.sorted(), positions: leftOut.values.reduce(0) { $0 + $1.count })
        }
    }

    private func isAbsent(_ path: String) -> Bool {
        guard let root, path.hasPrefix("/") else { return false }
        if let known = lock.withLock({ absence[path] }) { return known }
        var absent = false
        if !FileManager.default.fileExists(atPath: path), drift?.isChanged(path) != true {
            absent = IndexDrift.canonicalPath(path).hasPrefix(root + "/")
        }
        lock.withLock { absence[path] = absent }
        return absent
    }
}
