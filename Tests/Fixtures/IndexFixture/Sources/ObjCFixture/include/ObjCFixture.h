#import <Foundation/Foundation.h>

/// Objective-C surface used from Swift. It exists so the semantic layer is exercised across a
/// language boundary: the index stores these under Objective-C spellings (`ocGreetWithName:`),
/// while the Swift call site reads `ocGreet(withName:)`.
@interface OCGreeter : NSObject
- (NSString *)ocGreetWithName:(NSString *)name;
+ (NSInteger)ocDefaultCount;
@end
