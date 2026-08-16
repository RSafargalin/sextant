import Foundation
import Testing
@testable import SextantCore

/// The policy that decides between several index stores. What is pinned here is not a ranking but
/// the shape of the decision: it is made by a person, it is recorded, and it is visible in the
/// answer. A silent default would be the fastest way back to the defect this replaced.
@Suite("Store policy")
struct StorePolicyTests {

    private func candidate(_ path: String, units: Int, minutesAgo: Int, rejection: String? = nil) -> StoreCandidate {
        StoreCandidate(path: path, origin: nil, unitCount: units,
                       modified: Date().addingTimeInterval(-Double(minutesAgo) * 60), rejection: rejection)
    }

    @Test("recency takes one store, union takes all of them")
    func policiesChooseDifferently() {
        let new = candidate("/a/store", units: 10, minutesAgo: 1)
        let old = candidate("/b/store", units: 99, minutesAgo: 60)
        #expect(StoreSelection.choose(from: [new, old], policy: .recency) == [new])
        #expect(Set(StoreSelection.choose(from: [new, old], policy: .union).map(\.path)) == ["/a/store", "/b/store"])
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
