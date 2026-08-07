import Foundation

/// How a path is shown in an answer.
///
/// Keeping the last few components is not enough: it makes the prefix depend on how deep the
/// project happens to sit, so two files from one project come back looking unrelated —
/// `alamofire/Source/Alamofire.swift` next to `Source/Core/Session.swift`. Neither can be opened
/// or pasted anywhere, and a reader cannot tell which part is the project.
///
/// A path inside the project is shown relative to it, which is what the structural commands
/// already print and what an editor, a diff and a reader all understand. Only what lies outside —
/// the SDK, a dependency checkout — falls back to the tail, because there the full path is long
/// and its beginning says nothing.
public enum DisplayPath {
    public static func of(_ path: String, root: String?, tail: Int = 3) -> String {
        guard let root, !root.isEmpty else { return trimmed(path, tail: tail) }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath()
        let fileURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()

        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return trimmed(path, tail: tail)
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func trimmed(_ path: String, tail: Int) -> String {
        let components = path.split(separator: "/")
        guard components.count > tail else { return path }
        return "…/" + components.suffix(tail).joined(separator: "/")
    }
}
