import Darwin
import Foundation

/// Captures stdout and stderr around a call: commands print directly, but the daemon needs the
/// response as text. It lives in Core so it can be tested: the draining defect described below
/// would be invisible to tests inside the executable, and it hung the daemon on real projects.
public enum OutputCapture {
    public struct Captured: Sendable {
        public let value: Int32
        public let output: String
        public let errorOutput: String
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    /// Collects the pipe contents, draining them CONCURRENTLY with `body`.
    ///
    /// The crucial part: a pipe buffer holds about 64 KB, and a writer producing more than that
    /// would block forever if reading only started after it finished. The write ends are closed
    /// after `body`, which is the readers' EOF.
    ///
    /// Each reader gets a thread of its own rather than a block on the global queue. A queue only
    /// promises to run the block eventually, and "eventually" is not enough when the caller is
    /// already blocked on the write: the pool is finite, and anything that holds its threads —
    /// several `Process.waitUntilExit` calls, say — starves the reader that would unblock the
    /// writer. Reproduced with 80 blocked tasks on the global queue: the write never returned, and
    /// a watchdog scheduled on the same queue never fired either. The CI runner hit it for real,
    /// where the test for this very defect timed out at 60 seconds while passing in 0.002s locally.
    public static func collect(from pipes: [Pipe], while body: () -> Void) -> [String] {
        let boxes = pipes.map { _ in Box() }
        let readers = DispatchGroup()
        for (pipe, box) in zip(pipes, boxes) {
            readers.enter()
            let thread = Thread {
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { break }   // an empty chunk means EOF
                    box.append(chunk)
                }
                readers.leave()
            }
            thread.name = "sextant.output-drain"
            thread.start()
        }
        body()
        for pipe in pipes { try? pipe.fileHandleForWriting.close() }
        readers.wait()
        return boxes.map(\.text)
    }

    /// Runs `body` with everything it writes to standard output sent to standard error instead,
    /// in the order it was written.
    ///
    /// Swapping descriptors is process-global, as in `capture`.
    public static func sendingOutputToStandardError(_ body: () -> Int32) -> Int32 {
        fflush(stdout)
        let savedOut = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let code = body()
        fflush(stdout)
        dup2(savedOut, STDOUT_FILENO)
        Darwin.close(savedOut)
        return code
    }

    /// Runs `body` with stdout and stderr captured, returning its code and its output.
    ///
    /// With `mergingStreams`, both go into one pipe, in the order `body` wrote them, and come back
    /// together as `output` (`errorOutput` is empty): what a caller whose two streams are one file
    /// would have seen. Standard output is then line-buffered when `lineBufferedOutput` (the caller
    /// writes to a terminal) and fully buffered otherwise, as it would be in the caller's process.
    ///
    /// Swapping descriptors is process-global: the caller must guarantee there are no concurrent
    /// invocations (the daemon serves requests sequentially).
    public static func capture(mergingStreams: Bool = false, lineBufferedOutput: Bool = false,
                               _ body: () -> Int32) -> Captured {
        let outPipe = Pipe(), errorPipe = Pipe()
        let pipes = mergingStreams ? [outPipe] : [outPipe, errorPipe]
        var code: Int32 = 0
        let texts = collect(from: pipes) {
            fflush(stdout)
            let savedOut = dup(STDOUT_FILENO), savedError = dup(STDERR_FILENO)
            dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            dup2(pipes.last!.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
            if mergingStreams { setvbuf(stdout, nil, lineBufferedOutput ? _IOLBF : _IOFBF, Int(BUFSIZ)) }
            code = body()
            fflush(stdout)
            fflush(stderr)
            dup2(savedOut, STDOUT_FILENO)
            dup2(savedError, STDERR_FILENO)
            Darwin.close(savedOut)
            Darwin.close(savedError)
            if mergingStreams { setvbuf(stdout, nil, isatty(STDOUT_FILENO) != 0 ? _IOLBF : _IOFBF, Int(BUFSIZ)) }
        }
        return Captured(value: code, output: texts[0], errorOutput: mergingStreams ? "" : texts[1])
    }
}
