import Foundation

/// The one spelling of a path that the caches are keyed by.
///
/// `--project .`, `--project ./pkg/`, a symlinked checkout and an absolute path can all name the
/// same project; a cache keyed by the spelling keeps one entry per spelling, and a later command
/// that spells the project another way finds nothing. Symlinks are resolved (on macOS that also
/// folds `/private/tmp` and `/tmp` into one spelling for an existing path) and `.`/`..` removed.
public enum CanonicalPath {
    public static func of(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A file's path with symlinks resolved and `.`/`..` removed, also when the file no longer
    /// exists: its deepest existing ancestor is resolved and the rest appended. Resolving only an
    /// existing path is not enough — Foundation turns an existing `/private/tmp/x` into `/tmp/x` but
    /// leaves a missing one as it is, so a deleted file, or one whose whole directory went, would be
    /// spelled apart from the project it was in.
    public static func ofFile(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            rest.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return rest.reversed().reduce(existing.resolvingSymlinksInPath().standardizedFileURL) {
            $0.appendingPathComponent($1)
        }.path
    }

    /// The real path — every symlink resolved, `/private` kept, as a compiler records a file — of
    /// the deepest part of `path` that exists, with the rest appended.
    public static func real(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while existing.path != "/" {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                return rest.reversed().reduce(String(cString: resolved)) { $0 + "/" + $1 }
            }
            rest.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return "/" + rest.reversed().joined(separator: "/")
    }

    /// The name of a cache entry kept for a path: a hash of the canonical path, so the name has a
    /// fixed length however deep the path lies, two paths never share one, and two spellings of one
    /// path do. An entry named this way records the path it belongs to
    /// (`CacheEviction.recordOwner`), which is the only way back from the name to the path.
    public static func entryName(of path: String) -> String {
        String(ContentHash.of(of(path)).prefix(entryNameLength))
    }

    /// How many characters `entryName(of:)` has.
    public static let entryNameLength = 24

    /// Whether a cache entry's name has the form `entryName(of:)` gives.
    public static func isEntryName(_ name: String) -> Bool {
        name.utf8.count == entryNameLength
            && name.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }
}
