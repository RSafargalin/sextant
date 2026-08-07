import Foundation

/// The flags one C-family file was actually compiled with. The field names follow the standard
/// `compile_commands.json` shape, so the stored file is also readable by clangd and by libclang.
public struct CompileCommand: Codable, Equatable, Sendable {
    public let directory: String
    public let file: String
    public let arguments: [String]

    public init(directory: String, file: String, arguments: [String]) {
        self.directory = directory
        self.file = file
        self.arguments = arguments
    }
}

/// Where the compile flags for Objective-C, C and C++ come from.
///
/// They are read from the build graph, not scraped from build output. SwiftPM writes the whole
/// graph to `.build/<configuration>.yaml`, where every clang node carries its arguments as a JSON
/// array. That avoids shell quoting entirely, and it avoids the incremental hole: a rebuild that
/// compiles nothing prints nothing, while the manifest still describes every file.
///
/// Approximate flags are not an option — with them clang builds an AST for a quarter of the files
/// and fails outright on the rest, which is worse than refusing. A file absent from the database
/// is reported as such rather than parsed with a guess.
public enum CompilationDatabase {
    /// Source extensions a clang node may compile. Headers never appear as a compilation unit.
    static let compilableExtensions: Set<String> = ["m", "mm", "c", "cc", "cpp", "cxx"]

    // MARK: - Reading the build graph

    /// Compile commands from an llbuild manifest (`.build/debug.yaml`).
    ///
    /// The manifest is a build artefact rather than a published contract, so every shape that does
    /// not parse is skipped instead of guessed at, and the caller learns the count.
    public static func commands(inManifest text: String, directory: String) -> [CompileCommand] {
        var results: [CompileCommand] = []
        var tool: String?
        var inputs: [String] = []
        var arguments: [String] = []

        func flush() {
            defer { tool = nil; inputs = []; arguments = [] }
            guard tool == "clang", !arguments.isEmpty,
                  let file = inputs.first(where: { compilableExtensions.contains(($0 as NSString).pathExtension) })
            else { return }
            results.append(CompileCommand(directory: directory, file: file, arguments: arguments))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A node starts at the target it produces — a quoted name followed by a colon.
            // Recognised by shape rather than by indentation, which is not a contract either.
            if trimmed.hasPrefix("\""), trimmed.hasSuffix("\":") {
                flush()
                continue
            }
            if let value = trimmed.dropPrefix("tool: ") { tool = String(value) }
            if let value = trimmed.dropPrefix("inputs: ") { inputs = jsonStrings(String(value)) ?? [] }
            if let value = trimmed.dropPrefix("args: ") { arguments = jsonStrings(String(value)) ?? [] }
        }
        flush()
        return results
    }

    /// Build manifests belonging to an index store: `<root>/.build/<triple>/<configuration>/index/store`
    /// is written by the build whose manifest is `<root>/.build/<configuration>.yaml`.
    /// An empty result means the store has no manifest beside it (a DerivedData store, for
    /// instance) — the Xcode build describes itself elsewhere.
    public static func manifestPaths(forStore store: String) -> [String] {
        let suffix = "/index/store"
        guard store.hasSuffix(suffix) else { return [] }
        let configurationDirectory = String(store.dropLast(suffix.count)) as NSString   // …/.build/<triple>/<configuration>
        let configuration = configurationDirectory.lastPathComponent
        let buildDirectory = (configurationDirectory.deletingLastPathComponent as NSString).deletingLastPathComponent
        guard (buildDirectory as NSString).lastPathComponent == ".build", !configuration.isEmpty else { return [] }
        return ["\(buildDirectory)/\(configuration).yaml"]
    }

    /// Compile commands for a project, read from the manifests of the given index stores.
    /// Stores are passed in resolution order, and the first command for a file wins — the same
    /// order the semantic layer uses, so both answer from the same build.
    public static func capture(fromStores stores: [String]) -> [CompileCommand] {
        var byFile: [String: CompileCommand] = [:]
        var order: [String] = []
        for store in stores {
            for manifest in manifestPaths(forStore: store) {
                guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else { continue }
                // The package directory holds `.build`, which holds the manifest.
                let directory = ((manifest as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                for command in commands(inManifest: text, directory: directory) where byFile[command.file] == nil {
                    byFile[command.file] = command
                    order.append(command.file)
                }
            }
        }
        return order.compactMap { byFile[$0] }
    }

    // MARK: - Reading an Xcode build log

    /// Compile commands from the output of `xcodebuild`.
    ///
    /// Xcode has no equivalent of SwiftPM's build graph: its own manifest lists compile nodes
    /// without their arguments. What it does print, per file, is the block
    ///
    ///     CompileC <output.o> <source.m> normal <arch> <language> <compiler>
    ///         cd <directory>
    ///         <the full clang invocation>
    ///
    /// escaped for a shell and with most flags behind an `@response-file`. That is the only place
    /// the real flags appear, so this reads them there rather than reconstructing a command line
    /// from build settings — a reconstruction would be a guess, and a guess is what this whole
    /// layer refuses to parse with.
    ///
    /// The format is Xcode's, not a contract. Anything that does not parse is skipped rather than
    /// half-read, and the caller sees the count it did get.
    public static func commands(inXcodeLog log: String) -> [CompileCommand] {
        var results: [CompileCommand] = []
        var pending: (file: String, directory: String)?

        func flush(with invocation: String) {
            guard let pending else { return }
            let arguments = ShellWords.expandingResponseFiles(ShellWords.split(invocation))
            guard arguments.count > 1 else { return }
            results.append(CompileCommand(directory: pending.directory, file: pending.file, arguments: arguments))
        }

        for rawLine in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("CompileC ") {
                let words = ShellWords.split(String(line.dropFirst("CompileC ".count)))
                // <output> <source>: the source is what the command is about.
                if words.count >= 2, compilableExtensions.contains((words[1] as NSString).pathExtension) {
                    pending = (file: words[1], directory: (words[1] as NSString).deletingLastPathComponent)
                } else {
                    pending = nil
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if pending != nil, trimmed.hasPrefix("cd ") {
                let directory = ShellWords.split(String(trimmed.dropFirst(3))).first
                if let directory, let file = pending?.file { pending = (file: file, directory: directory) }
                continue
            }
            // The invocation itself: an absolute path to a compiler, with arguments after it.
            if pending != nil, trimmed.hasPrefix("/"), trimmed.contains(" "),
               let executable = ShellWords.split(trimmed).first,
               (executable as NSString).lastPathComponent.hasPrefix("clang") {
                flush(with: trimmed)
                pending = nil
            }
        }
        return results
    }

    // MARK: - Storage

    /// The database for a project, kept in the cache directory rather than in the project.
    ///
    /// The key is the canonical path, not the spelling: `sextant index --project ./pkg` and a
    /// later query with an absolute path are the same project, and keying on the raw string made
    /// the second one report every file as having no flags.
    public static func path(forRoot root: String) -> URL {
        let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let sanitized = canonical.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sextant/compile-db/\(sanitized).json")
    }

    public static func save(_ commands: [CompileCommand], forRoot root: String) throws {
        let url = path(forRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(commands).write(to: url, options: .atomic)
    }

    public static func load(forRoot root: String) -> [CompileCommand] {
        guard let data = try? Data(contentsOf: path(forRoot: root)),
              let commands = try? JSONDecoder().decode([CompileCommand].self, from: data) else { return [] }
        return commands
    }

    /// Merges a fresh capture into what is already known.
    ///
    /// One build covers one scheme and one destination, so a project built in parts would keep
    /// losing the flags of everything outside the last build. Entries for files that no longer
    /// exist are dropped, so the database does not accumulate deleted ones.
    public static func merge(existing: [CompileCommand], fresh: [CompileCommand]) -> [CompileCommand] {
        var byFile: [String: CompileCommand] = [:]
        for command in existing where FileManager.default.fileExists(atPath: command.file) {
            byFile[command.file] = command
        }
        for command in fresh { byFile[command.file] = command }
        return byFile.values.sorted { $0.file < $1.file }
    }

    // MARK: - Coverage

    /// Compilable C-family sources under a root. Headers are excluded: a header is not a
    /// compilation unit and never has a command of its own.
    public static func compilableSources(projectRoot: String, includeTests: Bool) -> [String] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        return SwiftSources.files(under: root, includeTests: includeTests, extensions: Array(compilableExtensions))
            .map { $0.resolvingSymlinksInPath().path }
            .sorted()
    }

    /// Sources with no command in the database — the files a structural query must refuse for
    /// rather than answer with guessed flags. Paths are compared symlink-resolved: the build
    /// records the path the compiler saw, which need not be spelled the way the walk spells it.
    public static func missingSources(_ commands: [CompileCommand], among sources: [String]) -> [String] {
        let known = Set(commands.map { URL(fileURLWithPath: $0.file).resolvingSymlinksInPath().path })
        return sources.filter { !known.contains($0) }
    }

    // MARK: - Using an entry

    /// Parse arguments for a file: the compiler path, the output and the dependency bookkeeping
    /// removed, and the source itself dropped — libclang is given the file separately.
    public static func parseArguments(of command: CompileCommand) -> [String] {
        var result: [String] = []
        var index = command.arguments.startIndex
        // The first argument is the compiler executable, not a flag.
        if index < command.arguments.endIndex { index += 1 }
        let flagsWithPathValue: Set<String> = ["-o", "-MF", "-MT", "-MQ", "-index-store-path", "-serialize-diagnostics"]
        while index < command.arguments.endIndex {
            let argument = command.arguments[index]
            if flagsWithPathValue.contains(argument) { index += 2; continue }
            if argument == "-c" || argument == "-MD" || argument == "-MMD" { index += 1; continue }
            if argument == command.file { index += 1; continue }
            result.append(argument)
            index += 1
        }
        return result
    }

    /// The target triple a file was compiled for. It decides which `#if` branches are active, so
    /// it is what an answer about that file is an answer *about*.
    public static func target(of command: CompileCommand) -> String? {
        guard let index = command.arguments.firstIndex(of: "-target"),
              index + 1 < command.arguments.endIndex else { return nil }
        return command.arguments[index + 1]
    }

    // MARK: - Helpers

    /// A JSON array of strings; nil when the line is not one (an unexpected manifest shape).
    private static func jsonStrings(_ text: String) -> [String]? {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let strings = array.compactMap { $0 as? String }
        return strings.count == array.count ? strings : nil
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
