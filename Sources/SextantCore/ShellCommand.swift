import Foundation

/// One simple command of a shell line: the words it runs with, and where its input and output go.
///
/// A line an agent hands to a shell is rarely one command: `cd`, `&&`, a pipe into a filter, a
/// heredoc carrying a script. What a line *runs* is decided by the words in command position, not
/// by every word that appears in it — a directory called `sextant` is not a call to sextant, and
/// `swift build | grep error` searches a build log, not the sources.
struct ShellCommand: Equatable {
    /// The words, without redirections and their targets.
    let words: [String]
    /// The command reads the output of the command before it through a pipe.
    let readsPipe: Bool
    /// The command's standard output goes to a file (`> f`, `>> f`, `&> f`), not to whoever ran it.
    let writesFile: Bool

    /// Simple commands of a line, in order.
    ///
    /// Quoting follows the shell: single quotes are literal; in double quotes a backslash escapes
    /// only `$`, a backtick, `"`, `\` and a newline; outside quotes it escapes anything, and before a
    /// newline continues the line. `;`, `&&`, `||`, `&`, `|`, newlines, parentheses, backticks and
    /// `$(` separate commands; a `#` at the start of a word starts a comment. Redirections are taken
    /// out of the words with their targets, and the body of a heredoc is skipped. A command
    /// substitution inside double quotes stays part of its word.
    static func commands(in line: String) -> [ShellCommand] {
        var parser = Parser(Array(line))
        parser.run()
        return parser.commands
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var commands: [ShellCommand] = []
        var words: [String] = []
        var current = ""
        var hasCurrent = false
        var readsPipe = false
        var writesFile = false
        /// The next word is the target of a redirection; `writes` says whether it receives stdout.
        var redirection: (writes: Bool, duplicates: Bool)?
        var heredocs: [(delimiter: String, stripsTabs: Bool)] = []

        init(_ characters: [Character]) {
            self.characters = characters
        }

        func character(at offset: Int) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        mutating func endWord() {
            defer {
                current = ""
                hasCurrent = false
            }
            guard hasCurrent else { return }
            if let target = redirection {
                // `>&2` duplicates a descriptor; `>&file` is a file.
                if target.writes && !(target.duplicates && current.allSatisfy(\.isNumber)) { writesFile = true }
                redirection = nil
                return
            }
            words.append(current)
        }

        mutating func endCommand(pipeFollows: Bool) {
            endWord()
            redirection = nil
            if !words.isEmpty {
                commands.append(ShellCommand(words: words, readsPipe: readsPipe, writesFile: writesFile))
            }
            words = []
            readsPipe = pipeFollows
            writesFile = false
        }

        mutating func run() {
            var quote: Character?
            var escaped = false
            while index < characters.count {
                let character = characters[index]
                let next = self.character(at: 1)
                defer { index += 1 }

                if escaped {
                    if character != "\n" {
                        current.append(character)
                        hasCurrent = true
                    }
                    escaped = false
                    continue
                }
                if let open = quote {
                    if character == open {
                        quote = nil
                    } else if open == "\"", character == "\\", let next, "$`\"\\\n".contains(next) {
                        escaped = true
                    } else {
                        current.append(character)
                    }
                    continue
                }
                switch character {
                case "\\":
                    escaped = true
                case "'", "\"":
                    quote = character
                    hasCurrent = true
                case " ", "\t", "\r":
                    endWord()
                case "#" where !hasCurrent:
                    while index + 1 < characters.count, characters[index + 1] != "\n" { index += 1 }
                case "\n":
                    endCommand(pipeFollows: false)
                    skipHeredocBodies()
                case ";", "(", ")", "`":
                    endCommand(pipeFollows: false)
                case "|":
                    if next == "|" {
                        index += 1
                        endCommand(pipeFollows: false)
                    } else {
                        if next == "&" { index += 1 }
                        endCommand(pipeFollows: true)
                    }
                case "&" where next == ">":
                    // `&>file` and `&>>file`: stdout and stderr together.
                    endWord()
                    index += 1
                    if self.character(at: 1) == ">" { index += 1 }
                    redirection = (writes: true, duplicates: false)
                case "&":
                    if next == "&" { index += 1 }
                    endCommand(pipeFollows: false)
                case ">", "<":
                    redirect(character)
                case "$" where next == "(":
                    index += 1
                    endCommand(pipeFollows: false)
                default:
                    current.append(character)
                    hasCurrent = true
                }
            }
            endCommand(pipeFollows: false)
        }

        /// An operator starting at `index`: `>`, `>>`, `>|`, `>&`, `<`, `<&`, `<<<`, or a heredoc.
        /// A word of digits right before it is the descriptor it applies to.
        mutating func redirect(_ operatorCharacter: Character) {
            let descriptor: String? = hasCurrent && !current.isEmpty && current.allSatisfy(\.isNumber) ? current : nil
            if descriptor != nil {
                current = ""
                hasCurrent = false
            } else {
                endWord()
            }

            if operatorCharacter == "<", character(at: 1) == "<" {
                if character(at: 2) == "<" {
                    index += 2
                    redirection = (writes: false, duplicates: false)
                } else {
                    index += 1
                    openHeredoc()
                }
                return
            }
            var duplicates = false
            if let following = character(at: 1), following == ">" || following == "|" || following == "&" {
                duplicates = following == "&"
                index += 1
            }
            let writes = operatorCharacter == ">" && (descriptor == nil || descriptor == "1")
            redirection = (writes: writes, duplicates: duplicates)
        }

        /// Reads the delimiter after `<<` or `<<-`. Quoting any part of it, or a backslash, only
        /// stops expansion in the body, so the quotes are removed from the delimiter.
        mutating func openHeredoc() {
            var stripsTabs = false
            if character(at: 1) == "-" {
                stripsTabs = true
                index += 1
            }
            while let following = character(at: 1), following == " " || following == "\t" { index += 1 }
            var delimiter = ""
            var quote: Character?
            while let following = character(at: 1) {
                if let open = quote {
                    if following == open { quote = nil } else { delimiter.append(following) }
                } else if following == "'" || following == "\"" {
                    quote = following
                } else if following == "\\" {
                    // A backslash quotes the character after it.
                } else if " \t\n;|&<>()".contains(following) {
                    break
                } else {
                    delimiter.append(following)
                }
                index += 1
            }
            if !delimiter.isEmpty { heredocs.append((delimiter, stripsTabs)) }
        }

        /// After the newline that ends a line opening heredocs, skips their bodies and delimiter lines.
        mutating func skipHeredocBodies() {
            while let open = heredocs.first {
                heredocs.removeFirst()
                while index + 1 < characters.count {
                    var end = index + 1
                    while end < characters.count, characters[end] != "\n" { end += 1 }
                    var text = String(characters[(index + 1)..<end])
                    index = end
                    if open.stripsTabs { text = String(text.drop { $0 == "\t" }) }
                    if text.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) == open.delimiter { break }
                }
            }
        }
    }
}
