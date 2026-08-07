import Foundation

/// Splitting a command line the way a shell would.
///
/// SwiftPM hands over its compile commands as JSON arrays, which need none of this. Xcode prints
/// them to a log, escaped for a shell — `-fmessage-length\=0` in the log, `'-std=gnu11'` in a
/// response file — so reading them back means undoing exactly that. Splitting on spaces instead
/// would break every path containing one, and those are ordinary in Xcode projects.
enum ShellWords {
    /// Words of a command line: backslash escapes outside quotes, literal single quotes, and
    /// double quotes where a backslash still escapes.
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                hasCurrent = true
                escaped = false
                continue
            }
            switch character {
            case "\\" where quote != "'":
                escaped = true
                hasCurrent = true
            case "'", "\"":
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                    hasCurrent = true
                } else {
                    current.append(character)
                }
            case " ", "\t", "\n", "\r":
                guard quote == nil else { current.append(character); break }
                if hasCurrent { words.append(current) }
                current = ""
                hasCurrent = false
            default:
                current.append(character)
                hasCurrent = true
            }
        }
        if hasCurrent { words.append(current) }
        return words
    }

    /// Expands `@file` arguments by reading the file and splitting it the same way. clang response
    /// files are the normal way Xcode passes the bulk of its flags, so a command line read without
    /// them is missing most of what it needs.
    static func expandingResponseFiles(_ arguments: [String], depth: Int = 0) -> [String] {
        guard depth < 4 else { return arguments }        // a response file naming itself would not end
        return arguments.flatMap { argument -> [String] in
            guard argument.hasPrefix("@"),
                  let contents = try? String(contentsOfFile: String(argument.dropFirst()), encoding: .utf8)
            else { return [argument] }
            return expandingResponseFiles(split(contents), depth: depth + 1)
        }
    }
}
