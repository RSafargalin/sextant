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
    public static func collect(from pipes: [Pipe], while body: () -> Void) -> [String] {
        let boxes = pipes.map { _ in Box() }
        let readers = DispatchGroup()
        for (pipe, box) in zip(pipes, boxes) {
            DispatchQueue.global().async(group: readers) {
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { return }   // an empty chunk means EOF
                    box.append(chunk)
                }
            }
        }
        body()
        for pipe in pipes { try? pipe.fileHandleForWriting.close() }
        readers.wait()
        return boxes.map(\.text)
    }

    /// Runs `body` with stdout and stderr captured, returning its code and its output.
    ///
    /// Swapping descriptors is process-global: the caller must guarantee there are no concurrent
    /// invocations (the daemon serves requests sequentially).
    public static func capture(_ body: () -> Int32) -> Captured {
        let outPipe = Pipe(), errorPipe = Pipe()
        var code: Int32 = 0
        let texts = collect(from: [outPipe, errorPipe]) {
            let savedOut = dup(STDOUT_FILENO), savedError = dup(STDERR_FILENO)
            dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            dup2(errorPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
            code = body()
            fflush(stdout)
            fflush(stderr)
            dup2(savedOut, STDOUT_FILENO)
            dup2(savedError, STDERR_FILENO)
            Darwin.close(savedOut)
            Darwin.close(savedError)
        }
        return Captured(value: code, output: texts[0], errorOutput: texts[1])
    }
}
