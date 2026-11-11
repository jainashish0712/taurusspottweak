// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// SGNagareDSPViewController.m - Dedicated Nagare Audio DSP User Interface

#import "SGNagareDSPViewController.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/NagareDSP/SGNagareDSPBridge.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <mach/mach.h>
#import <dlfcn.h>

static const CGFloat kPadding = 18.0;

@interface SGNagareDSPViewController () <UIScrollViewDelegate>
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UISegmentedControl *tabPicker;

// Tab views
@property (nonatomic, strong) UIView *subsystemsTab;
@property (nonatomic, strong) UIView *coreChainTab;

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
@property (nonatomic, strong) UILabel *telemetryLabel;
@property (nonatomic) NSInteger telemetryTick;
@end

static float SGNagareDSPGetCPUUsage(void) {
    kern_return_t kr;
    thread_array_t thread_list;
    mach_msg_type_number_t thread_count;
    thread_info_data_t thinfo;
    mach_msg_type_number_t thread_info_count;
    thread_basic_info_t basic_info_th;

    kr = task_threads(mach_task_self(), &thread_list, &thread_count);
    if (kr != KERN_SUCCESS) return 0.0f;

    float tot_cpu = 0.0f;
    for (mach_msg_type_number_t j = 0; j < thread_count; j++) {
        thread_info_count = THREAD_INFO_MAX;
        kr = thread_info(thread_list[j], THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
        if (kr == KERN_SUCCESS) {
            basic_info_th = (thread_basic_info_t)thinfo;
            if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
                tot_cpu += basic_info_th->cpu_usage / (float)TH_USAGE_SCALE * 100.0f;
            }
        }
    }
    vm_deallocate(mach_task_self(), (vm_address_t)thread_list, thread_count * sizeof(thread_act_t));
    return tot_cpu;
}

static float SGNagareDSPGetGPUUsage(void) {
    static mach_port_t (*s_IOServiceGetMatchingService)(mach_port_t, CFDictionaryRef) = NULL;
    static CFMutableDictionaryRef (*s_IOServiceMatching)(const char *) = NULL;
    static kern_return_t (*s_IORegistryEntryCreateCFProperties)(mach_port_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t) = NULL;
    static BOOL s_checked = NO;
    static mach_port_t s_accel = 0;

    if (!s_checked) {
        s_checked = YES;
        s_IOServiceGetMatchingService = (mach_port_t (*)(mach_port_t, CFDictionaryRef))dlsym(RTLD_DEFAULT, "IOServiceGetMatchingService");
        s_IOServiceMatching = (CFMutableDictionaryRef (*)(const char *))dlsym(RTLD_DEFAULT, "IOServiceMatching");
        s_IORegistryEntryCreateCFProperties = (kern_return_t (*)(mach_port_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t))dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperties");

        if (s_IOServiceGetMatchingService && s_IOServiceMatching) {
            CFMutableDictionaryRef match = s_IOServiceMatching("IOAccelerator");
            if (match) {
                s_accel = s_IOServiceGetMatchingService(0, match);
            }
        }
    }

    if (!s_accel || !s_IORegistryEntryCreateCFProperties) {
        return -1.0f;
    }

    CFMutableDictionaryRef props = NULL;
    if (s_IORegistryEntryCreateCFProperties(s_accel, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
        NSDictionary *dict = (__bridge NSDictionary *)props;
        NSDictionary *perf = dict[@"PerformanceStatistics"];
        float usage = -1.0f;
        if ([perf isKindOfClass:NSDictionary.class]) {
            NSNumber *val = perf[@"Device Utilization %"] ?: perf[@"GPU Core Utilization"] ?: perf[@"GPU Activity(%)"];
            if (val) usage = [val floatValue];
        }
        CFRelease(props);
        return usage;
    }
    return -1.0f;
}

static NSString *SGNagareDSPGetThermalString(void) {
    if (@available(iOS 11.0, *)) {
        switch (NSProcessInfo.processInfo.thermalState) {
            case NSProcessInfoThermalStateNominal: return @"Nominal";
            case NSProcessInfoThermalStateFair:    return @"Fair";
            case NSProcessInfoThermalStateSerious: return @"Warm";
            case NSProcessInfoThermalStateCritical:return @"Hot";
        }
    }
    return @"Nominal";
}

static UIImage *sgr_emptyThumbImage(void) {
    static UIImage *img;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 1), NO, 0.0);
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return img;
}

static void stripSliderThumb(UISlider *slider) {
    if (!slider) return;
    UIImage *empty = sgr_emptyThumbImage();
    [slider setThumbImage:empty forState:UIControlStateNormal];
    [slider setThumbImage:empty forState:UIControlStateHighlighted];
    [slider setThumbImage:empty forState:UIControlStateSelected];
    [slider setThumbImage:empty forState:UIControlStateDisabled];
    slider.thumbTintColor = UIColor.clearColor;
}

@implementation SGNagareDSPViewController

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

    SGNagareDSPViewController *dspVC = [[SGNagareDSPViewController alloc] init];
    dspVC.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = dspVC.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[
                UISheetPresentationControllerDetent.mediumDetent,
                UISheetPresentationControllerDetent.largeDetent
            ];
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 24.0;
        }
    }
    [topVC presentViewController:dspVC animated:YES completion:nil];
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
    [self updateTelemetry];
    __weak __typeof__(self) weakSelf = self;
    self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.telemetryTick++;
        if (strongSelf.telemetryTick % 5 == 0) {
            [strongSelf updateTelemetry];
        }
    }];
}

- (void)updateTelemetry {
    float cpu = SGNagareDSPGetCPUUsage();
    float gpu = SGNagareDSPGetGPUUsage();
    NSString *thermal = SGNagareDSPGetThermalString();

    if (gpu >= 0.0f) {
        self.telemetryLabel.text = [NSString stringWithFormat:@"CPU: %.0f%% • GPU: %.0f%%", cpu, gpu];
    } else {
        self.telemetryLabel.text = [NSString stringWithFormat:@"CPU: %.0f%% • %@", cpu, thermal];
    }
}

- (void)stopMeterTimer {
    if (self.meterTimer) {
        [self.meterTimer invalidate];
        self.meterTimer = nil;
    }
}

#pragma mark - Header & Layout

- (void)setupHeader {
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.blurView.contentView addSubview:header];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"Nagare Audio DSP";
    titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    titleLabel.textColor = SGRPrimary();
    [header addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = @"Audiophile Mastering & Real-Time DSP";
    subtitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    subtitleLabel.textColor = SGRSecondary();
    [header addSubview:subtitleLabel];

    self.telemetryLabel = [[UILabel alloc] init];
    self.telemetryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.telemetryLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    self.telemetryLabel.textColor = SGRAccent();
    self.telemetryLabel.text = @"CPU: -- • GPU: --";
    self.telemetryLabel.textAlignment = NSTextAlignmentRight;
    [header addSubview:self.telemetryLabel];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:config] forState:UIControlStateNormal];
    closeBtn.tintColor = SGRTertiary();
    [closeBtn addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:closeBtn];

    // Segmented tab picker
    self.tabPicker = [[UISegmentedControl alloc] initWithItems:@[@"Subsystems", @"Core Chain"]];
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

        [self.telemetryLabel.centerYAnchor constraintEqualToAnchor:subtitleLabel.centerYAnchor],
        [self.telemetryLabel.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-10],

        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.telemetryLabel.leadingAnchor constant:-6],

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
    if (index == 0) target = self.subsystemsTab;
    else if (index == 1) target = self.coreChainTab;
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
    stripSliderThumb(self.upscalerSlider);
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
    stripSliderThumb(self.restorerSlider);
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
    stripSliderThumb(self.hrtfAngleSlider);
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
    stripSliderThumb(sl);
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

    self.smartSwitch.on = SGNagareIsSmartEnhanceEnabled();
    self.smartSlider.value = SGNagareGetSmartIntensity();

    self.vibeSwitch.on = SGNagareIsVirtualBassEnabled();
    self.vibeSlider.value = SGNagareGetVirtualBassIntensity();

    self.tubeSwitch.on = SGNagareIsTubeWarmthEnabled();
    self.tubeSlider.value = SGNagareGetTubeWarmthIntensity();

    self.exciterSwitch.on = SGNagareIsExciterEnabled();
    self.exciterSlider.value = SGNagareGetExciterIntensity();

    self.stereoWidthSwitch.on = SGNagareIsStereoWidthEnabled();
    self.stereoWidthSlider.value = MAX(0.0f, SGNagareGetStereoWidth() - 1.0f);

    self.crossfeedSwitch.on = SGNagareIsCrossfeedEnabled();
    self.crossfeedSlider.value = SGNagareGetCrossfeedAmount();

    self.reverbSwitch.on = SGNagareIsReverbEnabled();
    float revWet = SGNagareGetReverbIntensity();
    self.reverbSlider.value = revWet > 0.0f ? (revWet / 0.4f) : 0.5f;
}

#pragma mark - Actions

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

- (void)updateCoreDSPState {
    BOOL anyCoreActive = self.smartSwitch.isOn || self.vibeSwitch.isOn ||
                         self.tubeSwitch.isOn || self.exciterSwitch.isOn ||
                         self.stereoWidthSwitch.isOn || self.crossfeedSwitch.isOn ||
                         self.reverbSwitch.isOn;
    SGNagareSetCoreDSPEnabled(anyCoreActive);
}

// Core Chain
- (void)smartToggled:(UISwitch *)sender {
    SGNagareSetSmartEnhance(sender.isOn, self.smartSlider.value);
    [self updateCoreDSPState];
}

- (void)smartSliderMoved:(UISlider *)sender {
    SGNagareSetSmartEnhance(self.smartSwitch.isOn, sender.value);
}

- (void)vibeToggled:(UISwitch *)sender {
    SGNagareSetVirtualBass(sender.isOn, self.vibeSlider.value, 120.0f);
    [self updateCoreDSPState];
}

- (void)vibeSliderMoved:(UISlider *)sender {
    SGNagareSetVirtualBass(self.vibeSwitch.isOn, sender.value, 120.0f);
}

- (void)tubeToggled:(UISwitch *)sender {
    SGNagareSetTubeWarmth(sender.isOn, self.tubeSlider.value, 0.4f);
    [self updateCoreDSPState];
}

- (void)tubeSliderMoved:(UISlider *)sender {
    SGNagareSetTubeWarmth(self.tubeSwitch.isOn, sender.value, 0.4f);
}

- (void)exciterToggled:(UISwitch *)sender {
    SGNagareSetExciter(sender.isOn, self.exciterSlider.value, 4000.0f);
    SGNagareSetAirBand(sender.isOn, self.exciterSlider.value);
    [self updateCoreDSPState];
}

- (void)exciterSliderMoved:(UISlider *)sender {
    SGNagareSetExciter(self.exciterSwitch.isOn, sender.value, 4000.0f);
    SGNagareSetAirBand(self.exciterSwitch.isOn, sender.value);
}

- (void)widthToggled:(UISwitch *)sender {
    SGNagareSetStereoWidth(sender.isOn, 1.0f + (sender.isOn ? self.stereoWidthSlider.value : 0.0f));
    [self updateCoreDSPState];
}

- (void)widthSliderMoved:(UISlider *)sender {
    SGNagareSetStereoWidth(self.stereoWidthSwitch.isOn, 1.0f + (self.stereoWidthSwitch.isOn ? sender.value : 0.0f));
}

- (void)crossfeedToggled:(UISwitch *)sender {
    SGNagareSetCrossfeed(sender.isOn, sender.isOn ? self.crossfeedSlider.value : 0.0f);
    [self updateCoreDSPState];
}

- (void)crossfeedSliderMoved:(UISlider *)sender {
    SGNagareSetCrossfeed(self.crossfeedSwitch.isOn, self.crossfeedSwitch.isOn ? sender.value : 0.0f);
}

- (void)reverbToggled:(UISwitch *)sender {
    float wet = sender.isOn ? (self.reverbSlider.value * 0.4f) : 0.0f;
    float dry = sender.isOn ? (1.0f - self.reverbSlider.value * 0.2f) : 1.0f;
    SGNagareSetReverb(sender.isOn, 0.5f, 0.5f, wet, dry, 1.0f);
    [self updateCoreDSPState];
}

- (void)reverbSliderMoved:(UISlider *)sender {
    float wet = self.reverbSwitch.isOn ? (sender.value * 0.4f) : 0.0f;
    float dry = self.reverbSwitch.isOn ? (1.0f - sender.value * 0.2f) : 1.0f;
    SGNagareSetReverb(self.reverbSwitch.isOn, 0.5f, 0.5f, wet, dry, 1.0f);
}

@end
