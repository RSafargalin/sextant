import Foundation

/// A file the user has told the tool to leave out.
///
/// `.gitignore` is git's file, edited for git's sake: generated code that is committed on
/// purpose, vendored sources and snapshot fixtures are all tracked deliberately and still have no
/// business in a map or a lint report. `--scope` cannot help — it narrows to one subtree and
/// cannot subtract.
///
/// The syntax is the small, predictable part of glob rather than gitignore: `*` inside one path
/// component, `**` across components, and a pattern with no `/` matching the file's name anywhere.
/// Deliberately absent are negation and "last pattern wins" — a partial gitignore is worse than
/// none, because nobody can predict where it stops (see the reasoning in issue #3).
public struct ExclusionPattern: Sendable, Equatable {
    private let segments: [String]
    /// A pattern without a separator matches a name at any depth: `*.pb.swift`.
    private let matchesNameOnly: Bool

    public init(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        matchesNameOnly = !trimmed.contains("/")
        segments = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Whether a path relative to the project root is excluded. A pattern that names a directory
    /// excludes what is inside it: `Sources/Legacy` is meant to remove the tree, not one entry.
    public func matches(relativePath path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if matchesNameOnly {
            guard let name = components.last, let pattern = segments.first else { return false }
            return Self.matches(name: name, pattern: pattern)
        }
        return Self.matches(components: components, patterns: segments, allowTrailing: true)
    }

    /// Path components against pattern segments, with `**` absorbing any number of them.
    private static func matches(components: [String], patterns: [String], allowTrailing: Bool) -> Bool {
        guard let pattern = patterns.first else {
            // Patterns exhausted: an exact match, or a directory pattern with a tree under it.
            return components.isEmpty || allowTrailing
        }
        if pattern == "**" {
            let rest = Array(patterns.dropFirst())
            if rest.isEmpty { return true }                      // `Generated/**`
            for index in 0...components.count
            where matches(components: Array(components[index...]), patterns: rest, allowTrailing: allowTrailing) {
                return true
            }
            return false
        }
        guard let component = components.first, matches(name: component, pattern: pattern) else { return false }
        return matches(components: Array(components.dropFirst()), patterns: Array(patterns.dropFirst()),
                       allowTrailing: allowTrailing)
    }

    /// One component against one pattern segment: `*` matches any run of characters within it.
    static func matches(name: String, pattern: String) -> Bool {
        guard pattern.contains("*") else { return name == pattern }
        let parts = pattern.components(separatedBy: "*")
        var index = name.startIndex

        if let first = parts.first, !first.isEmpty {
            guard name.hasPrefix(first) else { return false }
            index = name.index(index, offsetBy: first.count)
        }
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let found = name.range(of: part, range: index..<name.endIndex) else { return false }
            index = found.upperBound
        }
        if let last = parts.last, !last.isEmpty {
            guard name.hasSuffix(last), name.distance(from: index, to: name.endIndex) >= last.count else { return false }
        }
        return true
    }
}

public extension Array where Element == ExclusionPattern {
    /// Whether any pattern excludes the path.
    func exclude(relativePath path: String) -> Bool {
        contains { $0.matches(relativePath: path) }
    }
}
