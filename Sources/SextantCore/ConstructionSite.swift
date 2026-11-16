import Foundation

/// How an object is created, by language.
///
/// `construct` answers a heuristic question — where is this type built or injected — by reading
/// the lines the index points at. The shapes differ per language: Swift and C++ call the type,
/// Objective-C sends `alloc` or `new` to the class. Looking only for the Swift shape made the
/// command return nothing at all on an Objective-C project, which reads as "nothing constructs
/// this type" rather than "this command cannot see it".
public enum ConstructionSite {
    /// Text shapes that count as construction of `type` in a file of this kind.
    public static func shapes(of type: String, inFile path: String) -> [String] {
        let call = ["\(type)("]
        let message = ["[\(type) alloc]", "[\(type) new]"]
        switch (path as NSString).pathExtension {
        case "m", "mm": return message
        // A header belongs to either language, so it gets both shapes rather than a guess.
        case "h": return call + message
        default: return call
        }
    }

    /// Whether a line looks like a construction site.
    ///
    /// A shape must start at a word boundary: `makeStore(` ends with `Store(` and is not a
    /// construction of `Store`.
    public static func isConstruction(line: String, of type: String, inFile path: String) -> Bool {
        shapes(of: type, inFile: path).contains { WordBoundary.contains($0, in: line) }
    }

    /// Whether the reference at `column` (1-based, UTF-16, on the line as written) is itself a
    /// construction: the type called there, or sent `alloc`/`new` there. Two constructions on one
    /// line are two sites; a use of the type beside a construction on the same line is none.
    /// Without a column the line decides, as `isConstruction(line:of:inFile:)`.
    public static func isConstruction(line: String, column: Int?, of type: String, inFile path: String) -> Bool {
        guard let column, column >= 1,
              let at = line.utf16.index(line.utf16.startIndex, offsetBy: column - 1, limitedBy: line.utf16.endIndex),
              let start = String.Index(at, within: line) else {
            return isConstruction(line: line, of: type, inFile: path)
        }
        let rest = line[start...]
        return shapes(of: type, inFile: path).contains { shape in
            // A message shape starts at the bracket before the name the index points at.
            if shape.hasPrefix("[") {
                return start > line.startIndex && line[line.index(before: start)...].hasPrefix(shape)
            }
            return rest.hasPrefix(shape)
        }
    }

    /// The heuristic to show the user, so the answer states what it looked for.
    public static func description(of type: String, inFile path: String) -> String {
        shapes(of: type, inFile: path).map { "`\($0)`" }.joined(separator: " or ")
    }
}
