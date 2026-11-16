import Testing
@testable import SextantCore

@Suite("Construction sites")
struct ConstructionSiteTests {
    @Test("Swift and C++ call the type")
    func callShape() {
        #expect(ConstructionSite.isConstruction(line: "let a = Store(name: \"x\")", of: "Store", inFile: "A.swift"))
        #expect(ConstructionSite.isConstruction(line: "Widget w(4);", of: "Widget", inFile: "A.cpp") == false)
        #expect(ConstructionSite.isConstruction(line: "auto w = Widget(4);", of: "Widget", inFile: "A.cpp"))
    }

    @Test("Objective-C sends alloc or new to the class")
    func messageShape() {
        // The Swift shape never appears in Objective-C, so looking only for it returned nothing at
        // all — which reads as "nothing constructs this type".
        #expect(!ConstructionSite.isConstruction(line: "return [[Store alloc] init];", of: "Store", inFile: "A.swift"))
        #expect(ConstructionSite.isConstruction(line: "return [[Store alloc] init];", of: "Store", inFile: "A.m"))
        #expect(ConstructionSite.isConstruction(line: "Store *s = [Store new];", of: "Store", inFile: "A.mm"))
        #expect(!ConstructionSite.isConstruction(line: "[store save];", of: "Store", inFile: "A.m"))
    }

    @Test("A shape must start at a word boundary")
    func wordBoundary() {
        // `makeStore(` ends with `Store(`, and a substring match called that a construction site.
        #expect(!ConstructionSite.isConstruction(line: "Store makeStore(void);", of: "Store", inFile: "A.h"))
        #expect(!ConstructionSite.isConstruction(line: "let a = makeStore()", of: "Store", inFile: "A.swift"))
        #expect(ConstructionSite.isConstruction(line: "let a = makeStore() ?? Store()", of: "Store", inFile: "A.swift"))
    }

    @Test("A header belongs to either language, so it takes both shapes")
    func headerTakesBothShapes() {
        #expect(ConstructionSite.isConstruction(line: "#define MAKE_STORE [Store new]", of: "Store", inFile: "A.h"))
        #expect(ConstructionSite.isConstruction(line: "inline Store makeStore() { return Store(); }", of: "Store", inFile: "A.h"))
    }

    @Test("The heuristic is stated in the answer, per language")
    func describesItself() {
        #expect(ConstructionSite.description(of: "Store", inFile: "A.swift") == "`Store(`")
        #expect(ConstructionSite.description(of: "Store", inFile: "A.m") == "`[Store alloc]` or `[Store new]`")
    }

    @Test("A site is judged at the reference's column: two constructions on one line are two, a plain use beside one is none")
    func sitesAreJudgedAtTheirColumn() {
        let line = "    let v = Vec(x: 1, y: 2) <+> Vec(x: 3, y: 4) as Vec"
        #expect(ConstructionSite.isConstruction(line: line, column: 13, of: "Vec", inFile: "Use.swift"))
        #expect(ConstructionSite.isConstruction(line: line, column: 33, of: "Vec", inFile: "Use.swift"))
        #expect(!ConstructionSite.isConstruction(line: line, column: 52, of: "Vec", inFile: "Use.swift"))
        // Columns count UTF-16 code units: an emoji before the call takes two.
        let emoji = "let t = \"🙂\"; let v = Vec(x: 1)"
        #expect(ConstructionSite.isConstruction(line: emoji, column: 23, of: "Vec", inFile: "Use.swift"))
        // Objective-C: the bracket before the name the index points at.
        #expect(ConstructionSite.isConstruction(line: "return [[Store alloc] init];", column: 10, of: "Store", inFile: "A.m"))
        #expect(!ConstructionSite.isConstruction(line: "Store *s = [Store new];", column: 1, of: "Store", inFile: "A.m"))
        // Without a column, the line decides.
        #expect(ConstructionSite.isConstruction(line: line, column: nil, of: "Vec", inFile: "Use.swift"))
    }
}
