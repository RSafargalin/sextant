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

    /// Every DataStore Xcode holds for this project, with the facts needed to choose between them.
    /// A project routinely has several: a second checkout, an opened nested package, a stale
    /// directory from a renamed scheme. Which one answers is a decision, so they all come back.
    public static func candidates(forProjectRoot projectRoot: String, derivedData: String) -> [StoreCandidate] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: derivedData) else { return [] }

        var apps: [StoreCandidate] = []
        var packages: [StoreCandidate] = []
        for entry in entries.sorted() {
            let infoPlist = "\(derivedData)/\(entry)/info.plist"
            guard let info = NSDictionary(contentsOfFile: infoPlist),
                  let workspacePath = info["WorkspacePath"] as? String else { continue }
            let store = "\(derivedData)/\(entry)/Index.noindex/DataStore"
            guard manager.fileExists(atPath: store) else { continue }

            let modified = IndexFreshness.timestamp(ofStore: store)
            let rejection: String?
            if !workspace(workspacePath, isInProjectRoot: projectRoot) {
                // Only stores that belong to this checkout are shown at all; another project's
                // DerivedData is not a candidate anybody would want listed.
                continue
            } else if !belongsToSameProject(workspace: workspacePath, root: projectRoot) {
                continue
            } else if modified == nil {
                rejection = "no units — nothing to read"
            } else {
                rejection = nil
            }
            let candidate = StoreCandidate(path: store, origin: workspacePath,
                                           unitCount: StoreCandidate.unitCount(ofStore: store),
                                           modified: modified, rejection: rejection)
            if isAppWorkspace(workspacePath) { apps.append(candidate) } else { packages.append(candidate) }
        }
        // An app workspace (.xcodeproj/.xcworkspace) covers the whole project; the index of an
        // opened nested package is partial, so it is used only when no app store exists — and it
        // is still listed, with the reason, rather than disappearing.
        guard !apps.contains(where: \.isUsable) else {
            return apps + packages.map {
                StoreCandidate(path: $0.path, origin: $0.origin, unitCount: $0.unitCount, modified: $0.modified,
                               rejection: $0.rejection ?? "a nested package's index, partial by construction — "
                                        + "an app workspace store covers the project")
            }
        }
        return apps + packages
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

    /// Whether a workspace is part of the same project as the root, rather than merely somewhere
    /// beneath it.
    ///
    /// A path prefix is not a project boundary. Pointed at a home directory, the prefix test
    /// accepts every project the user has ever built — measured: `--project ~` offered the store
    /// of an unrelated app from `Downloads`, covering 6% of what it called "this project". The
    /// boundary that means something is the repository: a workspace belongs here when it is in the
    /// same checkout as the root. Outside git, the fallback is direct containment — the workspace
    /// sits in the root itself — which is the layout a project without version control has.
    static func belongsToSameProject(workspace: String, root: String) -> Bool {
        let workspaceDirectory = (workspace as NSString).deletingLastPathComponent
        let rootRepository = repositoryRoot(of: root)
        let workspaceRepository = repositoryRoot(of: workspaceDirectory)
        if let rootRepository, let workspaceRepository { return rootRepository == workspaceRepository }
        if rootRepository == nil, workspaceRepository == nil {
            let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            return URL(fileURLWithPath: workspaceDirectory).resolvingSymlinksInPath().standardizedFileURL.path == root
        }
        // One of them is under version control and the other is not: they are not one project.
        return false
    }

    private static func repositoryRoot(of directory: String) -> String? {
        guard let output = Command.output("/usr/bin/env", ["git", "-C", directory, "rev-parse", "--show-toplevel"]),
              case let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardizedFileURL.path
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
