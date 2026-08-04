/// A structural hygiene rule: one or more patterns sharing a message.
public struct Rule: Codable, Sendable {
    public let id: String
    public let message: String
    public let patterns: [String]

    public init(id: String, message: String, patterns: [String]) {
        self.id = id
        self.message = message
        self.patterns = patterns
    }
}

/// A rule violation that was found.
public struct RuleViolation: Sendable, Codable {
    public let ruleID: String
    public let file: String
    public let line: Int
    public let column: Int
    public let text: String
    public let message: String
}
