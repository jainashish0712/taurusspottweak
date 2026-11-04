#import "Core/SGCore.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Haptics/Haptics.h"
#import "Shared/AudioEffects/AudioEffectsPage.h"
#import "Settings/SGPageStyle.h"
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

@interface SGRAudioEffectsNavController : UINavigationController
@end

@implementation SGRAudioEffectsNavController
- (void)sgr_dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

static char kSGRStemsEdgeGestureKey;
static char kSGRAudioEffectsEdgeGestureKey;

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

    if (!objc_getAssociatedObject(host, &kSGRAudioEffectsEdgeGestureKey)) {
        // Right swipe strictly from the left physical bezel/edge of the screen
        UIScreenEdgePanGestureRecognizer *leftEdgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(sgr_handleAudioEffectsEdgePan:)];
        leftEdgePan.edges = UIRectEdgeLeft;
        leftEdgePan.delegate = [SGRStemsEdgeGestureDelegate sharedDelegate];
        leftEdgePan.cancelsTouchesInView = NO;
        [host addGestureRecognizer:leftEdgePan];
        objc_setAssociatedObject(host, &kSGRAudioEffectsEdgeGestureKey, leftEdgePan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

%new
- (void)sgr_handleAudioEffectsEdgePan:(UIScreenEdgePanGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        if (((UIViewController *)self).presentedViewController) return;
        SGPlayFeedback(SGFeedbackGrab);
        UIViewController *topVC = SGTopController() ?: (UIViewController *)self;
        if (!topVC) return;

        UIViewController *page = SGDSPSettingsPage();
        if (!page) return;

        SGRAudioEffectsNavController *nav = [[SGRAudioEffectsNavController alloc] initWithRootViewController:page];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        nav.navigationBar.tintColor = UIColor.whiteColor;
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet = nav.sheetPresentationController;
            if (sheet) {
                sheet.detents = @[
                    UISheetPresentationControllerDetent.mediumDetent,
                    UISheetPresentationControllerDetent.largeDetent
                ];
                sheet.prefersGrabberVisible = YES;
                sheet.preferredCornerRadius = 24.0;
            }
        }

        page.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:nav action:@selector(sgr_dismiss)];
        [topVC presentViewController:nav animated:YES completion:nil];
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
