#import <UIKit/UIKit.h>

@interface SGRStemsPage : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIButton *triggerButton;
- (void)openTapped;
- (void)showPageAnimated:(BOOL)animated;
- (void)hidePageAnimated:(BOOL)animated;
- (void)showPageFromGesture:(UIGestureRecognizer *)gesture;
- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)pan;
@end
