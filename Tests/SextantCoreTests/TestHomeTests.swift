import Foundation
import Testing
import TestHome

/// The test process runs with a home of its own, set before any test starts: tests used to write
/// compile databases, declaration caches and logs into the real `~/Library/Caches/sextant`.
@Suite("Test home")
struct TestHomeTests {
    @Test("Every test, and every process a test starts, sees the isolated home")
    func homeIsIsolated() throws {
        let home = String(cString: sextant_test_home())
        try #require(!home.isEmpty, "the isolated home could not be created")
        #expect(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == home)
        let seen = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        #expect(seen == URL(fileURLWithPath: home).resolvingSymlinksInPath().path)
    }
}
