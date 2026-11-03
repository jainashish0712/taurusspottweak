#import "SGRStemsViewController.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Nagare/SGNagareBridge.h"
#import <math.h>

static const CGFloat kPadding = 18.0;

@interface SGRStemsViewController () <UIScrollViewDelegate>
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UISegmentedControl *tabPicker;

// Tab views
@property (nonatomic, strong) UIView *stemsTab;
@property (nonatomic, strong) UIView *subsystemsTab;
@property (nonatomic, strong) UIView *coreChainTab;

// Stems Controls
@property (nonatomic, strong) UISwitch *stemsMasterSwitch;
@property (nonatomic, strong) UISegmentedControl *modePicker;
@property (nonatomic, strong) UISlider *vocalsSlider;
@property (nonatomic, strong) UISlider *drumsSlider;
@property (nonatomic, strong) UISlider *bassSlider;
@property (nonatomic, strong) UISlider *otherSlider;
@property (nonatomic, strong) UILabel *vocalsLabel;
@property (nonatomic, strong) UILabel *drumsLabel;
@property (nonatomic, strong) UILabel *bassLabel;
@property (nonatomic, strong) UILabel *otherLabel;
@property (nonatomic, strong) UIProgressView *vocalsMeter;
@property (nonatomic, strong) UIProgressView *drumsMeter;
@property (nonatomic, strong) UIProgressView *bassMeter;
@property (nonatomic, strong) UIProgressView *otherMeter;

// Subsystems Controls
@property (nonatomic, strong) UISwitch *upscalerSwitch;
@property (nonatomic, strong) UISlider *upscalerSlider;
@property (nonatomic, strong) UILabel *upscalerQualityLabel;
@property (nonatomic, strong) UISwitch *restorerSwitch;
@property (nonatomic, strong) UISlider *restorerSlider;
@property (nonatomic, strong) UISwitch *hrtfSwitch;
@property (nonatomic, strong) UISlider *hrtfAngleSlider;

// Core Chain Controls
@property (nonatomic, strong) UISwitch *smartSwitch;
@property (nonatomic, strong) UISlider *smartSlider;
@property (nonatomic, strong) UISwitch *vibeSwitch;
@property (nonatomic, strong) UISlider *vibeSlider;
@property (nonatomic, strong) UISwitch *tubeSwitch;
@property (nonatomic, strong) UISlider *tubeSlider;
@property (nonatomic, strong) UISwitch *exciterSwitch;
@property (nonatomic, strong) UISlider *exciterSlider;
@property (nonatomic, strong) UISwitch *stereoWidthSwitch;
@property (nonatomic, strong) UISlider *stereoWidthSlider;
@property (nonatomic, strong) UISwitch *crossfeedSwitch;
@property (nonatomic, strong) UISlider *crossfeedSlider;
@property (nonatomic, strong) UISwitch *reverbSwitch;
@property (nonatomic, strong) UISlider *reverbSlider;

@property (nonatomic, strong) NSTimer *meterTimer;
@end

@implementation SGRStemsViewController

+ (void)presentFromCurrentPlayer {
    UIViewController *topVC = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden) continue;
            if (!topVC || window.isKeyWindow) topVC = window.rootViewController;
        }
    }
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }

    if (!topVC) return;

    SGRStemsViewController *stemsVC = [[SGRStemsViewController alloc] init];
    stemsVC.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = stemsVC.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[
                UISheetPresentationControllerDetent.mediumDetent,
                UISheetPresentationControllerDetent.largeDetent
            ];
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 24.0;
        }
    }
    [topVC presentViewController:stemsVC animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor clearColor];

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.blurView.frame = self.view.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.blurView];

    [self setupHeader];
    [self setupScrollView];
    [self setupTabs];
    [self refreshControlsState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshControlsState];
    [self startMeterTimer];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopMeterTimer];
}

- (void)startMeterTimer {
    [self stopMeterTimer];
    __weak __typeof__(self) weakSelf = self;
    self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.04 repeats:YES block:^(NSTimer * _Nonnull timer) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateMeters];
    }];
}

- (void)stopMeterTimer {
    if (self.meterTimer) {
        [self.meterTimer invalidate];
        self.meterTimer = nil;
    }
}

- (void)updateMeters {
    if (self.tabPicker.selectedSegmentIndex != 0 || !SGNagareIsStemsEnabled()) {
        self.vocalsMeter.progress = 0.0f;
        self.drumsMeter.progress = 0.0f;
        self.bassMeter.progress = 0.0f;
        self.otherMeter.progress = 0.0f;
        return;
    }

    float v = 0, d = 0, b = 0, o = 0;
    SGNagareGetStemMeters(&v, &d, &b, &o);

    float vocalsMult = self.vocalsSlider.value;
    float drumsMult = self.drumsSlider.value;
    float bassMult = self.bassSlider.value;
    float otherMult = self.otherSlider.value;

    self.vocalsMeter.progress = fminf(1.0f, v * vocalsMult * 4.0f);
    self.drumsMeter.progress = fminf(1.0f, d * drumsMult * 4.0f);
    self.bassMeter.progress = fminf(1.0f, b * bassMult * 4.0f);
    self.otherMeter.progress = fminf(1.0f, o * otherMult * 4.0f);
}

#pragma mark - Helper Functions

static int NagareModeFromSegmentIndex(NSInteger segment) {
    switch (segment) {
        case 1: return 1; // Karaoke (SEPARATOR_MODE_KARAOKE)
        case 2: return 2; // Vocals Only (SEPARATOR_MODE_VOCALS_ONLY)
        case 3: return 4; // Drums Emphasis (SEPARATOR_MODE_DRUMS_EMPHASIS)
        case 4: return 3; // Bass Boost (SEPARATOR_MODE_BASS_BOOST)
        case 5: return 5; // Backing / Instrumental (SEPARATOR_MODE_INSTRUMENTAL)
        default: return 6; // Custom (SEPARATOR_MODE_CUSTOM)
    }
}

static NSInteger SegmentIndexFromNagareMode(int mode) {
    switch (mode) {
        case 1: return 1; // Karaoke
        case 2: return 2; // Vocals
        case 4: return 3; // Drums
        case 3: return 4; // Bass
        case 5: return 5; // Backing
        default: return 0; // Custom (mode 6 or fallback)
    }
}

#pragma mark - Header & Layout

- (void)setupHeader {
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.blurView.contentView addSubview:header];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"Stem Separation & DSP";
    titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    titleLabel.textColor = SGRPrimary();
    [header addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = @"Real-Time Nagare SIMD Audio Engine";
    subtitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    subtitleLabel.textColor = SGRSecondary();
    [header addSubview:subtitleLabel];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:config] forState:UIControlStateNormal];
    closeBtn.tintColor = SGRTertiary();
    [closeBtn addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:closeBtn];

    // Segmented tab picker
    self.tabPicker = [[UISegmentedControl alloc] initWithItems:@[@"4 Stems", @"Subsystems", @"Core Chain"]];
    self.tabPicker.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabPicker.selectedSegmentIndex = 0;
    self.tabPicker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self.tabPicker addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.blurView.contentView addSubview:self.tabPicker];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.blurView.contentView.safeAreaLayoutGuide.topAnchor constant:12],
        [header.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:kPadding],
        [header.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-kPadding],
        [header.heightAnchor constraintEqualToConstant:46],

        [titleLabel.topAnchor constraintEqualToAnchor:header.topAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:closeBtn.leadingAnchor constant:-8],

        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:closeBtn.leadingAnchor constant:-8],

        [closeBtn.topAnchor constraintEqualToAnchor:header.topAnchor],
        [closeBtn.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [closeBtn.widthAnchor constraintEqualToConstant:32],
        [closeBtn.heightAnchor constraintEqualToConstant:32],

        [self.tabPicker.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12],
        [self.tabPicker.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:kPadding],
        [self.tabPicker.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-kPadding],
        [self.tabPicker.heightAnchor constraintEqualToConstant:32],
    ]];
}

- (void)setupScrollView {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = YES;
    self.scrollView.alwaysBounceVertical = YES;
    [self.blurView.contentView addSubview:self.scrollView];

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 16.0;
    self.contentStack.layoutMargins = UIEdgeInsetsMake(12, kPadding, 48, kPadding);
    self.contentStack.layoutMarginsRelativeArrangement = YES;
    [self.scrollView addSubview:self.contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.tabPicker.bottomAnchor constant:10],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor],

        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],
    ]];
}

- (void)setupTabs {
    [self setupStemsTab];
    [self setupSubsystemsTab];
    [self setupCoreChainTab];

    [self showTabAtIndex:0];
}

- (void)showTabAtIndex:(NSInteger)index {
    for (UIView *subview in self.contentStack.arrangedSubviews) {
        [self.contentStack removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }
    UIView *target = nil;
    if (index == 0) target = self.stemsTab;
    else if (index == 1) target = self.subsystemsTab;
    else if (index == 2) target = self.coreChainTab;
    if (target) {
        target.hidden = NO;
        [self.contentStack addArrangedSubview:target];
    }
    [self.view layoutIfNeeded];
    [self.scrollView setContentOffset:CGPointZero animated:NO];
}

- (void)tabChanged:(UISegmentedControl *)sender {
    [UIView transitionWithView:self.scrollView duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        [self showTabAtIndex:sender.selectedSegmentIndex];
    } completion:nil];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Stems Tab

- (void)setupStemsTab {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14.0;
    self.stemsTab = stack;

    // Master Switch Card
    UIView *card = [self createCardView];
    [card.heightAnchor constraintEqualToConstant:72].active = YES;

    UILabel *switchLabel = [self createTitleLabel:@"Separate Audio Stems" subtitle:@"Real-time HPSS & Mid/Side separation"];
    switchLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.stemsMasterSwitch = [[UISwitch alloc] init];
    self.stemsMasterSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.stemsMasterSwitch.onTintColor = SGRAccent();
    [self.stemsMasterSwitch addTarget:self action:@selector(stemsMasterToggled:) forControlEvents:UIControlEventValueChanged];

    UIStackView *cardRow = [[UIStackView alloc] initWithArrangedSubviews:@[switchLabel, self.stemsMasterSwitch]];
    cardRow.translatesAutoresizingMaskIntoConstraints = NO;
    cardRow.alignment = UIStackViewAlignmentCenter;
    cardRow.distribution = UIStackViewDistributionEqualSpacing;
    [card addSubview:cardRow];

    [NSLayoutConstraint activateConstraints:@[
        [cardRow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cardRow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [cardRow.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];
    [stack addArrangedSubview:card];

    // Presets Mode Picker
    UILabel *modesHeader = [self createSectionHeader:@"Separation Mode"];
    modesHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:modesHeader];

    self.modePicker = [[UISegmentedControl alloc] initWithItems:@[@"Custom", @"Karaoke", @"Vocals", @"Drums", @"Bass", @"Backing"]];
    self.modePicker.translatesAutoresizingMaskIntoConstraints = NO;
    self.modePicker.selectedSegmentIndex = 0;
    self.modePicker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self.modePicker addTarget:self action:@selector(modePicked:) forControlEvents:UIControlEventValueChanged];
    [self.modePicker.heightAnchor constraintEqualToConstant:32].active = YES;
    [stack addArrangedSubview:self.modePicker];

    // 4 Sliders (Vocals, Drums, Bass, Other)
    UILabel *slidersHeader = [self createSectionHeader:@"Stem Balance"];
    slidersHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:slidersHeader];

    UIView *vocalsCard = [self createStemSliderRow:@"Vocals"
                                            symbol:@"mic.fill"
                                             color:[UIColor systemRedColor]
                                            slider:&_vocalsSlider
                                             label:&_vocalsLabel
                                             meter:&_vocalsMeter
                                            action:@selector(vocalsSliderMoved:)];
    [stack addArrangedSubview:vocalsCard];

    UIView *drumsCard = [self createStemSliderRow:@"Drums & Transients"
                                           symbol:@"waveform.path"
                                            color:[UIColor systemOrangeColor]
                                           slider:&_drumsSlider
                                            label:&_drumsLabel
                                            meter:&_drumsMeter
                                           action:@selector(drumsSliderMoved:)];
    [stack addArrangedSubview:drumsCard];

    UIView *bassCard = [self createStemSliderRow:@"Bass"
                                          symbol:@"guitars.fill"
                                           color:[UIColor systemBlueColor]
                                          slider:&_bassSlider
                                           label:&_bassLabel
                                           meter:&_bassMeter
                                          action:@selector(bassSliderMoved:)];
    [stack addArrangedSubview:bassCard];

    UIView *otherCard = [self createStemSliderRow:@"Instruments / Other"
                                           symbol:@"music.quarternote.3"
                                            color:[UIColor systemPurpleColor]
                                           slider:&_otherSlider
                                            label:&_otherLabel
                                            meter:&_otherMeter
                                           action:@selector(otherSliderMoved:)];
    [stack addArrangedSubview:otherCard];

    // Reset button
    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [resetBtn setTitle:@"Reset Stems to 100%" forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [resetBtn setTitleColor:SGRAccent() forState:UIControlStateNormal];
    resetBtn.backgroundColor = SGRSolidGlassFill();
    resetBtn.layer.cornerRadius = 14;
    resetBtn.clipsToBounds = YES;
    [resetBtn.heightAnchor constraintEqualToConstant:44].active = YES;
    [resetBtn addTarget:self action:@selector(resetStemsTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:resetBtn];
}

- (UIView *)createStemSliderRow:(NSString *)title
                         symbol:(NSString *)symbol
                          color:(UIColor *)color
                         slider:(UISlider * __strong *)outSlider
                          label:(UILabel * __strong *)outLabel
                          meter:(UIProgressView * __strong *)outMeter
                         action:(SEL)action {
    UIView *card = [self createCardView];
    [card.heightAnchor constraintEqualToConstant:90].active = YES;

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.image = [UIImage systemImageNamed:symbol];
    iconView.tintColor = color;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:iconView];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    titleLabel.textColor = SGRPrimary();
    [card addSubview:titleLabel];

    UILabel *valLabel = [[UILabel alloc] init];
    valLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valLabel.text = @"100%";
    valLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    valLabel.textAlignment = NSTextAlignmentRight;
    valLabel.textColor = SGRSecondary();
    [card addSubview:valLabel];
    if (outLabel) *outLabel = valLabel;

    UISlider *slider = [[UISlider alloc] init];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.minimumValue = 0.0f;
    slider.maximumValue = 2.0f;
    slider.value = 1.0f;
    slider.minimumTrackTintColor = color;
    [slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [card addSubview:slider];
    if (outSlider) *outSlider = slider;

    UIProgressView *meter = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    meter.translatesAutoresizingMaskIntoConstraints = NO;
    meter.progressTintColor = [color colorWithAlphaComponent:0.7];
    meter.trackTintColor = [UIColor clearColor];
    meter.progress = 0.0f;
    [card addSubview:meter];
    if (outMeter) *outMeter = meter;

    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [iconView.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [iconView.widthAnchor constraintEqualToConstant:22],
        [iconView.heightAnchor constraintEqualToConstant:22],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10],
        [titleLabel.centerYAnchor constraintEqualToAnchor:iconView.centerYAnchor],

        [valLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [valLabel.centerYAnchor constraintEqualToAnchor:iconView.centerYAnchor],
        [valLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:8],

        [slider.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [slider.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [slider.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:8],
        [slider.heightAnchor constraintEqualToConstant:28],

        [meter.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [meter.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [meter.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:4],
        [meter.heightAnchor constraintEqualToConstant:3],
    ]];

    return card;
}

#pragma mark - Subsystems Tab

- (void)setupSubsystemsTab {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16.0;
    self.subsystemsTab = stack;

    // 1. Audio Upscaler (SBR / DSEE)
    UILabel *upHeader = [self createSectionHeader:@"Audio Upscaler (SBR / DSEE)"];
    upHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:upHeader];

    UIView *upCard = [self createCardView];
    [upCard.heightAnchor constraintEqualToConstant:128].active = YES;

    UILabel *upTitle = [self createTitleLabel:@"Spectral Band Replication" subtitle:@"Reconstructs high frequencies lost to MP3/AAC"];
    upTitle.translatesAutoresizingMaskIntoConstraints = NO;

    self.upscalerSwitch = [[UISwitch alloc] init];
    self.upscalerSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.upscalerSwitch.onTintColor = SGRAccent();
    [self.upscalerSwitch addTarget:self action:@selector(upscalerToggled:) forControlEvents:UIControlEventValueChanged];

    UIStackView *upRow = [[UIStackView alloc] initWithArrangedSubviews:@[upTitle, self.upscalerSwitch]];
    upRow.translatesAutoresizingMaskIntoConstraints = NO;
    upRow.alignment = UIStackViewAlignmentCenter;
    upRow.distribution = UIStackViewDistributionEqualSpacing;
    [upCard addSubview:upRow];

    self.upscalerSlider = [[UISlider alloc] init];
    self.upscalerSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.upscalerSlider.minimumValue = 0.0f;
    self.upscalerSlider.maximumValue = 1.0f;
    self.upscalerSlider.value = SGNagareGetUpscalerIntensity();
    self.upscalerSlider.minimumTrackTintColor = SGRAccent();
    [self.upscalerSlider addTarget:self action:@selector(upscalerSliderMoved:) forControlEvents:UIControlEventValueChanged];
    [upCard addSubview:self.upscalerSlider];

    self.upscalerQualityLabel = [[UILabel alloc] init];
    self.upscalerQualityLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.upscalerQualityLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.upscalerQualityLabel.textColor = SGRSecondary();
    self.upscalerQualityLabel.text = @"Source Quality: Lossless (High)";
    [upCard addSubview:self.upscalerQualityLabel];

    [NSLayoutConstraint activateConstraints:@[
        [upRow.leadingAnchor constraintEqualToAnchor:upCard.leadingAnchor constant:16],
        [upRow.trailingAnchor constraintEqualToAnchor:upCard.trailingAnchor constant:-16],
        [upRow.topAnchor constraintEqualToAnchor:upCard.topAnchor constant:12],

        [self.upscalerSlider.leadingAnchor constraintEqualToAnchor:upCard.leadingAnchor constant:16],
        [self.upscalerSlider.trailingAnchor constraintEqualToAnchor:upCard.trailingAnchor constant:-16],
        [self.upscalerSlider.topAnchor constraintEqualToAnchor:upRow.bottomAnchor constant:8],
        [self.upscalerSlider.heightAnchor constraintEqualToConstant:28],

        [self.upscalerQualityLabel.leadingAnchor constraintEqualToAnchor:upCard.leadingAnchor constant:16],
        [self.upscalerQualityLabel.trailingAnchor constraintEqualToAnchor:upCard.trailingAnchor constant:-16],
        [self.upscalerQualityLabel.topAnchor constraintEqualToAnchor:self.upscalerSlider.bottomAnchor constant:6],
    ]];
    [stack addArrangedSubview:upCard];

    // 2. Dynamic Restorer
    UILabel *restHeader = [self createSectionHeader:@"Dynamic Range Restorer"];
    restHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:restHeader];

    UIView *restCard = [self createCardView];
    [restCard.heightAnchor constraintEqualToConstant:104].active = YES;

    UILabel *restTitle = [self createTitleLabel:@"De-Compress Mastering" subtitle:@"Multi-band expansion to undo loudness-war crushing"];
    restTitle.translatesAutoresizingMaskIntoConstraints = NO;

    self.restorerSwitch = [[UISwitch alloc] init];
    self.restorerSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.restorerSwitch.onTintColor = SGRAccent();
    [self.restorerSwitch addTarget:self action:@selector(restorerToggled:) forControlEvents:UIControlEventValueChanged];

    UIStackView *restRow = [[UIStackView alloc] initWithArrangedSubviews:@[restTitle, self.restorerSwitch]];
    restRow.translatesAutoresizingMaskIntoConstraints = NO;
    restRow.alignment = UIStackViewAlignmentCenter;
    restRow.distribution = UIStackViewDistributionEqualSpacing;
    [restCard addSubview:restRow];

    self.restorerSlider = [[UISlider alloc] init];
    self.restorerSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.restorerSlider.minimumValue = 0.0f;
    self.restorerSlider.maximumValue = 1.0f;
    self.restorerSlider.value = SGNagareGetRestorerIntensity();
    self.restorerSlider.minimumTrackTintColor = SGRAccent();
    [self.restorerSlider addTarget:self action:@selector(restorerSliderMoved:) forControlEvents:UIControlEventValueChanged];
    [restCard addSubview:self.restorerSlider];

    [NSLayoutConstraint activateConstraints:@[
        [restRow.leadingAnchor constraintEqualToAnchor:restCard.leadingAnchor constant:16],
        [restRow.trailingAnchor constraintEqualToAnchor:restCard.trailingAnchor constant:-16],
        [restRow.topAnchor constraintEqualToAnchor:restCard.topAnchor constant:12],

        [self.restorerSlider.leadingAnchor constraintEqualToAnchor:restCard.leadingAnchor constant:16],
        [self.restorerSlider.trailingAnchor constraintEqualToAnchor:restCard.trailingAnchor constant:-16],
        [self.restorerSlider.topAnchor constraintEqualToAnchor:restRow.bottomAnchor constant:10],
        [self.restorerSlider.heightAnchor constraintEqualToConstant:28],
    ]];
    [stack addArrangedSubview:restCard];

    // 3. HRTF Binaural Spatializer
    UILabel *hrtfHeader = [self createSectionHeader:@"Binaural HRTF (MIT KEMAR)"];
    hrtfHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:hrtfHeader];

    UIView *hrtfCard = [self createCardView];
    [hrtfCard.heightAnchor constraintEqualToConstant:104].active = YES;

    UILabel *hrtfTitle = [self createTitleLabel:@"Head-Related Transfer Function" subtitle:@"Binaural virtual speakers over headphones"];
    hrtfTitle.translatesAutoresizingMaskIntoConstraints = NO;

    self.hrtfSwitch = [[UISwitch alloc] init];
    self.hrtfSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.hrtfSwitch.onTintColor = SGRAccent();
    [self.hrtfSwitch addTarget:self action:@selector(hrtfToggled:) forControlEvents:UIControlEventValueChanged];

    UIStackView *hrtfRow = [[UIStackView alloc] initWithArrangedSubviews:@[hrtfTitle, self.hrtfSwitch]];
    hrtfRow.translatesAutoresizingMaskIntoConstraints = NO;
    hrtfRow.alignment = UIStackViewAlignmentCenter;
    hrtfRow.distribution = UIStackViewDistributionEqualSpacing;
    [hrtfCard addSubview:hrtfRow];

    self.hrtfAngleSlider = [[UISlider alloc] init];
    self.hrtfAngleSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.hrtfAngleSlider.minimumValue = -90.0f;
    self.hrtfAngleSlider.maximumValue = 90.0f;
    self.hrtfAngleSlider.value = SGNagareGetHRTFAngle();
    self.hrtfAngleSlider.minimumTrackTintColor = SGRAccent();
    [self.hrtfAngleSlider addTarget:self action:@selector(hrtfAngleMoved:) forControlEvents:UIControlEventValueChanged];
    [hrtfCard addSubview:self.hrtfAngleSlider];

    [NSLayoutConstraint activateConstraints:@[
        [hrtfRow.leadingAnchor constraintEqualToAnchor:hrtfCard.leadingAnchor constant:16],
        [hrtfRow.trailingAnchor constraintEqualToAnchor:hrtfCard.trailingAnchor constant:-16],
        [hrtfRow.topAnchor constraintEqualToAnchor:hrtfCard.topAnchor constant:12],

        [self.hrtfAngleSlider.leadingAnchor constraintEqualToAnchor:hrtfCard.leadingAnchor constant:16],
        [self.hrtfAngleSlider.trailingAnchor constraintEqualToAnchor:hrtfCard.trailingAnchor constant:-16],
        [self.hrtfAngleSlider.topAnchor constraintEqualToAnchor:hrtfRow.bottomAnchor constant:10],
        [self.hrtfAngleSlider.heightAnchor constraintEqualToConstant:28],
    ]];
    [stack addArrangedSubview:hrtfCard];
}

#pragma mark - Core Chain Tab

- (void)setupCoreChainTab {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16.0;
    self.coreChainTab = stack;

    // Smart Enhance
    UILabel *smartHeader = [self createSectionHeader:@"One-Touch Enhance"];
    smartHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:smartHeader];

    UIView *smartCard = [self createEffectCard:@"Smart Enhance"
                                      subtitle:@"Automatic multi-band optimization"
                                     outSwitch:&_smartSwitch
                                     outSlider:&_smartSlider
                                  switchAction:@selector(smartToggled:)
                                  sliderAction:@selector(smartSliderMoved:)];
    [stack addArrangedSubview:smartCard];

    // Harmonic & Bass
    UILabel *harmHeader = [self createSectionHeader:@"Harmonics & Bass"];
    harmHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:harmHeader];

    UIView *vibeCard = [self createEffectCard:@"Virtual Bass (Missing Fundamental)"
                                     subtitle:@"Psychoacoustic lower-octave synthesis"
                                    outSwitch:&_vibeSwitch
                                    outSlider:&_vibeSlider
                                 switchAction:@selector(vibeToggled:)
                                 sliderAction:@selector(vibeSliderMoved:)];
    [stack addArrangedSubview:vibeCard];

    UIView *tubeCard = [self createEffectCard:@"Tube Warmth"
                                     subtitle:@"Analog triode harmonic saturation"
                                    outSwitch:&_tubeSwitch
                                    outSlider:&_tubeSlider
                                 switchAction:@selector(tubeToggled:)
                                 sliderAction:@selector(tubeSliderMoved:)];
    [stack addArrangedSubview:tubeCard];

    UIView *exciterCard = [self createEffectCard:@"Harmonic Exciter & Air"
                                        subtitle:@"High-frequency overtone generation"
                                       outSwitch:&_exciterSwitch
                                       outSlider:&_exciterSlider
                                    switchAction:@selector(exciterToggled:)
                                    sliderAction:@selector(exciterSliderMoved:)];
    [stack addArrangedSubview:exciterCard];

    // Spatial & Acoustics
    UILabel *spatHeader = [self createSectionHeader:@"Spatial Audio & Acoustics"];
    spatHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:spatHeader];

    UIView *widthCard = [self createEffectCard:@"Stereo Widener"
                                      subtitle:@"Mid/Side ambient spatial expansion"
                                     outSwitch:&_stereoWidthSwitch
                                     outSlider:&_stereoWidthSlider
                                  switchAction:@selector(widthToggled:)
                                  sliderAction:@selector(widthSliderMoved:)];
    [stack addArrangedSubview:widthCard];

    UIView *crossfeedCard = [self createEffectCard:@"Headphone Crossfeed"
                                          subtitle:@"Woodworth ITD interaural delay"
                                         outSwitch:&_crossfeedSwitch
                                         outSlider:&_crossfeedSlider
                                      switchAction:@selector(crossfeedToggled:)
                                      sliderAction:@selector(crossfeedSliderMoved:)];
    [stack addArrangedSubview:crossfeedCard];

    UIView *reverbCard = [self createEffectCard:@"Schroeder Reverb"
                                       subtitle:@"Comb/allpass diffuse spatial room"
                                      outSwitch:&_reverbSwitch
                                      outSlider:&_reverbSlider
                                   switchAction:@selector(reverbToggled:)
                                   sliderAction:@selector(reverbSliderMoved:)];
    [stack addArrangedSubview:reverbCard];
}

- (UIView *)createEffectCard:(NSString *)title
                    subtitle:(NSString *)subtitle
                   outSwitch:(UISwitch * __strong *)outSwitch
                   outSlider:(UISlider * __strong *)outSlider
                switchAction:(SEL)switchAction
                sliderAction:(SEL)sliderAction {
    UIView *card = [self createCardView];
    [card.heightAnchor constraintEqualToConstant:104].active = YES;

    UILabel *titleLabel = [self createTitleLabel:title subtitle:subtitle];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    sw.onTintColor = SGRAccent();
    [sw addTarget:self action:switchAction forControlEvents:UIControlEventValueChanged];
    if (outSwitch) *outSwitch = sw;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, sw]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionEqualSpacing;
    [card addSubview:row];

    UISlider *sl = [[UISlider alloc] init];
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    sl.minimumValue = 0.0f;
    sl.maximumValue = 1.0f;
    sl.value = 0.5f;
    sl.minimumTrackTintColor = SGRAccent();
    [sl addTarget:self action:sliderAction forControlEvents:UIControlEventValueChanged];
    [card addSubview:sl];
    if (outSlider) *outSlider = sl;

    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [row.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],

        [sl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [sl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [sl.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:10],
        [sl.heightAnchor constraintEqualToConstant:28],
    ]];

    return card;
}

#pragma mark - Helper Views

- (UIView *)createCardView {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = SGRSolidGlassFill();
    card.layer.cornerRadius = SGRRadiusCard;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    return card;
}

- (UILabel *)createSectionHeader:(NSString *)title {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = [title uppercaseString];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    label.textColor = SGRTertiary();
    return label;
}

- (UILabel *)createTitleLabel:(NSString *)title subtitle:(NSString *)subtitle {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 2;

    NSMutableAttributedString *att = [[NSMutableAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: SGRPrimary()
    }];
    if (subtitle) {
        NSAttributedString *sub = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%@", subtitle] attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightRegular],
            NSForegroundColorAttributeName: SGRSecondary()
        }];
        [att appendAttributedString:sub];
    }
    label.attributedText = att;
    return label;
}

#pragma mark - State Refresh

- (void)refreshControlsState {
    self.stemsMasterSwitch.on = SGNagareIsStemsEnabled();
    self.modePicker.selectedSegmentIndex = SegmentIndexFromNagareMode(SGNagareGetSeparationMode());

    float v = 1, d = 1, b = 1, o = 1;
    SGNagareGetStemLevels(&v, &d, &b, &o);
    self.vocalsSlider.value = v;
    self.drumsSlider.value = d;
    self.bassSlider.value = b;
    self.otherSlider.value = o;

    self.vocalsLabel.text = [NSString stringWithFormat:@"%.0f%%", v * 100];
    self.drumsLabel.text = [NSString stringWithFormat:@"%.0f%%", d * 100];
    self.bassLabel.text = [NSString stringWithFormat:@"%.0f%%", b * 100];
    self.otherLabel.text = [NSString stringWithFormat:@"%.0f%%", o * 100];

    self.upscalerSwitch.on = SGNagareIsUpscalerEnabled();
    self.upscalerSlider.value = SGNagareGetUpscalerIntensity();

    int quality = SGNagareGetDetectedSourceQuality();
    if (quality == 2) self.upscalerQualityLabel.text = @"Source Quality: Lossless / Hi-Res";
    else if (quality == 1) self.upscalerQualityLabel.text = @"Source Quality: Medium Bitrate";
    else self.upscalerQualityLabel.text = @"Source Quality: Low Bitrate (Upscaling Active)";

    self.restorerSwitch.on = SGNagareIsRestorerEnabled();
    self.restorerSlider.value = SGNagareGetRestorerIntensity();

    self.hrtfSwitch.on = SGNagareIsHRTFEnabled();
    self.hrtfAngleSlider.value = SGNagareGetHRTFAngle();
}

#pragma mark - Actions

- (void)stemsMasterToggled:(UISwitch *)sender {
    SGNagareSetStemsEnabled(sender.isOn);
}

- (void)modePicked:(UISegmentedControl *)sender {
    int mode = NagareModeFromSegmentIndex(sender.selectedSegmentIndex);
    SGNagareSetSeparationMode(mode);

    // Apply presets
    switch (mode) {
        case 1: // Karaoke
            [self applyStemLevelsVocals:0.0f drums:1.0f bass:1.0f other:1.0f];
            break;
        case 2: // Vocals Only
            [self applyStemLevelsVocals:1.0f drums:0.0f bass:0.0f other:0.0f];
            break;
        case 4: // Drums Emphasis
            [self applyStemLevelsVocals:0.0f drums:1.5f bass:0.5f other:0.2f];
            break;
        case 3: // Bass Boost
            [self applyStemLevelsVocals:0.4f drums:0.8f bass:1.5f other:0.4f];
            break;
        case 5: // Backing / Instrumental
            [self applyStemLevelsVocals:0.0f drums:1.0f bass:1.0f other:1.0f];
            break;
        default:
            break;
    }
}

- (void)applyStemLevelsVocals:(float)v drums:(float)d bass:(float)b other:(float)o {
    self.vocalsSlider.value = v;
    self.drumsSlider.value = d;
    self.bassSlider.value = b;
    self.otherSlider.value = o;

    self.vocalsLabel.text = [NSString stringWithFormat:@"%.0f%%", v * 100];
    self.drumsLabel.text = [NSString stringWithFormat:@"%.0f%%", d * 100];
    self.bassLabel.text = [NSString stringWithFormat:@"%.0f%%", b * 100];
    self.otherLabel.text = [NSString stringWithFormat:@"%.0f%%", o * 100];

    SGNagareSetStemLevels(v, d, b, o);
    if (!self.stemsMasterSwitch.isOn) {
        [self.stemsMasterSwitch setOn:YES animated:YES];
        SGNagareSetStemsEnabled(YES);
    }
}

- (void)vocalsSliderMoved:(UISlider *)sender {
    self.vocalsLabel.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100];
    self.modePicker.selectedSegmentIndex = 0; // Custom
    SGNagareSetSeparationMode(6); // SEPARATOR_MODE_CUSTOM
    SGNagareSetStemLevels(self.vocalsSlider.value, self.drumsSlider.value, self.bassSlider.value, self.otherSlider.value);
    if (!self.stemsMasterSwitch.isOn) {
        [self.stemsMasterSwitch setOn:YES animated:YES];
        SGNagareSetStemsEnabled(YES);
    }
}

- (void)drumsSliderMoved:(UISlider *)sender {
    self.drumsLabel.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100];
    self.modePicker.selectedSegmentIndex = 0; // Custom
    SGNagareSetSeparationMode(6); // SEPARATOR_MODE_CUSTOM
    SGNagareSetStemLevels(self.vocalsSlider.value, self.drumsSlider.value, self.bassSlider.value, self.otherSlider.value);
    if (!self.stemsMasterSwitch.isOn) {
        [self.stemsMasterSwitch setOn:YES animated:YES];
        SGNagareSetStemsEnabled(YES);
    }
}

- (void)bassSliderMoved:(UISlider *)sender {
    self.bassLabel.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100];
    self.modePicker.selectedSegmentIndex = 0; // Custom
    SGNagareSetSeparationMode(6); // SEPARATOR_MODE_CUSTOM
    SGNagareSetStemLevels(self.vocalsSlider.value, self.drumsSlider.value, self.bassSlider.value, self.otherSlider.value);
    if (!self.stemsMasterSwitch.isOn) {
        [self.stemsMasterSwitch setOn:YES animated:YES];
        SGNagareSetStemsEnabled(YES);
    }
}

- (void)otherSliderMoved:(UISlider *)sender {
    self.otherLabel.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100];
    self.modePicker.selectedSegmentIndex = 0; // Custom
    SGNagareSetSeparationMode(6); // SEPARATOR_MODE_CUSTOM
    SGNagareSetStemLevels(self.vocalsSlider.value, self.drumsSlider.value, self.bassSlider.value, self.otherSlider.value);
    if (!self.stemsMasterSwitch.isOn) {
        [self.stemsMasterSwitch setOn:YES animated:YES];
        SGNagareSetStemsEnabled(YES);
    }
}

- (void)resetStemsTapped {
    [self applyStemLevelsVocals:1.0f drums:1.0f bass:1.0f other:1.0f];
    self.modePicker.selectedSegmentIndex = 0;
    SGNagareSetSeparationMode(6);
}

// Subsystems
- (void)upscalerToggled:(UISwitch *)sender {
    SGNagareSetUpscalerEnabled(sender.isOn);
}

- (void)upscalerSliderMoved:(UISlider *)sender {
    SGNagareSetUpscalerIntensity(sender.value);
}

- (void)restorerToggled:(UISwitch *)sender {
    SGNagareSetRestorerEnabled(sender.isOn);
}

- (void)restorerSliderMoved:(UISlider *)sender {
    SGNagareSetRestorerIntensity(sender.value);
}

- (void)hrtfToggled:(UISwitch *)sender {
    SGNagareSetHRTFEnabled(sender.isOn);
}

- (void)hrtfAngleMoved:(UISlider *)sender {
    SGNagareSetHRTFAngle(sender.value);
}

// Core Chain
- (void)smartToggled:(UISwitch *)sender {
    SGNagareSetCoreDSPEnabled(YES);
    SGNagareSetSmartEnhance(sender.isOn, self.smartSlider.value);
}

- (void)smartSliderMoved:(UISlider *)sender {
    SGNagareSetSmartEnhance(self.smartSwitch.isOn, sender.value);
}

- (void)vibeToggled:(UISwitch *)sender {
    SGNagareSetCoreDSPEnabled(YES);
    SGNagareSetVirtualBass(sender.isOn, self.vibeSlider.value, 120.0f);
}

- (void)vibeSliderMoved:(UISlider *)sender {
    SGNagareSetVirtualBass(self.vibeSwitch.isOn, sender.value, 120.0f);
}

- (void)tubeToggled:(UISwitch *)sender {
    SGNagareSetCoreDSPEnabled(YES);
    SGNagareSetTubeWarmth(sender.isOn, self.tubeSlider.value, 0.4f);
}

- (void)tubeSliderMoved:(UISlider *)sender {
    SGNagareSetTubeWarmth(self.tubeSwitch.isOn, sender.value, 0.4f);
}

- (void)exciterToggled:(UISwitch *)sender {
    SGNagareSetCoreDSPEnabled(YES);
    SGNagareSetExciter(sender.isOn, self.exciterSlider.value, 4000.0f);
    SGNagareSetAirBand(sender.isOn, self.exciterSlider.value);
}

- (void)exciterSliderMoved:(UISlider *)sender {
    SGNagareSetExciter(self.exciterSwitch.isOn, sender.value, 4000.0f);
    SGNagareSetAirBand(self.exciterSwitch.isOn, sender.value);
}

- (void)widthToggled:(UISwitch *)sender {
    SGNagareSetCoreDSPEnabled(YES);
    SGNagareSetStereoWidth(sender.isOn, 1.0f + sender.isOn * self.stereoWidthSlider.value);
}

- (void)widthSliderMoved:(UISlider *)sender {
    SGNagareSetStereoWidth(self.stereoWidthSwitch.isOn, 1.0f + sender.value);
}

- (void)crossfeedToggled:(UISwitch *)sender {
    SGNagareSetCoreDSPEnabled(YES);
    SGNagareSetCrossfeed(sender.isOn, self.crossfeedSlider.value);
}

- (void)crossfeedSliderMoved:(UISlider *)sender {
    SGNagareSetCrossfeed(self.crossfeedSwitch.isOn, sender.value);
}

- (void)reverbToggled:(UISwitch *)sender {
    SGNagareSetCoreDSPEnabled(YES);
    SGNagareSetReverb(sender.isOn, 0.5f, 0.5f, self.reverbSlider.value * 0.4f, 1.0f - self.reverbSlider.value * 0.2f, 1.0f);
}

- (void)reverbSliderMoved:(UISlider *)sender {
    SGNagareSetReverb(self.reverbSwitch.isOn, 0.5f, 0.5f, sender.value * 0.4f, 1.0f - sender.value * 0.2f, 1.0f);
}

@end
