import Foundation
import Testing
@testable import SextantCore

/// End-to-end: builds a miniature fixture package with an index store and exercises real semantic
/// queries (defs/refs/impls) through IndexStoreDB. It closes a gap: the semantic core used to be
/// verified only by manual dogfooding.
@Suite("Integration: IndexStore on a fixture", .serialized)
struct IndexStoreIntegrationTests {
    private static var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SextantCoreTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/IndexFixture")
    }

    @Test("build → defs/refs/impls against a real index store")
    func endToEnd() throws {
        let fixture = Self.fixture
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("Package.swift").path) else { return }
        guard let swiftc = run("/usr/bin/xcrun", ["--find", "swiftc"]) else { return }
        let library = (swiftc as NSString).deletingLastPathComponent.replacingOccurrences(of: "/bin", with: "/lib") + "/libIndexStore.dylib"
        guard FileManager.default.fileExists(atPath: library) else { return }

        _ = run("/usr/bin/env", ["swift", "build", "--enable-index-store", "--package-path", fixture.path])

        let build = fixture.appendingPathComponent(".build")
        var storePath: String?
        for triple in (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? [] {
            let candidate = build.appendingPathComponent("\(triple)/debug/index/store").path
            if FileManager.default.fileExists(atPath: candidate) { storePath = candidate }
        }
        let store = try #require(storePath, "the index store was not built")

        let databasePath = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-fixture-\(UUID().uuidString)").path
        let index = try IndexStore(storePath: store, libraryPath: library, databasePath: databasePath)

        // defs: the EnglishGreeter type
        #expect(index.lookup(name: "EnglishGreeter", query: .definitions).contains { $0.name == "EnglishGreeter" })
        // impls: implementations of the Greeter protocol include EnglishGreeter
        #expect(index.related(toName: "Greeter", query: .implementations).contains { $0.name == "EnglishGreeter" })
        // refs: EnglishGreeter has at least one reference (defaultGreeter = EnglishGreeter())
        #expect((index.lookup(name: "EnglishGreeter", query: .references).first?.references.count ?? 0) >= 1)

        // Bare-name method resolution: greet is both a protocol requirement and an implementation
        // (the index stores it with labels as `greet()`, so a bare name never matches exactly).
        #expect(index.lookup(name: "greet", query: .definitions).contains { $0.name.hasPrefix("greet") })

        // Cross-language resolution. The index is written by the whole clang family, not just
        // swiftc, so Objective-C declarations are in the same store — and a Swift call site
        // resolves to the Objective-C symbol it actually calls.
        //
        // The naming convention differs per language, which is the part that used to break:
        // Objective-C methods are stored as selectors (`ocGreetWithName:`), so neither an exact
        // match nor Swift's `name(` shape finds them by their bare name.
        let objcClass = index.lookup(name: "OCGreeter", query: .definitions)
        #expect(objcClass.contains { $0.definition?.path.hasSuffix(".m") == true },
                "an Objective-C class must resolve to its .m implementation")
        #expect((index.lookup(name: "OCGreeter", query: .references).first?.references.count ?? 0) >= 1,
                "the Swift call site references the Objective-C class")

        // No arguments — the selector equals the bare name, so this worked before the fix too.
        #expect(index.lookup(name: "ocDefaultCount", query: .definitions).contains { $0.name == "ocDefaultCount" })

        // Regression guard for the selector clause: with arguments the stored name carries a
        // colon, and the bare name resolved to nothing at all before it was added.
        let selector = index.lookup(name: "ocGreetWithName", query: .definitions)
        #expect(selector.contains { $0.name.hasPrefix("ocGreetWithName") },
                "a bare Objective-C method name must resolve to its selector")
        let objcCallers = index.lookup(name: "ocGreetWithName", query: .callers)
        #expect((objcCallers.first?.references.count ?? 0) >= 1,
                "a Swift call spelled ocGreet(withName:) must be found as a caller of the selector")

        // The three relation queries, on symbols where they have an answer. Asking them of a
        // class returns nothing — correctly so, and that empty result was once mistaken for a gap.
        let conformers = index.related(toName: "OCFeeding", query: .implementations)
        #expect(conformers.contains { $0.name == "OCGreeter" } && conformers.contains { $0.name == "OCFeeder" },
                "an Objective-C protocol must list its conformers, as a Swift protocol does")
        #expect(index.related(toName: "OCGreeter", query: .implementations).isEmpty,
                "a class is not a protocol: no implementations, and that is the right answer")

        // Objective-C calling Objective-C: an edge that does not cross the language boundary.
        let callees = index.related(toName: "ocFeedTwice", query: .callees)
        #expect(callees.contains { $0.name.hasPrefix("ocFeed") },
                "ocFeedTwice calls ocFeed, and the index records it")

        // Documenting actual behaviour: SDK symbols do not resolve by name in a project store
        // (only Reference roles exist), so the result is empty. A fallback anchor cannot be a call site.
        #expect(index.lookup(name: "String", query: .references).isEmpty)
        #expect(index.lookup(name: "String", query: .definitions).isEmpty)

        // symbolNames: resource-template completion by prefix (bare name, within scope).
        #expect(index.symbolNames(matchingPrefix: "Engl").contains("EnglishGreeter"))
        #expect(index.symbolNames(matchingPrefix: "Zzz").isEmpty)
        #expect(index.symbolNames(matchingPrefix: "E").isEmpty)   // a short prefix is rejected (scan guard)

        // The context pack: definition plus hierarchy in a single query
        let context = try #require(index.context(forName: "EnglishGreeter"))
        #expect(context.kinds.contains("struct"))
        #expect(!context.definitions.isEmpty)
        #expect(context.supertypes.contains { $0.name == "Greeter" })
        #expect(index.context(forName: "NoSuchSymbol") == nil)

        // The golden spec (deterministic tier): every assertion passes on the fixture.
        let goldenPath = fixture.appendingPathComponent("golden.json")
        let goldenData = try #require(FileManager.default.contents(atPath: goldenPath.path), "golden.json not found")
        let spec = try JSONDecoder().decode(GoldenSpec.self, from: goldenData)
        let set = try IndexStoreSet(
            storePaths: [store], libraryPath: library,
            databaseRoot: FileManager.default.temporaryDirectory.appendingPathComponent("sextant-golden-\(UUID().uuidString)").path
        )
        for result in Golden.evaluate(spec, against: set) {
            #expect(result.passed, "golden failure: [\(result.query)] \(result.symbol) — \(result.detail)")
        }

        // blast_radius: the impact of EnglishGreeter includes the file that uses it.
        let radius = try #require(set.blastRadius(forName: "EnglishGreeter"))
        #expect(radius.affectedFiles.contains { $0.hasSuffix("Code.swift") })
        #expect(radius.referenceCount >= 1)
    }

    private func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
