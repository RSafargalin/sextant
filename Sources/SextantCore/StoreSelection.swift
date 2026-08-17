import Foundation

/// A store the tool could use, with the facts a person needs to choose between them.
///
/// Rejected candidates are kept rather than dropped: "there is one store" and "there were three
/// and two were thrown away" are different statements, and only the second one lets a reader
/// notice that the wrong two were thrown away.
public struct StoreCandidate: Sendable, Equatable {
    public let path: String
    /// The build that produced it, as a human reads it: an Xcode workspace, a package directory.
    public let origin: String?
    public let unitCount: Int
    public let modified: Date?
    /// Why this store cannot be used, when it cannot. `nil` means it is a candidate.
    public let rejection: String?
    /// How much of the project this store was built from. Measured only where there is a decision
    /// to make or explain — reading every unit is not free, and with one candidate it buys nothing.
    public let coverage: StoreCoverage.Result?

    public init(path: String, origin: String? = nil, unitCount: Int, modified: Date?,
                rejection: String? = nil, coverage: StoreCoverage.Result? = nil) {
        self.path = path
        self.origin = origin
        self.unitCount = unitCount
        self.modified = modified
        self.rejection = rejection
        self.coverage = coverage
    }

    public func measuringCoverage(projectRoot: URL, libraryPath: String? = nil) -> StoreCandidate {
        guard isUsable, coverage == nil else { return self }
        return StoreCandidate(path: path, origin: origin, unitCount: unitCount, modified: modified,
                              rejection: rejection,
                              coverage: StoreCoverage.measure(store: path, projectRoot: projectRoot,
                                                              libraryPath: libraryPath))
    }

    public var isUsable: Bool { rejection == nil }

    /// Units under `v*/units` — the size of what the store holds. A directory listing, not a scan.
    public static func unitCount(ofStore path: String) -> Int {
        let store = URL(fileURLWithPath: path, isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { return 0 }
        return versions.filter { $0.hasPrefix("v") }.reduce(0) { total, version in
            let units = store.appendingPathComponent("\(version)/units").path
            return total + ((try? FileManager.default.contentsOfDirectory(atPath: units))?.count ?? 0)
        }
    }

    /// Whether the store is structurally incapable of answering: it has units, so it looks built
    /// and dates itself like a fresh one, but the records those units point at are gone.
    ///
    /// This is not a hypothetical shape. A build interrupted mid-write, a cache pruner that walks
    /// `records` because it is the larger directory, a partially copied store — each leaves exactly
    /// this. What makes it worth naming is the answer it produces: every lookup resolves to nothing,
    /// which reads as "this symbol is unused" unless the tool says otherwise.
    public static func lacksRecords(store path: String) -> Bool {
        let store = URL(fileURLWithPath: path, isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { return false }
        var sawUnits = false
        for version in versions where version.hasPrefix("v") {
            let units = store.appendingPathComponent("\(version)/units").path
            let records = store.appendingPathComponent("\(version)/records").path
            let unitCount = (try? FileManager.default.contentsOfDirectory(atPath: units))?.count ?? 0
            guard unitCount > 0 else { continue }
            sawUnits = true
            // A record directory is a tree of two-character shards; anything inside it counts.
            if ((try? FileManager.default.contentsOfDirectory(atPath: records))?.count ?? 0) > 0 { return false }
        }
        return sawUnits
    }
}

/// What to do when a project has more than one usable index store.
///
/// There is no answer that is right for every project, and the two on offer fail in opposite
/// directions — so the choice belongs to the person who knows how the project is built, not to a
/// default buried in the tool. `sextant store` prints this text; `sextant store use <policy>`
/// records the decision.
public enum StorePolicy: String, Sendable, CaseIterable {
    /// One store — the one whose units were written last.
    case recency
    /// Every usable store at once, merged and deduplicated.
    case union
    /// The store that was built from the most of this project's files.
    case coverage

    public static let configKey = "storePolicy"

    public var title: String {
        switch self {
        case .recency: return "recency — the store built last"
        case .union: return "union — every store at once"
        case .coverage: return "coverage — the store that covers most of the project"
        }
    }

    /// What the policy does.
    public var what: String {
        switch self {
        case .recency:
            return "Uses a single store: the one whose units were modified most recently. "
                 + "The others are named in every answer but not read."
        case .union:
            return "Opens every usable store and merges the records, deduplicated by symbol and "
                 + "position. Freshness is taken from the OLDEST of them."
        case .coverage:
            return "Reads every store's units, counts how many of the project's files each was "
                 + "actually built from, and uses the one that covers most. Ties go to the newer store."
        }
    }

    /// What it gives.
    public var gives: String {
        switch self {
        case .recency:
            return "The answer describes one build, so a definition, its references and their line "
                 + "numbers all come from the same compilation. Cost stays at one store."
        case .union:
            return "Nothing is lost to a choice: a symbol recorded in any of the stores is found. "
                 + "Where one store is a partial index (an editor's own, for instance), the other fills it in."
        case .coverage:
            return "The store most likely to answer a question about this project, chosen on what it "
                 + "holds rather than on when it was written. Measured on this repository: 132 of 143 "
                 + "files against 69 of 143 for the store `recency` would have picked."
        }
    }

    /// What it does NOT give.
    public var doesNotGive: String {
        switch self {
        case .recency:
            return "No completeness guarantee. The newest store can be the emptiest one — an editor "
                 + "rewrites its index constantly while covering only the files it has opened — and "
                 + "the answer is then quietly short."
        case .union:
            return "No single-build guarantee. Two stores of the same configuration disagree about "
                 + "any file edited between the builds, and the merged answer holds both positions. "
                 + "Measured on this repository: 83 references from the newest store alone, 91 once a "
                 + "store seven days older is merged in — the extra 8 are positions that have moved since."
        case .coverage:
            return "No freshness guarantee: the best-covering store can be the older one, and an "
                 + "answer from it is marked STALE but still chosen. Coverage is also a count of "
                 + "files, not of correctness — a store that covers everything badly still wins."
        }
    }

    /// What it costs and where it can hurt.
    public var risk: String {
        switch self {
        case .recency:
            return "Risk: silent incompleteness — the count in the answer is smaller than the truth "
                 + "and nothing says so."
        case .union:
            return "Risk: stale-looking answers and more time. Freshness comes from the oldest store, "
                 + "so one neglected store marks every answer STALE; each extra store adds its own "
                 + "open (≈3s measured on a 500-unit store, warm)."
        case .coverage:
            return "Risk: time on a large project, and a wrong answer where the toolchain cannot be "
                 + "read at all. Measured: 4.8s to read 22 725 units on the first look, ~0.5s once "
                 + "cached against the store's timestamp; with no libIndexStore the ranking falls "
                 + "back to `recency` and says so."
        }
    }

    public static func named(_ raw: String) -> StorePolicy? { StorePolicy(rawValue: raw) }

    public static var known: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// Applies a policy to the candidates and says, in words, what it did and why.
public enum StoreSelection {
    /// The stores to open. An empty result means there is nothing usable.
    public static func choose(from candidates: [StoreCandidate], policy: StorePolicy) -> [StoreCandidate] {
        let usable = candidates.filter(\.isUsable)
        guard usable.count > 1 else { return usable }
        switch policy {
        case .union:
            return usable
        case .coverage:
            // A store nobody could measure must not win by scoring zero; where no candidate can be
            // measured the ranking falls back to recency, and the explanation says so.
            let measured = usable.filter { $0.coverage != nil }
            guard !measured.isEmpty else { return choose(from: candidates, policy: .recency) }
            let best = measured.max {
                $0.coverage!.covered != $1.coverage!.covered
                    ? $0.coverage!.covered < $1.coverage!.covered
                    : ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast)
            }
            return best.map { [$0] } ?? []
        case .recency:
            // Ties broken by path, so the same project does not answer differently on two runs.
            let newest = usable.max {
                $0.modified ?? .distantPast != $1.modified ?? .distantPast
                    ? ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast)
                    : $0.path < $1.path
            }
            return newest.map { [$0] } ?? []
        }
    }

    /// The decision, in full: how many candidates there were, which were taken, which were left
    /// and why. Printed with every answer — a choice nobody can see is a choice nobody can correct.
    public static func explanation(candidates: [StoreCandidate], chosen: [StoreCandidate],
                                   policy: StorePolicy, shorten: (String) -> String) -> [String] {
        guard candidates.count > 1 || candidates.contains(where: { !$0.isUsable }) else { return [] }
        let chosenPaths = Set(chosen.map(\.path))
        // Where every candidate came from the same build directory, saying so under each of them
        // is noise; where they differ, it is the whole point.
        let showOrigin = Set(candidates.compactMap(\.origin)).count > 1
        var lines = ["ℹ index stores: \(candidates.count) candidate(s), policy `\(policy.rawValue)`:"]
        for candidate in candidates.sorted(by: { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }) {
            let mark = chosenPaths.contains(candidate.path) ? "→ using" : "  left  "
            let facts = describe(candidate)
            let why = candidate.rejection.map { " — \($0)" }
                ?? (chosenPaths.contains(candidate.path) ? "" : " — \(leftOutReason(candidate, chosen: chosen, policy: policy))")
            lines.append("   \(mark) \(shorten(candidate.path))  [\(facts)]\(why)")
            if let writer = writer(ofPath: candidate.path) { lines.append("            \(writer)") }
            if showOrigin, let origin = candidate.origin { lines.append("            built from \(shorten(origin))") }
        }
        return lines
    }

    /// What to print when several stores are usable and nobody has chosen a policy. The tool does
    /// not pick for the reader here: the two policies give different answers to the same question
    /// (measured: 83 references against one store, 34 against the other in the same project), and
    /// picking one silently is exactly the confident wrongness the tool exists to avoid.
    public static func unsetPolicyRefusal(candidates: [StoreCandidate], shorten: (String) -> String) -> [String] {
        var lines = [
            "sextant: \(candidates.filter(\.isUsable).count) index stores are usable for this project, "
            + "and no store policy is set — the answer depends on which is read, so nothing is guessed here.",
            "",
        ]
        for candidate in candidates.filter(\.isUsable)
            .sorted(by: { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }) {
            lines.append("   \(shorten(candidate.path))  [\(describe(candidate))]")
            if let writer = writer(ofPath: candidate.path) { lines.append("      \(writer)") }
            if let origin = candidate.origin { lines.append("      built from \(shorten(origin))") }
        }
        lines.append("")
        for policy in StorePolicy.allCases {
            lines.append("   \(policy.rawValue): \(policy.what)")
            lines.append("      gives: \(policy.gives)")
            lines.append("      does not give: \(policy.doesNotGive)")
            lines.append("      \(policy.risk)")
        }
        lines.append("")
        lines.append("Choose once: `sextant store use recency` or `sextant store use union` "
                     + "(writes \(StorePolicy.configKey) into .sextant.json).")
        lines.append("For one command only: --store-policy <name>, or --index-store <path> to name a store outright.")
        lines.append("`sextant store` shows this comparison again at any time.")
        return lines
    }

    /// Why a usable store is not being read, in the terms of the policy that left it out. Under
    /// `coverage` "not the most recent" would be a true sentence about the wrong criterion.
    static func leftOutReason(_ candidate: StoreCandidate, chosen: [StoreCandidate], policy: StorePolicy) -> String {
        switch policy {
        case .recency:
            return "not the most recent (`union` or `coverage` would weigh it differently)"
        case .coverage:
            guard let mine = candidate.coverage else {
                return "coverage not measurable, so it cannot win on it (`recency` would use its timestamp)"
            }
            let best = chosen.compactMap(\.coverage).map(\.covered).max() ?? 0
            return "covers less of the project (\(mine.covered) files against \(best))"
        case .union:
            return "not usable"
        }
    }

    /// The facts about one store, in the order a reader needs them: what it covers of this project
    /// first, because that is what decides whether it can answer, and only then its size and age.
    /// Who writes a store, where the path says so. Two paths under one `.build` look
    /// interchangeable, and one of them belongs to an editor: sourcekit-lsp keeps its own index
    /// under `index-build` and fills it in the background, so it covers what it has prepared
    /// rather than what was built. Nothing is decided here — the reader making the choice is told
    /// which store is theirs and which one an editor keeps for itself.
    public static func writer(ofPath path: String) -> String? {
        if path.contains("/.build/index-build/") { return "sourcekit-lsp's own index, filled in the background" }
        if path.contains("/Index.noindex/DataStore") { return "Xcode's own index" }
        return nil
    }

    static func describe(_ candidate: StoreCandidate) -> String {
        var parts: [String] = []
        if let coverage = candidate.coverage { parts.append("covers \(coverage.summary)") }
        parts.append("\(candidate.unitCount) unit(s)")
        if let modified = candidate.modified { parts.append(stamp(modified)) }
        return parts.joined(separator: ", ")
    }

    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
