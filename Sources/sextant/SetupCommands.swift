import SextantCore
import Darwin
import Foundation

// MARK: - init (set up a project in one command)

/// Absolute path to the running binary — it goes into `.mcp.json`, otherwise the client will
/// not find the server (GUI clients have a different PATH from the shell).
///
/// A symlink under `bin/` is NOT resolved: Homebrew installs `bin/sextant →
/// Cellar/sextant/<version>/…`, and the versioned path breaks on `brew upgrade`. The stable
/// symlink in bin survives the upgrade, so that is what gets written; only a relative launch
/// path is resolved.
private func executablePath() -> String {
    let standardized = launchURL().standardizedFileURL
    // Resolve symlinks only outside a bin directory (for example a launch through .build or a
    // personal symlink); a stable bin symlink is left as it is.
    if standardized.deletingLastPathComponent().lastPathComponent == "bin" {
        return standardized.path
    }
    return standardized.resolvingSymlinksInPath().path
}

/// The path the process was launched from, according to the kernel. When launched through
/// PATH, `argv[0]` is the bare name (`sextant`), and completing it against the current
/// directory produces a path that does not exist inside the project — so argv is only a
/// fallback.
func launchURL() -> URL {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    if _NSGetExecutablePath(&buffer, &size) == 0 {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }
    let raw = CommandLine.arguments.first ?? "sextant"
    return raw.hasPrefix("/")
        ? URL(fileURLWithPath: raw)
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(raw)
}

/// Registers sextant in `.mcp.json` without losing anyone else's servers: only our own key is
/// touched. nil means the file exists but `mcpServers` is not an object — overwriting would
/// silently destroy a structure we do not own.
private func mcpRegistration(existing: [String: Any]?, project: String, force: Bool) -> (json: [String: Any], status: String)? {
    var root = existing ?? [:]
    if let servers = root["mcpServers"], !(servers is [String: Any]) {
        return nil
    }
    var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
    if servers["sextant"] != nil, !force {
        return (root, "· .mcp.json: sextant is already registered (--force to overwrite)")
    }
    servers["sextant"] = [
        "command": executablePath(),
        "args": ["mcp", "--project", project]
    ]
    root["mcpServers"] = servers
    return (root, existing == nil ? "✅ .mcp.json created" : "✅ .mcp.json: sextant server added (the others were kept)")
}

private func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try (String(decoding: data, as: UTF8.self) + "\n").write(to: url, atomically: true, encoding: .utf8)
}

func runInit(arguments: [String]) -> Int32 {
    let root = projectRoot(in: arguments)
    let force = arguments.contains("--force")
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    print("# sextant init — \(root)")

    // 1. Project config: the defaults that both the CLI and MCP honour from here on.
    let configURL = rootURL.appendingPathComponent(".sextant.json")
    if FileManager.default.fileExists(atPath: configURL.path), !force {
        print("· .sextant.json already exists (--force to overwrite)")
    } else {
        do {
            try writeJSON(["budget": 6000, "maxFiles": 4000], to: configURL)
            print("✅ .sextant.json created (budget 6000, maxFiles 4000)")
        } catch {
            reportError("sextant init: could not write .sextant.json: \(error)")
            return 1
        }
    }

    // 2. MCP server registration — other people's servers in the file are left alone.
    var mcpOK = true
    let mcpURL = rootURL.appendingPathComponent(".mcp.json")
    let existing = (try? Data(contentsOf: mcpURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    if FileManager.default.fileExists(atPath: mcpURL.path), existing == nil {
        print("❌ .mcp.json exists but does not parse — leaving it alone, fix it by hand")
        mcpOK = false
    } else if let (json, status) = mcpRegistration(existing: existing, project: root, force: force) {
        do {
            try writeJSON(json, to: mcpURL)
            print(status)
        } catch {
            reportError("sextant init: could not write .mcp.json: \(error)")
            return 1
        }
    } else {
        // mcpServers is present but is not an object — overwriting silently is not acceptable.
        print("❌ .mcp.json: the mcpServers key is not an object — leaving it alone, fix it by hand")
        mcpOK = false
    }

    // 3. What already works, and what still needs a step from the user.
    let fileCount = SwiftSources.files(under: rootURL, includeTests: false).count
    print(fileCount > 0 ? "✅ Swift sources: \(fileCount) files" : "❌ no Swift sources found — sextant is meant for Swift projects")

    let hasLibrary = (optionValue("--index-lib", in: arguments) ?? discoverIndexStoreLibrary()) != nil
    print(hasLibrary ? "✅ libIndexStore found (semantics available)"
                     : "⚠ libIndexStore not found — only the syntactic commands work (map/api/search/lint/changed). Install an Xcode toolchain.")

    let stores = resolveStorePaths(in: arguments)
    print("")
    if stores.isEmpty {
        print("Next: build an index — `sextant index` (SPM) or `sextant index --app` (xcodeproj),")
        print("      then check it with `sextant doctor`. Already working: `sextant map`, `sextant api`.")
    } else {
        let stale = indexIsStale(paths: stores, root: root)
        print(stale ? "An index exists but is older than the sources — rebuild it: `sextant index`."
                    : "✅ index in place — semantics are ready: try `sextant context <symbol>`.")
    }
    if mcpOK {
        print("MCP: restart your client (Claude Code) so it picks up .mcp.json.")
    }
    return mcpOK ? 0 : 1
}
