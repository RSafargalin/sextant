import Foundation

/// Running external commands. Several modes with different error semantics; which one to use
/// depends on whether empty output would disguise a failure.
///
/// Every command started here reads its standard input from the null device unless input is passed
/// on purpose: a child that reads stdin would otherwise consume the input of whoever runs sextant —
/// the MCP client's requests, a hook's payload — or wait on a terminal. A command run while a query
/// is answered has a timeout of a few seconds; one that runs out is killed and reported as a
/// failure, never as an empty success.
public enum Command {
    /// Why a command produced no usable result.
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// The executable could not be started.
        case couldNotStart(String)
        /// The command did not finish in time and was killed.
        case timedOut(seconds: TimeInterval)
        /// The command finished with a non-zero exit status.
        case exited(Int32)
        /// The command succeeded, but what it printed is not UTF-8 text.
        case notText

        public var description: String {
            switch self {
            case .couldNotStart(let path): return "\(path) could not be started"
            case .timedOut(let seconds): return "timed out after \(Self.format(seconds)) s"
            case .exited(let status): return "exited with status \(status)"
            case .notText: return "printed something that is not UTF-8 text"
            }
        }

        private static func format(_ seconds: TimeInterval) -> String {
            seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
        }
    }

    /// How long a helper may run while a query is being answered, such as `git`.
    public static let queryTimeout: TimeInterval = 30
    /// How long a helper that asks the toolchain about itself may run (`xcrun --find`, `swift --version`).
    public static let toolchainTimeout: TimeInterval = 15

    /// A finished command: its exit status and everything it wrote to standard output.
    public struct Completion: Sendable, Equatable {
        public let status: Int32
        public let output: Data
    }

    /// Runs a command to completion and collects its standard output. stderr is discarded, stdin is
    /// the null device unless `input` is given (written from another thread, so a command that
    /// answers while it reads cannot fill its output pipe and stall), and stdout is drained while
    /// the command runs, so output larger than a pipe buffer cannot deadlock it. With a timeout, a
    /// command still running when it expires is terminated (killed if it ignores that) and the
    /// result is `.timedOut`; nil waits as long as the command runs.
    public static func run(_ launchPath: String, _ arguments: [String], input: Data? = nil,
                           timeout: TimeInterval?, environment: [String: String]? = nil,
                           in directory: URL? = nil) -> Result<Completion, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice

        // `waitUntilExit` spins the run loop and returns tens of milliseconds after the child has
        // exited; a semaphore signalled by the termination handler returns when it exits.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failure(.couldNotStart(launchPath)) }

        if let stdin, let input {
            let writer = Thread {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
            writer.start()
        }
        // The output is drained on a thread of its own rather than a dispatch queue: a caller that
        // blocks many queue threads at once (a test runner, a server) must not leave the read with
        // no thread to run on.
        let collected = Collected()
        let drained = DispatchSemaphore(value: 0)
        let reader = Thread {
            collected.set(output.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        reader.start()

        let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
        if exited.wait(timeout: deadline) == .timedOut {
            stop(process, exited: exited)
            return .failure(.timedOut(seconds: timeout ?? 0))
        }
        // A grandchild that keeps the pipe open would keep the read going after the command itself
        // has exited; the deadline covers that too.
        guard drained.wait(timeout: deadline) == .success else {
            return .failure(.timedOut(seconds: timeout ?? 0))
        }
        return .success(Completion(status: process.terminationStatus, output: collected.value))
    }

    /// Terminates a command, and kills it when it ignores that.
    private static func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        if exited.wait(timeout: .now() + 2) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var value: Data { lock.withLock { data } }
        func set(_ new: Data) { lock.withLock { data = new } }
    }

    /// The command's stdout, trimmed; the exit code is NOT checked — for commands where the output
    /// itself is what matters. nil when the command could not start or timed out.
    public static func output(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 120,
                              environment: [String: String]? = nil) -> String? {
        guard case .success(let completion) = run(launchPath, arguments, timeout: timeout, environment: environment)
        else { return nil }
        return String(data: completion.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// stdout of a successful command as is; nil on a non-zero code, a timeout or a failure to
    /// start, so a failure is never disguised as an empty result ("not a git repository" and "no
    /// changes" are different answers).
    public static func successOutput(_ launchPath: String, _ arguments: [String],
                                     timeout: TimeInterval = queryTimeout) -> String? {
        guard case .success(let output) = checkedOutput(launchPath, arguments, timeout: timeout) else { return nil }
        return output
    }

    /// stdout of a successful command, or the reason there is none.
    public static func checkedOutput(_ launchPath: String, _ arguments: [String],
                                     timeout: TimeInterval = queryTimeout) -> Result<String, Failure> {
        run(launchPath, arguments, timeout: timeout).flatMap { completion in
            guard completion.status == 0 else { return .failure(.exited(completion.status)) }
            guard let text = String(data: completion.output, encoding: .utf8) else { return .failure(.notText) }
            return .success(text)
        }
    }

    /// stdout of a successful command fed `input` on stdin, as bytes; nil on a non-zero code, a
    /// timeout or a failure to start.
    public static func successData(_ launchPath: String, _ arguments: [String], input: Data,
                                   timeout: TimeInterval = queryTimeout) -> Data? {
        guard case .success(let completion) = run(launchPath, arguments, input: input, timeout: timeout),
              completion.status == 0 else { return nil }
        return completion.output
    }

    /// Runs with inherited stdout and stderr so long builds show progress, and no timeout: this is
    /// the user's build. Returns the exit code, or -1 if the process failed to start.
    @discardableResult
    public static func status(_ launchPath: String, _ arguments: [String], in directory: URL? = nil) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        return waitForExit(process)
    }

    /// Runs a command with its output going to a file instead of the terminal, and returns the
    /// exit code. Used for a build whose log is the point: `xcodebuild` prints the compile flags
    /// only in full (non-quiet) output, which is far too much to put in front of a reader. No
    /// timeout: this is the user's build.
    @discardableResult
    public static func status(_ launchPath: String, _ arguments: [String], in directory: URL? = nil,
                              loggingTo logFile: URL) -> Int32 {
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: logFile) else {
            return status(launchPath, arguments, in: directory)
        }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        return waitForExit(process)
    }

    private static func waitForExit(_ process: Process) -> Int32 {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return -1 }
        exited.wait()
        return process.terminationStatus
    }

    /// Runs git in a directory, checking the exit code.
    public static func git(_ arguments: [String], in directory: String) -> String? {
        successOutput("/usr/bin/env", ["git", "-C", directory] + arguments)
    }
}
