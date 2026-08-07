import Foundation

/// Which `sextant` a shell actually runs.
///
/// Two install routes are documented — Homebrew and `make install` — and they land in different
/// directories. A copy built from source in `~/.local/bin` wins over the Homebrew one whenever it
/// comes first in `PATH`, and `brew upgrade` cannot fix that: the file is not Homebrew's. The
/// symptom is a tool that reports an old version after a successful upgrade, with nothing to
/// suggest why, so `doctor` says it instead of leaving it to be discovered.
public enum InstallationCheck {
    /// Every `sextant` on `PATH`, in the order a shell would try them.
    public static func binaries(inPath path: String, fileManager: FileManager = .default) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("sextant").path
            guard fileManager.isExecutableFile(atPath: candidate), seen.insert(candidate).inserted else { continue }
            found.append(candidate)
        }
        return found
    }

    /// What to tell the user, or nothing when there is only one. `running` is the binary asking —
    /// it is marked, because the interesting case is precisely when it is not the one that wins.
    public static func report(binaries: [String], running: String) -> [String] {
        guard binaries.count > 1 else { return [] }
        let runningPath = URL(fileURLWithPath: running).standardizedFileURL.path
        var lines = ["⚠ \(binaries.count) sextant binaries on PATH — a shell runs the first:"]
        for (position, binary) in binaries.enumerated() {
            var marks: [String] = []
            if position == 0 { marks.append("wins") }
            if sameFile(binary, runningPath) { marks.append("this one is running") }
            lines.append("     \(binary)" + (marks.isEmpty ? "" : "   ← \(marks.joined(separator: ", "))"))
        }
        lines.append("  A copy from `make install` shadows a Homebrew one, and `brew upgrade` cannot replace it.")
        return lines
    }

    /// Two paths pointing at the same binary — the Homebrew entry in `bin/` is a symlink into
    /// `Cellar`, so comparing the strings alone would call it a different tool.
    private static func sameFile(_ left: String, _ right: String) -> Bool {
        left == right
            || URL(fileURLWithPath: left).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: right).resolvingSymlinksInPath().path
    }
}
