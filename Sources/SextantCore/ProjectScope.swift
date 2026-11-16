import Foundation

/// The working root with `scope` (a project subdirectory) applied. It validates that the scope
/// does not lead outside the project and points at an existing directory — otherwise the result
/// would be computed over a different area without anyone noticing.
public enum ProjectScope {
    public enum Outcome: Sendable, Equatable {
        case resolved(String)
        case outsideProject
        case missingDirectory
        /// The scope names a file: a scope narrows the area to a directory.
        case notADirectory
    }

    /// Root for a scope; an empty or nil scope yields the project root itself.
    public static func resolve(root: String, scope: String?) -> Outcome {
        let base = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard let scope, !scope.isEmpty else { return .resolved(base.path) }

        // An absolute scope is the directory it names, inside the project or not — appended to the
        // root it would name a directory that does not exist, and be refused for the wrong reason.
        let named = scope.hasPrefix("/") ? URL(fileURLWithPath: scope, isDirectory: true) : base.appendingPathComponent(scope)
        let scoped = named.resolvingSymlinksInPath().standardizedFileURL
        guard scoped.path == base.path || scoped.path.hasPrefix(base.path + "/") else { return .outsideProject }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scoped.path, isDirectory: &isDirectory) else { return .missingDirectory }
        guard isDirectory.boolValue else { return .notADirectory }
        return .resolved(scoped.path)
    }

    /// The words after the scope's name in a refusal of an unusable scope.
    public static let notADirectoryReason = "is a file, not a directory — a scope narrows the area to a directory"
}
