import Foundation

/// A number raised to the smallest value a command can work with, and the sentence that says so.
///
/// A budget too small to hold a useful answer is raised rather than refused, because the value is
/// otherwise acceptable; the answer then names the value it used instead of the one requested.
public struct RaisedValue: Sendable, Equatable {
    /// The value to use: `requested`, or `minimum` when `requested` is below it.
    public let value: Int
    /// The sentence that names the change; nil when the requested value was used as it is.
    public let note: String?

    public init(_ requested: Int, minimum: Int, name: String) {
        if requested < minimum {
            value = minimum
            note = "\(name) \(requested) is below the minimum of \(minimum); \(minimum) was used"
        } else {
            value = requested
            note = nil
        }
    }
}
