import Foundation
import Testing
@testable import SextantCore

@Suite("Public API")
struct PublicAPITests {
    @Test("Shows only public, hides internal and private")
    func showsOnlyPublic() {
        let summaries = [
            FileSummary(relativePath: "A.swift", package: "Pkg", declarations: [
                Declaration(kind: .structKind, header: "struct PublicType", access: .public, members: [
                    Declaration(kind: .function, header: "func open()", access: .public),
                    Declaration(kind: .function, header: "func hidden()", access: .private)
                ]),
                Declaration(kind: .structKind, header: "struct InternalType", access: .internal)
            ])
        ]
        let output = PublicAPI.render(summaries)
        #expect(output.contains("PublicType"))
        #expect(output.contains("func open()"))
        #expect(!output.contains("InternalType"))
        #expect(!output.contains("hidden"))
    }

    @Test("A type filter matching nothing names the type instead of printing an empty surface")
    func missingTypeIsNamed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-api-type-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Geo"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "// swift-tools-version: 5.9\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public final class Square {}\nstruct Hidden {}\n"
            .write(to: root.appendingPathComponent("Sources/Geo/S.swift"), atomically: true, encoding: .utf8)
        #expect(PublicAPI.generate(projectRoot: root.path, package: nil, type: "Square").contains("final class Square"))
        for missing in ["Nope", "Hidden"] {
            let answer = PublicAPI.generate(projectRoot: root.path, package: nil, type: missing)
            #expect(answer == PublicAPI.missingType(missing))
            #expect(!answer.contains("declarations: 0"))
        }
        #expect(PublicAPI.unknownPackage("Nope", root: root.path)?.hasPrefix("no package named 'Nope'. Known:") == true)
    }

    @Test("Shows a type with public members inside an internal extension")
    func showsPublicMembersInExtension() {
        let summaries = [
            FileSummary(relativePath: "B.swift", package: "Pkg", declarations: [
                Declaration(kind: .extensionKind, header: "extension Foo", access: .internal, members: [
                    Declaration(kind: .function, header: "func exposed()", access: .public)
                ])
            ])
        ]
        let output = PublicAPI.render(summaries)
        #expect(output.contains("extension Foo"))
        #expect(output.contains("exposed"))
    }

    @Test("Prints members of a public extension and requirements of a public protocol")
    func rendersPublicExtensionAndProtocolMembers() {
        let source = """
        public extension Foo {
            func bar() {}
        }

        public protocol P {
            func fetch()
        }
        """
        let declarations = SwiftDeclarationExtractor.declarations(source: source)
        let summaries = [FileSummary(relativePath: "C.swift", package: "Pkg", declarations: declarations)]
        let output = PublicAPI.render(summaries)
        #expect(output.contains("extension Foo"))
        #expect(output.contains("bar"))
        #expect(output.contains("protocol P"))
        #expect(output.contains("fetch"))
    }
}
