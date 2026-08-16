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

    public init(path: String, origin: String? = nil, unitCount: Int, modified: Date?, rejection: String? = nil) {
        self.path = path
        self.origin = origin
        self.unitCount = unitCount
        self.modified = modified
        self.rejection = rejection
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

    public static let configKey = "storePolicy"

    public var title: String {
        switch self {
        case .recency: return "recency — the store built last"
        case .union: return "union — every store at once"
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
            let facts = "\(candidate.unitCount) unit(s)" + (candidate.modified.map { ", \(stamp($0))" } ?? "")
            let why = candidate.rejection.map { " — \($0)" }
                ?? (chosenPaths.contains(candidate.path) ? "" : " — not the most recent (`union` would use it too)")
            lines.append("   \(mark) \(shorten(candidate.path))  [\(facts)]\(why)")
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
            lines.append("   \(shorten(candidate.path))  [\(candidate.unitCount) unit(s)"
                         + (candidate.modified.map { ", \(stamp($0))" } ?? "") + "]")
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

    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
