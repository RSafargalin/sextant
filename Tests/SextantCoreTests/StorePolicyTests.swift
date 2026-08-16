import Foundation
import Testing
@testable import SextantCore

/// The policy that decides between several index stores. What is pinned here is not a ranking but
/// the shape of the decision: it is made by a person, it is recorded, and it is visible in the
/// answer. A silent default would be the fastest way back to the defect this replaced.
@Suite("Store policy")
struct StorePolicyTests {

    private func candidate(_ path: String, units: Int, minutesAgo: Int, rejection: String? = nil,
                           covers: Int? = nil, of total: Int = 100) -> StoreCandidate {
        StoreCandidate(path: path, origin: nil, unitCount: units,
                       modified: Date().addingTimeInterval(-Double(minutesAgo) * 60), rejection: rejection,
                       coverage: covers.map { StoreCoverage.Result(covered: $0, total: total, foreign: 0) })
    }

    @Test("recency takes one store, union takes all of them")
    func policiesChooseDifferently() {
        let new = candidate("/a/store", units: 10, minutesAgo: 1)
        let old = candidate("/b/store", units: 99, minutesAgo: 60)
        #expect(StoreSelection.choose(from: [new, old], policy: .recency) == [new])
        #expect(Set(StoreSelection.choose(from: [new, old], policy: .union).map(\.path)) == ["/a/store", "/b/store"])
    }

    /// The case the policy exists for, and the one a timestamp gets wrong: measured on this
    /// repository, the newer store was built from 69 of 143 files and the older one from 132.
    @Test("coverage takes the store built from more of the project, not the newer one")
    func coverageOutranksRecency() {
        let newerButThinner = candidate("/new/store", units: 560, minutesAgo: 1, covers: 69, of: 143)
        let olderButFuller = candidate("/old/store", units: 532, minutesAgo: 10_000, covers: 132, of: 143)
        #expect(StoreSelection.choose(from: [newerButThinner, olderButFuller], policy: .coverage) == [olderButFuller])
        #expect(StoreSelection.choose(from: [newerButThinner, olderButFuller], policy: .recency) == [newerButThinner])
    }

    /// Coverage that could not be measured must not score zero: a store nobody could read would
    /// then lose to any store at all, which is a decision made on missing data.
    @Test("with nothing measurable, coverage falls back to recency instead of ranking by silence")
    func coverageFallsBackWhenNothingIsMeasurable() {
        let newer = candidate("/new/store", units: 10, minutesAgo: 1)
        let older = candidate("/old/store", units: 99, minutesAgo: 500)
        #expect(StoreSelection.choose(from: [newer, older], policy: .coverage) == [newer])
    }

    @Test("a store whose coverage is unknown does not outrank a measured one")
    func unmeasuredDoesNotWin() {
        let measured = candidate("/known/store", units: 10, minutesAgo: 900, covers: 80, of: 100)
        let unknown = candidate("/unknown/store", units: 999, minutesAgo: 1)
        #expect(StoreSelection.choose(from: [measured, unknown], policy: .coverage) == [measured])
    }

    @Test("the reason a store was left out is stated in the terms of the policy")
    func leftOutReasonFollowsThePolicy() {
        let thin = candidate("/new/store", units: 560, minutesAgo: 1, covers: 69, of: 143)
        let full = candidate("/old/store", units: 532, minutesAgo: 10_000, covers: 132, of: 143)
        let byCoverage = StoreSelection.explanation(candidates: [thin, full], chosen: [full],
                                                    policy: .coverage, shorten: { $0 }).joined(separator: "\n")
        #expect(byCoverage.contains("covers less of the project (69 files against 132)"))
        #expect(byCoverage.contains("covers 132/143 files (92%)"))

        let byRecency = StoreSelection.explanation(candidates: [thin, full], chosen: [thin],
                                                   policy: .recency, shorten: { $0 }).joined(separator: "\n")
        #expect(byRecency.contains("not the most recent"))
    }

    @Test("a store that cannot be read is never chosen, whatever the policy")
    func rejectedCandidatesAreNotChosen() {
        let good = candidate("/a/store", units: 10, minutesAgo: 60)
        let broken = candidate("/b/store", units: 0, minutesAgo: 1, rejection: "no units — nothing to read")
        for policy in StorePolicy.allCases {
            #expect(StoreSelection.choose(from: [good, broken], policy: policy) == [good])
        }
    }

    @Test("one candidate needs no policy — there is nothing to decide")
    func singleCandidateIsUnambiguous() {
        let only = candidate("/a/store", units: 10, minutesAgo: 1)
        for policy in StorePolicy.allCases {
            #expect(StoreSelection.choose(from: [only], policy: policy) == [only])
        }
        // And nothing is said about a decision that was not made.
        #expect(StoreSelection.explanation(candidates: [only], chosen: [only], policy: .recency, shorten: { $0 }).isEmpty)
    }

    @Test("the explanation names every candidate, the ones used and why the others were not")
    func explanationIsComplete() {
        let new = candidate("/a/store", units: 10, minutesAgo: 1)
        let old = candidate("/b/store", units: 99, minutesAgo: 60)
        let broken = candidate("/c/store", units: 0, minutesAgo: 1, rejection: "no units — nothing to read")
        let text = StoreSelection.explanation(candidates: [new, old, broken], chosen: [new],
                                              policy: .recency, shorten: { $0 }).joined(separator: "\n")
        #expect(text.contains("3 candidate(s)"))
        #expect(text.contains("policy `recency`"))
        for path in ["/a/store", "/b/store", "/c/store"] { #expect(text.contains(path)) }
        #expect(text.contains("no units — nothing to read"))
        #expect(text.contains("10 unit(s)") && text.contains("99 unit(s)"))
    }

    /// The refusal is the product promise in one screen: it must show the stores, and it must
    /// describe both options — what each gives and what it does not — or the reader cannot decide.
    @Test("the refusal describes the stores and both policies, with their costs")
    func refusalIsSelfContained() {
        let text = StoreSelection.unsetPolicyRefusal(
            candidates: [candidate("/a/store", units: 10, minutesAgo: 1),
                         candidate("/b/store", units: 99, minutesAgo: 60)],
            shorten: { $0 }
        ).joined(separator: "\n")
        #expect(text.contains("/a/store") && text.contains("/b/store"))
        for policy in StorePolicy.allCases {
            #expect(text.contains(policy.rawValue))
            #expect(text.contains(policy.gives))
            #expect(text.contains(policy.doesNotGive))
            #expect(text.contains(policy.risk))
        }
        #expect(text.contains("sextant store use"))
    }

    @Test("a misspelled policy in the config is reported, not ignored")
    func unknownPolicyValueIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"storePolicy": "freshest"}"#
            .write(to: root.appendingPathComponent(".sextant.json"), atomically: true, encoding: .utf8)

        guard case .invalid(let reason) = ProjectConfig.read(projectRoot: root.path) else {
            Issue.record("a policy nobody implements has to be refused, not silently dropped")
            return
        }
        #expect(reason.contains("freshest"))
        #expect(reason.contains("recency") && reason.contains("union"))
    }

    @Test("a policy the tool knows is accepted")
    func knownPolicyValueIsAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"storePolicy": "union", "budget": 6000}"#
            .write(to: root.appendingPathComponent(".sextant.json"), atomically: true, encoding: .utf8)

        guard case .loaded(let config) = ProjectConfig.read(projectRoot: root.path) else {
            Issue.record("a valid config must load")
            return
        }
        #expect(config.storePolicy == "union")
        #expect(config.budget == 6000)
    }
}
