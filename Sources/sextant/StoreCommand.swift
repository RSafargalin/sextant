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
    let candidates = found.map {
        $0.measuringCoverage(projectRoot: URL(fileURLWithPath: root, isDirectory: true),
                             libraryPath: optionValue("--index-lib", in: arguments))
    }
    print("── index stores — \(shorten(root))")

    guard !candidates.isEmpty else {
        print("   none found. Build one with `sextant index`, or name one with --index-store.")
        return 0
    }
    print("   found by: \(source.rawValue)")
    for candidate in candidates.sorted(by: { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }) {
        let stamp = candidate.modified.map { StoreSelection.stamp($0) } ?? "no units"
        print("\n   \(shorten(candidate.path))")
        print("     units: \(candidate.unitCount)   ·   last written: \(stamp)")
        if let coverage = candidate.coverage {
            print("     covers: \(coverage.summary) of this project"
                  + (coverage.foreign > 0 ? "   ·   \(coverage.foreign) unit(s) from outside it" : ""))
        } else if candidate.isUsable {
            print("     covers: not measurable (libIndexStore unavailable) — ranking by coverage would")
            print("             fall back to recency")
        }
        if let origin = candidate.origin { print("     built from: \(shorten(origin))") }
        if let rejection = candidate.rejection { print("     NOT usable: \(rejection)") }
    }

    let usable = candidates.filter(\.isUsable)
    print("")
    if let (policy, origin) = storePolicy(in: arguments) {
        print("   policy: \(policy.rawValue) (from \(origin)) — \(policy.title)")
        let chosen = StoreSelection.choose(from: candidates, policy: policy)
        print("   with it, \(chosen.count) of \(usable.count) usable store(s) are read:")
        chosen.forEach { print("     \(shorten($0.path))") }
    } else if usable.count > 1 {
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
        reportError("sextant store use: could not write \(shorten(path)): \(error)")
        return 2
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
