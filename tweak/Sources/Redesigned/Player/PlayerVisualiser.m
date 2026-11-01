// Player redesign: the Visualizer background, a calm spectrum of what is playing behind the player, in the
// cover's colors, over the Fluid field held still (PlayerField.x keeps the field Fluid for this choice, as for
// Animated, so the ⋯ menu moves between all six background styles without a restart).
//
// The sound is Spotify's output as it plays, read on the render thread through the audio effects' notify
// (SGAudioSetOutputReader, Shared/AudioEffects/AudioEffects.h) into SGRSpectrum.m's bands. Here, on the main
// thread, a display link reads the bands, brings them to a share of the song's own loudness (the loudest band of
// the last few seconds at the top, so a quiet track moves as much as a loud one), eases each band up quickly
// and down slowly, and draws two soft hills across the foot of the screen, mirrored about its middle, the bass
// in the middle and the treble at either edge: a slow one behind, a quicker one in front. Each is a gradient of
// the cover's colors (SGRPalette's flow colors, kept dark enough that white text on them stays over 5.5:1)
// masked by a shape layer, so the render server does the drawing and the app only hands it two paths a frame.
//
// It moves only while it is in a window, Spotify is in front, the player is not opening or closing, Low Power
// Mode is off and the song plays; a pause lets the hills settle and the link stops, and nothing is read from
// the sound while it is stopped. At most 60 frames a second, 30 while the lyrics, which have a link of their own,
// are open and the hills are blurred behind them, and with Reduce Motion 15, with every band easing over
// seconds. While the player opens or closes the link is down, and comes back only once the animation is over:
// a link at 60 would hold the transition's 120 Hz down with it.
//
// ponytail: the hills follow what the output is handed, which a Bluetooth headset plays a fifth of a second or
// so later. Music Haptics schedules for the output latency; do the same here if the beat looks early on AirPods.
//
// Threading: main thread only, but for the reader, which runs on the render thread.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Audio/SGAudioPipeline.h"
#import "Shared/AudioEffects/AudioEffects.h"
#import "Shared/Player/PlayerEvents.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Player.h"
#import "SGRSpectrum.h"

enum { kBands = SGRSpectrumBands, kPoints = 2 * kBands - 1 };
// The loudness a band is drawn against: the loudest band of late at the top, kRange dB under it at the floor,
// the top falling kPeakFall dB a second after a loud passage and never under kPeakFloor, so silence stays flat.
static const float kRange = 40, kPeakFall = 4, kPeakFloor = -60;
// A rise toward the treble, in dB a band (three bands an octave), since music has less there: a tuning knob.
static const float kTilt = 0.6f;
// How quickly a band eases toward its level, up and down, in seconds; the hill behind is slower. With Reduce
// Motion both ease over kStillEase.
static const double kFrontUp = 0.08, kFrontDown = 0.4, kBackUp = 0.3, kBackDown = 0.9, kStillEase = 3;
// No new bands for this long reads as silence (a pause, a stall, a tap that never ran).
static const double kStale = 0.3;
// The hills' height at their tallest and at rest, as shares of the screen's height; the one behind is taller.
static const CGFloat kFrontHeight = 0.24, kBackHeight = 0.3, kRestHeight = 0.012;
// Below this every band has settled (under 2 pt at the top of the front hill), and a paused song's link can stop.
static const float kSettled = 0.02f;
// Each band shares this much with either neighbor, twice over, so one loud band is a hill and not a spike.
static const float kSpread = 0.25f;
static const NSTimeInterval kTransitionSlack = 0.05;

static NSUInteger sg_readers;

static void onAudioRender(const float *samples, UInt32 count, double sampleRate) {
    SGRSpectrumFeed(samples, count, sampleRate);
}

// The reader on while any view is moving, so nothing is analyzed while none is.
static void needReader(BOOL need) {
    if (need) {
        if (sg_readers++ == 0) {
            SGRSpectrumPrepare();
            SGAudioPipelineSetOutputReader(onAudioRender);
        }
    } else if (sg_readers && --sg_readers == 0) {
        SGAudioPipelineSetOutputReader(NULL);
    }
}

static NSDictionary *noActions(void) {
    static NSDictionary *none;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNull *off = NSNull.null;
        none = @{@"bounds": off, @"position": off, @"frame": off, @"path": off, @"colors": off};
    });
    return none;
}

@interface SGRVisualiserView : UIView <SGPlayerStateObserver>
// Where the hills stand, in points from the top: the screen's foot in the player. 0 is the bounds' foot.
@property (nonatomic) CGFloat baseline;
// The height the hills are a share of; 0 is the bounds' height.
@property (nonatomic) CGFloat screenHeight;
@property (nonatomic, readonly) BOOL blurred;
- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated;
- (void)appear:(BOOL)animated;
- (void)disappear:(void (^)(void))done;
@end

@implementation SGRVisualiserView {
    UIView *_content;   // the hills, faded in and out as one
    CAGradientLayer *_backFill, *_frontFill;
    CAShapeLayer *_backShape, *_frontShape;
    UIVisualEffectView *_lyricsBlur;
    UIViewPropertyAnimator *_lyricsBlurAnimator;
    BOOL _lyricsRequested;
    CADisplayLink *_link;
    BOOL _reading, _idle;
    float _front[kBands], _back[kBands], _peak;
    uint64_t _generation;
    CFTimeInterval _fresh, _last;
    NSUInteger _palette;
}

// As PlayerMotion.x: what fades is the effect view's effect, never its alpha or an ancestor's.
static UIBlurEffect *blurEffect(void) {
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

static UIViewPropertyAnimator *setBlurIntensity(UIVisualEffectView *view, UIViewPropertyAnimator *animator, CGFloat intensity) {
    intensity = MIN(1, MAX(0, intensity));
    if (animator && animator.state != UIViewAnimatingStateInactive) [animator stopAnimation:YES];
    view.effect = nil;
    if (intensity <= 0) return nil;

    __weak UIVisualEffectView *weakView = view;
    UIViewPropertyAnimator *fractional = [[UIViewPropertyAnimator alloc] initWithDuration:1
                                                                                    curve:UIViewAnimationCurveLinear
                                                                               animations:^{
        weakView.effect = blurEffect();
    }];
    [fractional startAnimation];
    [fractional pauseAnimation];
    fractional.fractionComplete = intensity;
    return fractional;
}

static CAGradientLayer *fill(CAShapeLayer *shape) {
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.actions = noActions();
    layer.startPoint = CGPointMake(0, 0.5);
    layer.endPoint = CGPointMake(1, 0.5);
    shape.actions = noActions();
    layer.mask = shape;
    return layer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    _peak = kPeakFloor;
    _content = [[UIView alloc] initWithFrame:frame];
    _backShape = [CAShapeLayer layer];
    _backFill = fill(_backShape);
    _backFill.opacity = 0.55f;
    [_content.layer addSublayer:_backFill];
    _frontShape = [CAShapeLayer layer];
    _frontFill = fill(_frontShape);
    [_content.layer addSublayer:_frontFill];
    [self addSubview:_content];
    _lyricsBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _lyricsBlur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_lyricsBlur];
    [self applyColors:@[UIColor.darkGrayColor, UIColor.darkGrayColor, UIColor.darkGrayColor, UIColor.darkGrayColor, UIColor.darkGrayColor]];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      NSProcessInfoPowerStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        [center addObserver:self selector:@selector(updateMotionSoon) name:name object:nil];
    }
    [center addObserver:self selector:@selector(artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(artworkChanged) name:@"SGRKawarpParametersDidChangeNotification" object:nil];
    [center addObserver:self selector:@selector(updateBlurOpacity) name:SGRPlayerBlurOpacityDidChangeNotification object:nil];
    [self updateBlurOpacity];
    SGRObservePlayerTransition(self, ^(id owner) { [owner updateMotion]; }, ^(id owner) { [owner updateMotion]; });
    SGAddPlayerStateObserver(self);
    [self artworkChanged];
    [self draw];
    return self;
}

- (void)dealloc {
    [self setReading:NO];
    [self setMoving:NO];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_lyricsBlurAnimator && _lyricsBlurAnimator.state != UIViewAnimatingStateInactive) [_lyricsBlurAnimator stopAnimation:YES];
}

- (void)updateBlurOpacity {
    CGFloat opacity = MIN(100, MAX(0, SGInt(SGRKeyPlayerVisualiserBlurOpacity, 100))) / 100.0;
    _lyricsBlurAnimator = setBlurIntensity(_lyricsBlur, _lyricsBlurAnimator, _lyricsRequested ? opacity : 0);
}

#pragma mark - color

// Bottom left, the whole cover and bottom right in front, the top two behind, so the hills read as the cover's
// lower half under its upper.
- (void)applyColors:(NSArray<UIColor *> *)colors {
    if (colors.count < 5) return;
    _frontFill.colors = @[(id)colors[2].CGColor, (id)colors[4].CGColor, (id)colors[3].CGColor];
    _backFill.colors = @[(id)colors[0].CGColor, (id)colors[1].CGColor];
}

- (void)artworkChanged {
    UIImage *image = SGRNowPlayingArtwork(NULL, NULL);
    if (!image) return;
    NSUInteger generation = ++_palette;
    SGRPaletteRequest request = {CGSizeZero, NO, YES, YES, NO};
    __weak SGRVisualiserView *weakSelf = self;
    [SGRPalette paletteForImage:image request:request completion:^(SGRPalette *palette) {
        SGRVisualiserView *view = weakSelf;
        if (!view || !palette.flowColors || generation != view->_palette) return;
        if (!view.window) {
            [view applyColors:palette.flowColors];
            return;
        }
        // The colors cross over as the field's do.
        [CATransaction begin];
        [CATransaction setAnimationDuration:SGRCrossfade];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        for (CAGradientLayer *layer in @[view->_frontFill, view->_backFill]) {
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"colors"];
            fade.fromValue = (layer.presentationLayer ?: layer).colors;
            [layer addAnimation:fade forKey:@"colors"];
        }
        [view applyColors:palette.flowColors];
        [CATransaction commit];
    }];
}

#pragma mark - showing

- (void)setBaseline:(CGFloat)baseline {
    if (baseline == _baseline) return;
    _baseline = baseline;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _content.frame = bounds;
    _lyricsBlur.frame = bounds;
    _backFill.frame = bounds;
    _frontFill.frame = bounds;
    _backShape.frame = bounds;
    _frontShape.frame = bounds;
    [self draw];
}

- (void)appear:(BOOL)animated {
    _content.alpha = 0;
    if (animated) SGRAnimate(SGRMotionFade, ^{ self->_content.alpha = 1; }, nil);
    else _content.alpha = 1;
}

- (void)disappear:(void (^)(void))done {
    [self setReading:NO];
    [self setMoving:NO];
    SGRAnimate(SGRMotionFade, ^{
        self->_content.alpha = 0;
        self->_lyricsRequested = NO;
        self->_lyricsBlurAnimator = setBlurIntensity(self->_lyricsBlur, self->_lyricsBlurAnimator, 0);
    }, ^(BOOL finished) { done(); });
}

- (BOOL)blurred {
    return _lyricsRequested;
}

- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated {
    _lyricsRequested = blurred;
    CGFloat opacity = MIN(100, MAX(0, SGInt(SGRKeyPlayerVisualiserBlurOpacity, 100))) / 100.0;
    void (^apply)(void) = ^{
        self->_lyricsBlurAnimator = setBlurIntensity(self->_lyricsBlur, self->_lyricsBlurAnimator, blurred ? opacity : 0);
    };
    if (animated) SGRAnimate(SGRMotionFade, apply, nil);
    else apply();
    [self updateMotion];
}

#pragma mark - moving

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updateMotion];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateMotion];
}

// The power state is reported off the main thread.
- (void)updateMotionSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateMotion]; });
}

- (BOOL)settled {
    for (int band = 0; band < kBands; band++) if (_front[band] > kSettled || _back[band] > kSettled) return NO;
    return YES;
}

// Moving while it may and there is something to show: the song playing, or the hills still settling after it
// stopped. While the player animates, it comes back once the animation is expected to be over.
- (void)updateMotion {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateMotion) object:nil];
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL may = self.window && front && !NSProcessInfo.processInfo.lowPowerModeEnabled;
    NSTimeInterval wait = SGPlayerTransitionEnds() - CACurrentMediaTime();
    if (may && (wait > 0 || SGRPlayerIsTransitioning())) {
        may = NO;
        // Without an expected end, the transition's ended notification brings it back.
        if (wait > 0) [self performSelector:@selector(updateMotion) withObject:nil afterDelay:wait + kTransitionSlack inModes:@[NSRunLoopCommonModes]];
    }
    BOOL playing = !SGPlayerState().isPaused;
    [self setMoving:may && (playing || !self.settled)];
    [self setReading:may && playing];
}

- (void)setReading:(BOOL)reading {
    if (reading == _reading) return;
    _reading = reading;
    needReader(reading);
}

- (void)setMoving:(BOOL)moving {
    if (moving) {
        if (!_link) {
            _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
            [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            _last = 0;
        }
        // Calmer behind the lyrics, whose own link runs at the display's rate, and calmest with Reduce Motion.
        // While a playing song sends nothing (a stall, or no tap at all), a few frames a second watch for it.
        float most = _idle ? 4 : SGRReduceMotion() ? 15 : _lyricsBlur.effect ? 30 : 60;
        _link.preferredFrameRateRange = CAFrameRateRangeMake(most / 2, most, most);
    } else if (_link) {
        [_link invalidate];
        _link = nil;
    }
}

static float ease(float value, float target, double dt, double up, double down) {
    double tau = target > value ? up : down;
    return value + (target - value) * (float)(1 - exp(-dt / tau));
}

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    double dt = _last ? MIN(now - _last, 0.1) : link.duration;
    _last = now;
    float levels[kBands];
    uint64_t generation = SGRSpectrumRead(levels);
    if (generation != _generation) {
        _generation = generation;
        _fresh = now;
    }
    BOOL silent = !_reading || now - _fresh > kStale;
    float loudest = kPeakFloor;
    for (int band = 0; band < kBands; band++) {
        levels[band] += kTilt * band;
        loudest = fmaxf(loudest, levels[band]);
    }
    if (!silent) _peak = fmaxf(fmaxf(loudest, _peak - kPeakFall * (float)dt), kPeakFloor);
    BOOL still = SGRReduceMotion();
    float targets[kBands];
    for (int band = 0; band < kBands; band++) targets[band] = silent ? 0 : fminf(1, fmaxf(0, (levels[band] - (_peak - kRange)) / kRange));
    for (int pass = 0; pass < 2; pass++) {
        float before = targets[0];
        for (int band = 0; band < kBands; band++) {
            float here = targets[band], next = targets[MIN(band + 1, kBands - 1)];
            targets[band] = kSpread * before + (1 - 2 * kSpread) * here + kSpread * next;
            before = here;
        }
    }
    for (int band = 0; band < kBands; band++) {
        float target = targets[band];
        _front[band] = ease(_front[band], target, dt, still ? kStillEase : kFrontUp, still ? kStillEase : kFrontDown);
        _back[band] = ease(_back[band], target, dt, still ? kStillEase : kBackUp, still ? kStillEase : kBackDown);
    }
    [self draw];
    BOOL idle = silent && self.settled;
    if (idle && !_idle) {
        // The last step down to rest, too small to see, so a settled hill is drawn exactly at rest.
        memset(_front, 0, sizeof _front);
        memset(_back, 0, sizeof _back);
        [self draw];
    }
    if (idle != _idle) {
        _idle = idle;
        [self updateMotion];
    }
}

#pragma mark - drawing

// A smooth line through the points (Catmull-Rom as cubic Béziers), closed down to the foot of the bounds.
static CGPathRef hillPath(const CGPoint *points, int count, CGFloat foot) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, points[0].x, foot);
    CGPathAddLineToPoint(path, NULL, points[0].x, points[0].y);
    for (int i = 0; i < count - 1; i++) {
        CGPoint before = points[MAX(i - 1, 0)], from = points[i], to = points[i + 1], after = points[MIN(i + 2, count - 1)];
        CGPathAddCurveToPoint(path, NULL, from.x + (to.x - before.x) / 6, from.y + (to.y - before.y) / 6,
                              to.x - (after.x - from.x) / 6, to.y - (after.y - from.y) / 6, to.x, to.y);
    }
    CGPathAddLineToPoint(path, NULL, points[count - 1].x, foot);
    CGPathCloseSubpath(path);
    return path;
}

// The bass in the middle, each band out to either side, the treble at the edges; a band's height eased in so
// quiet bands lie low and only the strong ones stand up.
static void shape(CAShapeLayer *layer, const float *bands, CGFloat width, CGFloat baseline, CGFloat foot, CGFloat tallest, CGFloat rest) {
    CGPoint points[kPoints];
    for (int i = 0; i < kPoints; i++) {
        float value = bands[abs(i - (kBands - 1))];
        CGFloat height = rest + (tallest - rest) * powf(value, 1.2f);
        points[i] = CGPointMake(width * i / (kPoints - 1), baseline - height);
    }
    CGPathRef path = hillPath(points, kPoints, foot);
    layer.path = path;
    CGPathRelease(path);
}

- (void)draw {
    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0) return;
    CGFloat baseline = _baseline > 0 ? _baseline : bounds.size.height;
    CGFloat screen = _screenHeight > 0 ? _screenHeight : bounds.size.height;
    CGFloat foot = MAX(baseline, bounds.size.height), rest = round(screen * kRestHeight);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shape(_backShape, _back, bounds.size.width, baseline, foot, screen * kBackHeight, rest * 1.5);
    shape(_frontShape, _front, bounds.size.width, baseline, foot, screen * kFrontHeight, rest);
    [CATransaction commit];
}

@end

#pragma mark - in the player

static SGRVisualiserView *sg_view;

BOOL SGRPlayerVisualiserShowing(void) {
    SGRPlayerBackgroundKind background = SGRPlayerBackground();
    return background == SGRPlayerBackgroundVisualiser
        || (background == SGRPlayerBackgroundAnimated
            && SGRPlayerAnimatedFallback() == SGRPlayerBackgroundVisualiser);
}

// One preview view, reused: the Player page tears its old one down on every tap of the background control,
// and each of those teardowns races the display link and the palette read it had just started.
UIView *SGRPlayerVisualiserPreview(void) {
    static SGRVisualiserView *view;
    if (!view) view = [[SGRVisualiserView alloc] initWithFrame:CGRectZero];
    return view;
}

// The hills from the top of the field to the foot of its bleed, standing on the screen's foot.
static void layOut(SGRArtworkField *field) {
    if (sg_view.superview != field) [field addSubview:sg_view];
    else if (field.subviews.lastObject != sg_view) [field bringSubviewToFront:sg_view];
    CGSize size = field.bounds.size;
    CGFloat screen = field.window.bounds.size.height ?: size.height;
    CGRect frame = CGRectMake(0, 0, size.width, MAX(size.height, screen) + field.bleed.bottom);
    if (!CGRectEqualToRect(sg_view.frame, frame)) sg_view.frame = frame;
    sg_view.baseline = screen;
    sg_view.screenHeight = screen;
}

void SGRPlayerVisualiserUpdate(void) {
    SGRArtworkField *field = SGRPlayerField();
    // Not over an Animated artwork clip still playing: the Player page can change the choice under it, which the
    // player takes up when it next starts.
    BOOL wanted = SGRPlayerVisualiserShowing() && field && !SGRPlayerMotionShowing();
    if (!wanted) {
        SGRVisualiserView *old = sg_view;
        sg_view = nil;
        if (old.window) [old disappear:^{ [old removeFromSuperview]; }];
        else [old removeFromSuperview];
        return;
    }
    BOOL made = !sg_view;
    if (made) sg_view = [[SGRVisualiserView alloc] initWithFrame:CGRectZero];
    layOut(field);
    if (made) {
        [sg_view setBlurred:SGRPlayerLyricsOpen() animated:NO];
        [sg_view appear:field.window != nil];
        SGLog(@"redesign player: visualizer on the field");
    } else {
        BOOL open = SGRPlayerLyricsOpen();
        if (open != sg_view.blurred) [sg_view setBlurred:open animated:sg_view.window != nil];
    }
}


#pragma mark - Kawarp Fluid Domain Warping

enum { kKawarpBlurSize = 128 };

static NSString *const kShaderSource = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct VertexOut {\n"
"    float4 position [[position]];\n"
"    float2 texCoord;\n"
"};\n"
"\n"
"vertex VertexOut kawarpVertex(uint vertexID [[vertex_id]]) {\n"
"    const float2 pos[6] = {\n"
"        float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),\n"
"        float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)\n"
"    };\n"
"    const float2 uv[6] = {\n"
"        float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0),\n"
"        float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0)\n"
"    };\n"
"    VertexOut out;\n"
"    out.position = float4(pos[vertexID], 0.0, 1.0);\n"
"    out.texCoord = uv[vertexID];\n"
"    return out;\n"
"}\n"
"\n"
"fragment float4 kawarpTintFragment(\n"
"    VertexOut in [[stage_in]],\n"
"    texture2d<float> tex [[texture(0)]],\n"
"    sampler s [[sampler(0)]],\n"
"    constant float3 &tintColor [[buffer(0)]],\n"
"    constant float &tintIntensity [[buffer(1)]]\n"
") {\n"
"    float4 color = tex.sample(s, in.texCoord);\n"
"    float luma = dot(color.rgb, float3(0.299, 0.587, 0.114));\n"
"    float darkMask = 1.0 - smoothstep(0.0, 0.5, luma);\n"
"    color.rgb = mix(color.rgb, tintColor, darkMask * tintIntensity);\n"
"    return color;\n"
"}\n"
"\n"
"fragment float4 kawaseBlurFragment(\n"
"    VertexOut in [[stage_in]],\n"
"    texture2d<float> tex [[texture(0)]],\n"
"    sampler s [[sampler(0)]],\n"
"    constant float &offset [[buffer(0)]]\n"
") {\n"
"    float2 texelSize = 1.0 / float2(128.0, 128.0);\n"
"    float4 color = 0.0;\n"
"    color += tex.sample(s, in.texCoord + float2(-offset, -offset) * texelSize);\n"
"    color += tex.sample(s, in.texCoord + float2( offset, -offset) * texelSize);\n"
"    color += tex.sample(s, in.texCoord + float2(-offset,  offset) * texelSize);\n"
"    color += tex.sample(s, in.texCoord + float2( offset,  offset) * texelSize);\n"
"    return color * 0.25;\n"
"}\n"
"\n"
"static inline float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }\n"
"static inline float2 mod289(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }\n"
"static inline float3 permute(float3 x) { return mod289(((x * 34.0) + 1.0) * x); }\n"
"\n"
"static inline float snoise(float2 v) {\n"
"    const float4 C = float4(0.211324865405187, 0.366025403784439,\n"
"                            -0.577350269189626, 0.024390243902439);\n"
"    float2 i  = floor(v + dot(v, float2(C.y, C.y)));\n"
"    float2 x0 = v - i + dot(i, float2(C.x, C.x));\n"
"    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);\n"
"    float4 x12 = float4(x0.x, x0.y, x0.x, x0.y) + float4(C.x, C.x, C.z, C.z);\n"
"    x12.x -= i1.x;\n"
"    x12.y -= i1.y;\n"
"    float2 i_mod = mod289(i);\n"
"    float3 p = permute(permute(i_mod.y + float3(0.0, i1.y, 1.0)) + i_mod.x + float3(0.0, i1.x, 1.0));\n"
"    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);\n"
"    m = m * m; m = m * m;\n"
"    float3 x = 2.0 * fract(p * C.w) - 1.0;\n"
"    float3 h = abs(x) - 0.5;\n"
"    float3 ox = floor(x + 0.5);\n"
"    float3 a0 = x - ox;\n"
"    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);\n"
"    float3 g;\n"
"    g.x = a0.x * x0.x + h.x * x0.y;\n"
"    g.y = a0.y * x12.x + h.y * x12.y;\n"
"    g.z = a0.z * x12.z + h.z * x12.w;\n"
"    return 130.0 * dot(m, g);\n"
"}\n"
"\n"
"static inline float hash31(float3 p) {\n"
"    p = fract(p * 0.1031);\n"
"    p += dot(p, float3(p.z, p.y, p.x) + 31.32);\n"
"    return fract((p.x + p.y) * p.z);\n"
"}\n"
"\n"
"struct KawarpUniforms {\n"
"    float time;\n"
"    float intensity;\n"
"    float saturation;\n"
"    float dithering;\n"
"    float scale;\n"
"    float blend;\n"
"    float2 resolution;\n"
"};\n"
"\n"
"fragment float4 kawarpMainFragment(\n"
"    VertexOut in [[stage_in]],\n"
"    texture2d<float> texCurrent [[texture(0)]],\n"
"    texture2d<float> texNext [[texture(1)]],\n"
"    sampler s [[sampler(0)]],\n"
"    constant KawarpUniforms &u [[buffer(0)]]\n"
") {\n"
"    float2 uv = (in.texCoord - 0.5) / u.scale + 0.5;\n"
"    uv = clamp(uv, 0.0, 1.0);\n"
"    float t = u.time * 0.05;\n"
"\n"
"    float2 center = uv - 0.5;\n"
"    float centerWeight = 1.0 - smoothstep(0.0, 0.7, length(center));\n"
"\n"
"    float n1 = snoise(uv * 0.35 + float2(t, t * 0.7));\n"
"    float n2 = snoise(uv * 0.35 + float2(-t * 0.8, t * 0.5) + float2(50.0, 50.0));\n"
"    float n3 = snoise(uv * 0.9 + float2(t * 1.2, -t) + float2(100.0, 0.0));\n"
"    float n4 = snoise(uv * 0.9 + float2(-t, t * 1.1) + float2(0.0, 100.0));\n"
"\n"
"    float2 warp = float2(\n"
"        n1 * 0.65 + n3 * 0.35,\n"
"        n2 * 0.65 + n4 * 0.35\n"
"    ) * centerWeight;\n"
"\n"
"    float2 warpedUV = uv + warp * u.intensity;\n"
"    warpedUV = clamp(warpedUV, 0.0, 1.0);\n"
"\n"
"    float4 color1 = texCurrent.sample(s, warpedUV);\n"
"    float4 color2 = texNext.sample(s, warpedUV);\n"
"    float4 color = mix(color1, color2, u.blend);\n"
"\n"
"    float2 vCenter = in.texCoord - 0.5;\n"
"    float vignette = 1.0 - dot(vCenter, vCenter) * 0.3;\n"
"    color.rgb *= vignette;\n"
"\n"
"    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));\n"
"    color.rgb = mix(float3(gray), color.rgb, u.saturation);\n"
"\n"
"    float2 pixelPos = floor(in.texCoord * u.resolution);\n"
"    float noise = hash31(float3(pixelPos, floor(u.time * 60.0)));\n"
"    color.rgb += (noise - 0.5) * u.dithering;\n"
"\n"
"    return color;\n"
"}\n";

struct KawarpUniforms {
    float time;
    float intensity;
    float saturation;
    float dithering;
    float scale;
    float blend;
    simd_float2 resolution;
};

@interface SGRKawarpView : UIView <SGPlayerStateObserver>
@property (nonatomic, readonly) BOOL blurred;
- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated;
- (void)appear:(BOOL)animated;
- (void)disappear:(void (^)(void))done;
@end

@implementation SGRKawarpView {
    CAMetalLayer *_metalLayer;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _tintPipeline;
    id<MTLRenderPipelineState> _blurPipeline;
    id<MTLRenderPipelineState> _mainPipeline;
    id<MTLSamplerState> _sampler;

    id<MTLTexture> _blurTexture1;
    id<MTLTexture> _blurTexture2;
    id<MTLTexture> _currentTexture;
    id<MTLTexture> _nextTexture;

    CADisplayLink *_link;
    CFTimeInterval _lastFrameTime;
    double _accumulatedTime;
    CFTimeInterval _transitionStart;
    BOOL _transitioning;
    BOOL _hasImage;

    UIVisualEffectView *_lyricsBlur;
    UIViewPropertyAnimator *_lyricsBlurAnimator;
    BOOL _lyricsRequested;
}

+ (Class)layerClass {
    return [CAMetalLayer class];
}



- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        SGLog(@"kawarp: Metal is not available on this device");
        return nil;
    }

    _queue = [_device newCommandQueue];
    _metalLayer = (CAMetalLayer *)self.layer;
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.opaque = YES;

    if (![self setupMetalPipelines]) return nil;
    [self setupTextures];

    _lyricsBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _lyricsBlur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_lyricsBlur];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      NSProcessInfoPowerStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        [center addObserver:self selector:@selector(updateMotionSoon) name:name object:nil];
    }
    [center addObserver:self selector:@selector(artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    SGRObservePlayerTransition(self, ^(id owner) { [owner updateMotion]; }, ^(id owner) { [owner updateMotion]; });
    SGAddPlayerStateObserver(self);

    [self artworkChanged];
    return self;
}

- (void)dealloc {
    [self setMoving:NO];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_lyricsBlurAnimator && _lyricsBlurAnimator.state != UIViewAnimatingStateInactive) [_lyricsBlurAnimator stopAnimation:YES];
}

- (BOOL)setupMetalPipelines {
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kShaderSource options:nil error:&error];
    if (!library || error) {
        SGLog(@"kawarp: shader compilation failed: %@", error);
        return NO;
    }

    id<MTLFunction> vertexFn = [library newFunctionWithName:@"kawarpVertex"];
    id<MTLFunction> tintFn = [library newFunctionWithName:@"kawarpTintFragment"];
    id<MTLFunction> blurFn = [library newFunctionWithName:@"kawaseBlurFragment"];
    id<MTLFunction> mainFn = [library newFunctionWithName:@"kawarpMainFragment"];

    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = vertexFn;

    // Ping-pong blur textures are RGBA8Unorm
    desc.fragmentFunction = tintFn;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    _tintPipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];

    desc.fragmentFunction = blurFn;
    _blurPipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];

    // Screen output pipeline
    desc.fragmentFunction = mainFn;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _mainPipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];

    MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
    samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [_device newSamplerStateWithDescriptor:samplerDesc];

    return _tintPipeline && _blurPipeline && _mainPipeline && _sampler;
}

- (void)setupTextures {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:kKawarpBlurSize
                                                                                   height:kKawarpBlurSize
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    _blurTexture1 = [_device newTextureWithDescriptor:desc];
    _blurTexture2 = [_device newTextureWithDescriptor:desc];
    _currentTexture = [_device newTextureWithDescriptor:desc];
    _nextTexture = [_device newTextureWithDescriptor:desc];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _lyricsBlur.frame = bounds;
    CGSize nativeSize = CGSizeMake(bounds.size.width * self.contentScaleFactor, bounds.size.height * self.contentScaleFactor);
    if (!CGSizeEqualToSize(_metalLayer.drawableSize, nativeSize) && nativeSize.width > 0 && nativeSize.height > 0) {
        _metalLayer.drawableSize = nativeSize;
    }
}

#pragma mark - artwork & blur

- (void)artworkChanged {
    UIImage *image = SGRNowPlayingArtwork(NULL, NULL);
    if (!image) return;

    // Draw image to 128x128 32-bit RGBA bitmap
    size_t width = kKawarpBlurSize, height = kKawarpBlurSize;
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(data.mutableBytes, width, height, 8, width * 4, space,
                                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return;

    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image.CGImage);
    CGContextRelease(ctx);

    MTLTextureDescriptor *srcDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                       width:width
                                                                                      height:height
                                                                                   mipmapped:NO];
    id<MTLTexture> rawTexture = [_device newTextureWithDescriptor:srcDesc];
    [rawTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                  mipmapLevel:0
                    withBytes:data.bytes
                  bytesPerRow:width * 4];

    // Step 1: Pre-tint dark areas -> _blurTexture1
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = _blurTexture1;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_tintPipeline];
    [enc setFragmentTexture:rawTexture atIndex:0];
    [enc setFragmentSamplerState:_sampler atIndex:0];

    NSInteger tintRGB = SGInt(SGRKeyKawarpTintColor, 0x28283C);
    float tr = ((tintRGB >> 16) & 0xFF) / 255.0f;
    float tg = ((tintRGB >> 8) & 0xFF) / 255.0f;
    float tb = (tintRGB & 0xFF) / 255.0f;
    simd_float3 tintColor = simd_make_float3(tr, tg, tb);
    float tintIntensity = (float)SGInt(SGRKeyKawarpTint, 15) / 100.0f;
    [enc setFragmentBytes:&tintColor length:sizeof(tintColor) atIndex:0];
    [enc setFragmentBytes:&tintIntensity length:sizeof(tintIntensity) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];

    // Step 2: Kawase blur ping-ponging
    int blurPasses = (int)SGInt(SGRKeyKawarpBlur, 8);
    blurPasses = MAX(1, MIN(blurPasses, 40));
    id<MTLTexture> readTex = _blurTexture1;
    id<MTLTexture> writeTex = _blurTexture2;
    for (int i = 0; i < blurPasses; i++) {
        pass.colorAttachments[0].texture = writeTex;
        enc = [cmd renderCommandEncoderWithDescriptor:pass];
        [enc setRenderPipelineState:_blurPipeline];
        [enc setFragmentTexture:readTex atIndex:0];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        float offset = (float)i + 0.5f;
        [enc setFragmentBytes:&offset length:sizeof(offset) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [enc endEncoding];

        id<MTLTexture> swap = readTex;
        readTex = writeTex;
        writeTex = swap;
    }

    // Step 3: Copy to next texture
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    if (!_hasImage) {
        [blit copyFromTexture:readTex toTexture:_currentTexture];
        [blit copyFromTexture:readTex toTexture:_nextTexture];
        _hasImage = YES;
        _transitioning = NO;
    } else {
        id<MTLTexture> swap = _currentTexture;
        _currentTexture = _nextTexture;
        _nextTexture = swap;
        [blit copyFromTexture:readTex toTexture:_nextTexture];
        _transitioning = YES;
        _transitionStart = CACurrentMediaTime();
    }
    [blit endEncoding];
    [cmd commit];
}

#pragma mark - display loop

- (void)appear:(BOOL)animated {
    self.alpha = 0;
    if (animated) SGRAnimate(SGRMotionFade, ^{ self.alpha = 1; }, nil);
    else self.alpha = 1;
}

- (void)disappear:(void (^)(void))done {
    [self setMoving:NO];
    SGRAnimate(SGRMotionFade, ^{
        self.alpha = 0;
        self->_lyricsRequested = NO;
        self->_lyricsBlurAnimator = setBlurIntensity(self->_lyricsBlur, self->_lyricsBlurAnimator, 0);
    }, ^(BOOL finished) { if (done) done(); });
}

- (BOOL)blurred {
    return _lyricsRequested;
}

- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated {
    _lyricsRequested = blurred;
    CGFloat opacity = MIN(100, MAX(0, SGInt(SGRKeyPlayerVisualiserBlurOpacity, 100))) / 100.0;
    void (^apply)(void) = ^{
        self->_lyricsBlurAnimator = setBlurIntensity(self->_lyricsBlur, self->_lyricsBlurAnimator, blurred ? opacity : 0);
    };
    if (animated) SGRAnimate(SGRMotionFade, apply, nil);
    else apply();
    [self updateMotion];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updateMotion];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateMotion];
}

- (void)updateMotionSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateMotion]; });
}

- (void)updateMotion {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateMotion) object:nil];
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL may = self.window && front && !NSProcessInfo.processInfo.lowPowerModeEnabled;
    NSTimeInterval wait = SGPlayerTransitionEnds() - CACurrentMediaTime();
    if (may && (wait > 0 || SGRPlayerIsTransitioning())) {
        may = NO;
        if (wait > 0) [self performSelector:@selector(updateMotion) withObject:nil afterDelay:wait + 0.05 inModes:@[NSRunLoopCommonModes]];
    }
    BOOL playing = !SGPlayerState().isPaused;
    [self setMoving:may && playing];
}

- (void)setMoving:(BOOL)moving {
    if (moving) {
        if (!_link) {
            _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
            [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            _lastFrameTime = 0;
        }
        float most = SGRReduceMotion() ? 15 : _lyricsRequested ? 30 : 60;
        _link.preferredFrameRateRange = CAFrameRateRangeMake(most / 2, most, most);
    } else if (_link) {
        [_link invalidate];
        _link = nil;
    }
}

- (void)tick:(CADisplayLink *)link {
    if (!_hasImage || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;

    CFTimeInterval now = link.timestamp;
    double dt = _lastFrameTime ? MIN(now - _lastFrameTime, 0.1) : link.duration;
    _lastFrameTime = now;

    // Speed setting (default 100%)
    float speedMultiplier = (float)SGInt(SGRKeyKawarpSpeed, 100) / 100.0f;
    _accumulatedTime += dt * speedMultiplier;

    // Optional audio reactivity pulse
    float baseIntensity = (float)SGInt(SGRKeyKawarpIntensity, 100) / 100.0f;
    if (SGEnabled(SGRKeyKawarpAudioReactive)) {
        float levels[SGRSpectrumBands];
        SGRSpectrumRead(levels);
        float bass = fmaxf(0.0f, (levels[0] + levels[1] + levels[2]) / 3.0f + 60.0f) / 60.0f;
        baseIntensity *= (1.0f + 0.25f * fminf(1.0f, bass));
    }

    // Crossfade blend factor
    float blend = 1.0f;
    if (_transitioning) {
        float transitionDuration = (float)SGInt(SGRKeyKawarpTransition, 1000) / 1000.0f;
        if (transitionDuration <= 0.001f) {
            _transitioning = NO;
        } else {
            double elapsed = CACurrentMediaTime() - _transitionStart;
            if (elapsed >= transitionDuration) {
                _transitioning = NO;
            } else {
                blend = (float)(0.5 - 0.5 * cos((elapsed / transitionDuration) * M_PI));
            }
        }
    }

    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable) return;

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_mainPipeline];
    [enc setFragmentTexture:_currentTexture atIndex:0];
    [enc setFragmentTexture:_nextTexture atIndex:1];
    [enc setFragmentSamplerState:_sampler atIndex:0];

    struct KawarpUniforms u;
    u.time = (float)_accumulatedTime;
    u.intensity = baseIntensity;
    u.saturation = (float)SGInt(SGRKeyKawarpSaturation, 150) / 100.0f;
    u.dithering = (float)SGInt(SGRKeyKawarpDither, 80) / 10000.0f;
    u.scale = (float)SGInt(SGRKeyKawarpScale, 100) / 100.0f;
    u.blend = blend;
    u.resolution = simd_make_float2((float)self.bounds.size.width, (float)self.bounds.size.height);
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];

    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];

    [cmd presentDrawable:drawable];
    [cmd commit];
}

@end

#pragma mark - Redesigned Player Integration

static SGRKawarpView *sg_kawarpView;

BOOL SGRPlayerKawarpShowing(void) {
    SGRPlayerBackgroundKind background = SGRPlayerBackground();
    return background == SGRPlayerBackgroundKawarp
        || (background == SGRPlayerBackgroundAnimated
            && SGRPlayerAnimatedFallback() == SGRPlayerBackgroundKawarp);
}

UIView *SGRPlayerKawarpPreview(void) {
    static SGRKawarpView *preview;
    if (!preview) preview = [[SGRKawarpView alloc] initWithFrame:CGRectZero];
    return preview;
}

static void layOutKawarp(SGRArtworkField *field) {
    if (sg_kawarpView.superview != field) [field addSubview:sg_kawarpView];
    else if (field.subviews.lastObject != sg_kawarpView) [field bringSubviewToFront:sg_kawarpView];
    CGSize size = field.bounds.size;
    CGFloat screen = field.window.bounds.size.height ?: size.height;
    CGRect frame = CGRectMake(0, 0, size.width, MAX(size.height, screen) + field.bleed.bottom);
    if (!CGRectEqualToRect(sg_kawarpView.frame, frame)) sg_kawarpView.frame = frame;
}

void SGRPlayerKawarpUpdate(void) {
    SGRArtworkField *field = SGRPlayerField();
    BOOL wanted = SGRPlayerKawarpShowing() && field && !SGRPlayerMotionShowing();
    if (!wanted) {
        SGRKawarpView *old = sg_kawarpView;
        sg_kawarpView = nil;
        if (old.window) [old disappear:^{ [old removeFromSuperview]; }];
        else [old removeFromSuperview];
        return;
    }
    BOOL made = !sg_kawarpView;
    if (made) sg_kawarpView = [[SGRKawarpView alloc] initWithFrame:CGRectZero];
    layOutKawarp(field);
    if (made) {
        [sg_kawarpView setBlurred:SGRPlayerLyricsOpen() animated:NO];
        [sg_kawarpView appear:field.window != nil];
        SGLog(@"redesign player: kawarp on the field");
    } else {
        BOOL open = SGRPlayerLyricsOpen();
        if (open != sg_kawarpView.blurred) [sg_kawarpView setBlurred:open animated:sg_kawarpView.window != nil];
    }
}

