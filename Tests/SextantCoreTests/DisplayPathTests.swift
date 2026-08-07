import Foundation
import Testing
@testable import SextantCore

/// How a path is shown decides whether a reader can act on it. Keeping the last three components
/// made the prefix depend on how deep the project sits, so two files from one project came back
/// looking unrelated and neither could be opened.
@Suite("Display paths")
struct DisplayPathTests {
    @Test("A file inside the project is shown relative to it")
    func relativeInsideTheProject() {
        #expect(DisplayPath.of("/w/alamofire/Source/Alamofire.swift", root: "/w/alamofire")
                == "Source/Alamofire.swift")
        #expect(DisplayPath.of("/w/alamofire/Source/Core/Session.swift", root: "/w/alamofire")
                == "Source/Core/Session.swift")
        // The same two files used to differ by prefix: `alamofire/Source/Alamofire.swift` against
        // `Source/Core/Session.swift`, purely because of how many components each had.
    }

    @Test("A trailing slash on the root changes nothing")
    func rootSpelling() {
        #expect(DisplayPath.of("/w/p/A.swift", root: "/w/p/") == "A.swift")
        #expect(DisplayPath.of("/w/p/A.swift", root: "/w/p") == "A.swift")
    }

    @Test("A file outside the project keeps a tail, marked as one")
    func tailOutsideTheProject() {
        // An SDK header or a dependency checkout: the beginning of the path says nothing, but the
        // result must not look like a relative path inside the project either.
        let shown = DisplayPath.of("/Applications/Xcode.app/Contents/Developer/SDKs/Foundation.h", root: "/w/p")
        #expect(shown.hasPrefix("…/"))
        #expect(shown.hasSuffix("Developer/SDKs/Foundation.h"))
    }

    @Test("Without a root there is only the tail")
    func noRoot() {
        #expect(DisplayPath.of("/a/b/c/d/e.swift", root: nil) == "…/c/d/e.swift")
        #expect(DisplayPath.of("short.swift", root: nil) == "short.swift")
    }
}
