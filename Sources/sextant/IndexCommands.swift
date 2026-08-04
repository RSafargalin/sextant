import SextantCore
import Darwin
import Foundation

// MARK: - Index store resolution

/// Index store paths plus their source: `--index-store`, else the umbrella cache, else the
/// project's SPM stores (a single root gives clean dedup), else DerivedData matched by
/// WorkspacePath ⊂ project (reliable for any scheme name or layout; excludes other worktrees).
/// SPM and DerivedData are deliberately NOT merged: different roots and configurations would
/// double-count. An app target (xcodeproj) is covered through DerivedData.
/// Freshness and its warning live in `openIndex` via provenance — one place, not duplicated.
func resolveIndex(in arguments: [String]) -> (paths: [String], source: IndexProvenance.Source) {
    if let explicit = optionValue("--index-store", in: arguments) { return ([explicit], .explicit) }
    let rootPath = projectRoot(in: arguments)
    if let umbrella = IndexBuild.umbrellaStorePath(forRoot: rootPath) { return ([umbrella], .umbrella) }
    let projectStores = IndexStoreLocator.stores(under: URL(fileURLWithPath: rootPath, isDirectory: true))
    if !projectStores.isEmpty { return (projectStores, .spm) }
    let derivedData = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Developer/Xcode/DerivedData"
    if let store = DerivedDataLocator.dataStore(forProjectRoot: rootPath, derivedData: derivedData) { return ([store], .derivedData) }
    return ([], .spm)
}

func resolveStorePaths(in arguments: [String]) -> [String] { resolveIndex(in: arguments).paths }

/// Index freshness: whether any source is newer than the freshest store.
func indexIsStale(paths: [String], root: String) -> Bool {
    IndexFreshness.isStale(storePaths: paths, projectRoot: root)
}

// MARK: - doctor (setup self-check)

func runDoctor(arguments: [String]) -> Int32 {
    let root = projectRoot(in: arguments)
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    print("# sextant doctor — \(shorten(root))")
    var ok = true

    let fileCount = SwiftSources.files(under: rootURL, includeTests: false).count
    if fileCount > 0 {
        print("✅ Swift sources: \(fileCount) files")
    } else {
        print("❌ no Swift sources found under \(root)")
        ok = false
    }

    switch ProjectConfig.read(projectRoot: root) {
    case .missing:
        break
    case .loaded:
        print("✅ .sextant.json read")
    case .invalid(let reason):
        print("❌ .sextant.json exists but could not be parsed (\(reason)) — defaults ignored")
        ok = false
    }

    if let library = optionValue("--index-lib", in: arguments) ?? discoverIndexStoreLibrary() {
        print("✅ libIndexStore: \(shorten(library))")
    } else {
        print("❌ libIndexStore.dylib not found — pass --index-lib or install an Xcode toolchain")
        ok = false
    }

    // --fix: build before diagnosing if the index is missing or stale (passes --app and the
    // rest through to index).
    if arguments.contains("--fix") {
        let currentStores = resolveStorePaths(in: arguments)
        if currentStores.isEmpty || indexIsStale(paths: currentStores, root: root) {
            reportError("sextant doctor --fix: index missing or stale — building…")
            _ = runIndex(arguments: arguments)
        }
    }

    let stores = resolveStorePaths(in: arguments)
    if stores.isEmpty {
        print("❌ no index store found — build one: `sextant index` (SPM) or `sextant index --app` (xcodeproj)")
        ok = false
    } else {
        for store in stores {
            switch IndexFreshness.state(storePaths: [store], projectRoot: root) {
            case .fresh:
                print("✅ index store: \(shorten(store))")
            case .stale:
                print("⚠ index store: \(shorten(store))  (older than the sources — rebuild the project or run `sextant index`)")
            case .unknown:
                print("⚠ index store: \(shorten(store))  (empty or unreadable — freshness unknown)")
                ok = false
            }
        }
        if let set = openIndex(arguments, label: "doctor") {
            print("✅ index opened: \(set.storeCount) store(s)")
        } else {
            print("❌ index failed to open")
            ok = false
        }
    }

    print(ok ? "\n✅ ready — `sextant mcp` will work (semantics and structure)" : "\n❌ there are problems — see above")
    return ok ? 0 : 1
}

// MARK: - index

/// Indexing an app target through xcodebuild (COMPILER_INDEX_STORE_ENABLE) — this covers what
/// the SPM index does not. The resolver then finds the DerivedData store by WorkspacePath.
func runXcodeIndex(root: URL, arguments: [String]) -> Int32 {
    guard let containerFlag = IndexBuild.xcodeContainerFlag(root: root) else {
        reportError("sextant index --app: no .xcworkspace or .xcodeproj found in \(root.path).")
        return 1
    }

    guard let scheme = optionValue("--scheme", in: arguments) ?? IndexBuild.detectScheme(containerFlag: containerFlag) else {
        reportError("sextant index --app: could not determine the scheme. Pass --scheme <name>.")
        return 1
    }
    let destination = optionValue("--destination", in: arguments) ?? "generic/platform=macOS"

    reportError("ℹ sextant index --app will run xcodebuild (a build) — trusted code only.")
    print("▶ xcodebuild build -scheme \(scheme) -destination '\(destination)' (COMPILER_INDEX_STORE_ENABLE=YES)")
    let buildArgs = ["xcodebuild", "build", "-scheme", scheme, "-destination", destination,
                     "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "-quiet"] + containerFlag
    let status = Command.status("/usr/bin/env", buildArgs, in: root)
    guard status == 0 else {
        reportError("sextant index --app: xcodebuild failed (code \(status)). Check --scheme and --destination.")
        return 1
    }
    let derivedData = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Developer/Xcode/DerivedData"
    if let store = DerivedDataLocator.dataStore(forProjectRoot: root.path, derivedData: derivedData) {
        print("\nindex ready (app, DerivedData): \(store)")
        return 0
    }
    print("\nbuild succeeded, but no DerivedData index was found (check WorkspacePath).")
    return 1
}

func runIndex(arguments: [String]) -> Int32 {
    let rootPath = projectRoot(in: arguments)

    if arguments.contains("--app") {
        return runXcodeIndex(root: URL(fileURLWithPath: rootPath, isDirectory: true), arguments: arguments)
    }
    if arguments.contains("--no-build") {
        if let store = resolveStorePaths(in: arguments).first {
            print("index (no build): \(store)")
            return 0
        }
        reportError("sextant index --no-build: no existing index (build in Xcode, or drop --no-build).")
        return 1
    }
    reportError("ℹ sextant index will execute Package.swift (a build) — run it only on trusted code.")

    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let packageDirs = IndexStoreLocator.swiftPackages(under: root)
    guard !packageDirs.isEmpty else {
        reportError("sextant index: no SPM packages found under \(rootPath). For Xcode projects, build in Xcode (DerivedData) or pass --index-store.")
        return 1
    }

    // A single package is built directly — IndexStoreLocator will find its .build store.
    if packageDirs.count == 1 {
        let package = packageDirs[0]
        print("▶ swift build --enable-index-store: \(package.lastPathComponent)")
        let status = Command.status("/usr/bin/env", ["swift", "build", "--enable-index-store"], in: package)
        guard status == 0, let store = IndexStoreLocator.stores(under: root).first else {
            reportError("sextant index: build failed (code \(status)).")
            return 1
        }
        print("\nindex ready: \(store)")
        return 0
    }

    // Several packages — one umbrella manifest, one pass.
    let packages = packageDirs.compactMap(IndexBuild.readPackage(at:))
    let plan = IndexBuild.umbrellaPlan(packages: packages, expected: packageDirs.map { $0.path })
    // Report skipped manifests BEFORE the verdict: a refusal over duplicates or platforms is
    // decided on an incomplete set, and staying quiet about that would be silently wrong.
    if !plan.skipped.isEmpty {
        reportError("⚠ sextant index: manifests not read (they will NOT be in the index): \(plan.skipped.joined(separator: ", "))")
    }
    let manifest: String
    switch plan.outcome {
    case .noManifests:
        reportError("sextant index: could not read any manifest (swift package dump-package).")
        return 1
    case .duplicateIdentities(let identities):
        reportError("sextant index: packages share a directory name (\(identities.joined(separator: ", "))) — the umbrella will not build. Rename the directory or use --index-store.")
        return 1
    case .unsupportedPlatform(let names):
        reportError("sextant index: packages without macOS support (\(names.joined(separator: ", "))) — `swift build` cannot run on the host. Use an Xcode build (DerivedData) or --index-store.")
        return 1
    case .ready(let text, _, _):
        manifest = text
    }

    let umbrella: URL
    do {
        umbrella = try IndexBuild.writeUmbrella(manifest: manifest, forRoot: rootPath)
    } catch {
        reportError("sextant index: could not create the umbrella: \(error)")
        return 1
    }

    print("▶ umbrella build (\(packages.count) packages, one pass): swift build --enable-index-store")
    let status = Command.status("/usr/bin/env", ["swift", "build", "--enable-index-store"], in: umbrella)
    guard status == 0, let store = IndexBuild.umbrellaStorePath(forRoot: rootPath) else {
        reportError("sextant index: umbrella build failed (code \(status)).")
        return 1
    }
    print("\nindex ready (single store): \(store)")
    return 0
}

// MARK: - Opening the index (shared helper)

/// With --reindex, rebuilds the index before the query (freshness per build).
func ensureFreshIndex(_ arguments: [String]) {
    if arguments.contains("--reindex") { _ = runIndex(arguments: arguments) }
}

/// Indexes opened within this process. For a one-shot CLI run that is a single open, as
/// before; for long-lived processes (`serve`, MCP) it reuses an already-open set — which is
/// the whole point of the daemon, since otherwise every request re-imports the units.
/// Thread-safe (NSLock): a process may serve requests from more than one context.
private final class IndexMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var sets: [String: IndexStoreSet] = [:]

    func set(forKey key: String, make: () throws -> IndexStoreSet) rethrows -> IndexStoreSet {
        if let cached = lock.withLock({ sets[key] }) {
            cached.pollForChanges()   // pick up reindexing on a hot store
            return cached
        }
        let created = try make()
        lock.withLock { sets[key] = created }
        return created
    }
}

private let indexMemo = IndexMemo()

func openIndex(_ arguments: [String], label: String, listen: Bool = false) -> IndexStoreSet? {
    ensureFreshIndex(arguments)
    let (storePaths, source) = resolveIndex(in: arguments)
    guard !storePaths.isEmpty,
          let libraryPath = optionValue("--index-lib", in: arguments) ?? discoverIndexStoreLibrary() else {
        reportError("sextant \(label): no index store found (sextant index / an Xcode build / --index-store).")
        return nil
    }
    // Provenance on stderr — the single place that marks source and freshness, which is what
    // keeps the tool from being quietly wrong.
    let freshness = IndexFreshness.state(storePaths: storePaths, projectRoot: projectRoot(in: arguments))
    reportError(IndexProvenance(source: source, storeCount: storePaths.count, freshness: freshness).summary)
    // In the cache directory rather than /tmp: periodic cleanup of temporary files killed the
    // warm IndexStoreDB database and brought back the cold start (~2.1s instead of ~0.2s).
    let databaseRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/sextant/index-db").path
    let root = projectRoot(in: arguments)
    do {
        return try indexMemo.set(forKey: "\(storePaths.joined(separator: ":"))|\(libraryPath)|\(listen)|\(root)") {
            try IndexStoreSet(storePaths: storePaths, libraryPath: libraryPath, databaseRoot: databaseRoot, listenToUnitEvents: listen, projectRoot: root)
        }
    } catch {
        reportError("sextant \(label): could not open the index: \(error)")
        return nil
    }
}
