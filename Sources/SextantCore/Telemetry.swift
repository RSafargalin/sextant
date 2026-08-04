import Darwin
import Foundation

/// Local OPT-IN usage telemetry: it turns sessions into a signal of which tool ran and how it
/// ended, instead of hand-written field reports. Enabled by `SEXTANT_TELEMETRY` in the
/// environment: the value is a file path, and `1` means the default
/// `~/Library/Caches/sextant/telemetry.jsonl`. Local only, nothing is sent anywhere. OFF by default.
public enum Telemetry {
    public static func record(command: String, argument: String?, exitCode: Int32, durationMs: Double, timestamp: Double) {
        guard let raw = ProcessInfo.processInfo.environment["SEXTANT_TELEMETRY"], !raw.isEmpty else { return }
        let path = (raw == "1")
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/sextant/telemetry.jsonl").path
            : raw

        let entry: [String: Any] = [
            "ts": timestamp,
            "command": command,
            "arg": argument ?? "",
            "exit": exitCode,
            "ms": Int(durationMs.rounded())   // whole milliseconds — no float noise in the JSON
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        // Atomic append: O_APPEND plus a single write(2) (atomic below PIPE_BUF), so concurrent
        // processes do not tear lines apart (FileHandle seek+write is not atomic across processes).
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
}
