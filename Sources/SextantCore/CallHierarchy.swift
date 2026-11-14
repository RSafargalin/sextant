import Foundation

/// The bound on a call-hierarchy walk, shared by the CLI and MCP so that both cut in the same
/// place and both say so.
public enum CallHierarchy {
    /// How many callees or callers of one symbol are expanded under it.
    public static let breadth = 40

    /// The line that states what the breadth bound left out of one node, with the true total, or
    /// nil when nothing was left out.
    public static func omissionNote(total: Int, direction: CallDirection) -> String? {
        guard total > breadth else { return nil }
        let noun = direction == .callers ? "callers" : "callees"
        return "… (first \(breadth) of \(total) \(noun) shown)"
    }
}
