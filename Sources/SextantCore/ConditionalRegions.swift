import Foundation

/// Lines that live under conditional compilation — inside a `#if … #endif` block.
///
/// Swift and the C family spell it the same way, and the reason for looking is the same in both:
/// an index holds one configuration of a project, so a declaration inside a branch that
/// configuration does not contain is simply absent. Absent without explanation reads as "there is
/// no such symbol", which is the one answer this tool must never give by accident.
///
/// This is a line scan, not a parse: it does not evaluate the conditions, and a `#if` inside a
/// string or a comment would fool it. That is enough for what it is used for — explaining an
/// answer that is already textual, never producing one.
public enum ConditionalRegions {
    /// 1-based line numbers inside a conditional block. The directive lines themselves are not
    /// included: a reader asks about the code, not about the `#if`.
    public static func lines(inSource source: String) -> Set<Int> {
        var result: Set<Int> = []
        var depth = 0
        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if") {
                depth += 1
            } else if line.hasPrefix("#endif") {
                depth = max(0, depth - 1)
            } else if line.hasPrefix("#else") || line.hasPrefix("#elif") {
                continue                       // a boundary between branches, not code
            } else if depth > 0 {
                result.insert(offset + 1)
            }
        }
        return result
    }

    /// Whether the source has any conditional compilation at all — the cheap question, for
    /// deciding whether an answer needs the caveat.
    public static func areUsed(inSource source: String) -> Bool {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#if") }
    }
}
