import Foundation

/// Walks a project's Swift sources with a shared set of exclusion rules.
public enum SwiftSources {
    static let skippedDirectories: Set<String> = [
        ".build", ".git", ".swiftpm", "DerivedData", ".index-store",
        "Pods", "Carthage", "node_modules", "checkouts", "build", "Build", "vendor"
    ]

    /// Directories to skip: the usual vendored ones plus simple directory patterns from the root
    /// `.gitignore`. A pragmatic subset: directory names without `/` or `*`; paths and globs are ignored.
    static func ignoredDirectoryNames(under root: URL) -> Set<String> {
        var names = skippedDirectories
        guard let content = try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8) else {
            return names
        }
        for rawLine in content.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            if line.hasPrefix("/") { line.removeFirst() }
            if line.hasSuffix("/") { line.removeLast() }
            guard !line.isEmpty, !line.contains("/"), !line.contains("*") else { continue }
            names.insert(line)
        }
        return names
    }

    /// Skip a directory and everything in it: hidden (a `.` prefix) or explicitly excluded.
    static func shouldSkip(directory name: String, ignored: Set<String>) -> Bool {
        name.hasPrefix(".") || ignored.contains(name)
    }

    /// The `.swift` list via git (tracked plus untracked-not-ignored — full gitignore, C speed).
    /// nil means the directory is not under git (falls back to FileManager). Works in a git worktree.
    /// Extra safety: `.build/` and `checkouts/` are dropped in case vendored code is not ignored.
    static func gitSwiftFiles(under root: URL, includeTests: Bool, extensions: [String] = ["swift"]) -> [URL]? {
        let suffixes = extensions.map { ".\($0)" }
        let pathspecs = extensions.map { "*.\($0)" }
        guard let output = runGit(["-C", root.path, "ls-files", "-z",
                                   "--cached", "--others", "--exclude-standard", "--"] + pathspecs) else { return nil }
        var result: [URL] = []
        for piece in output.split(separator: "\0") {
            let name = String(piece)
            guard suffixes.contains(where: name.hasSuffix) else { continue }
            let components = name.split(separator: "/").map(String.init)
            guard let last = components.last, !last.hasPrefix(".") else { continue }
            // The same filtering as in FileManager mode (shouldSkip): dot directories
            // (.claude, .build, …) and vendored code. We do not rely on the project ignoring them.
            if components.dropLast().contains(where: { $0.hasPrefix(".") || skippedDirectories.contains($0) }) { continue }
            if !includeTests, last.hasSuffix("Tests.swift") { continue }
            result.append(root.appendingPathComponent(name))
        }
        return result
    }

    /// Changed source files between revisions (or against the working tree), plus the repository root.
    /// nil means not a git repository, or an invalid ref. Paths are relative to the repository root
    /// (that is what `git diff` prints), so the working copy must be read from `topLevel`, not from
    /// `root` — with `root` a subdirectory, `root + relative` doubles the path.
    /// `-z` plus splitting on NUL keeps non-ASCII names from being quoted and dropped by the filter.
    ///
    /// C-family files come back separately rather than being filtered away. Diffing them needs a
    /// parser that works on the text of an arbitrary revision, which the compiler index cannot
    /// supply — it only knows the built state. Dropping them silently made a commit touching only
    /// `.m` files report "no symbol-level changes".
    public static func changedFiles(root: String, from: String, to: String?)
        -> (topLevel: String, swift: [String], clang: [String])? {
        guard let topLevelRaw = runGit(["-C", root, "rev-parse", "--show-toplevel"]) else { return nil }
        let topLevel = topLevelRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Revisions are validated explicitly. `git diff` accepts a range ("HEAD~1..HEAD"), but
        // `git show` fails on one: the old source silently became empty and the whole file looked
        // "added" — a plausible but wrong answer.
        for revision in [from, to].compactMap({ $0 }) {
            guard runGit(["-C", root, "rev-parse", "--verify", "--quiet", "\(revision)^{commit}"]) != nil else { return nil }
        }

        let extensions = ["swift"] + IndexDeclarations.clangExtensions
        let pathspecs = extensions.map { "*.\($0)" }
        let suffixes = extensions.map { ".\($0)" }

        var arguments = ["-C", root, "diff", "--name-only", "-z", from]
        if let to { arguments.append(to) }
        arguments += ["--"] + pathspecs
        guard let output = runGit(arguments) else { return nil }
        var files = output.split(separator: "\0").map(String.init).filter { name in suffixes.contains(where: name.hasSuffix) }

        // Comparing against the working tree: a new file is not in the git index yet, and without
        // it "what changed" would stay silent about a type just created. `--full-name` gives paths
        // from the repository root, like diff (ls-files defaults to the current directory).
        if to == nil,
           let untracked = runGit(["-C", root, "ls-files", "--others", "--exclude-standard", "--full-name", "-z", "--"] + pathspecs) {
            files += untracked.split(separator: "\0").map(String.init).filter { name in suffixes.contains(where: name.hasSuffix) }
        }
        let unique = Array(Set(files)).sorted()
        return (topLevel, unique.filter { $0.hasSuffix(".swift") }, unique.filter { !$0.hasSuffix(".swift") })
    }

    /// File contents at a git revision (`git show <revision>:<path>`); nil means the file does not
    /// exist at that revision (added or removed). The path is relative to the repository root.
    public static func fileContent(root: String, revision: String, relativePath: String) -> String? {
        runGit(["-C", root, "show", "\(revision):\(relativePath)"])
    }

    private static func runGit(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Per-process memo of the file list (root|includeTests → files), so withinScale and the
    /// command itself do not call git twice. In a long-lived MCP server it is cleared per tool call.
    /// Thread-safe (NSLock) — Swift Testing runs tests concurrently.
    private final class FileListMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: [URL]] = [:]
        func value(_ key: String) -> [URL]? { lock.withLock { map[key] } }
        func set(_ key: String, _ value: [URL]) { lock.withLock { map[key] = value } }
        func clear() { lock.withLock { map.removeAll() } }
    }
    private static let fileListMemo = FileListMemo()

    public static func clearFileListMemo() { fileListMemo.clear() }

    /// Patterns the user excluded, applied to every walk.
    ///
    /// Set once per command from `.sextant.json` and the `--exclude` flags, rather than threaded
    /// through twenty call sites where one would eventually be forgotten — and applied here, after
    /// both discovery paths, so a git project and a non-git one leave out exactly the same files.
    private final class Exclusions: @unchecked Sendable {
        private let lock = NSLock()
        private var patterns: [ExclusionPattern] = []
        private var source: [String] = []

        func set(_ raw: [String]) {
            lock.withLock {
                source = raw
                patterns = raw.map(ExclusionPattern.init)
            }
        }
        var current: (patterns: [ExclusionPattern], key: String) {
            lock.withLock { (patterns, source.joined(separator: "\u{1}")) }
        }
    }
    private static let exclusions = Exclusions()

    /// Replaces the exclusion list for this process. Called by the entry points; a long-lived
    /// server sets it per request, because the config may have been edited since the last one.
    public static func setExclusions(_ patterns: [String]) {
        exclusions.set(patterns)
    }

    /// Every `.swift` file under the root: the git list in a repository, otherwise a FileManager walk. Memoised.
    public static func files(under root: URL, includeTests: Bool, extensions: [String] = ["swift"]) -> [URL] {
        let (patterns, exclusionKey) = exclusions.current
        // The exclusions are part of the key: changing them must not be answered from the memo.
        let key = "\(root.path)|\(includeTests)|\(extensions.joined(separator: ","))|\(exclusionKey)"
        if let cached = fileListMemo.value(key) { return cached }
        // A repository answers for itself; a directory that is not one still gets git's own
        // gitignore rules, borrowed; only where git is unavailable does the plain walk run.
        let discovered = gitSwiftFiles(under: root, includeTests: includeTests, extensions: extensions)
            ?? borrowedGitFiles(under: root, includeTests: includeTests, extensions: extensions)
            ?? enumeratedFiles(under: root, includeTests: includeTests, extensions: extensions)
        let result = patterns.isEmpty
            ? discovered
            : discovered.filter { !patterns.exclude(relativePath: relativePath(of: $0, root: root)) }
        fileListMemo.set(key, result)
        return result
    }

    /// Files under a directory that is **not** a repository, with `.gitignore` still honoured in
    /// full — by borrowing git rather than reimplementing it.
    ///
    /// git is handed the project as a work tree while its git dir lives in the cache, so nothing
    /// is written inside the project and the whole of gitignore applies: negation, bracket
    /// classes, nested `.gitignore` files, "last matching pattern wins", the anchoring rules. The
    /// alternative — a hand-rolled subset — was tried and is worse than nothing: a partial
    /// implementation fails silently, and a user cannot predict where it stops.
    ///
    /// nil means git could not be borrowed (not installed, or the directory is unreadable), and
    /// the caller falls back to a plain walk.
    static func borrowedGitFiles(under root: URL, includeTests: Bool, extensions: [String]) -> [URL]? {
        let gitDirectory = borrowedGitDirectory(for: root)
        if !FileManager.default.fileExists(atPath: gitDirectory.path) {
            try? FileManager.default.createDirectory(at: gitDirectory.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            guard runGit(["init", "-q", "--bare", gitDirectory.path]) != nil else { return nil }
        }
        let suffixes = extensions.map { ".\($0)" }
        let pathspecs = extensions.map { "*.\($0)" }
        // `--others --exclude-standard`: everything untracked that gitignore does not exclude —
        // in a work tree with an empty index, that is every file the user would consider theirs.
        guard let output = runGit(["--git-dir", gitDirectory.path, "--work-tree", root.path,
                                   "-C", root.path, "ls-files", "-z", "--others", "--exclude-standard",
                                   "--"] + pathspecs) else { return nil }

        var result: [URL] = []
        for piece in output.split(separator: "\0") {
            let name = String(piece)
            guard suffixes.contains(where: name.hasSuffix) else { continue }
            let components = name.split(separator: "/").map(String.init)
            guard let last = components.last, !last.hasPrefix(".") else { continue }
            if components.dropLast().contains(where: { $0.hasPrefix(".") || skippedDirectories.contains($0) }) { continue }
            if !includeTests, last.hasSuffix("Tests.swift") { continue }
            result.append(root.appendingPathComponent(name))
        }
        return result
    }

    /// The borrowed git dir for a project: in the cache, never inside the project. Writing a
    /// `.git` into someone's directory would turn a read-only question into a change to their tree.
    static func borrowedGitDirectory(for root: URL) -> URL {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sextant/gitdir/\(ContentHash.of(canonical).prefix(16)).git")
    }

    /// FileManager fallback for non-git directories: a walk that skips hidden and service directories.
    private static func enumeratedFiles(under root: URL, includeTests: Bool, extensions: [String] = ["swift"]) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        let ignored = ignoredDirectoryNames(under: root)
        var result: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if shouldSkip(directory: url.lastPathComponent, ignored: ignored) { enumerator.skipDescendants() }
                continue
            }
            guard extensions.contains(url.pathExtension), !url.lastPathComponent.hasPrefix(".") else { continue }
            if !includeTests, url.lastPathComponent.hasSuffix("Tests.swift") { continue }
            result.append(url)
        }
        return result
    }

    /// Whether the Swift file count exceeds a limit. Under git this is an exact count, memoised so
    /// a later `files` call reuses it; under FileManager it exits early, for huge non-git repositories.
    public static func exceedsLimit(under root: URL, includeTests: Bool, limit: Int) -> Bool {
        let key = "\(root.path)|\(includeTests)"
        if let cached = fileListMemo.value(key) { return cached.count > limit }
        if let git = gitSwiftFiles(under: root, includeTests: includeTests) {
            fileListMemo.set(key, git)
            return git.count > limit
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return false }

        let ignored = ignoredDirectoryNames(under: root)
        var count = 0
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if shouldSkip(directory: url.lastPathComponent, ignored: ignored) { enumerator.skipDescendants() }
                continue
            }
            guard url.pathExtension == "swift", !url.lastPathComponent.hasPrefix(".") else { continue }
            if !includeTests, url.lastPathComponent.hasSuffix("Tests.swift") { continue }
            count += 1
            if count > limit { return true }
        }
        return false
    }

    /// Whether any source is newer than a date (early exit) — used to check index freshness.
    ///
    /// Every language the index covers counts, not just Swift. Walking `*.swift` alone left the
    /// C family — half of the Apple environment — outside the freshness signal: editing a `.m`
    /// or a header kept the marker saying `fresh`, which is a trust label on a stale answer.
    public static func hasSourceNewer(than date: Date, under root: URL) -> Bool {
        let extensions = ["swift"] + IndexDeclarations.clangExtensions
        if let git = gitSwiftFiles(under: root, includeTests: true, extensions: extensions) {
            for url in git {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified > date { return true }
            }
            return false
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else { return false }

        let ignored = ignoredDirectoryNames(under: root)
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                if shouldSkip(directory: url.lastPathComponent, ignored: ignored) { enumerator.skipDescendants() }
                continue
            }
            guard extensions.contains(url.pathExtension), !url.lastPathComponent.hasPrefix(".") else { continue }
            if let modified = values?.contentModificationDate, modified > date { return true }
        }
        return false
    }

    /// Path relative to the project root.
    public static func relativePath(of url: URL, root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents else {
            return url.lastPathComponent
        }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Package name from a relative path: `Packages/<X>/...` → X; otherwise the first component.
    public static func package(for relativePath: String) -> String {
        let components = relativePath.split(separator: "/").map(String.init)
        if components.first == "Packages", components.count > 1 { return components[1] }
        return components.first ?? "."
    }
}
