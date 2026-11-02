#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"
#import "SGRStemsPage.h"
#import <objc/runtime.h>

static char kStemsPageKey;

%hook _TtC19NowPlaying_ViewImpl24NowPlayingViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (!SGRedesignedUI()) return;
    UIViewController *vc = (UIViewController *)self;
    UIView *host = vc.viewIfLoaded;
    if (!host || host.bounds.size.height < 300) return;

    SGRStemsPage *page = objc_getAssociatedObject(host, &kStemsPageKey);
    if (!page) {
        page = [[SGRStemsPage alloc] initWithFrame:CGRectMake(host.bounds.size.width, 0, host.bounds.size.width, host.bounds.size.height)];
        page.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:page];
        objc_setAssociatedObject(host, &kStemsPageKey, page, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Add swipe left gesture on host to reveal Stems page on the right
        UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:page action:@selector(showPageFromGesture:)];
        swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
        [host addGestureRecognizer:swipeLeft];
    } else {
        // Keep frame positioned cleanly offscreen or onscreen
        if (page.frame.origin.x > 0) {
            page.frame = CGRectMake(host.bounds.size.width, 0, host.bounds.size.width, host.bounds.size.height);
        } else {
            page.frame = host.bounds;
        }
    }
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC19NowPlaying_ViewImpl24NowPlayingViewController"]);
}
