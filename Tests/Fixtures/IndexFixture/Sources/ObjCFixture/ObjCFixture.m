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

@implementation OCGreeter (Shouting)

- (NSString *)ocShoutWithName:(NSString *)name {
    return [[self ocGreetWithName:name] uppercaseString];
}

@end

@implementation OCFeeder

- (NSInteger)ocFeed {
    return 2;
}

- (NSInteger)ocFeedTwice {
    return [self ocFeed] + [self ocFeed];
}

- (OCFeeder *)ocTwin {
    return [[OCFeeder alloc] init];
}

@end
