#import <UIKit/UIKit.h>

@interface SGRStemsPage : UIView
- (void)showPageAnimated:(BOOL)animated;
- (void)hidePageAnimated:(BOOL)animated;
- (void)showPageFromGesture:(UIGestureRecognizer *)gesture;
@end
