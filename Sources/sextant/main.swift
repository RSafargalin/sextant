import SextantCore
import Darwin
import Foundation

// MARK: - Environment helpers

func discoverIndexStoreLibrary() -> String? {
    guard let swiftc = Command.output("/usr/bin/xcrun", ["--find", "swiftc"]) else { return nil }
    let libraryPath = (swiftc as NSString)
        .deletingLastPathComponent
        .replacingOccurrences(of: "/bin", with: "/lib")
        + "/libIndexStore.dylib"
    return FileManager.default.fileExists(atPath: libraryPath) ? libraryPath : nil
}

func optionValue(_ flag: String, in arguments: [String]) -> String? {
    ArgumentParsing.value(of: flag, in: arguments)
}

/// Flags that consume the next token as their value (those values are not positional arguments).
let valueFlags: Set<String> = CommandCatalog.valueFlags

/// The first positional argument: neither an option nor an option's value.
func firstPositional(_ arguments: [String]) -> String? {
    ArgumentParsing.positionals(arguments, valueFlags: valueFlags).first
}

/// Project root: an explicit `--project`, then `CLAUDE_PROJECT_DIR` (Claude Code sets it for an
/// MCP server), then the current directory. The environment variable is more reliable than cwd
/// because it does not depend on where the process was started; clients that do not set it fall
/// back to cwd.
func projectRoot(in arguments: [String]) -> String {
    if let explicit = optionValue("--project", in: arguments) { return explicit }
    if let env = ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"], !env.isEmpty {
        return (env as NSString).standardizingPath   // strip a trailing slash, resolve ~ and ..
    }
    return FileManager.default.currentDirectoryPath
}

/// Exclusions for this run: the repeatable `--exclude` flags, or the config list when there are
/// none. The flags REPLACE rather than extend, the way the other options do — a command line that
/// meant to narrow the list must not silently inherit the project's.
func applyExclusions(_ arguments: [String]) {
    let fromFlags = ArgumentParsing.values(of: "--exclude", in: arguments)
    let fromConfig = loadConfig(arguments)?.exclude ?? []
    SwiftSources.setExclusions(fromFlags.isEmpty ? fromConfig : fromFlags)
}

/// Project config (.sextant.json) — the defaults sitting underneath the CLI flags.
func loadConfig(_ arguments: [String]) -> ProjectConfig? {
    configMemo.value(forRoot: projectRoot(in: arguments))
}

/// The config is read once per run (several helpers ask for it in a row), and a broken
/// `.sextant.json` is reported once: ignoring it silently used to hide the user's typos.
/// Thread-safe (NSLock) — Swift Testing runs tests concurrently.
private final class ConfigMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: ProjectConfig?] = [:]

    func value(forRoot root: String) -> ProjectConfig? {
        lock.withLock {
            if let cached = map[root] { return cached }
            let config: ProjectConfig?
            switch ProjectConfig.read(projectRoot: root) {
            case .missing:
                config = nil
            case .loaded(let value):
                config = value
            case .invalid(let reason):
                reportError("sextant: .sextant.json could not be parsed (\(reason)) — config defaults ignored.")
                config = nil
            }
            map[root] = config
            return config
        }
    }
}

private let configMemo = ConfigMemo()

/// Root with `--scope` (a project subdirectory) applied. Validates that the scope is inside the
/// project and exists; on violation it returns nil and reports why. This guards against a quietly
/// wrong result and against escaping the repository.
func scopedRoot(in arguments: [String]) -> String? {
    let root = projectRoot(in: arguments)
    let scope = optionValue("--scope", in: arguments) ?? loadConfig(arguments)?.scope
    switch ProjectScope.resolve(root: root, scope: scope) {
    case .resolved(let path):
        return path
    case .outsideProject:
        reportError("sextant: --scope '\(scope ?? "")' is outside the project.")
        return nil
    case .missingDirectory:
        reportError("sextant: --scope '\(scope ?? "")' — directory does not exist.")
        return nil
    }
}

/// Scale guard: returns false and reports when there are more Swift files than the limit
/// (`--max-files`, default 4000). It keeps map/api/search/lint from hanging on huge repositories.
func withinScale(_ root: String, includeTests: Bool, arguments: [String]) -> Bool {
    let maxFiles = optionValue("--max-files", in: arguments).flatMap(Int.init) ?? loadConfig(arguments)?.maxFiles ?? 4000
    let url = URL(fileURLWithPath: root, isDirectory: true)
    guard !SwiftSources.exceedsLimit(under: url, includeTests: includeTests, limit: maxFiles) else {
        reportError("sextant: more Swift files than the limit of \(maxFiles). Narrow the area with --scope <subdirectory>, or raise --max-files <N>.")
        return false
    }
    return true
}

func reportError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

/// A path as an answer shows it: relative to the project when it is inside it, and only then a
/// tail. The project root is read from the process arguments, which is where every command gets
/// it — a display helper must not disagree with the command about what the project is.
func shorten(_ path: String) -> String {
    DisplayPath.of(path, root: projectRoot(in: CommandLine.arguments))
}

/// Compact output: yes for an agent (piped), no for a human (TTY). `--full` and `--compact`
/// force it either way. A histogram by file without snippets instead of a full list saves tokens.
func isCompact(_ arguments: [String]) -> Bool {
    if arguments.contains("--full") { return false }
    if arguments.contains("--compact") { return true }
    return isatty(STDOUT_FILENO) == 0
}

/// Prints a value as pretty JSON (for `--json`).
func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) {
        print(json)
    } else {
        reportError("sextant: could not serialise JSON")
    }
}

struct SearchHit: Encodable {
    let file: String
    let line: Int
    let column: Int
    let text: String
}

/// Cached reading of source lines — used for snippets in refs/defs/callers.
final class SourceLineReader {
    private var cache: [String: [String]] = [:]

    func line(_ number: Int, inFile path: String) -> String? {
        let lines: [String]
        if let cached = cache[path] {
            lines = cached
        } else {
            let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            lines = content.components(separatedBy: "\n")
            cache[path] = lines
        }
        guard number >= 1, number <= lines.count else { return nil }
        let trimmed = lines[number - 1].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Entry point

/// Per-command help, and a refusal on an unknown flag. A typo that was silently ignored
/// (`--budjet`) quietly reverted behaviour to the default — the UX equivalent of a wrong answer.
/// Returns an exit code when the command should not run.
func precheck(_ name: String, _ arguments: [String]) -> Int32? {
    guard let spec = CommandCatalog.command(named: name) else { return nil }
    if arguments.contains("--help") || arguments.contains("-h") {
        print(CommandCatalog.help(for: spec))
        return 0
    }
    let unknown = CommandCatalog.unknownFlags(in: arguments, for: spec)
    guard unknown.isEmpty else {
        for flag in unknown {
            let suggestion = CommandCatalog.closestFlag(to: flag, in: spec).map { " Did you mean: \($0)?" } ?? ""
            reportError("sextant \(name): unknown flag '\(flag)'.\(suggestion)")
        }
        reportError("Help: sextant \(name) --help")
        return 2
    }
    return nil
}

func dispatch(_ arguments: [String]) -> Int32 {
    let rest = Array(arguments.dropFirst())
    if let name = arguments.first, let code = precheck(name, rest) { return code }
    // Exclusions are set once per command, before anything walks the tree.
    applyExclusions(rest)
    switch arguments.first {
    case "--version", "-v", "version": print(Sextant.version); return 0
    case "init": return runInit(arguments: rest)
    case "serve": return runServe(arguments: rest)
    case "map": return runMap(arguments: rest)
    case "api": return runAPI(arguments: rest)
    case "search": return runSearch(arguments: rest)
    case "lint": return runLint(arguments: rest)
    case "refs": return runSemantic(.references, arguments: rest)
    case "defs": return runSemantic(.definitions, arguments: rest)
    case "callers": return runSemantic(.callers, arguments: rest)
    case "callees": return runRelated(.callees, label: "callees", arguments: rest)
    case "impls": return runRelated(.implementations, label: "impls", arguments: rest)
    case "supertypes": return runRelated(.supertypes, label: "supertypes", arguments: rest)
    case "hierarchy": return runHierarchy(arguments: rest)
    case "context": return runContext(arguments: rest)
    case "blast": return runBlast(arguments: rest)
    case "body": return runBody(arguments: rest)
    case "construct": return runConstruct(arguments: rest)
    case "changed": return runChanged(arguments: rest)
    case "mcp": return runMCP(arguments: rest)
    case "doctor": return runDoctor(arguments: rest)
    case "golden": return runGolden(arguments: rest)
    case "bench": return runBench(arguments: rest)
    case "adoption": return runAdoption(arguments: rest)
    case "hook": return runHook(arguments: rest)
    case "completion": return runCompletion(arguments: rest)
    case "index": return runIndex(arguments: rest)
    case "--help", "-h", "help", nil: printUsage(); return 0
    case let command?:
        reportError("sextant: unknown command '\(command)'")
        printUsage()
        return 2
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

/// A project root that does not exist is a typo, and it used to be answered rather than refused:
/// `lint --project /no/such/dir` reported "✅ No violations found" with exit 0 — a clean bill of
/// health for a directory nobody looked at. `--scope` has always refused the same mistake, so the
/// two halves of the same question now behave the same way.
if let root = optionValue("--project", in: arguments) {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory)
    if !exists || !isDirectory.boolValue {
        reportError("sextant: --project '\(root)' — \(exists ? "not a directory" : "directory does not exist").")
        exit(2)
    }
}

let started = DispatchTime.now()
// Use the warm-index daemon if one is running; otherwise the normal path — no daemon is not an error.
let code = runViaDaemon(arguments) ?? dispatch(arguments)
Telemetry.record(
    command: arguments.first ?? "",
    argument: firstPositional(Array(arguments.dropFirst())),
    exitCode: code,
    durationMs: Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000,
    timestamp: Date().timeIntervalSince1970
)
exit(code)
