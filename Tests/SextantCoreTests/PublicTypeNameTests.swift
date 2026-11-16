import Testing
@testable import SextantCore

/// The name a command looks a declaration up by comes from the declaration, not from its rendered
/// header: a header carries modifiers and generic clauses, and reading the word after the first
/// space named `final class Square` "class".
@Suite("Public type names")
struct PublicTypeNameTests {
    static let source = """
    public final class FinalBox {}
    open class OpenBase {}
    @MainActor public final class MainBox {}
    public indirect enum Tree { case leaf, node(Tree) }
    public distributed actor Remote {}
    nonisolated public struct Detached {}
    package struct PackageLevel {}
    public struct Generic<Element: Equatable>: Sequence where Element: Hashable {}
    public final class GenericFinal<T> {}
    public struct `class` {}
    public protocol Shape {}
    public actor Counter {}
    """

    @Test("Every public type keeps its name whatever modifiers, attributes and generics it has")
    func publicTypesAreNamedByTheDeclaration() {
        let declarations = SwiftDeclarationExtractor.declarations(source: Self.source)
        let summaries = [FileSummary(relativePath: "T.swift", package: "P", declarations: declarations)]
        let types = RepoMap.publicTypes(in: summaries)
        #expect(types.map(\.name) == ["FinalBox", "OpenBase", "MainBox", "Tree", "Remote", "Detached",
                                      "Generic", "GenericFinal", "class", "Shape", "Counter"])
        #expect(types.map(\.kind) == [.classKind, .classKind, .classKind, .enumKind, .actorKind, .structKind,
                                      .structKind, .classKind, .structKind, .protocolKind, .actorKind])
        // `package` is not public: it stays off a map of public types.
        #expect(!types.contains { $0.name == "PackageLevel" })
    }
}
