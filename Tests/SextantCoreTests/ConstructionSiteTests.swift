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
}
