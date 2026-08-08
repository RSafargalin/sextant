import XCTest
@testable import SextantCore

/// The notices are the only place a caller learns that one command runs foreign code, so they are
/// held to the measurement rather than to whatever prose survives the next edit.
final class BuildTrustTests: XCTestCase {
    func testSwiftPackageNoticeMatchesWhatWasMeasured() {
        let notice = BuildTrust.swiftPackageNotice
        XCTAssertFalse(BuildTrust.swiftPM.networkFromManifest)
        XCTAssertFalse(BuildTrust.swiftPM.writeToHome)
        XCTAssertTrue(BuildTrust.swiftPM.readHome, "a manifest reads the home directory — the notice must not promise otherwise")
        XCTAssertTrue(notice.contains("no network"))
        XCTAssertTrue(notice.contains("read it"), "the notice claims a protection it does not have if it omits the read")
    }

    /// The Xcode path has no sandbox at all, and saying the same thing for both would be a lie
    /// about the more dangerous one.
    func testXcodeNoticeDoesNotClaimASandbox() {
        XCTAssertTrue(BuildTrust.xcodeNotice.contains("no sandbox"))
        XCTAssertNotEqual(BuildTrust.xcodeNotice, BuildTrust.swiftPackageNotice)
    }

    /// Both notices have to name the way out, otherwise they are a warning without an alternative.
    func testBothNoticesOfferTheWayThatRunsNothing() {
        for notice in [BuildTrust.swiftPackageNotice, BuildTrust.xcodeNotice] {
            XCTAssertTrue(notice.contains("--no-build"), "a notice that offers no alternative only teaches the reader to ignore it")
        }
        XCTAssertTrue(BuildTrust.summary.contains("--no-build"))
    }

    /// An agent decides from the tool description, and every description that sends it to `index`
    /// has to say that `index` builds.
    func testToolDescriptionsThatSendTheAgentToIndexSayItBuilds() {
        let sending = MCPTools.definitions()
            .compactMap { $0["description"] as? String }
            .filter { $0.contains("sextant index") }
        XCTAssertFalse(sending.isEmpty)
        for description in sending {
            XCTAssertTrue(description.contains("RUNS the project's build"),
                          "a description sends the agent to run a build without saying so")
        }
    }
}
