import CryptoKit
import Foundation

/// The state of a project's sources at one moment, recorded so that a later moment can be compared
/// with it by content rather than by modification time.
///
/// In a git repository the state is the `HEAD` commit plus every source that differed from it —
/// modified, staged, untracked, or deleted. Everything else is, by definition, the content of that
/// commit. Outside git it is every source with its size and content hash.
///
/// Content is identified by git's blob hash (SHA-1 over `blob <size>\0` and the bytes), computed in
/// process. Using git's own identity lets a file that was clean when recorded be compared with the
/// recorded commit's tree without reading the file out of git.
public struct SourceSnapshot: Codable, Sendable, Equatable {
    public struct GitState: Codable, Sendable, Equatable {
        /// The commit checked out when the snapshot was taken.
        public let head: String
        /// The project root relative to the repository's top level: empty, or `sub/dir/`.
        public let prefix: String

        public init(head: String, prefix: String) {
            self.head = head
            self.prefix = prefix
        }
    }

    public struct FileRecord: Codable, Sendable, Equatable {
        /// The blob hash of the content; nil when the file did not exist (deleted from `HEAD`).
        public let hash: String?
        public let size: Int?
        /// Modification time, seconds since 1970. Outside git a file whose size and time both match
        /// is taken as unchanged without being read; a changed time alone leads to a hash.
        public let modified: Double?

        public init(hash: String?, size: Int?, modified: Double?) {
            self.hash = hash
            self.size = size
            self.modified = modified
        }
    }

    /// nil when the project was not in a git repository with a commit.
    public let git: GitState?
    /// In git: the sources that differed from `HEAD`. Outside git: every source. Keyed by the path
    /// relative to the project root.
    public let files: [String: FileRecord]

    public init(git: GitState?, files: [String: FileRecord]) {
        self.git = git
        self.files = files
    }

    /// The outcome of comparing the sources now with a snapshot.
    public enum Comparison: Sendable, Equatable {
        /// The sources whose content differs from the snapshot, relative to the project root, sorted.
        case compared(changed: [String])
        /// The comparison cannot be made, and why.
        case incomparable(String)
    }

    /// Runs git with the given arguments and returns its standard output, or nil when it fails.
    /// Tests substitute one that fails on purpose; everything else uses `system`.
    public struct GitRunner: Sendable {
        let run: @Sendable ([String]) -> String?

        public init(_ run: @escaping @Sendable ([String]) -> String?) {
            self.run = run
        }

        /// The installed git, run with `--no-optional-locks`: a read such as `git status` otherwise
        /// refreshes the repository's index file as a side effect, which would be a write into the
        /// user's repository made by a question about it.
        public static let system = GitRunner { arguments in
            Command.successOutput("/usr/bin/env", ["git", "--no-optional-locks"] + arguments)
        }
    }

    /// Why the sources could not be recorded.
    public struct CaptureFailure: Error, Sendable, Equatable {
        public let reason: String
    }

    // MARK: - Capture

    /// The sources under `projectRoot` as they are now. A failed git command is a failure, never
    /// an empty list: "nothing was dirty" recorded from a `git status` that did not run would mark
    /// every later edit of a file dirty at that moment as unchanged.
    public static func capture(projectRoot: URL, git runner: GitRunner = .system) -> Result<SourceSnapshot, CaptureFailure> {
        if let repository = Repository(projectRoot: projectRoot, runner: runner), let head = repository.head {
            guard let dirty = repository.dirtySources() else {
                return .failure(CaptureFailure(reason: "`git status` failed, so the files that differ from HEAD are unknown"))
            }
            var files: [String: FileRecord] = [:]
            for path in dirty {
                files[path] = record(of: projectRoot.appendingPathComponent(path))
            }
            return .success(SourceSnapshot(git: GitState(head: head, prefix: repository.prefix), files: files))
        }
        var files: [String: FileRecord] = [:]
        for url in SwiftSources.indexedSources(under: projectRoot) {
            files[SwiftSources.relativePath(of: url, root: projectRoot)] = record(of: url)
        }
        return .success(SourceSnapshot(git: nil, files: files))
    }

    // MARK: - Comparison

    /// The sources whose content now differs from this snapshot.
    ///
    /// In git the candidates come from git itself — what is dirty now, what was dirty then, and
    /// what differs between the recorded commit and the current one — and each candidate is then
    /// confirmed by content. A file that was dirty when recorded and still has that content is not
    /// a change; a file reverted to the commit's content after being recorded dirty is one.
    public func changes(projectRoot: URL, git runner: GitRunner = .system) -> Comparison {
        guard let git else { return compareEveryFile(projectRoot: projectRoot) }
        guard let repository = Repository(projectRoot: projectRoot, runner: runner) else {
            return .incomparable("the project is no longer in the git repository it was indexed in")
        }
        guard repository.prefix == git.prefix else {
            return .incomparable("the project sits at another place in its repository than when it was indexed")
        }
        guard let currentHead = repository.head else {
            return .incomparable("the repository has no checked-out commit")
        }

        guard let dirty = repository.dirtySources() else {
            return .incomparable("`git status` failed, so what is dirty now is unknown")
        }
        var candidates = Set(files.keys)
        candidates.formUnion(dirty)
        if currentHead != git.head {
            guard let moved = repository.sourcesChanged(from: git.head, to: currentHead) else {
                return .incomparable(repository.hasCommit(git.head)
                    ? "git could not compare \(git.head.prefix(10)) with HEAD"
                    : "the commit the index was built at (\(git.head.prefix(10))) is no longer in the repository")
            }
            candidates.formUnion(moved)
        }

        // What a file held when the snapshot was taken: its record if it was dirty then, otherwise
        // the content of the recorded commit (absent from that tree means it did not exist).
        let clean = candidates.filter { files[$0] == nil }.sorted()
        guard let tree = repository.blobs(at: git.head, paths: clean) else {
            return .incomparable("git could not read the tree of \(git.head.prefix(10))")
        }
        var changed: [String] = []
        for path in candidates {
            let expected = files[path].map(\.hash) ?? tree[path]
            let current = Self.blobHash(ofFile: projectRoot.appendingPathComponent(path).path)
            if expected != current { changed.append(path) }
        }
        return .compared(changed: changed.sorted())
    }

    private func compareEveryFile(projectRoot: URL) -> Comparison {
        var changed: [String] = []
        var seen = Set<String>()
        for url in SwiftSources.indexedSources(under: projectRoot) {
            let path = SwiftSources.relativePath(of: url, root: projectRoot)
            seen.insert(path)
            guard let recorded = files[path], recorded.hash != nil else {
                changed.append(path)
                continue
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize
            if size != recorded.size {
                changed.append(path)
                continue
            }
            if let modified = values?.contentModificationDate?.timeIntervalSince1970, modified == recorded.modified {
                continue
            }
            if Self.blobHash(ofFile: url.path) != recorded.hash { changed.append(path) }
        }
        for (path, recorded) in files where recorded.hash != nil && !seen.contains(path) {
            changed.append(path)
        }
        return .compared(changed: changed.sorted())
    }

    // MARK: - Content identity

    /// git's blob hash of a file's content, or nil when it cannot be read.
    public static func blobHash(ofFile path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return blobHash(of: data)
    }

    public static func blobHash(of data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func record(of url: URL) -> FileRecord {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return FileRecord(hash: nil, size: nil, modified: nil)
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
        return FileRecord(hash: blobHash(of: data), size: data.count, modified: modified)
    }
}

/// The git operations the snapshot needs, all run from the repository's top level with literal
/// pathspecs through one runner, and all answering in paths relative to the project root.
private struct Repository {
    let topLevel: String
    /// The project root relative to the top level: empty, or `sub/dir/`.
    let prefix: String
    /// The checked-out commit; nil in a repository with no commit yet.
    let head: String?
    private let runner: SourceSnapshot.GitRunner

    /// One `git rev-parse` answers all three where there is a commit; every process started here
    /// is paid on every query.
    init?(projectRoot: URL, runner: SourceSnapshot.GitRunner) {
        self.runner = runner
        if let output = runner.run(["-C", projectRoot.path, "rev-parse", "--show-toplevel", "--show-prefix", "HEAD"]) {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 3, !lines[0].isEmpty, !lines[2].isEmpty else { return nil }
            (topLevel, prefix, head) = (lines[0], lines[1], lines[2])
        } else {
            guard let output = runner.run(["-C", projectRoot.path, "rev-parse", "--show-toplevel", "--show-prefix"]) else {
                return nil
            }
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 2, !lines[0].isEmpty else { return nil }
            (topLevel, prefix, head) = (lines[0], lines[1], nil)
        }
    }

    func hasCommit(_ commit: String) -> Bool {
        run(["cat-file", "-e", "\(commit)^{commit}"]) != nil
    }

    /// Sources that differ from `HEAD` in the index or the work tree, untracked ones included.
    /// Renames are reported as a deletion and an addition, so both paths are named. nil when
    /// git fails.
    func dirtySources() -> [String]? {
        guard let output = run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames",
                                "--", scope]) else { return nil }
        return output.split(separator: "\0").compactMap { entry in
            // `XY path`: two status letters and a space.
            guard entry.count > 3 else { return nil }
            return projectPath(String(entry.dropFirst(3)))
        }
    }

    /// Sources whose content differs between two commits.
    func sourcesChanged(from: String, to: String) -> [String]? {
        guard let output = run(["diff", "--name-only", "-z", "--no-renames", from, to, "--", scope]) else { return nil }
        return output.split(separator: "\0").compactMap { projectPath(String($0)) }
    }

    /// The blob hash of each path in a commit's tree; a path absent from the tree is absent here.
    func blobs(at commit: String, paths: [String]) -> [String: String]? {
        var result: [String: String] = [:]
        var start = 0
        while start < paths.count {
            let chunk = paths[start..<min(start + 200, paths.count)].map { prefix + $0 }
            start += 200
            guard let output = run(["ls-tree", "-z", commit, "--"] + chunk) else { return nil }
            for entry in output.split(separator: "\0") {
                // `<mode> <type> <object>\t<path>`
                guard let tab = entry.firstIndex(of: "\t") else { continue }
                let fields = entry[..<tab].split(separator: " ")
                guard fields.count == 3, fields[1] == "blob",
                      let path = projectPath(String(entry[entry.index(after: tab)...])) else { continue }
                result[path] = String(fields[2])
            }
        }
        return result
    }

    /// The project's part of the repository as a pathspec.
    private var scope: String { prefix.isEmpty ? "." : String(prefix.dropLast()) }

    /// A top-level-relative path as a project-relative one, when it is an indexed source.
    private func projectPath(_ path: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return SwiftSources.isIndexedSource(relativePath: relative) ? relative : nil
    }

    private func run(_ arguments: [String]) -> String? {
        runner.run(["--literal-pathspecs", "-C", topLevel] + arguments)
    }
}
