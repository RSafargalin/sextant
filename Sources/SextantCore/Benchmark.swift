import Darwin
import Foundation

/// Measurements for `bench`: latency, payload volume, peak memory. Moved out of the CLI because
/// the guard against performance regressions rests on these, and they must not be untestable.
public enum Benchmark {
    public static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
    }

    /// Linearly interpolated percentile (p ∈ [0,100]); 0 for an empty set.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = max(0, min(100, p)) / 100.0 * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down)), upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// Peak resident set size in bytes (macOS). nil if getrusage failed, so that a silent
    /// "0 MB" is never passed off as a valid measurement.
    public static func peakRSSBytes() -> Int? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Int(usage.ru_maxrss)   // macOS: bytes
    }

    /// Result size as compact JSON — a stable RELATIVE proxy for payload volume, for tracking
    /// regressions. It is NOT the CLI or MCP text output, and it is not an exact token count.
    /// sortedKeys keeps it deterministic when the set of fields varies.
    public static func jsonByteCount(_ value: some Encodable) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? encoder.encode(value))?.count ?? 0
    }
}
