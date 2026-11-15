import Foundation
import Testing
@testable import SextantCore

@Suite("Index store selection")
struct DerivedDataLocatorTests {
    @Test("The glob includes the project name")
    func globContainsProject() {
        let glob = DerivedDataLocator.dataStoreGlob(projectName: "MyApp", home: "/Users/x")
        #expect(glob.contains("MyApp-*"))
        #expect(glob.hasSuffix("Index.noindex/DataStore"))
    }
}
