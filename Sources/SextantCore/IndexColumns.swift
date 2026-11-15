import Foundation

/// The index store's positions in reported columns (`SourceColumn`). The store records a column in
/// bytes of UTF-8; it is restated from the line it was recorded on, in the text it was recorded
/// in: for a file changed since the index was built, the indexed text `IndexDrift` supplies; for
/// any other, the file as it is now.
///
/// A position whose line cannot be read states no column (nil) rather than one in the store's
/// unit. Its line stays as recorded, and what is known about it is said where it always was: in a
/// changed file whose indexed text is unavailable, or that is gone, `IndexDrift` marks it
/// unconfirmed; over an index judged by build time, the answer names a file that no longer exists
/// and withholds a snippet the recorded line no longer holds.
///
/// One per answer: each file is read once, and only when a position in it is restated.
final class IndexColumns: @unchecked Sendable {
    private enum Text {
        case current(ByteLines)
        case indexed([String])
        case unreadable
    }

    private let drift: IndexDrift?
    private let lock = NSLock()
    private var texts: [String: Text] = [:]

    init(drift: IndexDrift?) {
        self.drift = drift
    }

    /// The position with its column restated, or with none when its line cannot be read.
    func restate(_ location: SourceLocation) -> SourceLocation {
        guard let recorded = location.column else { return location }
        let column: Int?
        switch text(of: location.path) {
        case .current(let lines):
            column = lines.column(line: location.line, utf8Column: recorded)
        case .indexed(let lines):
            column = location.line >= 1 && location.line <= lines.count
                ? SourceColumn.column(ofUTF8Column: recorded, inLine: lines[location.line - 1]) : nil
        case .unreadable:
            column = nil
        }
        return location.withColumn(column)
    }

    private func text(of path: String) -> Text {
        lock.lock()
        if let cached = texts[path] { lock.unlock(); return cached }
        lock.unlock()
        let text: Text
        if let drift, drift.isChanged(path) {
            text = drift.indexedLines(ofFile: path).map(Text.indexed) ?? .unreadable
        } else {
            text = FileManager.default.contents(atPath: path).map { Text.current(ByteLines($0)) } ?? .unreadable
        }
        lock.lock()
        texts[path] = text
        lock.unlock()
        return text
    }
}
