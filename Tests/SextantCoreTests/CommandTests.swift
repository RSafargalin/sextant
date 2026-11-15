import Foundation
import Testing
@testable import SextantCore

/// Running other programs: a helper that hangs is stopped and named, a helper never reads the
/// input of whoever runs sextant, and output of any size comes back whole.
@Suite("Running helpers")
struct CommandTests {
    @Test("A helper that does not finish in time is a named failure, not an empty success",
          .timeLimit(.minutes(1)))
    func timeoutIsAFailure() {
        #expect(Command.output("/bin/sleep", ["30"], timeout: 1) == nil)
        #expect(Command.successOutput("/bin/sleep", ["30"], timeout: 1) == nil)
        #expect(Command.successData("/bin/sleep", ["30"], input: Data("x".utf8), timeout: 1) == nil)
        guard case .failure(let failure) = Command.run("/bin/sleep", ["30"], timeout: 1) else {
            Issue.record("a command that outlived its timeout was reported as finished")
            return
        }
        #expect(failure == .timedOut(seconds: 1))
        #expect(failure.description == "timed out after 1 s")
    }

    @Test("A failed or unstartable helper is told apart from one that printed nothing")
    func failuresAreNamed() {
        #expect(Command.checkedOutput("/bin/sh", ["-c", "exit 3"]) == .failure(.exited(3)))
        #expect(Command.checkedOutput("/bin/sh", ["-c", "true"]) == .success(""))
        #expect(Command.checkedOutput("/no/such/tool", []) == .failure(.couldNotStart("/no/such/tool")))
    }

    /// Whoever runs sextant owns its standard input: the MCP client's requests, a hook's payload,
    /// a terminal. A helper reading it would take what is not its own, or wait on a person.
    @Test("A helper's standard input is the null device, not the caller's", .timeLimit(.minutes(1)))
    func standardInputIsNull() throws {
        let nullDevice = try #require(Command.output("/usr/bin/stat", ["-L", "-f", "%Hr,%Lr", "/dev/null"]))
        let child = Command.output("/bin/sh", ["-c", "stat -L -f %Hr,%Lr /dev/stdin"], timeout: 10)
        #expect(child == nullDevice)
        // A helper that reads its input to the end finishes at once instead of waiting.
        #expect(Command.output("/bin/cat", [], timeout: 10) == "")
    }

    @Test("Input given on purpose reaches the helper")
    func deliberateInputArrives() {
        let echoed = Command.successData("/bin/cat", [], input: Data("hello\n".utf8))
        #expect(echoed == Data("hello\n".utf8))
    }

    /// Reading only after the child exits deadlocks once the output fills the pipe buffer (64 KiB).
    @Test("Output larger than a pipe buffer comes back whole", .timeLimit(.minutes(1)))
    func largeOutputIsRead() throws {
        let size = 4 * 1024 * 1024
        let script = "head -c \(size) /dev/zero | tr '\\000' 'a'"
        let output = try #require(Command.successOutput("/bin/sh", ["-c", script], timeout: 30))
        #expect(output.utf8.count == size)
        let fed = try #require(Command.successData("/bin/cat", [], input: Data(repeating: 0x62, count: size), timeout: 30))
        #expect(fed.count == size)
    }

    @Test("A helper started for the caller sees the environment it is given")
    func environmentIsPassed() {
        let value = Command.output("/bin/sh", ["-c", "printf %s \"$SEXTANT_PROBE\""], environment: ["SEXTANT_PROBE": "caller"])
        #expect(value == "caller")
    }
}

@Suite("Toolchain libraries")
struct ToolchainLibraryTests {
    @Test("The library directory comes from the tool's own directory, not from any `/bin` in the path")
    func libraryBesideTool() {
        #expect(IndexStoreUnits.toolchainLibrary(named: "libIndexStore.dylib",
                                                 besideTool: "/Users/bin-tools/tc/usr/bin/swiftc")
                == "/Users/bin-tools/tc/usr/lib/libIndexStore.dylib")
        #expect(IndexStoreUnits.toolchainLibrary(named: "libclang.dylib",
                                                 besideTool: "/opt/bin/toolchain/usr/bin/clang\n")
                == "/opt/bin/toolchain/usr/lib/libclang.dylib")
        #expect(IndexStoreUnits.toolchainLibrary(named: "libclang.dylib", besideTool: "/usr/local/clang") == nil)
    }
}
