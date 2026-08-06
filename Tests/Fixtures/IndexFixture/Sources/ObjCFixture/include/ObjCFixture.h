#import <Foundation/Foundation.h>

/// A protocol with two conformers. `impls` has to find both, the way it does for a Swift protocol
/// — the conformance is recorded by clang, not by SwiftSyntax.
@protocol OCFeeding <NSObject>
- (NSInteger)ocFeed;
@end

/// Objective-C surface used from Swift. It exists so the semantic layer is exercised across a
/// language boundary: the index stores these under Objective-C spellings (`ocGreetWithName:`),
/// while the Swift call site reads `ocGreet(withName:)`.
@interface OCGreeter : NSObject <OCFeeding>
- (NSString *)ocGreetWithName:(NSString *)name;
+ (NSInteger)ocDefaultCount;
- (NSInteger)ocFeed;
@end

/// A second conformer whose `ocFeedTwice` calls `ocFeed`, giving `callees` and `hierarchy`
/// an edge to traverse inside Objective-C rather than across the language boundary.
@interface OCFeeder : NSObject <OCFeeding>
- (NSInteger)ocFeed;
- (NSInteger)ocFeedTwice;
@end

/// A category: a method attached to a class declared elsewhere. Swift has no equivalent that
/// crosses a file this way, so the question is whether resolution finds the method at all and
/// whether it lands under the class it extends.
@interface OCGreeter (Shouting)
- (NSString *)ocShoutWithName:(NSString *)name;
@end
