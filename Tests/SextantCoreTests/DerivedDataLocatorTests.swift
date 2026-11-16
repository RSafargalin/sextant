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

    /// Regression: `xcodebuild -derivedDataPath <dir>` writes `info.plist` and `Index.noindex` into
    /// `<dir>` itself, and only `<dir>/<entry>/info.plist` was looked at.
    @Test("A store built with -derivedDataPath is found in that directory itself, as well as per project")
    func findsBothLayouts() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-dd-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        let project = base.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        func store(in directory: URL) throws {
            let units = directory.appendingPathComponent("Index.noindex/DataStore/v5/units")
            try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
            try Data("u".utf8).write(to: units.appendingPathComponent("main.o-HASH"))
            let info: NSDictionary = ["WorkspacePath": project.appendingPathComponent("App.xcodeproj").path]
            try info.write(to: directory.appendingPathComponent("info.plist"))
        }
        let direct = base.appendingPathComponent("direct")
        try store(in: direct)
        let found = DerivedDataLocator.candidates(forProjectRoot: project.path, derivedData: direct.path)
        #expect(found.map(\.path) == [direct.path + "/Index.noindex/DataStore"])

        let xcode = base.appendingPathComponent("xcode")
        try store(in: xcode.appendingPathComponent("App-abc"))
        #expect(DerivedDataLocator.candidates(forProjectRoot: project.path, derivedData: xcode.path).count == 1)
    }
}
