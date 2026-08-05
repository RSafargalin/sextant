#import "ObjCFixture.h"

@implementation OCGreeter

- (NSString *)ocGreetWithName:(NSString *)name {
    return [NSString stringWithFormat:@"hello %@", name];
}

+ (NSInteger)ocDefaultCount {
    return 3;
}

- (NSInteger)ocFeed {
    return 1;
}

@end

@implementation OCFeeder

- (NSInteger)ocFeed {
    return 2;
}

- (NSInteger)ocFeedTwice {
    return [self ocFeed] + [self ocFeed];
}

@end
