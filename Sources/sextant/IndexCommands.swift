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
///
/// The decision over the candidates, with coverage measured only where several remain to choose
/// between: reading every unit costs seconds on a large store and buys nothing where there is no
/// decision to make.
func resolveStores(in arguments: [String]) -> (resolution: StoreResolution, source: IndexProvenance.Source) {
    let (candidates, source) = indexCandidates(in: arguments)
    let root = URL(fileURLWithPath: projectRoot(in: arguments), isDirectory: true)
    let library = optionValue("--index-lib", in: arguments)
    let resolution = StoreSelection.resolve(candidates, policy: storePolicy(in: arguments)?.policy) {
        $0.measuringCoverage(projectRoot: root, libraryPath: library)
    }
    return (resolution, source)
}

/// Every store the tool could use, in the order sources take precedence, together with where they
/// came from. The policy is applied afterwards — this only finds them.
func indexCandidates(in arguments: [String]) -> (candidates: [StoreCandidate], source: IndexProvenance.Source) {
    if let explicit = optionValue("--index-store", in: arguments) {
        return ([StoreCandidate(path: explicit, unitCount: StoreCandidate.unitCount(ofStore: explicit),
                                modified: IndexFreshness.timestamp(ofStore: explicit))], .explicit)
    }
    let rootPath = projectRoot(in: arguments)
    if let umbrella = IndexBuild.umbrellaStorePath(forRoot: rootPath) {
        return ([StoreCandidate(path: umbrella, unitCount: StoreCandidate.unitCount(ofStore: umbrella),
                                modified: IndexFreshness.timestamp(ofStore: umbrella))], .umbrella)
    }
    let spm = IndexStoreLocator.candidates(under: URL(fileURLWithPath: rootPath, isDirectory: true))
    if spm.contains(where: \.isUsable) { return (spm, .spm) }
    let xcode = DerivedDataLocator.candidates(forProjectRoot: rootPath, derivedData: derivedDataRoot(in: arguments))
    if xcode.contains(where: \.isUsable) { return (xcode, .derivedData) }
    return (spm + xcode, spm.isEmpty ? .derivedData : .spm)
}

/// The policy in force and where it came from, so the answer can say so.
func storePolicy(in arguments: [String]) -> (policy: StorePolicy, origin: String)? {
    if let raw = optionValue("--store-policy", in: arguments) {
        guard let policy = StorePolicy.named(raw) else { return nil }
        return (policy, "--store-policy")
    }
    if let raw = CallerContext.environmentValue("SEXTANT_STORE_POLICY"), let policy = StorePolicy.named(raw) {
        return (policy, "SEXTANT_STORE_POLICY")
    }
    if let raw = loadConfig(arguments)?.storePolicy, let policy = StorePolicy.named(raw) {
        return (policy, ".sextant.json")
    }
    return nil
}

/// The stores to open. One usable candidate needs no policy — there is nothing to decide. Several
/// do, unless one of them is the store `sextant index` built, and with none set nothing is picked:
/// the policies give different answers to the same question, so guessing here would be the
/// confident wrongness the tool exists to prevent.
func resolveIndex(in arguments: [String]) -> (paths: [String], source: IndexProvenance.Source) {
    let (resolution, source) = resolveStores(in: arguments)
    return (resolution.chosen.map(\.path), source)
}

func resolveStorePaths(in arguments: [String]) -> [String] { resolveIndex(in: arguments).paths }

/// The trust label for the stores a resolution chose: where they came from, which rule chose
/// them, how fresh they are and on what basis, and how much of the project they cover.
func indexProvenance(_ resolution: StoreResolution, source: IndexProvenance.Source,
                     arguments: [String]) -> IndexProvenance {
    let paths = resolution.chosen.map(\.path)
    let root = projectRoot(in: arguments)
    let report = IndexFreshness.report(storePaths: paths, projectRoot: root)
    // Coverage of the single opened store: cached against the store's own state, so this is a
    // lookup on every run but the first after a build. With several stores the number would be a
    // sum of overlapping sets, which is not a fact about anything.
    let coverage = paths.count == 1
        ? StoreCoverage.measure(store: paths[0], projectRoot: URL(fileURLWithPath: root, isDirectory: true),
                                libraryPath: optionValue("--index-lib", in: arguments))
        : nil
    let aside = resolution.setAsideByOwnStoreRule
    let selection = resolution.decidedByOwnStoreRule
        ? "the store `sextant index` built, ahead of \(aside) ordinary build store(s) (rule; a store policy overrides)"
        : nil
    return IndexProvenance(source: source, storeCount: paths.count, report: report, selection: selection,
                           coverage: coverage)
}

/// Where Xcode keeps its build products. The default location is a default, not a rule: a project
/// built with `xcodebuild -derivedDataPath ./build` — which every CI does, and many people do
/// locally — puts its index somewhere the default never looks, and the tool would report no index
/// for a project that has one.
func derivedDataRoot(in arguments: [String]) -> String {
    if let explicit = optionValue("--derived-data", in: arguments) { return explicit }
    if let environment = CallerContext.environmentValue("SEXTANT_DERIVED_DATA"), !environment.isEmpty {
        return (environment as NSString).standardizingPath
    }
    return "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Developer/Xcode/DerivedData"
}

/// Whether the index is stale, by the freshness layer.
func indexIsStale(paths: [String], root: String) -> Bool {
    IndexFreshness.isStale(storePaths: paths, projectRoot: root)
}

// MARK: - Compile database (flags for the C family)

/// Captures the compile flags from the build graph the build just wrote, and stores them for the
/// project. Nothing is captured for an Xcode build (it describes itself elsewhere), and an empty
/// capture never replaces a database that already has entries — silently losing the flags would
/// turn later structural queries into refusals with no explanation.
func captureCompileDatabase(root: String, stores: [String], buildLog: URL) {
    // The native build system writes a graph that describes every file, compiled this time or
    // not, so it is read first. The Swift Build system writes none, and there the flags are read
    // from what the build just printed.
    let fromGraph = CompilationDatabase.capture(fromStores: stores)
    guard fromGraph.isEmpty else {
        saveCompileDatabase(fromGraph, forRoot: root, emptyReason: "")
        return
    }
    let log = (try? String(contentsOf: buildLog, encoding: .utf8)) ?? ""
    saveCompileDatabase(CompilationDatabase.commands(inBuildLog: log), forRoot: root,
                        emptyReason: "no clang commands in the build graph or the build log (an incremental build compiles nothing — `swift package clean`, then run this again)")
}

/// Runs `swift build` for an index, with its output in a log rather than on the terminal: the
/// build is verbose, and a failure is reported with the end of that log.
private func runSwiftBuild(_ build: [String], in directory: URL, log: URL) -> Int32 {
    try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    print("   build log: \(log.path)")
    let status = Command.status("/usr/bin/env", ["swift"] + build, in: directory, loggingTo: log)
    if status != 0, let text = try? String(contentsOf: log, encoding: .utf8) {
        text.split(separator: "\n").suffix(30).forEach { reportError("   \($0)") }
    }
    return status
}

/// Stores a fresh capture, merged with what was already known. Nothing is lost when a project is
/// built in parts (one scheme, one destination at a time), and an empty capture never wipes a
/// database — that would turn every later structural query into an unexplained refusal.
func saveCompileDatabase(_ captured: [CompileCommand], forRoot root: String, emptyReason: String) {
    let sources = CompilationDatabase.compilableSources(projectRoot: root, includeTests: true)
    guard !sources.isEmpty else { return }

    guard !captured.isEmpty else {
        // A build that compiled nothing states no flags, and that is not a loss when an earlier
        // one already did: changed flags would have recompiled the file and been printed.
        let known = CompilationDatabase.load(forRoot: root)
        let missing = CompilationDatabase.missingSources(known, among: sources)
        guard !missing.isEmpty else {
            print("compile database: \(known.count) file(s), kept from an earlier build — this one compiled none of them")
            return
        }
        reportError("⚠ compile database: \(emptyReason) — \(missing.count) Objective-C/C/C++ file(s) will not be readable structurally.")
        return
    }
    let merged = CompilationDatabase.merge(existing: CompilationDatabase.load(forRoot: root), fresh: captured)
    do {
        try CompilationDatabase.save(merged, forRoot: root)
    } catch {
        reportError("⚠ compile database: could not be written (\(error)) — the C family will not be readable structurally.")
        return
    }
    let missing = CompilationDatabase.missingSources(merged, among: sources)
    print("compile database: \(merged.count) file(s)" + (missing.isEmpty ? "" : ", \(missing.count) without flags"))
}

/// What the build just produced, measured rather than assumed: a store that holds none of the
/// project's tests answers every question about them with silence, and the build is the last moment
/// at which that can still be said out loud.
func reportTestCoverage(ofStore store: String, root: String, arguments: [String], isXcode: Bool) {
    let coverage = StoreCoverage.measure(store: store,
                                         projectRoot: URL(fileURLWithPath: root, isDirectory: true),
                                         libraryPath: optionValue("--index-lib", in: arguments))
    guard let note = IndexBuild.missingTestsNote(uncoveredTests: coverage?.uncoveredTests ?? 0,
                                                 isXcode: isXcode) else { return }
    reportError(note)
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

    let (resolution, _) = resolveStores(in: arguments)
    let stores = resolution.chosen.map(\.path)
    let usableCandidates = resolution.candidates.filter(\.isUsable)
    if resolution.needsPolicy {
        // The state a check-up exists to name: there IS an index, in fact more than one, and the
        // tool is refusing to guess between them. "No index store found" would send the reader to
        // build a third.
        print("❌ store policy NOT SET — \(usableCandidates.count) usable stores, and the answer depends")
        print("   on which is read. Choose once: `sextant store use <\(StorePolicy.known)>`; `sextant store`")
        print("   shows what each gives and costs. Until then semantic commands refuse rather than guess.")
        for candidate in usableCandidates.sorted(by: { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }) {
            print("     \(shorten(candidate.path))  [\(candidate.unitCount) unit(s)"
                  + (candidate.modified.map { ", \(StoreSelection.stamp($0))" } ?? "") + "]")
        }
        ok = false
    } else if stores.isEmpty {
        print("❌ no index store found — build one: `sextant index` (SPM) or `sextant index --app` (xcodeproj)")
        ok = false
    } else {
        if resolution.decidedByOwnStoreRule {
            print("ℹ store chosen by rule: \(StoreSelection.ownStoreRule)")
        }
        for store in stores {
            let report = IndexFreshness.report(storePaths: [store], projectRoot: root)
            switch report.state {
            case .fresh:
                print("✅ index store: \(shorten(store))  (fresh — \(report.basisDescription))")
            case .stale:
                let reasons = report.reasons()
                let why = reasons.isEmpty ? "older than the sources" : reasons.joined(separator: "; ")
                print("⚠ index store: \(shorten(store))  (\(why) — \(report.basisDescription); run `sextant index`, or rebuild whatever wrote it)")
            case .unknown:
                print("⚠ index store: \(shorten(store))  (empty or unreadable — freshness unknown)")
                ok = false
            }
            if let problem = report.snapshotProblem {
                print("   snapshot of `sextant index` not used: \(problem)")
            }
            if report.testsSkipped {
                print("⚠ index store built without tests (`--no-tests`) — references from tests are missing")
            }
        }
        if let set = openIndex(arguments, label: "doctor") {
            print("✅ index opened: \(set.storeCount) store(s)")
        } else {
            print("❌ index failed to open")
            ok = false
        }
    }

    // The compile database matters only where there is C-family code; a pure Swift project is
    // not told about a layer it does not use.
    let clangSources = CompilationDatabase.compilableSources(projectRoot: root, includeTests: false)
    if !clangSources.isEmpty {
        let commands = CompilationDatabase.load(forRoot: root)
        let missing = CompilationDatabase.missingSources(commands, among: clangSources)
        if commands.isEmpty {
            print("⚠ compile database: none — Objective-C, C and C++ stay outside the structural layer. Build one: `sextant index`")
        } else if missing.isEmpty {
            print("✅ compile database: \(commands.count) file(s), covering all \(clangSources.count) C-family source(s)")
        } else {
            print("⚠ compile database: \(missing.count) of \(clangSources.count) C-family source(s) have no flags (added since the last build?) — `sextant index`")
        }
    }

    // Which binary a shell would run. Not a fault of the setup, but a version answering that is
    // not the version installed is the kind of thing nobody thinks to check.
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    InstallationCheck.report(binaries: InstallationCheck.binaries(inPath: path),
                             running: launchURL().path).forEach { print($0) }

    // The half of the setup that lives outside this process. Everything above can be perfect while
    // no client is wired to any of it — which is exactly how the hook shipped, sat in no settings
    // file for ten days, and was never missed by a check-up that only ever asked about itself.
    if let mcp = ClientWiring.mcpRegistration(projectRoot: root) {
        if mcp.binaryExists {
            print("✅ MCP registered in \(mcp.source) → \(shorten(mcp.binary))")
        } else {
            print("❌ MCP registered in \(mcp.source) → \(mcp.binary), which is not an executable file")
            print("   the client starts nothing and says nothing — re-register: `sextant init --force`")
            ok = false
        }
    } else {
        print("· MCP not registered for this project — `sextant init` adds it to .mcp.json")
    }

    if let hook = ClientWiring.hookRegistration(projectRoot: root) {
        if !hook.binaryExists {
            print("❌ adoption hook in \(hook.source) → \(hook.binary), which is not an executable file")
            print("   it records nothing while looking installed — `sextant hook --install` prints the right snippet")
            ok = false
        } else if let last = AdoptionLog.lastRecordedAt() {
            print("✅ adoption hook in \(hook.source) → \(shorten(hook.binary)), last wrote \(StoreSelection.stamp(last))")
        } else {
            print("⚠ adoption hook in \(hook.source) → \(shorten(hook.binary)), but nothing has ever been recorded")
            print("   the entry may sit in a file this client does not read — check with `sextant adoption`")
        }
    } else {
        print("· adoption hook not installed (optional) — `sextant hook --install` prints the snippet")
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

    reportError(BuildTrust.xcodeNotice)
    print("▶ xcodebuild build -scheme \(scheme) -destination '\(destination)' (COMPILER_INDEX_STORE_ENABLE=YES)")
    // The log goes to a file, not the terminal: the compile flags appear only in full output,
    // which is thousands of lines, and that output is the only place Xcode states them.
    let logFile = IndexBuild.umbrellaDirectory(forRoot: root.path).appendingPathComponent("xcodebuild.log")
    try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    print("   build log: \(logFile.path)")
    let buildArgs = ["xcodebuild", "build", "-scheme", scheme, "-destination", destination,
                     "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO"] + containerFlag
    let status = Command.status("/usr/bin/env", buildArgs, in: root, loggingTo: logFile)
    guard status == 0 else {
        reportError("sextant index --app: xcodebuild failed (code \(status)). Check --scheme and --destination.")
        if let log = try? String(contentsOf: logFile, encoding: .utf8) {
            log.split(separator: "\n").suffix(15).forEach { reportError("   \($0)") }
        }
        return 1
    }
    if let store = DerivedDataLocator.dataStore(forProjectRoot: root.path,
                                                derivedData: derivedDataRoot(in: arguments)) {
        print("\nindex ready (app, DerivedData): \(store)")
        reportTestCoverage(ofStore: store, root: root.path, arguments: arguments, isXcode: true)
        // Xcode writes no build graph with arguments in it, so the flags are read from the log
        // the build just produced — the one place they are stated in full.
        let log = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        saveCompileDatabase(CompilationDatabase.commands(inXcodeLog: log), forRoot: root.path,
                            emptyReason: "no compile commands in the xcodebuild log (an incremental build compiles nothing — try `xcodebuild clean` first)")
        return 0
    }
    // An incremental build compiles nothing, and a build that compiles nothing writes no index
    // units — so a deleted or never-written store stays absent while the build reports success.
    // Observed on an Xcode project whose products were already built: `build succeeded` and no
    // store, twice in a row, with nothing in the output to say why.
    print("\nbuild succeeded, but no DerivedData index was found.")
    print("An incremental build compiles nothing and therefore indexes nothing: `xcodebuild clean`,")
    print("then run this again. If it is not that, the store is elsewhere — check WorkspacePath in")
    print("DerivedData, or pass --derived-data / --index-store.")
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
    reportError(BuildTrust.swiftPackageNotice)

    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let packageDirs = IndexStoreLocator.swiftPackages(under: root)
    guard !packageDirs.isEmpty else {
        reportError("sextant index: no SPM packages found under \(rootPath). For Xcode projects, build in Xcode (DerivedData) or pass --index-store.")
        return 1
    }

    // A single package is built directly, in a build tree of its own inside `.build`, where
    // IndexStoreLocator finds the store beside the ordinary ones.
    let testsBuilt = !arguments.contains("--no-tests")
    if packageDirs.count == 1 {
        let package = packageDirs[0]
        let scratch = IndexStoreLocator.indexBuildDirectory(ofPackage: package)
        let build = IndexBuild.swiftBuildArguments(scratchPath: scratch.path, buildTests: testsBuilt)
        print("▶ swift \(build.joined(separator: " ")): \(package.lastPathComponent)")
        let log = IndexBuild.buildLog(forRoot: rootPath)
        // Recorded before the build reads them: a file edited while it runs then reads as changed.
        let sources = captureSources(ofProject: rootPath)
        let status = runSwiftBuild(build, in: package, log: log)
        let built = IndexStoreLocator.storePaths(inBuildDirectory: scratch)
        let candidates = IndexStoreLocator.candidates(under: root)
        let store = candidates.first(where: { $0.isUsable && built.contains($0.path) })?.path
        if let store {
            recordSnapshot(store: store, root: rootPath, sources: sources, status: status,
                           testsBuilt: testsBuilt, log: log)
        }
        guard status == 0 else {
            reportError("sextant index: build failed (code \(status)).")
            if let store {
                reportError("   the store it left is marked as coming from a failed build: \(store)")
            }
            return 1
        }
        guard let store else {
            reportError("sextant index: the build succeeded, but it left no index store with units under \(scratch.path).")
            return 1
        }
        print("\nindex ready: \(store)")
        if StoreSelection.resolve(candidates, policy: storePolicy(in: arguments)?.policy).needsPolicy {
            reportError("⚠ this is one of \(candidates.filter(\.isUsable).count) usable index stores for this project, and no store policy is set —")
            reportError("   semantic commands will refuse rather than guess between them. `sextant store` compares them.")
        }
        reportTestCoverage(ofStore: store, root: rootPath, arguments: arguments, isXcode: false)
        captureCompileDatabase(root: rootPath, stores: [store], buildLog: log)
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

    let build = IndexBuild.swiftBuildArguments(scratchPath: IndexBuild.umbrellaBuildDirectory(forRoot: rootPath).path,
                                               buildTests: testsBuilt)
    print("▶ umbrella build (\(packages.count) packages, one pass): swift \(build.joined(separator: " "))")
    let log = IndexBuild.buildLog(forRoot: rootPath)
    let sources = captureSources(ofProject: rootPath)
    let status = runSwiftBuild(build, in: umbrella, log: log)
    let umbrellaStore = IndexBuild.umbrellaStorePath(forRoot: rootPath)
    if let umbrellaStore {
        recordSnapshot(store: umbrellaStore, root: rootPath, sources: sources, status: status,
                       testsBuilt: testsBuilt, log: log)
    }
    guard status == 0 else {
        reportError("sextant index: umbrella build failed (code \(status)).")
        return 1
    }
    guard let store = umbrellaStore else {
        reportError("sextant index: the umbrella build succeeded, but it left no index store with units under \(IndexBuild.umbrellaBuildDirectory(forRoot: rootPath).path).")
        return 1
    }
    print("\nindex ready (single store): \(store)")
    reportTestCoverage(ofStore: store, root: rootPath, arguments: arguments, isXcode: false)
    captureCompileDatabase(root: rootPath, stores: [store], buildLog: log)
    return 0
}

/// The sources as they are before a build, with a copy of every one git cannot give back later —
/// what was dirty, or everything outside git — so that an answer over the store can still be
/// mapped onto the sources once they change.
func captureSources(ofProject rootPath: String) -> Result<SourceSnapshot, SourceSnapshot.CaptureFailure> {
    let sources = IndexSnapshot.sources(ofProject: rootPath)
    if case .success(let snapshot) = sources {
        IndexedText.keepCopies(of: snapshot, projectRoot: rootPath)
    }
    return sources
}

/// Records what the store a build just left was built from, so that freshness can later be
/// judged by content. A snapshot that cannot be written is reported, not fatal: freshness then
/// falls back to build time and says so.
func recordSnapshot(store: String, root: String, sources captured: Result<SourceSnapshot, SourceSnapshot.CaptureFailure>,
                    status: Int32, testsBuilt: Bool, log: URL) {
    let sources: SourceSnapshot
    switch captured {
    case .success(let value):
        sources = value
    case .failure(let failure):
        reportError("⚠ sextant index: no snapshot of the sources was recorded (\(failure.reason)) — "
                    + "freshness will be judged by build time.")
        return
    }
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    guard let snapshot = IndexSnapshot.afterBuild(store: store, projectRoot: root, sources: sources,
                                                  exitStatus: status, testsBuilt: testsBuilt, buildLog: text,
                                                  toolchain: ToolchainIdentity.currentWithVersion()) else { return }
    do {
        try snapshot.save()
        IndexedText.prune()
    } catch {
        reportError("⚠ sextant index: the snapshot of the sources could not be written (\(error)) — "
                    + "freshness will be judged by build time.")
    }
}

// MARK: - Opening the index (shared helper)

/// With --reindex, rebuilds the index before the query. Returns false when the rebuild failed:
/// the query then has no index it asked for, and answering from the previous one would present
/// an old answer as a fresh one. Under `--json` the build's progress goes to stderr, so standard
/// output carries the JSON document alone.
func ensureFreshIndex(_ arguments: [String], label: String) -> Bool {
    guard arguments.contains("--reindex") else { return true }
    let status = arguments.contains("--json")
        ? OutputCapture.sendingOutputToStandardError { runIndex(arguments: arguments) }
        : runIndex(arguments: arguments)
    guard status == 0 else {
        reportError("sextant \(label): --reindex failed — not answering from the index that was there before the rebuild.")
        return false
    }
    return true
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

/// `quiet` подавляет сообщение об отсутствии стора: вызывающий сам объяснит, что именно
/// потеряно. Две строки об одном и том же читаются как две разные проблемы.
func openIndex(_ arguments: [String], label: String, listen: Bool = false, quiet: Bool = false) -> IndexStoreSet? {
    openIndexReporting(arguments, label: label, listen: listen, quiet: quiet)?.set
}

/// The index every symbol command answers from: the opened stores, stated against the sources as
/// they are now. The freshness report the label was printed from is the one the answer is mapped
/// by, so the label and the answer cannot disagree.
func openTranslatedIndex(_ arguments: [String], label: String) -> TranslatedIndex? {
    guard let (set, report) = openIndexReporting(arguments, label: label) else { return nil }
    return TranslatedIndex(set, drift: report.flatMap { IndexDrift(report: $0, projectRoot: projectRoot(in: arguments)) })
}

/// `openIndex`, together with the freshness report its label was printed from.
func openIndexReporting(_ arguments: [String], label: String, listen: Bool = false,
                        quiet: Bool = false) -> (set: IndexStoreSet, report: IndexFreshness.Report?)? {
    guard ensureFreshIndex(arguments, label: label) else { return nil }
    let (resolution, source) = resolveStores(in: arguments)
    let storePaths = resolution.chosen.map(\.path)
    guard !storePaths.isEmpty,
          let libraryPath = optionValue("--index-lib", in: arguments) ?? discoverIndexStoreLibrary() else {
        if !quiet {
            // Two different states, and they need two different sentences: nothing to read, or
            // several things to read and nobody has said which.
            if resolution.needsPolicy {
                StoreSelection.unsetPolicyRefusal(candidates: resolution.candidates, shorten: shorten).forEach(reportError)
            } else {
                reportError("sextant \(label): no index store found (sextant index / an Xcode build / --index-store).")
            }
        }
        return nil
    }
    // Provenance on stderr — the single place that marks source and freshness, which is what
    // keeps the tool from being quietly wrong.
    let provenance = indexProvenance(resolution, source: source, arguments: arguments)
    reportError(provenance.summary)
    // The decision itself, whenever there was one to make: how many stores were in reach, which
    // are being read, and what the others were left out for.
    if resolution.policy != nil || resolution.decidedByOwnStoreRule {
        StoreSelection.explanation(of: resolution, shorten: shorten).forEach(reportError)
    }
    // In the cache directory rather than /tmp: periodic cleanup of temporary files killed the
    // warm IndexStoreDB database and brought back the cold start (~2.1s instead of ~0.2s).
    let databaseRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/sextant/index-db").path
    let root = projectRoot(in: arguments)
    do {
        let set = try indexMemo.set(forKey: "\(storePaths.joined(separator: ":"))|\(libraryPath)|\(listen)|\(root)") {
            try IndexStoreSet(storePaths: storePaths, libraryPath: libraryPath, databaseRoot: databaseRoot, listenToUnitEvents: listen, projectRoot: root)
        }
        return (set, provenance.report)
    } catch {
        reportError("sextant \(label): could not open the index: \(error)")
        return nil
    }
}
