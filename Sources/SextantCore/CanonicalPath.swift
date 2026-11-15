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

    /// The canonical path as one file-name component, for caches that keep one entry per project.
    public static func fileName(of path: String) -> String {
        of(path).replacingOccurrences(of: "/", with: "_")
    }
}
