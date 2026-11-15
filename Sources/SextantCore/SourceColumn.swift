import Foundation
import SwiftSyntax

/// The unit of every column sextant reports — in text, in `--json`, in MCP tool results and
/// resources: 1-based, counted in UTF-16 code units, the unit an LSP client uses by default. A
/// character outside the Basic Multilingual Plane (an emoji) counts 2, a Cyrillic letter 1, a tab 1.
///
/// The sources of positions count bytes of UTF-8 — the index store, SwiftSyntax and libclang alike —
/// so each restates its columns through here, from the text of the line the position is on.
public enum SourceColumn {
    /// How a position is written, in words: the one sentence help and tool descriptions use.
    public static let positionFormat = "A position is file:line:column, both 1-based; the column counts UTF-16 "
        + "code units (an emoji counts 2, a tab 1), the unit an LSP client uses by default."

    /// The column of the position that follows `prefix`, the bytes of its line before it.
    public static func column(after prefix: some Collection<UInt8>) -> Int {
        if !prefix.contains(where: { $0 >= 0x80 }) { return prefix.count + 1 }
        return String(decoding: prefix, as: UTF8.self).utf16.count + 1
    }

    /// The column of the position at `utf8Column` (1-based, in bytes) on `line`, the bytes of the
    /// line without its terminator. nil when the line is too short to hold that position.
    public static func column(ofUTF8Column utf8Column: Int, inLine line: some Collection<UInt8>) -> Int? {
        guard utf8Column >= 1, utf8Column - 1 <= line.count else { return nil }
        return column(after: line.prefix(utf8Column - 1))
    }

    /// The column of the position at `utf8Column` (1-based, in bytes) on `line`.
    public static func column(ofUTF8Column utf8Column: Int, inLine line: String) -> Int? {
        column(ofUTF8Column: utf8Column, inLine: line.utf8)
    }
}

/// A text's lines by byte offset, for restating positions a source counted in bytes.
struct ByteLines {
    let bytes: [UInt8]
    /// The offset each line starts at; the first is 0.
    private let starts: [Int]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        var starts = [0]
        bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count,
                  let found = memchr(base + offset, Int32(UInt8(ascii: "\n")), buffer.count - offset) {
                offset = UnsafeRawPointer(found) - base + 1
                starts.append(offset)
            }
        }
        self.starts = starts
    }

    init(_ data: Data) {
        self.init(data.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) })
    }

    /// The bytes of a line (1-based), without its line feed; nil when there is no such line.
    func line(_ number: Int) -> ArraySlice<UInt8>? {
        guard number >= 1, number <= starts.count else { return nil }
        let start = starts[number - 1]
        let end = number < starts.count ? starts[number] - 1 : bytes.count
        return bytes[start..<end]
    }

    /// The reported column of the position at `utf8Column` (1-based, in bytes) on line `number`.
    func column(line number: Int, utf8Column: Int) -> Int? {
        line(number).flatMap { SourceColumn.column(ofUTF8Column: utf8Column, inLine: $0) }
    }

    /// The line (1-based) and reported column of a byte offset; nil outside the text.
    func position(ofOffset offset: Int) -> (line: Int, column: Int)? {
        guard offset >= 0, offset <= bytes.count else { return nil }
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return (low + 1, SourceColumn.column(after: bytes[starts[low]..<offset]))
    }
}

/// Positions in a Swift syntax tree, in reported columns. SwiftSyntax counts a column in bytes of
/// UTF-8; the bytes of the line before the position are what it is restated from, read from the
/// tree on the first position asked for.
final class SwiftColumns {
    private let tree: Syntax
    let converter: SourceLocationConverter
    private lazy var bytes: [UInt8] = tree.syntaxTextBytes

    init(tree: some SyntaxProtocol) {
        self.tree = Syntax(tree)
        self.converter = SourceLocationConverter(fileName: "", tree: tree)
    }

    /// The line (1-based) and reported column of a position in the tree.
    func position(of position: AbsolutePosition) -> (line: Int, column: Int) {
        let location = converter.location(for: position)
        let end = min(location.offset, bytes.count)
        let start = max(0, end - (location.column - 1))
        return (location.line, SourceColumn.column(after: bytes[start..<end]))
    }
}
