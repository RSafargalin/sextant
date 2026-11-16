import Foundation
import Testing
@testable import SextantCore

/// A property is never called itself — its getter and setter are. Its callers are the callers of
/// its accessors, said as such; and an accessor's own name, `getter:area`, is written in source as
/// its property's.
@Suite("Property callers")
struct PropertyCallerTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/IndexFixture")
    static var ready: Bool { BuildProducts.indexStore(under: fixture) != nil && BuildProducts.indexStoreLibrary != nil }

    private static func render(_ hits: [SymbolHit], symbol: String, compact: Bool) -> SymbolReport.Rendering {
        SymbolReport.lookup(symbol: symbol, hits: hits, query: .callers,
                            style: .cli(compact: compact, referenceLimit: 50), path: { $0 }) { location in
            let lines = (try? String(contentsOfFile: location.path, encoding: .utf8))?.components(separatedBy: "\n") ?? []
            return location.line <= lines.count ? lines[location.line - 1] : nil
        }
    }

    @Test("An accessor is written as its property; a selector or a labelled method is not an accessor")
    func accessorNamesAreWrittenAsTheirProperty() {
        #expect(SymbolName.written("getter:area") == "area")
        #expect(SymbolName.written("setter:opacity") == "opacity")
        #expect(SymbolName.written("getter:subscript(_:)") == "subscript")
        #expect(SymbolName.written("save(_:)") == "save")
        #expect(SymbolName.written("save:") == "save")
        #expect(SymbolName.written("didSet:") == "didSet")
        #expect(SymbolName.written("setValue:forKey:") == "setValue")
        #expect(SymbolName.accessorKind(of: "getter:area") == "getter")
        #expect(SymbolName.accessorKind(of: "init(x:)") == nil)
        #expect(SymbolName.accessorKind(of: "didSet:") == nil)
    }

    @Test("The callers of a computed property are the calls of its getter, and say so",
          .enabled(if: PropertyCallerTests.ready, "needs the fixture's index store — run `make fixture`"))
    func propertyCallersAreAccessorCalls() throws {
        let store = try #require(BuildProducts.indexStore(under: Self.fixture))
        let library = try #require(BuildProducts.indexStoreLibrary)
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-property-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: database) }
        let index = try IndexStore(storePath: store, libraryPath: library, databasePath: database.path)

        // `let viaProtocol: Greeter = defaultGreeter` in Code.swift reads the property: one call of its getter.
        let hits = index.lookup(name: "defaultGreeter", query: .callers)
        let hit = try #require(hits.first, "\(hits)")
        #expect(hit.references.count == 1, "\(hit.references)")
        #expect(hit.references.first?.path.hasSuffix("Code.swift") == true)
        #expect(hit.accessors == ["getter"])
        let rendered = Self.render(hits, symbol: "defaultGreeter", compact: true)
        #expect(rendered.lines.contains { $0.contains("calls (of its getter): 1") }, "\(rendered.lines)")

        // A property's references are an answer of their own and carry no accessor note.
        #expect(index.lookup(name: "defaultGreeter", query: .references).allSatisfy { $0.accessors == nil })

        // The getter asked for by its own name: its call line holds `defaultGreeter`, so nothing is withheld.
        let getter = index.lookup(name: "getter:defaultGreeter", query: .callers)
        #expect(getter.first?.references.count == 1, "\(getter)")
        let gotten = Self.render(getter, symbol: "getter:defaultGreeter", compact: false)
        #expect(gotten.advisory?.contains("withheld") != true, "\(gotten.advisory ?? "")")
    }
}
