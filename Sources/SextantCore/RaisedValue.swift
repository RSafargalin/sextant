import Foundation

/// A number moved into the range a command can work with, and the sentence that says so.
///
/// A budget too small to hold a useful answer is raised rather than refused, because the value is
/// otherwise acceptable; one larger than any answer could use is lowered for the same reason. The
/// answer then names the value it used instead of the one requested.
public struct RaisedValue: Sendable, Equatable {
    /// The value to use: `requested`, or the nearer bound when `requested` is outside them.
    public let value: Int
    /// The sentence that names the change; nil when the requested value was used as it is.
    public let note: String?

    public init(_ requested: Int, minimum: Int, maximum: Int = .max, name: String) {
        if requested < minimum {
            value = minimum
            note = "\(name) \(requested) is below the minimum of \(minimum); \(minimum) was used"
        } else if requested > maximum {
            value = maximum
            note = "\(name) \(requested) is above the maximum of \(maximum); \(maximum) was used"
        } else {
            value = requested
            note = nil
        }
    }
}

/// The bounds of a token budget, shared by `map`, `api` and their MCP tools.
public enum TokenBudget {
    /// The largest budget an answer is rendered under. A larger one is lowered to it and the answer
    /// says so. At four characters a token it is a 400-million-character answer — more than any
    /// project's map or surface — and its character count stays far inside `Int`.
    public static let maximum = 100_000_000

    /// `requested` within `minimum...maximum`, named when it was moved.
    public static func bounded(_ requested: Int, minimum: Int, name: String) -> RaisedValue {
        RaisedValue(requested, minimum: minimum, maximum: maximum, name: name)
    }

    /// The character count a budget stands for, saturating rather than overflowing.
    static func characters(_ budget: Int) -> Int {
        let (product, overflow) = budget.multipliedReportingOverflow(by: 4)
        return overflow ? (budget < 0 ? .min : .max) : product
    }
}
