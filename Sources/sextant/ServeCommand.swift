import SextantCore
import Darwin
import Foundation

// MARK: - serve (daemon with a warm index)

func runServe(arguments: [String]) -> Int32 {
    // A client dropping the connection (Ctrl-C on a command) would otherwise kill the daemon
    // with SIGPIPE.
    signal(SIGPIPE, SIG_IGN)
    let project = URL(fileURLWithPath: projectRoot(in: arguments), isDirectory: true)
        .standardizedFileURL.path
    let socketPath = DaemonSocket.path(forProject: project)

    let listener: DaemonSocket.Listener
    do {
        listener = try DaemonSocket.listen(at: socketPath)
    } catch DaemonSocket.Failure.busy {
        reportError("sextant serve: a daemon already listens on \(socketPath) — a second one is not needed.")
        return 1
    } catch {
        reportError("sextant serve: could not open the socket \(socketPath): \(error)")
        return 1
    }
    defer { DaemonSocket.stop(listener) }

    // The index is opened once — that is the entire reason the daemon exists.
    let warm = openIndex(arguments, label: "serve") != nil
    reportError("sextant serve: listening on \(socketPath) · project \(project) · index \(warm ? "warm" : "unavailable (build it later with `sextant index`)")")
    reportError("Stop with Ctrl-C; clients use the daemon automatically (SEXTANT_NO_DAEMON=1 disables it).")

    while let client = DaemonSocket.accept(listener) {
        defer { DaemonSocket.close(client) }
        guard let line = DaemonSocket.Reader(client).line(),
              let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(DaemonRequest.self, from: data) else { continue }

        let name = request.arguments.first ?? ""
        let response: DaemonResponse
        if request.projectRoot != project {
            // The socket is named after the project root, but a request can also arrive
            // directly. Answering about someone else's project is exactly the kind of quiet
            // wrongness a grep replacement must never produce.
            response = DaemonResponse(exitCode: 2, output: "",
                                      errorOutput: "sextant serve: request is about a different project (\(request.projectRoot)) — this daemon serves \(project).\n")
        } else if DaemonPolicy.servesRequest(request.arguments) {
            let captured = OutputCapture.capture { dispatch(request.arguments) }
            response = DaemonResponse(exitCode: captured.value, output: captured.output, errorOutput: captured.errorOutput)
        } else {
            // The daemon never builds or sets up: those run foreign code and write into the project.
            response = DaemonResponse(exitCode: 2, output: "", errorOutput: "sextant serve: '\(name)' runs only directly (it builds or configures).\n")
        }
        if let encoded = try? JSONEncoder().encode(response) {
            DaemonSocket.send(String(decoding: encoded, as: UTF8.self), to: client)
        }
    }
    return 0
}

// MARK: - Daemon client

/// Tries to run a command through the daemon. nil means there is no daemon, or the command is
/// not one it serves: the caller then runs it itself. Falling back is the normal path, not an error.
func runViaDaemon(_ arguments: [String]) -> Int32? {
    guard ProcessInfo.processInfo.environment["SEXTANT_NO_DAEMON"] == nil,
          let name = arguments.first, DaemonPolicy.servesRequest(arguments) else { return nil }

    let rest = Array(arguments.dropFirst())
    // The root is resolved ON THE CLIENT: the daemon has its own working directory, where
    // "--project ." would mean a different project. This also pins the output mode, since
    // inside the daemon stdout is always a pipe.
    let root = URL(fileURLWithPath: projectRoot(in: rest), isDirectory: true).standardizedFileURL.path
    var forwarded = arguments.filter { $0 != "--project" }
    if let index = arguments.firstIndex(of: "--project"), index + 1 < arguments.count {
        forwarded = arguments.enumerated().filter { $0.offset != index && $0.offset != index + 1 }.map { $0.element }
    }
    forwarded += ["--project", root]
    if let spec = CommandCatalog.command(named: name), spec.flags.contains(where: { $0.name == "--compact" }),
       !arguments.contains("--compact"), !arguments.contains("--full") {
        forwarded.append(isCompact(rest) ? "--compact" : "--full")
    }

    let socketPath = DaemonSocket.path(forProject: root)
    // The timeout is insurance: a hung daemon must not hang the CLI — the command runs locally.
    guard let handle = DaemonSocket.connect(to: socketPath, readTimeout: 120) else { return nil }
    defer { DaemonSocket.close(handle) }

    guard let request = try? JSONEncoder().encode(DaemonRequest(arguments: forwarded, projectRoot: root)),
          DaemonSocket.send(String(decoding: request, as: UTF8.self), to: handle),
          let line = DaemonSocket.Reader(handle).line(),
          let data = line.data(using: .utf8),
          let response = try? JSONDecoder().decode(DaemonResponse.self, from: data) else { return nil }

    if !response.output.isEmpty { FileHandle.standardOutput.write(Data(response.output.utf8)) }
    if !response.errorOutput.isEmpty { FileHandle.standardError.write(Data(response.errorOutput.utf8)) }
    return response.exitCode
}
