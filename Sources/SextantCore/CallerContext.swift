import Foundation

/// The part of a command's input that belongs to the process that asked, not to the process that
/// answers: the environment variables that change an answer, and whether the output goes to a
/// terminal. A command run by `sextant serve` reads these from the caller's request, so it answers
/// exactly as it would have in the caller's own process.
public struct CallerContext: Codable, Sendable, Equatable {
    /// Environment variables whose value changes what a command answers. A variable read by a
    /// command that the daemon serves belongs here, or the daemon answers with its own value.
    /// `PATH`, `DEVELOPER_DIR` and `TOOLCHAINS` decide which `swift` builds the project, which
    /// freshness compares against the toolchain the index was built with.
    public static let environmentNames: Set<String> = ["SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA",
                                                       "PATH", "DEVELOPER_DIR", "TOOLCHAINS"]

    /// The caller's values of `environmentNames`; a variable the caller did not set is absent.
    public let environment: [String: String]
    /// Whether the caller's standard output is a terminal.
    public let outputIsTerminal: Bool
    /// Whether the caller's standard output and standard error are one open file (one terminal, or
    /// `2>&1`), so the order in which a command writes to the two is visible. nil from a client
    /// that does not send it.
    public let outputSharesErrorStream: Bool?
    /// The size of the buffer the C library gives the caller's standard output: where a command's
    /// output is cut into writes, and so where its standard error can fall in between when the two
    /// streams are one file. nil from a client that does not send it.
    public let outputBufferSize: Int?

    public init(environment: [String: String], outputIsTerminal: Bool, outputSharesErrorStream: Bool? = nil,
                outputBufferSize: Int? = nil) {
        self.environment = environment.filter { Self.environmentNames.contains($0.key) }
        self.outputIsTerminal = outputIsTerminal
        self.outputSharesErrorStream = outputSharesErrorStream
        self.outputBufferSize = outputBufferSize
    }

    /// The context of the current process.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                               outputIsTerminal: Bool = isatty(STDOUT_FILENO) != 0) -> CallerContext {
        CallerContext(environment: environment, outputIsTerminal: outputIsTerminal,
                      outputSharesErrorStream: sameFile(STDOUT_FILENO, STDERR_FILENO),
                      outputBufferSize: streamBufferSize(STDOUT_FILENO))
    }

    /// The buffer size the C library chooses for a stream on `descriptor`: the file's preferred
    /// block size, or `BUFSIZ` when the file reports none.
    static func streamBufferSize(_ descriptor: Int32) -> Int {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_blksize > 0 else { return Int(BUFSIZ) }
        return Int(status.st_blksize)
    }

    /// Whether two descriptors refer to the same file (device and inode).
    static func sameFile(_ left: Int32, _ right: Int32) -> Bool {
        var a = stat(), b = stat()
        guard fstat(left, &a) == 0, fstat(right, &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    // MARK: Reading

    /// The value of one of `environmentNames`: the caller's while a request is being answered,
    /// otherwise this process's own. A variable the caller did not set reads as unset, whatever
    /// this process has.
    public static func environmentValue(_ name: String,
                                        process: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if environmentNames.contains(name), let active = active.value { return active.environment[name] }
        return process[name]
    }

    /// The environment a command answers in: this process's own, with each of `environmentNames`
    /// as the caller has it while a request is being answered (absent where the caller did not
    /// set it). The environment a helper that asks the toolchain is started with.
    public static func effectiveEnvironment(process: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        guard let active = active.value else { return process }
        var environment = process.filter { !environmentNames.contains($0.key) }
        environment.merge(active.environment) { _, caller in caller }
        return environment
    }

    /// Whether standard output is a terminal: the caller's while a request is being answered,
    /// otherwise this process's own.
    public static func outputIsTerminal(process: () -> Bool = { isatty(STDOUT_FILENO) != 0 }) -> Bool {
        active.value?.outputIsTerminal ?? process()
    }

    /// Runs `body` with `context` as the caller. nil leaves this process's own values in force.
    public static func during<T>(_ context: CallerContext?, _ body: () throws -> T) rethrows -> T {
        let previous = active.exchange(context)
        defer { _ = active.exchange(previous) }
        return try body()
    }

    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var context: CallerContext?

        var value: CallerContext? { lock.withLock { context } }

        func exchange(_ new: CallerContext?) -> CallerContext? {
            lock.withLock {
                let old = context
                context = new
                return old
            }
        }
    }

    private static let active = Slot()
}
