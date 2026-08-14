import Foundation

/// Finds the current index store in Xcode's DerivedData.
///
/// The DerivedData path is non-deterministic (a hash of the project path), and one project may
/// have several directories. The freshest by modification time is chosen.
public enum DerivedDataLocator {
    /// Glob pattern for a project's DataStore directories, by name.
    public static func dataStoreGlob(projectName: String, home: String) -> String {
        "\(home)/Library/Developer/Xcode/DerivedData/\(projectName)-*/Index.noindex/DataStore"
    }

    /// The freshest DataStore among the candidates; ties broken by path for determinism.
    public static func freshest(from candidates: [(path: String, modified: Date)]) -> String? {
        candidates.max { lhs, rhs in
            lhs.modified != rhs.modified ? lhs.modified < rhs.modified : lhs.path < rhs.path
        }?.path
    }

    /// The project's freshest DataStore, located through `info.plist` → WorkspacePath. Matching by
    /// project path rather than scheme name is reliable and excludes other worktrees.
    public static func dataStore(forProjectRoot projectRoot: String, derivedData: String) -> String? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: derivedData) else { return nil }

        var appWorkspaces: [(path: String, modified: Date)] = []
        var packageWorkspaces: [(path: String, modified: Date)] = []
        for entry in entries {
            let infoPlist = "\(derivedData)/\(entry)/info.plist"
            guard let info = NSDictionary(contentsOfFile: infoPlist),
                  let workspacePath = info["WorkspacePath"] as? String,
                  workspace(workspacePath, isInProjectRoot: projectRoot) else { continue }

            let store = "\(derivedData)/\(entry)/Index.noindex/DataStore"
            guard manager.fileExists(atPath: store),
                  let modified = IndexFreshness.timestamp(ofStore: store)
            else { continue }

            if isAppWorkspace(workspacePath) {
                appWorkspaces.append((store, modified))
            } else {
                packageWorkspaces.append((store, modified))
            }
        }
        // An app workspace (.xcodeproj/.xcworkspace) covers the whole project; the index of an
        // opened nested package (Package.swift) is partial, so it is used only when no app exists.
        return freshest(from: appWorkspaces.isEmpty ? packageWorkspaces : appWorkspaces)
    }

    /// Whether WorkspacePath points at an Xcode project or workspace, rather than a nested Package.swift.
    static func isAppWorkspace(_ path: String) -> Bool {
        path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace")
    }

    /// Whether the workspace lies inside the project root, respecting path component boundaries,
    /// and holds paths this project can use.
    ///
    /// The second half is not a refinement — it is the whole difference between an answer and
    /// nothing. An agent worktree lives *inside* the checkout (`.claude/worktrees/<name>`), so its
    /// DerivedData passes the prefix test, and being rebuilt more recently it also wins on
    /// freshness. Every record in it then names a path under that worktree, which the record
    /// filter rejects as foreign — so the tool picks a store, opens it, reports `fresh`, and
    /// answers every question with nothing. Selection has to apply the same predicate the filter
    /// applies, or the two layers disagree and the disagreement is invisible.
    static func workspace(_ workspacePath: String, isInProjectRoot projectRoot: String) -> Bool {
        let workspace = URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath().standardizedFileURL.path
        let root = URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().standardizedFileURL.path
        guard workspace == root || workspace.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return false }
        return IndexStore.inScope(path: workspace, root: root)
    }
}
