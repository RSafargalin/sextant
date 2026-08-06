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

    // MARK: - Storage

    /// The database for a project, kept in the cache directory rather than in the project.
    public static func path(forRoot root: String) -> URL {
        let sanitized = root.replacingOccurrences(of: "/", with: "_")
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
