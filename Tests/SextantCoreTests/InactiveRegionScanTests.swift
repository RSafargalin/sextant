import Foundation
import Testing
@testable import SextantCore

/// Code inside an `#if` branch the build does not contain cannot be answered for structurally —
/// it never reaches the tree. These cover the textual fallback that keeps such code from being
/// silently absent from an answer.
@Suite("Inactive regions")
struct InactiveRegionScanTests {
    private let source = """
    - (void)always { [self reload]; }
    #if TARGET_OS_IPHONE
    - (void)onPhone { [self reload]; }
    - (void)reloadLater { }
    #endif
    """

    /// The `#if` body, as clang would report it: from the directive to the `#endif`.
    private var skipped: Range<Int> {
        let text = source
        let start = text.range(of: "#if")!.lowerBound
        let end = text.range(of: "#endif")!.upperBound
        return text.utf8.distance(from: text.utf8.startIndex, to: start.samePosition(in: text.utf8)!)
            ..< text.utf8.distance(from: text.utf8.startIndex, to: end.samePosition(in: text.utf8)!)
    }

    @Test("Only lines inside the skipped range are reported")
    func staysInsideTheSkippedRange() {
        let hits = InactiveRegionScan.occurrences(anchors: ["reload"], source: Data(source.utf8), ranges: [skipped])
        // Line 1 is compiled — the structural answer already covers it and must not be repeated.
        #expect(hits.map { $0.line } == [3])
        #expect(hits.first?.text == "- (void)onPhone { [self reload]; }")
    }

    @Test("An anchor must match a whole identifier")
    func respectsWordBoundaries() {
        // `reloadLater` is not an occurrence of `reload`, textual tier or not.
        let hits = InactiveRegionScan.occurrences(anchors: ["reload"], source: Data(source.utf8), ranges: [skipped])
        #expect(!hits.contains { $0.text.contains("reloadLater") })
    }

    @Test("Every anchor has to be present")
    func requiresAllAnchors() {
        #expect(InactiveRegionScan.occurrences(anchors: ["reload", "missing"],
                                               source: Data(source.utf8), ranges: [skipped]).isEmpty)
    }

    @Test("A pattern made only of metavariables says nothing textual")
    func withoutAnchorsReportsNothing() {
        // `$X * $X` spells out no identifier; guessing from text would report everything.
        #expect(InactiveRegionScan.occurrences(anchors: [], source: Data(source.utf8), ranges: [skipped]).isEmpty)
    }

    @Test("No skipped ranges means nothing to report")
    func withoutRangesReportsNothing() {
        #expect(InactiveRegionScan.occurrences(anchors: ["reload"], source: Data(source.utf8), ranges: []).isEmpty)
    }
}

@Suite("Word boundaries")
struct WordBoundaryTests {
    @Test("An identifier does not match inside a longer one")
    func identifierNeedle() {
        #expect(WordBoundary.contains("ocFeed", in: "return [self ocFeed];"))
        #expect(!WordBoundary.contains("ocFeed", in: "- (NSInteger)ocFeedOnPhone {"))
        #expect(!WordBoundary.contains("ocFeed", in: "[self superOcFeed]"))
    }

    @Test("A needle ending in punctuation needs no boundary after it")
    func punctuationNeedle() {
        #expect(WordBoundary.contains("Store(", in: "let a = Store(name: x)"))
        #expect(!WordBoundary.contains("Store(", in: "let a = makeStore(name: x)"))
        #expect(WordBoundary.contains("[Store alloc]", in: "return [[Store alloc] init];"))
    }
}
