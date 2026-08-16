import Foundation

/// Positions the index records that the source does not carry.
///
/// A macro records a reference twice: once where it is written, and once at the macro call it was
/// expanded from. Both land on the same line with different columns, so deduplication by position
/// keeps them both and every count over macro-wrapped code comes out high. Measured on this
/// repository, where `#require`/`#expect` from swift-testing wrap most references in the tests:
/// `refs SwiftSources` reported 81 references against 73 occurrences of the name in the sources —
/// a number nothing in the text can account for.
///
/// The rule is deliberately narrow: a position is dropped only when the column does not hold the
/// symbol's name **and** another position on the same line does. A position with no verified
/// sibling is kept, because the name may be written in a form this check cannot see (`Self`, a
/// typealias, a selector) and losing a real location is worse than counting one twice.
enum ReferencePositions {
    static func verified(_ locations: [SourceLocation], name: String) -> [SourceLocation] {
        guard locations.count > 1 else { return locations }
        let needle = Array(baseName(of: name).utf8)
        guard !needle.isEmpty else { return locations }

        // Only a line holding more than one position can lose one, so only those lines are read.
        // A reference alone on its line is kept whatever its column says — there is nothing to
        // prefer it to — and on a large project that is almost all of them.
        var perLine: [String: Int] = [:]
        for location in locations { perLine["\(location.path):\(location.line)", default: 0] += 1 }
        guard perLine.contains(where: { $0.value > 1 }) else { return locations }

        var lines: [String: [String]] = [:]
        func carriesName(_ location: SourceLocation) -> Bool {
            if lines[location.path] == nil {
                let content = (try? String(contentsOfFile: location.path, encoding: .utf8)) ?? ""
                lines[location.path] = content.components(separatedBy: "\n")
            }
            guard let file = lines[location.path], location.line >= 1, location.line <= file.count else {
                return true   // unreadable: not evidence of anything, so nothing is dropped
            }
            let bytes = Array(file[location.line - 1].utf8)
            let start = location.column - 1
            guard start >= 0, start < bytes.count else { return false }
            return bytes[start...].starts(with: needle)
        }

        var verifiedByLine: [String: Bool] = [:]
        var checked: [(location: SourceLocation, carries: Bool)] = []
        for location in locations {
            let key = "\(location.path):\(location.line)"
            let carries = perLine[key] == 1 ? true : carriesName(location)
            if carries { verifiedByLine[key] = true }
            checked.append((location, carries))
        }
        return checked
            .filter { $0.carries || verifiedByLine["\($0.location.path):\($0.location.line)"] != true }
            .map(\.location)
    }

    /// `save(_:)` and `save:` are written `save(` and `save:` in source, so the part before the
    /// first separator is what a column can be checked against.
    private static func baseName(of name: String) -> String {
        String(name.prefix { $0 != "(" && $0 != ":" })
    }
}
