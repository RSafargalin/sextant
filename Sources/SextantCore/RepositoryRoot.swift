import Foundation

/// The repository a directory belongs to, found on disk without running git.
///
/// A linked worktree resolves to the main working tree of its repository — or to the repository
/// itself when it is bare — so every worktree of one project, and every subdirectory of it, is the
/// same project. A submodule is its own project.
/// A directory outside any repository is its own root.
public enum RepositoryRoot {
    public static func of(_ directory: String) -> String {
        let start = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
        var level = start
        while true {
            let marker = level.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return level.path }
                return mainWorkingTree(ofLinkedCheckout: level, marker: marker) ?? level.path
            }
            let parent = level.deletingLastPathComponent()
            if parent.path == level.path { return start.path }
            level = parent
        }
    }

    /// For a `.git` file (`gitdir: <path>`): the working tree of the common git directory when it is
    /// a `.git` inside one, the common directory itself when the repository is bare. nil when the
    /// git dir has no common directory — a submodule.
    private static func mainWorkingTree(ofLinkedCheckout level: URL, marker: URL) -> String? {
        guard let contents = try? String(contentsOf: marker, encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDirectory = URL(fileURLWithPath: path, isDirectory: true,
                               relativeTo: URL(fileURLWithPath: level.path, isDirectory: true)).standardizedFileURL

        guard let common = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8)
        else { return nil }
        let commonDirectory = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines),
                                  isDirectory: true,
                                  relativeTo: URL(fileURLWithPath: gitDirectory.path, isDirectory: true)).standardizedFileURL
        let root = commonDirectory.lastPathComponent == ".git" ? commonDirectory.deletingLastPathComponent() : commonDirectory
        return root.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
