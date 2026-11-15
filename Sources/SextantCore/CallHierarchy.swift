import Foundation

/// The bound on a call-hierarchy walk, shared by the CLI and MCP so that both cut in the same
/// place and both say so.
public enum CallHierarchy {
    /// How many callees or callers of one symbol are expanded under it.
    public static let breadth = 40

    /// The line that states what a bound left out of a list of callees or callers, with the true
    /// total, or nil when nothing was left out. `shown` is the bound: the breadth of a hierarchy
    /// node unless another list is meant.
    public static func omissionNote(total: Int, shown: Int = breadth, direction: CallDirection) -> String? {
        guard total > shown else { return nil }
        let noun = direction == .callers ? "callers" : "callees"
        return "… (first \(shown) of \(total) \(noun) shown)"
    }
}
