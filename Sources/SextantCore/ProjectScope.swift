import Foundation

/// The working root with `scope` (a project subdirectory) applied. It validates that the scope
/// does not lead outside the project and points at an existing directory — otherwise the result
/// would be computed over a different area without anyone noticing.
public enum ProjectScope {
    public enum Outcome: Sendable, Equatable {
        case resolved(String)
        case outsideProject
        case missingDirectory
    }

    /// Root for a scope; an empty or nil scope yields the project root itself.
    public static func resolve(root: String, scope: String?) -> Outcome {
        let base = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard let scope, !scope.isEmpty else { return .resolved(base.path) }

        let scoped = base.appendingPathComponent(scope).resolvingSymlinksInPath().standardizedFileURL
        guard scoped.path == base.path || scoped.path.hasPrefix(base.path + "/") else { return .outsideProject }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scoped.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missingDirectory
        }
        return .resolved(scoped.path)
    }
}
