import Foundation
import Testing
@testable import SextantCore

@Suite("Index store selection")
struct DerivedDataLocatorTests {
    @Test("Returns the freshest by mtime")
    func picksFreshest() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let result = DerivedDataLocator.freshest(from: [
            (path: "/old/DataStore", modified: old),
            (path: "/new/DataStore", modified: new)
        ])
        #expect(result == "/new/DataStore")
    }

    @Test("An empty list gives nil")
    func emptyIsNil() {
        #expect(DerivedDataLocator.freshest(from: []) == nil)
    }

    @Test("The glob includes the project name")
    func globContainsProject() {
        let glob = DerivedDataLocator.dataStoreGlob(projectName: "MyApp", home: "/Users/x")
        #expect(glob.contains("MyApp-*"))
        #expect(glob.hasSuffix("Index.noindex/DataStore"))
    }
}
