#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"
#import "SGRStemsPage.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

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
        CGFloat w = host.bounds.size.width;
        CGFloat h = host.bounds.size.height;

        page = [[SGRStemsPage alloc] initWithFrame:CGRectMake(w, 0, w, h)];
        page.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:page];
        objc_setAssociatedObject(host, &kStemsPageKey, page, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // System-prioritized screen edge pan from right edge
        UIScreenEdgePanGestureRecognizer *edgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:page action:@selector(handleEdgePan:)];
        edgePan.edges = UIRectEdgeRight;
        edgePan.delegate = page;
        [host addGestureRecognizer:edgePan];

        // Floating right-edge glass handle button
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        CGFloat btnW = 34, btnH = 48;
        btn.frame = CGRectMake(w - btnW, h * 0.44, btnW, btnH);
        btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        btn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        btn.layer.cornerRadius = 16;
        btn.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
        btn.clipsToBounds = YES;

        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:@"waveform" withConfiguration:config];
        if (!img) img = [UIImage systemImageNamed:@"chevron.left" withConfiguration:config];
        if (img) {
            [btn setImage:img forState:UIControlStateNormal];
        } else {
            [btn setTitle:@"‹" forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
        }
        btn.tintColor = UIColor.whiteColor;
        [btn addTarget:page action:@selector(openTapped) forControlEvents:UIControlEventTouchUpInside];

        [host addSubview:btn];
        page.triggerButton = btn;
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
