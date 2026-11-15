import Foundation

/// The text of sources as an index was built from them, kept so that an answer over a stale index
/// can be stated against the sources as they are now.
///
/// Content is addressed by git's blob hash, the identity `SourceSnapshot` already records. A file
/// that was clean in git when the store was built is read back from the repository's object
/// database. A file that was dirty then, or every file outside git, has no such copy, so
/// `sextant index` keeps one in sextant's cache directory, `index-snapshot-text/<hash>` — never in
/// the project.
public enum IndexedText {
    /// Outside git every source would be copied; above this total the copies are not kept, and
    /// answers in files changed since indexing fall to "not verifiable".
    public static let copyLimit = 64 * 1024 * 1024

    /// The directory the copies are kept in.
    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Caches/sextant/index-snapshot-text")
    }

    /// Keeps a copy of every file the snapshot records with a hash, unless one is already kept.
    /// A file whose content no longer has the recorded hash is skipped: a copy of anything else
    /// would be read later as the indexed text. Returns how many copies exist for the snapshot.
    @discardableResult
    public static func keepCopies(of sources: SourceSnapshot, projectRoot: String,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int {
        let recorded = sources.files.compactMap { path, record in record.hash.map { (path, $0, record.size ?? 0) } }
        guard !recorded.isEmpty else { return 0 }
        guard recorded.reduce(0, { $0 + $1.2 }) <= copyLimit else { return 0 }
        let root = URL(fileURLWithPath: IndexSnapshot.canonical(projectRoot), isDirectory: true)
        let folder = directory(home: home)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var kept = 0
        for (path, hash, _) in recorded {
            let target = folder.appendingPathComponent(hash)
            if FileManager.default.fileExists(atPath: target.path) { kept += 1; continue }
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(path).path),
                  SourceSnapshot.blobHash(of: data) == hash else { continue }
            if (try? data.write(to: target, options: .atomic)) != nil { kept += 1 }
        }
        return kept
    }

    /// Removes every kept copy no snapshot in the cache refers to any more, and returns the copies
    /// removed with the bytes they held.
    @discardableResult
    public static func prune(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (removed: [String], bytes: Int64) {
        let folder = directory(home: home)
        guard let copies = try? FileManager.default.contentsOfDirectory(atPath: folder.path), !copies.isEmpty else { return ([], 0) }
        let snapshots = IndexSnapshot.location(forStore: "/", home: home).deletingLastPathComponent()
        var referenced = Set<String>()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [] where name.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: snapshots.appendingPathComponent(name).path) else { continue }
            guard let snapshot = try? decoder.decode(IndexSnapshot.self, from: data) else {
                // A snapshot this version cannot read may still refer to copies: keep them all.
                return ([], 0)
            }
            snapshot.sources.files.values.compactMap(\.hash).forEach { referenced.insert($0) }
        }
        var removed: [String] = []
        var bytes: Int64 = 0
        for copy in copies.sorted() where !referenced.contains(copy) {
            let url = folder.appendingPathComponent(copy)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            removed.append(copy)
            bytes += size
        }
        return (removed, bytes)
    }

    /// The content with the given blob hash: the kept copy, else the repository's object, verified
    /// against the hash either way. nil when neither holds it.
    public static func content(hash: String, projectRoot: String,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               git: SourceSnapshot.GitRunner = .system) -> Data? {
        contents(hashes: [hash], projectRoot: projectRoot, home: home, git: git)[hash]
    }

    /// The contents with the given blob hashes, each verified against its hash; a hash neither a
    /// kept copy nor the repository holds is absent. The repository is asked once for all of them
    /// (`git cat-file --batch`) where the runner can feed it.
    public static func contents(hashes: [String], projectRoot: String,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                git: SourceSnapshot.GitRunner = .system) -> [String: Data] {
        var result: [String: Data] = [:]
        var missing: [String] = []
        for hash in Set(hashes) where hash.count == 40 && hash.allSatisfy(\.isHexDigit) {
            if let data = FileManager.default.contents(atPath: directory(home: home).appendingPathComponent(hash).path),
               SourceSnapshot.blobHash(of: data) == hash {
                result[hash] = data
            } else {
                missing.append(hash)
            }
        }
        guard !missing.isEmpty else { return result }
        if let batch = git.runWithInput,
           let output = batch(["-C", projectRoot, "cat-file", "--batch"], Data((missing.joined(separator: "\n") + "\n").utf8)) {
            for (hash, data) in parseBatch(output) where missing.contains(hash) && SourceSnapshot.blobHash(of: data) == hash {
                result[hash] = data
            }
            return result
        }
        for hash in missing {
            guard let output = git.run(["-C", projectRoot, "cat-file", "blob", hash]) else { continue }
            let data = Data(output.utf8)
            if SourceSnapshot.blobHash(of: data) == hash { result[hash] = data }
        }
        return result
    }

    /// The objects in `git cat-file --batch` output: `<hash> <type> <size>\n<bytes>\n` each, or
    /// `<hash> missing\n` for one the repository does not hold.
    static func parseBatch(_ output: Data) -> [String: Data] {
        let bytes = [UInt8](output)
        var result: [String: Data] = [:]
        var index = 0
        while index < bytes.count {
            guard let end = bytes[index...].firstIndex(of: UInt8(ascii: "\n")) else { break }
            let header = String(decoding: bytes[index..<end], as: UTF8.self).split(separator: " ")
            index = end + 1
            guard header.count == 3, let size = Int(header[2]) else { continue }
            guard index + size <= bytes.count else { break }
            if header[1] == "blob" { result[String(header[0])] = Data(bytes[index..<index + size]) }
            index += size + 1
        }
        return result
    }
}
