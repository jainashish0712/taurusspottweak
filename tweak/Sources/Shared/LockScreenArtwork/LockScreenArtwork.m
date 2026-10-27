#import <MediaPlayer/MediaPlayer.h>
#import "LockScreenArtwork.h"

NSString *const SGArtworkSourceSpotify = @"spotify";
NSString *const SGArtworkSourceApple = @"applemusic";

NSArray<NSString *> *SGArtworkOrder(void) {
    id stored = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyLockScreenArtworkSources];
    NSArray *keys = [stored isKindOfClass:NSArray.class] ? stored : @[SGArtworkSourceApple, SGArtworkSourceSpotify];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (id key in keys) {
        BOOL known = [key isEqual:SGArtworkSourceSpotify] || [key isEqual:SGArtworkSourceApple];
        if (known && ![order containsObject:key]) [order addObject:key];
    }
    return order;
}

void SGArtworkSetOrder(NSArray<NSString *> *order) {
    [NSUserDefaults.standardUserDefaults setObject:order ?: @[] forKey:SGKeyLockScreenArtworkSources];
}

BOOL SGAnimatedArtworkAvailable(void) {
    return NSClassFromString(@"MPMediaItemAnimatedArtwork") != nil;
}

NSArray<NSString *> *SGAnimatedArtworkKeys(void) {
    if ([MPNowPlayingInfoCenter respondsToSelector:@selector(supportedAnimatedArtworkKeys)])
        return MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys;
    return nil;
}

NSString *SGAnimatedArtworkKey(CGFloat *aspect) {
    NSArray<NSString *> *supported = SGAnimatedArtworkKeys();
    if (!supported.count) return nil;
    if ([supported containsObject:MPNowPlayingInfoProperty3x4AnimatedArtwork]) {
        if (aspect) *aspect = 3.0 / 4.0;
        return MPNowPlayingInfoProperty3x4AnimatedArtwork;
    }
    if ([supported containsObject:MPNowPlayingInfoProperty1x1AnimatedArtwork]) {
        if (aspect) *aspect = 1;
        return MPNowPlayingInfoProperty1x1AnimatedArtwork;
    }
    return nil;
}

NSDictionary *SGArtworkInInfo(NSDictionary *info, id artwork, NSString *key) {
    if (!info.count || !artwork || !key.length) return info;
    if (info[key] == artwork) return info;
    NSMutableDictionary *shown = [info mutableCopy];
    shown[key] = artwork;
    return shown;
}
