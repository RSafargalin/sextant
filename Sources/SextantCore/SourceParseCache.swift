import Foundation
import SwiftParser
import SwiftSyntax

/// Cache of parsed Swift files, invalidated by modification time.
///
/// Within a single invocation it removes repeated parsing — one file is parsed once for all
/// patterns and rules. In a long-lived process (MCP) it outlives requests and keeps the AST warm.
/// Thread-safe (NSLock): the cache outlives requests in long-lived processes (MCP, `serve`),
/// where it is reached from more than one context.
public final class SourceParseCache: @unchecked Sendable {
    private struct Entry {
        let modified: Date
        let tree: SourceFileSyntax
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// The file's parsed tree — from the cache when the mtime is unchanged, otherwise parsed anew.
    public func tree(atPath path: String) -> SourceFileSyntax? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if let modified, let entry = lock.withLock({ entries[path] }), entry.modified == modified {
            return entry.tree
        }
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // Parsing happens outside the lock: it is expensive, and repeating it on a race is safer
        // than holding the lock.
        let tree = Parser.parse(source: source)
        if let modified { lock.withLock { entries[path] = Entry(modified: modified, tree: tree) } }
        return tree
    }

    public var count: Int { lock.withLock { entries.count } }
}
