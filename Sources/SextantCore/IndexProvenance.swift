import Foundation

/// Origin and freshness of the opened index store — a trust label attached to the output.
/// It makes explicit where the semantic data came from and whether it is stale.
public struct IndexProvenance: Sendable {
    public enum Source: String, Sendable {
        case explicit       // given via --index-store
        case umbrella       // the umbrella cache (~/Library/Caches/sextant)
        case spm            // .build of the project's SPM packages
        case derivedData    // Xcode DerivedData

        /// Where a store found by the locators comes from, read from its path. A store named with
        /// `--index-store` is `explicit` whatever its path, and only the caller knows that.
        public static func of(storePath: String) -> Source {
            if IndexBuild.isUmbrellaStore(storePath) { return .umbrella }
            if storePath.contains("/Index.noindex/DataStore") { return .derivedData }
            return .spm
        }
    }

    public let source: Source
    public let storeCount: Int
    public let freshness: IndexFreshness.State
    /// The grounds of the freshness verdict, when they were computed: the basis, and what changed.
    public let report: IndexFreshness.Report?
    /// The rule that chose the store, when a rule rather than a policy or the lack of a choice did.
    public let selection: String?
    /// How much of the project the opened store was built from, when it could be measured. Fresh
    /// is about time; this is about extent, and an answer can be perfectly fresh over half the
    /// project — a release build, for one, compiles no test target, so every reference from a test
    /// is missing from a store nothing else marks as partial.
    public let coverage: StoreCoverage.Result?
    /// The stores read, so that the advice on a stale index names what refreshes them.
    public let storePaths: [String]

    public init(source: Source, storeCount: Int, freshness: IndexFreshness.State,
                coverage: StoreCoverage.Result? = nil, storePaths: [String] = []) {
        self.source = source
        self.storeCount = storeCount
        self.freshness = freshness
        self.report = nil
        self.selection = nil
        self.coverage = coverage
        self.storePaths = storePaths
    }

    public init(source: Source, storeCount: Int, report: IndexFreshness.Report,
                selection: String? = nil, coverage: StoreCoverage.Result? = nil, storePaths: [String] = []) {
        self.source = source
        self.storeCount = storeCount
        self.freshness = report.state
        self.report = report
        self.selection = selection
        self.coverage = coverage
        self.storePaths = storePaths
    }

    /// What refreshes the stores this answer was read from.
    public var refreshAdvice: String {
        guard storePaths.isEmpty else { return StoreSelection.refreshAdvice(forStores: storePaths) }
        return source == .derivedData ? StoreSelection.xcodeRefreshAdvice : StoreSelection.refreshAdvice(forStores: [])
    }

    /// Compact label for stderr: `[index: spm · 1 store · fresh (compared by build time)]`.
    public var summary: String {
        let selected = selection.map { " · \($0)" } ?? ""
        let extent = coverage.map { " · covers \($0.summary)" } ?? ""
        let tests = report?.testsSkipped == true ? " · built without tests (`--no-tests`)" : ""
        return "[index: \(source.rawValue) · \(storeCount) store(s)\(selected) · \(freshnessLabel)\(extent)\(tests)]"
    }

    /// The freshness verdict with its basis and, when stale, what to do about it.
    public var freshnessLabel: String {
        let basis = report.map { " (\($0.basisDescription))" } ?? ""
        switch freshness {
        case .fresh:
            return "fresh\(basis)"
        case .stale:
            if let reasons = report?.reasons(), !reasons.isEmpty {
                return "⚠ STALE — \(reasons.joined(separator: "; ")): run `sextant index`\(basis)"
            }
            // An Xcode build refreshes the store it reads from; the store `sextant index` builds in a
            // tree of its own is refreshed only by running it again.
            return "⚠ STALE — sources are newer: \(refreshAdvice)\(basis)"
        case .unknown:
            // Absence of data is not passed off as freshness: a trust label must not lie.
            return "⚠ freshness unknown (the store is empty or unreadable)"
        }
    }
}
