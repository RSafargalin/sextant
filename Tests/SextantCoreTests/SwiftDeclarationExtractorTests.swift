import Testing
@testable import SextantCore

@Suite("Declaration extraction (SwiftSyntax)")
struct SwiftDeclarationExtractorTests {
    let source = """
    import Foundation

    public struct Event: Identifiable, Hashable {
        public let id: UUID
        private var secret: Int
        public func overlaps(_ other: Event) -> Bool { false }
    }

    enum Kind {
        case a, b
    }

    private func helper() {}
    """

    @Test("Finds a public type with inheritance")
    func findsPublicType() {
        let declarations = SwiftDeclarationExtractor.declarations(source: source)
        let event = declarations.first { $0.header.hasPrefix("struct Event") }
        #expect(event != nil)
        #expect(event?.access == .public)
        #expect(event?.header.contains("Identifiable, Hashable") == true)
    }

    @Test("Extracts type members with their access levels")
    func extractsMembers() {
        let declarations = SwiftDeclarationExtractor.declarations(source: source)
        let event = declarations.first { $0.header.hasPrefix("struct Event") }
        let function = event?.members.first { $0.kind == .function }
        #expect(function?.header.contains("overlaps") == true)
        #expect(function?.access == .public)
        let secret = event?.members.first { $0.header.contains("secret") }
        #expect(secret?.access == .private)
    }

    @Test("The default access level is internal")
    func defaultAccessIsInternal() {
        let declarations = SwiftDeclarationExtractor.declarations(source: source)
        let kind = declarations.first { $0.header.hasPrefix("enum Kind") }
        #expect(kind?.access == .internal)
    }

    @Test("Recognises a private top-level function")
    func detectsPrivateFunction() {
        let declarations = SwiftDeclarationExtractor.declarations(source: source)
        let helper = declarations.first { $0.header.contains("helper") }
        #expect(helper?.access == .private)
    }

    @Test("Members of a public extension inherit public")
    func publicExtensionMembersArePublic() {
        let declarations = SwiftDeclarationExtractor.declarations(source: "public extension Foo { func bar() {} }")
        let bar = declarations.first?.members.first { $0.header.contains("bar") }
        #expect(bar?.access == .public)
    }

    @Test("An explicit member modifier beats the extension default")
    func explicitMemberAccessWins() {
        let declarations = SwiftDeclarationExtractor.declarations(source: "public extension Foo { internal func baz() {} }")
        let baz = declarations.first?.members.first { $0.header.contains("baz") }
        #expect(baz?.access == .internal)
    }

    @Test("Members of a private extension inherit private and drop out of the map (access >= internal)")
    func privateExtensionMembersArePrivate() {
        let declarations = SwiftDeclarationExtractor.declarations(source: "private extension Foo { func qux() {} }")
        let qux = declarations.first?.members.first { $0.header.contains("qux") }
        #expect(qux?.access == .private)
    }

    @Test("Requirements of a public protocol inherit public")
    func publicProtocolRequirementsArePublic() {
        let declarations = SwiftDeclarationExtractor.declarations(source: "public protocol P { func fetch() }")
        let fetch = declarations.first?.members.first { $0.header.contains("fetch") }
        #expect(fetch?.access == .public)
    }

    @Test("Regression: members of a plain struct stay internal")
    func structMembersRemainInternal() {
        let declarations = SwiftDeclarationExtractor.declarations(source: "struct S { func f() {} }")
        let f = declarations.first?.members.first { $0.header.contains("f") }
        #expect(f?.access == .internal)
    }

    @Test("Regression: a nested type in a public extension is public, but its members are internal")
    func nestedTypeInPublicExtension() {
        let declarations = SwiftDeclarationExtractor.declarations(source: "public extension Foo { struct Bar { let x: Int } }")
        let bar = declarations.first?.members.first { $0.header.hasPrefix("struct Bar") }
        #expect(bar?.access == .public)
        let x = bar?.members.first { $0.header.contains("x") }
        #expect(x?.access == .internal)
    }
}
