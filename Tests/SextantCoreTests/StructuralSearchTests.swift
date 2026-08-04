import Testing
@testable import SextantCore

@Suite("Structural search")
struct StructuralSearchTests {
    @Test("Matches try? $X.save() and ignores non-matches")
    func matchesTryOptionalSave() throws {
        let search = try PatternSearch(pattern: "try? $X.save()")
        let source = """
        func a() { try? context.save() }
        func b() { try? self.store.save() }
        func c() { context.save() }
        func d() { try? context.fetch() }
        """
        let matches = search.search(source: source, fileName: "X.swift")
        #expect(matches.count == 2)
    }

    @Test("A metavariable binds consistently")
    func metavariableConsistency() throws {
        let search = try PatternSearch(pattern: "$X == $X")
        let source = "let a = (x == x)\nlet b = (x == y)"
        let matches = search.search(source: source, fileName: "X.swift")
        #expect(matches.count == 1)
    }

    @Test("Matches member access regardless of the receiver")
    func matchesMemberAccess() throws {
        let search = try PatternSearch(pattern: "$X.current")
        let source = "let a = Calendar.current\nlet b = TimeZone.current\nlet c = foo.other"
        let matches = search.search(source: source, fileName: "X.swift")
        #expect(matches.count == 2)
    }

    @Test("Statement pattern: guard $X else { return }")
    func matchesStatementPattern() throws {
        let search = try PatternSearch(pattern: "guard $X else { return }")
        let source = """
        func f() { guard ok else { return } }
        func g() { guard bad else { fatalError() } }
        """
        let matches = search.search(source: source, fileName: "X.swift")
        #expect(matches.count == 1)
    }

    @Test("An over-broad pattern ($X) is rejected")
    func rejectsBarePattern() {
        #expect(throws: PatternSearch.Failure.self) {
            _ = try PatternSearch(pattern: "$X")
        }
    }
}
