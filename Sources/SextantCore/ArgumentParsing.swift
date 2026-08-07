/// Command-line argument parsing that accounts for flags which take a value.
public enum ArgumentParsing {
    /// The value of a `--flag value` option. If the next token is itself an option (`--…`), the
    /// value was omitted and nil is returned, rather than treating the next flag as a value.
    public static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let next = arguments[index + 1]
        return next.hasPrefix("--") ? nil : next
    }

    /// Positional arguments: neither options nor the values of value-taking flags count as positional.
    /// Every value of a repeatable flag, in the order given: `--exclude a --exclude b` is two
    /// patterns, not the last one.
    public static func values(of flag: String, in arguments: [String]) -> [String] {
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if arguments[index] == flag, index + 1 < arguments.endIndex {
                result.append(arguments[index + 1])
                index += 2
                continue
            }
            index += 1
        }
        return result
    }

    public static func positionals(_ arguments: [String], valueFlags: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valueFlags.contains(argument) { index += 2; continue }
            if argument.hasPrefix("--") { index += 1; continue }
            result.append(argument)
            index += 1
        }
        return result
    }
}
