import SextantCore
import Darwin
import Foundation

// MARK: - golden (semantic regression check)

func runGolden(arguments: [String]) -> Int32 {
    guard let specPath = optionValue("--spec", in: arguments) else {
        reportError("sextant golden: expected --spec <file.json>")
        return 2
    }
    guard let data = FileManager.default.contents(atPath: specPath) else {
        reportError("sextant golden: spec not found: \(specPath)")
        return 2
    }
    let spec: GoldenSpec
    do { spec = try JSONDecoder().decode(GoldenSpec.self, from: data) }
    catch { reportError("sextant golden: could not parse the spec (\(error))"); return 2 }

    guard let set = openIndex(arguments, label: "golden") else { return 1 }
    let results = Golden.evaluate(spec, against: set)
    let failed = results.filter { !$0.passed }.count

    if arguments.contains("--json") { printJSON(results); return failed == 0 ? 0 : 1 }
    for result in results {
        print("\(result.passed ? "✅" : "❌") [\(result.query)] \(result.symbol) — \(result.detail)")
    }
    print(failed == 0 ? "\n✅ golden passed (\(results.count) assertions)" : "\n❌ failures: \(failed)/\(results.count)")
    return failed == 0 ? 0 : 1
}

// MARK: - bench (latency, payload, RSS)

func runBench(arguments: [String]) -> Int32 {
    let iterations = max(1, optionValue("--iterations", in: arguments).flatMap(Int.init) ?? 20)
    let symbols = (optionValue("--symbols", in: arguments) ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !symbols.isEmpty else {
        reportError("sextant bench: expected --symbols a,b,c")
        return 2
    }
    guard let set = openIndex(arguments, label: "bench") else { return 1 }

    struct OpStat: Encodable {
        var op: String
        var p50ms: Double
        var p95ms: Double
        var payloadBytes: Int   // summed across symbols for one pass (a proxy, not tokens)
        var approxTokens: Int
    }
    let ops = ["context", "refs", "defs"]
    var latencies: [String: [Double]] = Dictionary(uniqueKeysWithValues: ops.map { ($0, []) })
    // payload is deterministic per (op, symbol) — computed once per symbol and aggregated by
    // sum. It used to be overwritten, so it reflected only the last symbol: a false metric.
    var payloadPerSymbol: [String: [String: Int]] = Dictionary(uniqueKeysWithValues: ops.map { ($0, [:]) })

    // Warm-up: the first call pays for a cold IndexStoreDB cache and must not land in p95.
    for symbol in symbols {
        _ = set.context(forName: symbol, sampleLimit: 10)
        _ = set.lookup(name: symbol, query: .references)
        _ = set.lookup(name: symbol, query: .definitions)
    }

    for iteration in 0..<iterations {
        for symbol in symbols {
            var start = DispatchTime.now()
            let context = set.context(forName: symbol, sampleLimit: 10)
            latencies["context"]?.append(Benchmark.elapsedMs(since: start))

            start = DispatchTime.now()
            let references = set.lookup(name: symbol, query: .references)
            latencies["refs"]?.append(Benchmark.elapsedMs(since: start))

            start = DispatchTime.now()
            let definitions = set.lookup(name: symbol, query: .definitions)
            latencies["defs"]?.append(Benchmark.elapsedMs(since: start))

            if iteration == 0 {
                payloadPerSymbol["context"]?[symbol] = Benchmark.jsonByteCount(context)
                payloadPerSymbol["refs"]?[symbol] = Benchmark.jsonByteCount(references)
                payloadPerSymbol["defs"]?[symbol] = Benchmark.jsonByteCount(definitions)
            }
        }
    }

    func payloadSum(_ op: String) -> Int { (payloadPerSymbol[op] ?? [:]).values.reduce(0, +) }
    let stats = ops.map { op in
        OpStat(op: op,
               p50ms: (Benchmark.percentile(latencies[op] ?? [], 50) * 100).rounded() / 100,
               p95ms: (Benchmark.percentile(latencies[op] ?? [], 95) * 100).rounded() / 100,
               payloadBytes: payloadSum(op),
               approxTokens: payloadSum(op) / 4)
    }
    let rssMB = Benchmark.peakRSSBytes().map { Double($0) / 1_048_576 }
    let rssText = rssMB.map { String(format: "%.1f MB", $0) } ?? "n/a (getrusage failed)"

    if arguments.contains("--json") {
        struct Report: Encodable { let iterations: Int; let symbols: [String]; let peakRSSMB: Double?; let ops: [OpStat] }
        printJSON(Report(iterations: iterations, symbols: symbols, peakRSSMB: rssMB, ops: stats))
        return 0
    }
    print("# sextant bench — \(iterations) iterations × \(symbols.count) symbol(s) (payload Σ over symbols, a proxy)")
    print("\("op".padding(toLength: 8, withPad: " ", startingAt: 0))  p50(ms)  p95(ms)  payload   ≈tok")
    for stat in stats {
        let op = stat.op.padding(toLength: 8, withPad: " ", startingAt: 0)
        let line = op + String(format: "  %7.2f  %7.2f  %7d  %5d", stat.p50ms, stat.p95ms, stat.payloadBytes, stat.approxTokens)
        print(line)
    }
    print("peak RSS: \(rssText)")
    return 0
}
