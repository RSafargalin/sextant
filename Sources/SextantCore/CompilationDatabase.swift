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
/// They are read from the build graph wherever one exists. SwiftPM's native build system writes
/// the whole graph to `.build/<configuration>.yaml`, where every clang node carries its arguments
/// as a JSON array. That avoids shell quoting entirely, and it avoids the incremental hole: a
/// rebuild that compiles nothing prints nothing, while the manifest still describes every file.
///
/// SwiftPM's Swift Build system and Xcode write no such graph. There the flags are read from the
/// build's own output, which states them only for the files it compiled.
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

    /// Build manifests belonging to an index store: `<build>/<triple>/<configuration>/index/store`
    /// is written by the build whose manifest is `<build>/<configuration>.yaml`, where `<build>` is
    /// a package's `.build` or the build tree `sextant index` keeps inside it.
    /// An empty result means the store has no manifest beside it (a DerivedData store, for
    /// instance) — the Xcode build describes itself elsewhere.
    public static func manifestPaths(forStore store: String) -> [String] {
        let suffix = "/index/store"
        guard store.hasSuffix(suffix) else { return [] }
        let configurationDirectory = String(store.dropLast(suffix.count)) as NSString   // …/<build>/<triple>/<configuration>
        let configuration = configurationDirectory.lastPathComponent
        let buildDirectory = (configurationDirectory.deletingLastPathComponent as NSString).deletingLastPathComponent
        guard !configuration.isEmpty, packageDirectory(ofBuildDirectory: buildDirectory) != nil else { return [] }
        return ["\(buildDirectory)/\(configuration).yaml"]
    }

    /// The package a build directory belongs to: the parent of `.build`, whether the build
    /// directory is `.build` itself or the build tree of `sextant index` inside it.
    static func packageDirectory(ofBuildDirectory buildDirectory: String) -> String? {
        let build = buildDirectory as NSString
        if build.lastPathComponent == ".build" { return build.deletingLastPathComponent }
        let parent = build.deletingLastPathComponent as NSString
        guard build.lastPathComponent == IndexStoreLocator.indexBuildDirectoryName,
              parent.lastPathComponent == ".build" else { return nil }
        return parent.deletingLastPathComponent
    }

    /// Compile commands for a project, read from the manifests of the given index stores.
    /// Stores are passed in resolution order, and the first command for a file wins — the same
    /// order the semantic layer uses, so both answer from the same build.
    public static func capture(fromStores stores: [String]) -> [CompileCommand] {
        var byFile: [String: CompileCommand] = [:]
        var order: [String] = []
        for store in stores {
            for manifest in manifestPaths(forStore: store) {
                guard let text = try? String(contentsOfFile: manifest, encoding: .utf8),
                      let directory = packageDirectory(ofBuildDirectory: (manifest as NSString).deletingLastPathComponent)
                else { continue }
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

    // MARK: - Reading a verbose SwiftPM build log

    /// Compile commands from the output of `swift build -v`.
    ///
    /// SwiftPM's Swift Build system writes no graph with arguments in it: its manifest names the
    /// compile nodes and a response file holding part of their flags, and the whole invocation is
    /// stated only in verbose output, as
    ///
    ///     Compile <source> (<arch>)
    ///         cd <directory>
    ///         <the full clang invocation>
    ///
    /// The header carries a bare file name, so the source is taken from the invocation itself —
    /// the argument `-c` introduces. A dependency scan repeats the same flags behind a `builtin-`
    /// prefix and a link step runs clang with no `-c`; neither is a compile and neither is read.
    ///
    /// A build that compiles nothing prints no invocation, so an incremental run yields an empty
    /// result — the caller keeps what an earlier capture found and says so when there is none.
    public static func commands(inBuildLog log: String) -> [CompileCommand] {
        var byFile: [String: CompileCommand] = [:]
        var order: [String] = []
        var directory: String?

        for rawLine in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // A task block ends at an empty line or at the next unindented header; the directory
            // belongs to its own block only.
            if !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t"), !trimmed.isEmpty { directory = nil }
            if trimmed.hasPrefix("cd ") {
                directory = ShellWords.split(String(trimmed.dropFirst(3))).first
                continue
            }
            guard trimmed.hasPrefix("/"), trimmed.contains(" -c ") else { continue }
            let words = ShellWords.split(trimmed)
            guard let executable = words.first, (executable as NSString).lastPathComponent.hasPrefix("clang"),
                  let flag = words.firstIndex(of: "-c"), flag + 1 < words.endIndex else { continue }
            let file = words[flag + 1]
            guard compilableExtensions.contains((file as NSString).pathExtension) else { continue }
            let arguments = ShellWords.expandingResponseFiles(words)
            if byFile[file] == nil { order.append(file) }
            byFile[file] = CompileCommand(directory: directory ?? (file as NSString).deletingLastPathComponent,
                                          file: file, arguments: arguments)
        }
        return order.compactMap { byFile[$0] }
    }

    // MARK: - Storage

    /// The database for a project, kept in the cache directory rather than in the project.
    ///
    /// The key is the canonical path, not the spelling: `sextant index --project ./pkg` and a
    /// later query with an absolute path are the same project, and keying on the raw string made
    /// the second one report every file as having no flags. The file keeps the
    /// `compile_commands.json` name and shape; the entry beside it records the root.
    public static func path(forRoot root: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        entry(forRoot: root, home: home).appendingPathComponent(fileName)
    }

    /// The cache entry of a project's database: a directory named by `CanonicalPath.entryName`,
    /// holding the database and the record of the root it was stored for.
    public static func entry(forRoot root: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(home: home).appendingPathComponent(CanonicalPath.entryName(of: root), isDirectory: true)
    }

    static let fileName = "compile_commands.json"

    private static var directory: URL { directory(home: FileManager.default.homeDirectoryForCurrentUser) }

    private static func directory(home: URL) -> URL {
        CacheEviction.root(home: home).appendingPathComponent("compile-db", isDirectory: true)
    }

    /// The flags of the files under `root`, wherever they were stored.
    ///
    /// Flags are stored under the root `sextant index` was run for, and a file's flags are the same
    /// whichever root a later command is asked about — so they are read from the database of
    /// `root` itself, of every root that contains it, and of every root inside it (a nested
    /// package indexed on its own), and only the entries for files under `root` are kept. Where
    /// two databases describe one file, the one stored for `root` itself wins, then the one of the
    /// nearest root.
    ///
    /// An entry for a file that no longer exists is left out unless `includingMissing`: a deleted
    /// file's flags are still how its last revision was compiled, which is what `changed` parses
    /// that revision with.
    public static func commands(forFilesUnder root: String, includingMissing: Bool = false) -> [CompileCommand] {
        databases(forFilesUnder: root, includingMissing: includingMissing).flatMap(\.commands)
    }

    /// The databases `commands(forFilesUnder:)` reads its answer from, each with the entries it
    /// contributes; a database that contributes nothing is absent.
    static func databases(forFilesUnder root: String,
                          includingMissing: Bool = false) -> [(url: URL, commands: [CompileCommand])] {
        let own = CanonicalPath.of(root)
        // The roots are read from the entries' records — a hash names an entry, and only the
        // record leads back to the root. An entry without a record is never read.
        let roots = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter(CanonicalPath.isEntryName)
            .compactMap { name -> (root: String, url: URL)? in
                let entry = directory.appendingPathComponent(name, isDirectory: true)
                guard let data = FileManager.default.contents(atPath: entry.appendingPathComponent(CacheEviction.ownerFileName).path),
                      let recorded = String(data: data, encoding: .utf8), recorded.hasPrefix("/") else { return nil }
                return (recorded, entry.appendingPathComponent(fileName))
            }
            .filter { $0.root == own || $0.root.hasPrefix(own + "/") || own.hasPrefix($0.root + "/") }
            // The root itself first, then nearer roots before farther ones.
            .sorted { ($0.root == own ? 0 : 1, abs($0.root.count - own.count), $0.root)
                    < ($1.root == own ? 0 : 1, abs($1.root.count - own.count), $1.root) }
        let prefix = own + "/"
        var seen: Set<String> = []
        var result: [(url: URL, commands: [CompileCommand])] = []
        for (_, url) in roots {
            guard let data = try? Data(contentsOf: url),
                  let commands = try? JSONDecoder().decode([CompileCommand].self, from: data) else { continue }
            var contributed: [CompileCommand] = []
            for command in commands where includingMissing || FileManager.default.fileExists(atPath: command.file) {
                let file = resolvedPath(command.file)
                guard file.hasPrefix(prefix), seen.insert(file).inserted else { continue }
                contributed.append(command)
            }
            if !contributed.isEmpty { result.append((url, contributed)) }
        }
        return result
    }

    /// A source's path as the database keys it (`CanonicalPath.ofFile`), so a deleted file is
    /// spelled the way it was while it existed.
    public static func resolvedPath(_ path: String) -> String {
        CanonicalPath.ofFile(path)
    }

    public static func save(_ commands: [CompileCommand], forRoot root: String,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = path(forRoot: root, home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        CacheEviction.recordOwner(CanonicalPath.of(root), in: url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(commands).write(to: url, options: .atomic)
    }

    public static func load(forRoot root: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CompileCommand] {
        load(from: path(forRoot: root, home: home))
    }

    private static func load(from url: URL) -> [CompileCommand] {
        guard let data = try? Data(contentsOf: url),
              let commands = try? JSONDecoder().decode([CompileCommand].self, from: data) else { return [] }
        // Entries for files that are gone are dropped on the way in, not only when a new capture
        // merges over them: a database is pruned when it is next built, and a project that is not
        // rebuilt keeps them for as long as it is not. Measured on this machine: two databases
        // held 75 of 75 and 72 of 73 entries for files deleted weeks earlier.
        return commands.filter { FileManager.default.fileExists(atPath: $0.file) }
    }

    /// The file a project's flags were kept in before entries were named by a hash: the canonical
    /// root with every `/` turned into `_`, plus `.json`, directly in `compile-db`.
    static func legacyPath(forRoot root: String, home: URL) -> URL {
        directory(home: home).appendingPathComponent(legacyFileName(ofCanonicalRoot: CanonicalPath.of(root)))
    }

    /// The name of the file of the earlier naming for a root already in canonical form.
    static func legacyFileName(ofCanonicalRoot root: String) -> String {
        root.replacingOccurrences(of: "/", with: "_") + ".json"
    }

    /// How many commands the file of the earlier naming holds for `root` while the project's own
    /// entry has none — what the next `sextant index` carries over; nil when there is nothing to carry.
    public static func legacyCommandCount(forRoot root: String,
                                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int? {
        guard load(forRoot: root, home: home).isEmpty else { return nil }
        let count = load(from: legacyPath(forRoot: root, home: home)).count
        return count > 0 ? count : nil
    }

    /// Carries the flags of the earlier naming into the project's entry, once: when the entry has
    /// no flags and the file of the earlier naming for exactly this root exists. Entries for files
    /// that are gone are left behind, as `load` leaves them. The entry keeps the old file's write
    /// time, which is when those flags were captured. Returns how many commands were carried over,
    /// or nil when nothing was. The old file is left for `CacheEviction` to remove.
    public static func migrateLegacyEntry(forRoot root: String,
                                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int? {
        guard load(forRoot: root, home: home).isEmpty else { return nil }
        let legacy = legacyPath(forRoot: root, home: home)
        let commands = load(from: legacy)
        guard !commands.isEmpty,
              let captured = (try? legacy.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              (try? save(commands, forRoot: root, home: home)) != nil else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: captured], ofItemAtPath: path(forRoot: root, home: home).path)
        return commands.count
    }

    /// When the flags were captured — the file's own write time, so the stored JSON keeps the
    /// `compile_commands.json` shape that clangd and libclang can read.
    public static func capturedAt(forRoot root: String) -> Date? {
        (try? path(forRoot: root).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// What to say when the flags are older than the build they claim to describe.
    ///
    /// Flags are captured by `sextant index`; a build made any other way — Xcode, `swift build`,
    /// CI — moves the index forward and leaves them behind. Nothing in a structural answer shows
    /// it, and the answer is not merely incomplete: a `-DFEATURE=1` that has since become `0`
    /// yields a structural match inside code the current build does not contain. That is the
    /// highest level of confidence this tool offers, standing on a stale fact.
    ///
    /// The flags judged are the ones the answer reads — from the root's own database, and from the
    /// databases of the roots around it and inside it — and they are as old as the oldest of those.
    ///
    /// A database is as recent as its capture or as the last successful `sextant index` that
    /// confirmed it (`confirm(forRoot:)`), whichever is later: a build that recompiled none of the
    /// C-family files left their flags as they were, and only a build made some other way leaves
    /// them behind unconfirmed.
    public static func stalenessNote(forRoot root: String, storePaths: [String]) -> [String] {
        let captures = databases(forFilesUnder: root).compactMap { database -> (date: Date, confirmed: Bool)? in
            let captured = modificationDate(database.url)
            let confirmed = modificationDate(database.url.deletingLastPathComponent().appendingPathComponent(confirmationFileName))
            switch (captured, confirmed) {
            case (let captured?, let confirmed?) where confirmed > captured: return (confirmed, true)
            case (let captured?, _): return (captured, false)
            default: return nil
            }
        }
        guard let oldest = captures.min(by: { $0.date < $1.date }) else { return [] }
        let captured = oldest.date
        guard let built = IndexFreshness.timestamp(ofStores: storePaths), built > captured else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let gap = built.timeIntervalSince(captured)
        let later = gap < 90 ? "\(Int(gap.rounded()))s later"
            : gap < 5400 ? "\(Int((gap / 60).rounded())) minutes later"
            : "\(Int((gap / 3600).rounded())) hours later"
        return ["⚠ compile flags \(oldest.confirmed ? "last confirmed by `sextant index`" : "captured") "
                + "\(formatter.string(from: captured)); the project was built "
                + "\(later) (\(formatter.string(from: built))) — the C-family answers below stand on the "
                + "older flags. A macro that changed in between makes them describe code this build does "
                + "not contain. Refresh with `sextant index`."]
    }

    /// The file in a database's entry whose write time is when a successful `sextant index` last
    /// found the database current.
    static let confirmationFileName = "confirmed"

    /// Records that the project's flags are current for the build `sextant index` just completed:
    /// it succeeded and recompiled none of the files they describe, so none of their flags changed.
    public static func confirm(forRoot root: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let location = entry(forRoot: root, home: home)
        guard FileManager.default.fileExists(atPath: location.appendingPathComponent(fileName).path) else { return }
        try? Data().write(to: location.appendingPathComponent(confirmationFileName), options: .atomic)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
    /// The walk is the one over every C-family extension, shared (and memoised) with the header
    /// list, so a command that needs both walks the tree once. `fileLimit` is the `--max-files`
    /// bound, shared with the Swift files (`SwiftSources.files(limit:)`).
    public static func compilableSources(projectRoot: String, includeTests: Bool, fileLimit: Int? = nil) -> [String] {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        return SwiftSources.files(under: root, includeTests: includeTests, extensions: IndexDeclarations.clangExtensions,
                                  limit: fileLimit)
            .filter { compilableExtensions.contains($0.pathExtension) }
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
        let flagsWithPathValue: Set<String> = ["-o", "-MF", "-MT", "-MQ", "-index-store-path", "-index-unit-output-path",
                                                "-serialize-diagnostics", "--serialize-diagnostics"]
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
