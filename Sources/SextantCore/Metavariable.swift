import Foundation

/// Metavariables in a structural pattern, shared by both engines.
///
/// A real parser cannot read `$X`, so each metavariable is substituted for a plain identifier —
/// a sentinel — which the matcher recognises back by name. The Swift and the C-family engines use
/// the same substitution, so a pattern means the same thing in both.
public enum Metavariable {
    public struct Substitution: Sendable {
        /// The pattern with metavariables replaced by sentinel identifiers.
        public let text: String
        /// Sentinel → the name the user wrote (`SEXTANTMETA_X` → `X`).
        public let singleByName: [String: String]
        /// Sentinels standing for a variadic (`$$$`, `$$$Name`).
        public let variadic: Set<String>
    }

    public static func substitute(_ pattern: String) -> Substitution {
        let characters = Array(pattern)
        var result = ""
        var single: [String: String] = [:]
        var variadic: Set<String> = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "$" else {
                result.append(characters[index]); index += 1; continue
            }
            if index + 2 < characters.count, characters[index + 1] == "$", characters[index + 2] == "$" {
                var cursor = index + 3
                var name = ""
                while cursor < characters.count, isIdentifierPart(characters[cursor]) {
                    name.append(characters[cursor]); cursor += 1
                }
                let sentinel = name.isEmpty ? "SEXTANTVARIADIC" : "SEXTANTVARIADIC_\(name)"
                variadic.insert(sentinel)
                result += sentinel
                index = cursor
            } else if index + 1 < characters.count, isIdentifierStart(characters[index + 1]) {
                var cursor = index + 1
                var name = ""
                while cursor < characters.count, isIdentifierPart(characters[cursor]) {
                    name.append(characters[cursor]); cursor += 1
                }
                let sentinel = "SEXTANTMETA_\(name)"
                single[sentinel] = name
                result += sentinel
                index = cursor
            } else {
                result.append(characters[index]); index += 1
            }
        }
        return Substitution(text: result, singleByName: single, variadic: variadic)
    }

    static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    static func isIdentifierPart(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }
}
