#import "Core/SGCore.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Haptics/Haptics.h"
#import "Player.h"
#import "SGRStemsViewController.h"
#import <objc/runtime.h>

@interface SGRStemsEdgeGestureDelegate : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedDelegate;
@end

@implementation SGRStemsEdgeGestureDelegate
+ (instancetype)sharedDelegate {
    static SGRStemsEdgeGestureDelegate *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [SGRStemsEdgeGestureDelegate new]; });
    return inst;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    while (v) {
        if ([v isKindOfClass:UIControl.class] || [v isKindOfClass:UISlider.class]) {
            return NO;
        }
        v = v.superview;
    }
    return YES;
}
@end

static char kSGRStemsEdgeGestureKey;

%hook _TtC19NowPlaying_ViewImpl24NowPlayingViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host) return;

    if (!objc_getAssociatedObject(host, &kSGRStemsEdgeGestureKey)) {
        // Left swipe strictly from the right physical bezel/edge of the screen
        UIScreenEdgePanGestureRecognizer *edgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(sgr_handleStemsEdgePan:)];
        edgePan.edges = UIRectEdgeRight;
        edgePan.delegate = [SGRStemsEdgeGestureDelegate sharedDelegate];
        edgePan.cancelsTouchesInView = NO;
        [host addGestureRecognizer:edgePan];
        objc_setAssociatedObject(host, &kSGRStemsEdgeGestureKey, edgePan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%new
- (void)sgr_handleStemsEdgePan:(UIScreenEdgePanGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        if (((UIViewController *)self).presentedViewController) return;
        SGPlayFeedback(SGFeedbackGrab);
        [SGRStemsViewController presentFromCurrentPlayer];
    }
}
%end

%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)handleTap {
    if (SGRPlayerKawarpShowing()) {
        BOOL hidden = !SGFlag(SGRKeyKawarpCoverHidden, NO);
        SGSetEnabled(SGRKeyKawarpCoverHidden, hidden);
        SGRPlayerUpdateCoverVisibility(YES);
        return;
    }
    if (SGFlag(SGKeyGestures, NO)) return;
    %orig;
}
%end

%hook _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView
- (void)layoutSubviews {
    %orig;
    SGGestureAttach((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView",
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
        @"_TtC19NowPlaying_ViewImpl24NowPlayingViewController",
    ]);
}
