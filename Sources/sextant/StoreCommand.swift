import Foundation
import SextantCore

/// `sextant store` — the index stores in reach, and the policy that decides between them.
///
/// The policy is a person's decision, not a default: the options answer the same question
/// differently, and the difference is invisible in the answer itself. This command is where the
/// decision is read and made.
func runStore(arguments: [String]) -> Int32 {
    // Through the shared parser, so that the value of `--project` is not read as a subcommand.
    let rest = ArgumentParsing.positionals(arguments, valueFlags: valueFlags)
    switch rest.first {
    case nil, "show":
        return showStores(arguments: arguments)
    case "use":
        guard let name = rest.dropFirst().first else {
            reportError("sextant store use: expected a policy — \(StorePolicy.known).")
            return 2
        }
        return useStorePolicy(named: name, arguments: arguments)
    case let other?:
        reportError("sextant store: unknown subcommand '\(other)' — expected `show` or `use <policy>`.")
        return 2
    }
}

private func showStores(arguments: [String]) -> Int32 {
    // Here coverage is measured even for a single store: this is the screen a person reads to
    // decide, and "what does it actually cover" is the question they came with.
    let (found, source) = indexCandidates(in: arguments)
    let root = projectRoot(in: arguments)
    let measured = found.map {
        $0.measuringCoverage(projectRoot: URL(fileURLWithPath: root, isDirectory: true),
                             libraryPath: optionValue("--index-lib", in: arguments))
    }
    let policy = storePolicy(in: arguments)
    let resolution = StoreSelection.resolve(measured, policy: policy?.policy)
    let candidates = resolution.candidates
    print("── index stores — \(shorten(root))")

    guard !candidates.isEmpty else {
        print("   none found. Build one with `sextant index`, or name one with --index-store.")
        return 0
    }
    let sources = source == .explicit ? [source]
        : Array(Set(candidates.map { IndexProvenance.Source.of(storePath: $0.path) })).sorted { $0.rawValue < $1.rawValue }
    print("   found by: \(sources.map(\.rawValue).joined(separator: ", "))")
    for candidate in candidates.sorted(by: { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }) {
        let stamp = candidate.modified.map { StoreSelection.stamp($0) } ?? "no units"
        print("\n   \(shorten(candidate.path))")
        print("     units: \(candidate.unitCount)   ·   last written: \(stamp)")
        if let coverage = candidate.coverage {
            print("     covers: \(coverage.summary) of this project"
                  + (coverage.foreign > 0 ? "   ·   \(coverage.foreign) unit(s) from outside it" : ""))
        } else if candidate.modified != nil {
            print("     covers: not measurable (libIndexStore unavailable) — ranking by coverage would")
            print("             fall back to recency")
        }
        if candidate.modified != nil {
            print("     freshness: \(freshnessLine(IndexFreshness.report(storePaths: [candidate.path], projectRoot: root)))")
        }
        if let writer = StoreSelection.writer(ofPath: candidate.path) { print("     \(writer)") }
        if let origin = candidate.origin { print("     built from: \(shorten(origin))") }
        if let rejection = candidate.rejection { print("     not read: \(rejection)") }
    }

    let usable = candidates.filter(\.isUsable)
    print("")
    print("   rule: \(StoreSelection.ownStoreRule).")
    if let (policy, origin) = policy {
        print("   policy: \(policy.rawValue) (from \(origin)) — \(policy.title)")
        print("   with it, \(resolution.chosen.count) of \(usable.count) usable store(s) are read:")
        resolution.chosen.forEach { print("     \(shorten($0.path))") }
    } else if resolution.decidedByOwnStoreRule {
        print("   policy: not set — the rule decides: the store `sextant index` built is read, and the")
        print("   \(resolution.setAsideByOwnStoreRule) store(s) an ordinary build left are not:")
        resolution.chosen.forEach { print("     \(shorten($0.path))") }
        print("   To read them instead or as well, set a policy: `sextant store use <\(StorePolicy.known)>`.")
    } else if resolution.needsPolicy {
        print("   policy: NOT SET — with several usable stores nothing is chosen, and every")
        print("   semantic command refuses rather than guess. The options:")
        for policy in StorePolicy.allCases {
            print("\n     \(policy.title)")
            print("       what: \(policy.what)")
            print("       gives: \(policy.gives)")
            print("       does not give: \(policy.doesNotGive)")
            print("       \(policy.risk)")
        }
        print("\n   Choose: `sextant store use <\(StorePolicy.known)>`")
    } else {
        print("   policy: not set — and not needed here: one usable store leaves nothing to decide.")
        print("   It becomes a decision as soon as a second one appears (an editor's own index, a")
        print("   second checkout). Set it in advance with `sextant store use <\(StorePolicy.known)>`.")
    }
    return 0
}

/// One store's freshness in a line: the verdict, what changed, and the basis it was judged on.
private func freshnessLine(_ report: IndexFreshness.Report) -> String {
    var line: String
    switch report.state {
    case .fresh: line = "fresh"
    case .stale:
        let reasons = report.reasons()
        line = "STALE" + (reasons.isEmpty ? " — sources are newer" : " — " + reasons.joined(separator: "; "))
    case .unknown: line = "unknown (empty or unreadable)"
    }
    line += " (\(report.basisDescription))"
    if report.testsSkipped { line += "; built without tests (`--no-tests`)" }
    if let problem = report.snapshotProblem { line += "; snapshot not used: \(problem)" }
    return line
}

/// Records the decision in `.sextant.json`, keeping whatever else is in the file.
private func useStorePolicy(named name: String, arguments: [String]) -> Int32 {
    guard let policy = StorePolicy.named(name) else {
        reportError("sextant store use: unknown policy '\(name)' — known policies are \(StorePolicy.known).")
        return 2
    }
    let root = projectRoot(in: arguments)
    let path = "\(root)/.sextant.json"

    var object: [String: Any] = [:]
    if let data = FileManager.default.contents(atPath: path) {
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            reportError("sextant store use: \(shorten(path)) does not parse as JSON — fix it first, "
                        + "so that writing the policy does not throw the rest of it away.")
            return 2
        }
        object = parsed
    }
    object[StorePolicy.configKey] = policy.rawValue
    do {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (String(decoding: data, as: UTF8.self) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        // Not a usage error: the command was understood and the file system refused it.
        reportError("sextant store use: could not write \(shorten(path)): \(error)")
        return 1
    }
    print("── store policy: \(policy.title)")
    print("   \(policy.what)")
    print("   gives: \(policy.gives)")
    print("   does not give: \(policy.doesNotGive)")
    print("   \(policy.risk)")
    print("\n   written to \(shorten(path)) — every command in this project now follows it.")
    print("   Change it with `sextant store use <\(StorePolicy.known)>`; override once with --store-policy.")
    return 0
}
