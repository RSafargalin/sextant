#import "ObjCFixture.h"

@implementation OCGreeter

- (NSString *)ocGreetWithName:(NSString *)name {
    return [NSString stringWithFormat:@"hello %@", name];
}

+ (NSInteger)ocDefaultCount {
    return 3;
}

@end
