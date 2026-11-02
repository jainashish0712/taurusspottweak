#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Sing/SGSingDSP.h"
#import "Shared/Sing/SGSingController.h"
#import "Player.h"
#import "SGRStemsPage.h"

@interface SGRStemsPage ()
@end

@implementation SGRStemsPage {
    UIView *_navBar;
    UIButton *_backButton;
    UILabel *_titleLabel;

    UIView *_initialView;
    UIButton *_separateButton;
    UILabel *_hintLabel;
    UIActivityIndicatorView *_spinner;

    UIView *_slidersView;
    UILabel *_vocalsLabel, *_vocalsValue;
    UISlider *_vocalsSlider;
    UILabel *_drumsLabel, *_drumsValue;
    UISlider *_drumsSlider;
    UILabel *_bassLabel, *_bassValue;
    UISlider *_bassSlider;
    UILabel *_otherLabel, *_otherValue;
    UISlider *_otherSlider;
    UIButton *_resetButton;

    BOOL _separated;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.96];
    self.clipsToBounds = YES;

    // Navigation Bar
    _navBar = [UIView new];
    [self addSubview:_navBar];

    _backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _backButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [_backButton setTitle:@"‹ Now Playing" forState:UIControlStateNormal];
    [_backButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [_backButton addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];
    [_navBar addSubview:_backButton];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.text = @"Stems";
    [_navBar addSubview:_titleLabel];

    // Initial View
    _initialView = [UIView new];
    [self addSubview:_initialView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.color = UIColor.whiteColor;
    _spinner.hidesWhenStopped = YES;
    [_initialView addSubview:_spinner];

    _separateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _separateButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    _separateButton.layer.cornerRadius = 22;
    _separateButton.layer.cornerCurve = kCACornerCurveContinuous;
    _separateButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [_separateButton setTitle:@"Separate" forState:UIControlStateNormal];
    [_separateButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [_separateButton addTarget:self action:@selector(separateTapped) forControlEvents:UIControlEventTouchUpInside];
    [_initialView addSubview:_separateButton];

    _hintLabel = [UILabel new];
    _hintLabel.font = [UIFont systemFontOfSize:14];
    _hintLabel.textColor = SGGrey();
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.text = @"Isolate Vocals, Drums, Bass & Other";
    [_initialView addSubview:_hintLabel];

    // Sliders View
    _slidersView = [UIView new];
    _slidersView.hidden = YES;
    [self addSubview:_slidersView];

    _vocalsLabel = [self makeLabel:@"Vocals"];
    _vocalsValue = [self makeValueLabel];
    _vocalsSlider = [self makeSlider];
    [_slidersView addSubview:_vocalsLabel];
    [_slidersView addSubview:_vocalsValue];
    [_slidersView addSubview:_vocalsSlider];

    _drumsLabel = [self makeLabel:@"Drums"];
    _drumsValue = [self makeValueLabel];
    _drumsSlider = [self makeSlider];
    [_slidersView addSubview:_drumsLabel];
    [_slidersView addSubview:_drumsValue];
    [_slidersView addSubview:_drumsSlider];

    _bassLabel = [self makeLabel:@"Bass"];
    _bassValue = [self makeValueLabel];
    _bassSlider = [self makeSlider];
    [_slidersView addSubview:_bassLabel];
    [_slidersView addSubview:_bassValue];
    [_slidersView addSubview:_bassSlider];

    _otherLabel = [self makeLabel:@"Other"];
    _otherValue = [self makeValueLabel];
    _otherSlider = [self makeSlider];
    [_slidersView addSubview:_otherLabel];
    [_slidersView addSubview:_otherValue];
    [_slidersView addSubview:_otherSlider];

    _resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _resetButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_resetButton setTitle:@"Reset Stems" forState:UIControlStateNormal];
    [_resetButton setTitleColor:SGRed() forState:UIControlStateNormal];
    [_resetButton addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    [_slidersView addSubview:_resetButton];

    // Swipe right to go back
    UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeRight:)];
    swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
    [self addGestureRecognizer:swipeRight];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UILabel *)makeLabel:(NSString *)text {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    l.textColor = UIColor.whiteColor;
    l.text = text;
    return l;
}

- (UILabel *)makeValueLabel {
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
    l.textColor = SGGrey();
    l.textAlignment = NSTextAlignmentRight;
    l.text = @"100%";
    return l;
}

- (UISlider *)makeSlider {
    UISlider *s = [UISlider new];
    s.minimumValue = 0.0f;
    s.maximumValue = 1.0f;
    s.value = 1.0f;
    s.minimumTrackTintColor = SGGreen();
    s.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    [s addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
    return s;
}

- (void)sliderMoved:(UISlider *)slider {
    float val = slider.value;
    UILabel *lbl = nil;
    if (slider == _vocalsSlider) lbl = _vocalsValue;
    else if (slider == _drumsSlider) lbl = _drumsValue;
    else if (slider == _bassSlider) lbl = _bassValue;
    else if (slider == _otherSlider) lbl = _otherValue;
    lbl.text = [NSString stringWithFormat:@"%.0f%%", val * 100];

    SGSingSet4StemGains(_vocalsSlider.value, _drumsSlider.value, _bassSlider.value, _otherSlider.value);
}

- (void)resetTapped {
    _vocalsSlider.value = 1.0f;
    _drumsSlider.value = 1.0f;
    _bassSlider.value = 1.0f;
    _otherSlider.value = 1.0f;
    _vocalsValue.text = @"100%";
    _drumsValue.text = @"100%";
    _bassValue.text = @"100%";
    _otherValue.text = @"100%";
    SGSingSet4StemGains(1.0f, 1.0f, 1.0f, 1.0f);
}

- (void)separateTapped {
    _separateButton.enabled = NO;
    _separateButton.alpha = 0.5;
    [_spinner startAnimating];
    _hintLabel.text = @"Splitting stems...";

    SGSingConfigure(YES);
    SGSingSetEnabled(YES);

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_separated = YES;
        [strongSelf->_spinner stopAnimating];
        [UIView transitionWithView:strongSelf duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            strongSelf->_initialView.hidden = YES;
            strongSelf->_slidersView.hidden = NO;
        } completion:nil];
    });
}

- (void)artworkChanged {
    // Reset state for new track
    _separated = NO;
    _separateButton.enabled = YES;
    _separateButton.alpha = 1.0;
    [_spinner stopAnimating];
    _hintLabel.text = @"Isolate Vocals, Drums, Bass & Other";
    _initialView.hidden = NO;
    _slidersView.hidden = YES;
    [self resetTapped];
}

- (void)backTapped {
    [self hidePageAnimated:YES];
}

- (void)handleSwipeRight:(UISwipeGestureRecognizer *)gesture {
    [self hidePageAnimated:YES];
}

- (void)showPageFromGesture:(UIGestureRecognizer *)gesture {
    [self showPageAnimated:YES];
}

- (void)showPageAnimated:(BOOL)animated {
    UIView *superview = self.superview;
    if (!superview) return;
    CGRect endFrame = superview.bounds;
    if (animated) {
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.frame = endFrame;
        } completion:nil];
    } else {
        self.frame = endFrame;
    }
}

- (void)hidePageAnimated:(BOOL)animated {
    UIView *superview = self.superview;
    if (!superview) return;
    CGRect endFrame = CGRectMake(superview.bounds.size.width, 0, superview.bounds.size.width, superview.bounds.size.height);
    if (animated) {
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.frame = endFrame;
        } completion:nil];
    } else {
        self.frame = endFrame;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat w = b.size.width, h = b.size.height;
    CGFloat top = self.safeAreaInsets.top > 0 ? self.safeAreaInsets.top : 24;

    _navBar.frame = CGRectMake(0, top, w, 44);
    _backButton.frame = CGRectMake(16, 0, 130, 44);
    _titleLabel.frame = CGRectMake((w - 100) / 2, 0, 100, 44);

    CGFloat contentTop = top + 54;
    CGFloat contentHeight = h - contentTop - (self.safeAreaInsets.bottom > 0 ? self.safeAreaInsets.bottom : 20);

    _initialView.frame = CGRectMake(24, contentTop, w - 48, contentHeight);
    CGFloat btnW = 160, btnH = 44;
    _separateButton.frame = CGRectMake(((w - 48) - btnW) / 2, contentHeight / 2 - btnH - 10, btnW, btnH);
    _spinner.center = CGPointMake((w - 48) / 2, CGRectGetMinY(_separateButton.frame) - 30);
    _hintLabel.frame = CGRectMake(0, CGRectGetMaxY(_separateButton.frame) + 14, w - 48, 22);

    _slidersView.frame = CGRectMake(24, contentTop, w - 48, contentHeight);
    CGFloat sliderW = w - 48;
    CGFloat rowH = 68;
    CGFloat startY = (contentHeight - (rowH * 4 + 50)) / 2;
    if (startY < 10) startY = 10;

    // Vocals
    _vocalsLabel.frame = CGRectMake(0, startY, sliderW - 60, 20);
    _vocalsValue.frame = CGRectMake(sliderW - 60, startY, 60, 20);
    _vocalsSlider.frame = CGRectMake(0, startY + 24, sliderW, 30);

    // Drums
    _drumsLabel.frame = CGRectMake(0, startY + rowH, sliderW - 60, 20);
    _drumsValue.frame = CGRectMake(sliderW - 60, startY + rowH, 60, 20);
    _drumsSlider.frame = CGRectMake(0, startY + rowH + 24, sliderW, 30);

    // Bass
    _bassLabel.frame = CGRectMake(0, startY + rowH * 2, sliderW - 60, 20);
    _bassValue.frame = CGRectMake(sliderW - 60, startY + rowH * 2, 60, 20);
    _bassSlider.frame = CGRectMake(0, startY + rowH * 2 + 24, sliderW, 30);

    // Other
    _otherLabel.frame = CGRectMake(0, startY + rowH * 3, sliderW - 60, 20);
    _otherValue.frame = CGRectMake(sliderW - 60, startY + rowH * 3, 60, 20);
    _otherSlider.frame = CGRectMake(0, startY + rowH * 3 + 24, sliderW, 30);

    // Reset button
    _resetButton.frame = CGRectMake((sliderW - 140) / 2, startY + rowH * 4 + 16, 140, 34);
}

@end
