import Testing
@testable import SextantCore

@Suite("Tool metadata")
struct SextantTests {
    @Test("Version is non-empty and semver-shaped")
    func versionIsPresent() {
        #expect(!Sextant.version.isEmpty)
        #expect(Sextant.version.split(separator: ".").count == 3)
    }

    @Test("The description states what the tool is for")
    func aboutMentionsPurpose() {
        #expect(Sextant.about.contains("code intelligence"))
    }
}
