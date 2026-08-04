import Foundation

/// Running external commands. Three modes with different error semantics; which one to use
/// depends on whether empty output would disguise a failure.
public enum Command {
    /// The command's stdout, trimmed; the exit code is NOT checked — for commands where the output
    /// itself is what matters. stderr is discarded (an undrained pipe deadlocks on large output),
    /// with a watchdog on the timeout.
    public static func output(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 120) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// stdout of a successful command as is; nil on a non-zero code, so a failure is never
    /// disguised as an empty result ("not a git repository" and "no changes" are different answers).
    public static func successOutput(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Runs with inherited stdio so long builds show progress; returns the exit code, or -1 if the process failed to start.
    @discardableResult
    public static func status(_ launchPath: String, _ arguments: [String], in directory: URL? = nil) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs git in a directory, checking the exit code.
    public static func git(_ arguments: [String], in directory: String) -> String? {
        successOutput("/usr/bin/env", ["git", "-C", directory] + arguments)
    }
}
