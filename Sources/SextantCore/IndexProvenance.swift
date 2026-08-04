import Foundation

/// Origin and freshness of the opened index store — a trust label attached to the output.
/// It makes explicit where the semantic data came from and whether it is stale.
public struct IndexProvenance: Sendable {
    public enum Source: String, Sendable {
        case explicit       // given via --index-store
        case umbrella       // the umbrella cache (~/Library/Caches/sextant)
        case spm            // .build of the project's SPM packages
        case derivedData    // Xcode DerivedData
    }

    public let source: Source
    public let storeCount: Int
    public let freshness: IndexFreshness.State

    public init(source: Source, storeCount: Int, freshness: IndexFreshness.State) {
        self.source = source
        self.storeCount = storeCount
        self.freshness = freshness
    }

    /// Compact label for stderr: `[index: spm · 1 store · fresh]`.
    public var summary: String {
        let label: String
        switch freshness {
        case .fresh:
            label = "fresh"
        case .stale:
            label = "⚠ STALE — sources are newer: rebuild the project (an ordinary build updates the index) or run `sextant index`"
        case .unknown:
            // Absence of data is not passed off as freshness: a trust label must not lie.
            label = "⚠ freshness unknown (the store is empty or unreadable)"
        }
        return "[index: \(source.rawValue) · \(storeCount) store(s) · \(label)]"
    }
}
