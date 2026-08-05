import Foundation
import Testing
@testable import SextantCore

/// `body` extracts a declaration given the line the index reports. Swift is parsed; the C family
/// is delimited textually, and these cover the cases where a naive delimiter returns something
/// plausible but wrong — which is worse than returning nothing.
@Suite("Declaration text for the C family")
struct CFamilySourceBodyTests {
    @Test("Objective-C container runs to @end, which has no closing brace at all")
    func objcContainer() {
        let source = """
        #import "X.h"

        @implementation OCGreeter

        - (NSString *)greet {
            return @"hi";
        }

        @end

        void after(void) {}
        """
        let body = SourceBody.delimitedDeclaration(atLine: 3, source: source)
        #expect(body?.hasPrefix("@implementation OCGreeter") == true)
        #expect(body?.hasSuffix("@end") == true)
        // Brace matching would have stopped at the method's `}` and cut the container short.
        #expect(body?.contains("return @\"hi\";") == true)
        #expect(body?.contains("void after") == false)
    }

    @Test("A C++ type keeps the trailing semicolon a Swift declaration would not have")
    func cxxTrailingSemicolon() {
        let source = """
        namespace n {
        struct Counter {
            int value;
        };
        }
        """
        #expect(SourceBody.delimitedDeclaration(atLine: 2, source: source) == "struct Counter {\n    int value;\n};")
    }

    @Test("A prototype without a body ends at its semicolon")
    func prototypeStopsAtSemicolon() {
        let source = """
        int c_double(int input);
        int other(int input) { return input; }
        """
        // Running on to the next line's braces would attach someone else's body to this name.
        #expect(SourceBody.delimitedDeclaration(atLine: 1, source: source) == "int c_double(int input);")
    }

    @Test("A brace inside a string, a char literal or a comment does not count")
    func bracesInLiteralsIgnored() {
        let source = """
        int f(int x) {
            const char *s = "{{{";
            char c = '{';
            /* } and { in a block comment */
            // } in a line comment
            return x;
        }
        int after(void) { return 0; }
        """
        let body = SourceBody.delimitedDeclaration(atLine: 1, source: source)
        #expect(body?.hasSuffix("return x;\n}") == true)
        #expect(body?.contains("int after") == false)
    }

    @Test("An escaped quote does not end the string early")
    func escapedQuote() {
        let source = """
        int f(void) {
            const char *s = "he said \\" } \\" and left";
            return 0;
        }
        """
        let body = SourceBody.delimitedDeclaration(atLine: 1, source: source)
        // Treating the escaped quote as a terminator would put the `}` back in play and end here.
        #expect(body?.hasSuffix("return 0;\n}") == true)
    }

    @Test("An unterminated declaration yields nothing rather than the rest of the file")
    func unterminatedYieldsNil() {
        #expect(SourceBody.delimitedDeclaration(atLine: 1, source: "int f(void) {\n    return 0;") == nil)
        #expect(SourceBody.delimitedDeclaration(atLine: 1, source: "@implementation X\n") == nil)
    }

    @Test("An out-of-range or blank line yields nothing")
    func outOfRange() {
        #expect(SourceBody.delimitedDeclaration(atLine: 99, source: "int f(void) {}") == nil)
        #expect(SourceBody.delimitedDeclaration(atLine: 1, source: "\nint f(void) {}") == nil)
    }
}
