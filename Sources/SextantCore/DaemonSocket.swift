import Darwin
import Foundation

/// Unix socket for the `sextant serve` daemon: a warm index serves CLI calls, removing the cold
/// start from every invocation. The protocol is line-delimited JSON, one line per message.
public enum DaemonSocket {
    /// The listening socket together with the lock file that proves ownership of it.
    /// The lock descriptor lives exactly as long as the socket: closing it releases the flock.
    public struct Listener {
        public let handle: Int32
        public let path: String
        let lock: Int32
    }

    /// Socket path for a project. The name is a hash of the path: `sun_path` is limited to about
    /// 104 bytes, and project roots get long (worktrees, nested packages).
    public static func path(forProject root: String) -> String {
        let resolved = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sextant/serve")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("\(ContentHash.of(resolved).prefix(16)).sock").path
    }

    public enum Failure: Error, Equatable {
        case pathTooLong
        case busy          // a live daemon is already listening on the socket
        case systemError(String)
    }

    /// The listening socket. Ownership is proven by an exclusive flock on an adjacent lock file:
    /// the probe "connect failed ⇒ the file is orphaned" is wrong when a live daemon is busy and
    /// its backlog is full — a second daemon would then steal the socket from the first.
    public static func listen(at path: String) throws -> Listener {
        let lockPath = path + ".lock"
        let lock = open(lockPath, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { throw Failure.systemError(errnoText()) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(lock)
            throw Failure.busy
        }
        try? FileManager.default.removeItem(atPath: path)

        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { _ = Darwin.close(lock); throw Failure.systemError(errnoText()) }
        guard var address = try? socketAddress(path) else {
            close(handle)
            _ = Darwin.close(lock)
            throw Failure.pathTooLong
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(handle, $0, size) }
        }
        guard bound == 0 else {
            close(handle)
            _ = Darwin.close(lock)
            throw Failure.systemError(errnoText())
        }
        guard Darwin.listen(handle, 16) == 0 else {
            close(handle)
            _ = Darwin.close(lock)
            throw Failure.systemError(errnoText())
        }
        // Owner only: the socket executes commands on the user's behalf.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return Listener(handle: handle, path: path, lock: lock)
    }

    /// Stops accepting and releases ownership of the socket.
    public static func stop(_ listener: Listener) {
        close(listener.handle)
        try? FileManager.default.removeItem(atPath: listener.path)
        _ = Darwin.close(listener.lock)   // releases the flock — the socket is free for a new daemon
    }

    /// Waits for a client. nil means the socket was closed or the call was interrupted.
    public static func accept(_ listener: Listener, readTimeout: TimeInterval = 15) -> Int32? {
        let client = Darwin.accept(listener.handle, nil, nil)
        guard client >= 0 else { return nil }
        // A silent client would otherwise block the sequential serving loop forever.
        var timeout = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return client
    }

    /// Connects to the daemon; nil means there is none (no socket, or nobody listening).
    /// `readTimeout` guards against waiting forever on a hung daemon: the client gives up and runs
    /// the command itself instead of hanging.
    public static func connect(to path: String, readTimeout: TimeInterval? = nil) -> Int32? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return nil }
        guard var address = try? socketAddress(path) else { close(handle); return nil }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(handle, $0, size) }
        }
        guard connected == 0 else { close(handle); return nil }
        if let readTimeout {
            var timeout = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
            setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        return handle
    }

    public static func close(_ handle: Int32) {
        _ = Darwin.close(handle)
    }

    /// Sends a string with a trailing newline; false means the connection was dropped.
    @discardableResult
    public static func send(_ text: String, to handle: Int32) -> Bool {
        let payload = Array((text + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let written = payload[offset...].withUnsafeBufferPointer { buffer in
                Darwin.write(handle, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    /// Buffered line reading from the socket: messages can be large (a repository map).
    public final class Reader {
        private let handle: Int32
        private var buffer: [UInt8] = []

        public init(_ handle: Int32) { self.handle = handle }

        public func line() -> String? {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                if let index = buffer.firstIndex(of: 0x0A) {
                    let line = Array(buffer[..<index])
                    buffer.removeSubrange(...index)
                    return String(decoding: line, as: UTF8.self)
                }
                let read = chunk.withUnsafeMutableBufferPointer { Darwin.read(handle, $0.baseAddress, $0.count) }
                guard read > 0 else {
                    guard !buffer.isEmpty else { return nil }
                    let line = String(decoding: buffer, as: UTF8.self)
                    buffer.removeAll()
                    return line
                }
                buffer.append(contentsOf: chunk[..<read])
            }
        }
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
                destination[bytes.count] = 0
            }
        }
        return address
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}

/// Daemon request and response.
public struct DaemonRequest: Codable, Sendable {
    public let arguments: [String]
    /// Project root, ALREADY resolved by the client. Without it the daemon would resolve
    /// `--project .` and relative paths in ITS OWN working directory, quietly answering about a
    public let projectRoot: String

    public init(arguments: [String], projectRoot: String) {
        self.arguments = arguments
        self.projectRoot = projectRoot
    }
}

public struct DaemonResponse: Codable, Sendable {
    public let exitCode: Int32
    public let output: String
    public let errorOutput: String

    public init(exitCode: Int32, output: String, errorOutput: String) {
        self.exitCode = exitCode
        self.output = output
        self.errorOutput = errorOutput
    }
}

/// Commands the daemon will NOT serve: a build executes foreign code, setup writes into the
/// project, and server modes make no sense over a socket. The client runs these itself.
public enum DaemonPolicy {
    public static let refusedCommands: Set<String> = ["index", "serve", "mcp", "init", "doctor", "golden", "bench"]

    public static func servesCommand(_ name: String) -> Bool {
        !refusedCommands.contains(name) && CommandCatalog.command(named: name) != nil
    }

    /// `--reindex` triggers the same build as the forbidden `index`, so it must not go through the
    /// daemon: it runs with the owner's environment and would build an arbitrary project on request.
    public static func servesRequest(_ arguments: [String]) -> Bool {
        guard let name = arguments.first, servesCommand(name) else { return false }
        return !arguments.contains("--reindex")
    }
}
