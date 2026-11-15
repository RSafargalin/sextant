import Foundation

/// The part of a command's input that belongs to the process that asked, not to the process that
/// answers: the environment variables that change an answer, and whether the output goes to a
/// terminal. A command run by `sextant serve` reads these from the caller's request, so it answers
/// exactly as it would have in the caller's own process.
public struct CallerContext: Codable, Sendable, Equatable {
    /// Environment variables whose value changes what a command answers. A variable read by a
    /// command that the daemon serves belongs here, or the daemon answers with its own value.
    public static let environmentNames: Set<String> = ["SEXTANT_STORE_POLICY", "SEXTANT_DERIVED_DATA"]

    /// The caller's values of `environmentNames`; a variable the caller did not set is absent.
    public let environment: [String: String]
    /// Whether the caller's standard output is a terminal.
    public let outputIsTerminal: Bool

    public init(environment: [String: String], outputIsTerminal: Bool) {
        self.environment = environment.filter { Self.environmentNames.contains($0.key) }
        self.outputIsTerminal = outputIsTerminal
    }

    /// The context of the current process.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                               outputIsTerminal: Bool = isatty(STDOUT_FILENO) != 0) -> CallerContext {
        CallerContext(environment: environment, outputIsTerminal: outputIsTerminal)
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
