#import "SGStemsBridge.h"
#import "source_separator.h"
#import "SCNetEngine.h"
#import "SGSpleeterEngine.h"
#import "SGSpleeterModelManager.h"

#import "Core/SGPrefs.h"
#import "Core/SGLog.h"
#import "Shared/Audio/SGAudioPipeline.h"
#import "Shared/Player/PlayerState.h"
#include <atomic>
#include <cmath>
#include <algorithm>

NSNotificationName const SGStemsSettingsDidChangeNotification = @"SGStemsSettingsDidChangeNotification";

// Preference keys (supporting both new and existing stored preferences)
#define SGKeyStemsEnabled         @"spotifyglass.nagare.stems.enabled"
#define SGKeyStemsVocals          @"spotifyglass.nagare.stems.vocals"
#define SGKeyStemsDrums           @"spotifyglass.nagare.stems.drums"
#define SGKeyStemsBass            @"spotifyglass.nagare.stems.bass"
#define SGKeyStemsOther           @"spotifyglass.nagare.stems.other"
#define SGKeyStemsMode            @"spotifyglass.nagare.stems.mode"

namespace {

std::atomic<bool> g_initialized{false};
std::atomic<double> g_currentSampleRate{44100.0};

// Stems state
std::atomic<bool> g_stemsEnabled{false};
std::atomic<float> g_stemVocals{1.0f};
std::atomic<float> g_stemDrums{1.0f};
std::atomic<float> g_stemBass{1.0f};
std::atomic<float> g_stemOther{1.0f};
std::atomic<int> g_stemMode{6}; // SEPARATOR_MODE_CUSTOM

// Audio format tracking
std::atomic<uint64_t> g_layout{0};
std::atomic<double> g_rateBits{44100.0};

static constexpr int kMaxScratchFrames = 2048;
static float s_scratchLeft[kMaxScratchFrames];
static float s_scratchRight[kMaxScratchFrames];

void loadPreferences() {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    if ([ud objectForKey:SGKeyStemsEnabled]) {
        g_stemsEnabled.store([ud boolForKey:SGKeyStemsEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyStemsVocals]) {
        g_stemVocals.store([ud floatForKey:SGKeyStemsVocals], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyStemsDrums]) {
        g_stemDrums.store([ud floatForKey:SGKeyStemsDrums], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyStemsBass]) {
        g_stemBass.store([ud floatForKey:SGKeyStemsBass], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyStemsOther]) {
        g_stemOther.store([ud floatForKey:SGKeyStemsOther], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyStemsMode]) {
        int m = (int)[ud integerForKey:SGKeyStemsMode];
        if (m == 0) m = 6; // SEPARATOR_MODE_CUSTOM
        g_stemMode.store(m, std::memory_order_relaxed);
    } else {
        g_stemMode.store(6, std::memory_order_relaxed);
    }
}

inline float readSample(const void *data, UInt32 index, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4) {
        if (isFloat) return ((const float *)data)[index];
        int32_t val = ((const int32_t *)data)[index];
        return fraction ? (float)((double)val / (double)(1u << fraction)) : (float)(val / 2147483648.0);
    }
    return ((const int16_t *)data)[index] / 32768.0f;
}

inline void writeSample(void *data, UInt32 index, float value, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4) {
        if (isFloat) {
            ((float *)data)[index] = value;
        } else {
            double scaled = fraction ? (double)value * (double)(1u << fraction) : (double)value * 2147483647.0;
            ((int32_t *)data)[index] = (int32_t)lrint(fmax(-2147483648.0, fmin(scaled, 2147483647.0)));
        }
    } else {
        ((int16_t *)data)[index] = (int16_t)lrintf(fmaxf(-32768, fminf(value * 32768, 32767)));
    }
}

void prepareOutput(AudioUnit unit) {
    AudioStreamBasicDescription format = {};
    UInt32 size = sizeof(format);
    OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size);
    if (status != noErr || format.mFormatID != kAudioFormatLinearPCM || format.mSampleRate <= 0) return;

    UInt32 bytes = format.mBitsPerChannel / 8;
    g_rateBits.store(format.mSampleRate, std::memory_order_relaxed);
    g_layout.store((uint64_t)format.mFormatFlags | ((uint64_t)(format.mChannelsPerFrame & 0xffff) << 32) | ((uint64_t)bytes << 48), std::memory_order_relaxed);

    SGStemsSetSampleRate(format.mSampleRate);
    SGLog(@"stems: output configured at %.0f Hz, %u channels", format.mSampleRate, (unsigned)format.mChannelsPerFrame);
}

OSStatus renderedCallback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                          UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)timestamp;
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;

    bool stems = g_stemsEnabled.load(std::memory_order_acquire);
    if (!stems) return noErr;

    uint64_t layout = g_layout.load(std::memory_order_relaxed);
    if (layout == 0) {
        if (refCon) {
            prepareOutput((AudioUnit)refCon);
            layout = g_layout.load(std::memory_order_relaxed);
        }
        if (layout == 0) {
            if (data->mNumberBuffers >= 2 && data->mBuffers[0].mDataByteSize == frames * sizeof(float)) {
                UInt32 flagsVal = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
                UInt32 chVal = 2, byteVal = 4;
                layout = (uint64_t)flagsVal | ((uint64_t)chVal << 32) | ((uint64_t)byteVal << 48);
                g_layout.store(layout, std::memory_order_relaxed);
            } else if (data->mNumberBuffers == 1 && data->mBuffers[0].mDataByteSize == frames * 2 * sizeof(float)) {
                UInt32 flagsVal = kAudioFormatFlagIsFloat;
                UInt32 chVal = 2, byteVal = 4;
                layout = (uint64_t)flagsVal | ((uint64_t)chVal << 32) | ((uint64_t)byteVal << 48);
                g_layout.store(layout, std::memory_order_relaxed);
            }
        }
    }
    UInt32 formatFlags = (UInt32)layout, channels = (UInt32)(layout >> 32) & 0xffff, bytes = (UInt32)(layout >> 48);
    BOOL isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL split = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 fraction = (formatFlags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift;

    if ((bytes != 2 && bytes != 4) || channels < 1) return noErr;

    BOOL fits = split ? data->mNumberBuffers == channels : data->mNumberBuffers == 1 && data->mBuffers[0].mNumberChannels == channels;
    for (UInt32 b = 0; fits && b < data->mNumberBuffers; b++) {
        fits = data->mBuffers[b].mData && data->mBuffers[b].mDataByteSize == frames * bytes * (split ? 1 : channels);
    }
    if (!fits) return noErr;

    BOOL silent = (*flags & kAudioUnitRenderAction_OutputIsSilence) != 0;

    // Fast path: standard CoreAudio 32-bit floating point non-interleaved stereo
    if (split && isFloat && bytes == 4 && channels >= 2) {
        float *left = (float *)data->mBuffers[0].mData;
        float *right = (float *)data->mBuffers[1].mData;
        if (silent) {
            memset(left, 0, frames * sizeof(float));
            memset(right, 0, frames * sizeof(float));
        }

        spleeter_engine_process(left, right, frames);

        // Brickwall safety limiter & NaN/Inf protection
        for (UInt32 i = 0; i < frames; i++) {
            if (std::isnan(left[i]) || std::isinf(left[i])) left[i] = 0.0f;
            else left[i] = std::max(-1.0f, std::min(1.0f, left[i]));
            if (std::isnan(right[i]) || std::isinf(right[i])) right[i] = 0.0f;
            else right[i] = std::max(-1.0f, std::min(1.0f, right[i]));
        }

        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

    // Fallback path: interleaved or integer PCM
    for (UInt32 done = 0; done < frames;) {
        UInt32 count = std::min(frames - done, (UInt32)kMaxScratchFrames);
        const void *first = data->mBuffers[0].mData;
        const void *second = split && channels > 1 ? data->mBuffers[1].mData : first;
        UInt32 stride = split ? 1 : channels, secondOffset = !split && channels > 1 ? 1 : 0;

        for (UInt32 i = 0; i < count; i++) {
            UInt32 at = (done + i) * stride;
            s_scratchLeft[i] = silent ? 0 : readSample(first, at, bytes, isFloat, fraction);
            s_scratchRight[i] = silent ? 0 : readSample(second, at + secondOffset, bytes, isFloat, fraction);
        }

        spleeter_engine_process(s_scratchLeft, s_scratchRight, count);

        for (UInt32 i = 0; i < count; i++) {
            if (std::isnan(s_scratchLeft[i]) || std::isinf(s_scratchLeft[i])) s_scratchLeft[i] = 0.0f;
            else s_scratchLeft[i] = std::max(-1.0f, std::min(1.0f, s_scratchLeft[i]));
            if (std::isnan(s_scratchRight[i]) || std::isinf(s_scratchRight[i])) s_scratchRight[i] = 0.0f;
            else s_scratchRight[i] = std::max(-1.0f, std::min(1.0f, s_scratchRight[i]));
        }

        void *firstOut = data->mBuffers[0].mData;
        void *secondOut = split && channels > 1 ? data->mBuffers[1].mData : firstOut;
        for (UInt32 i = 0; i < count; i++) {
            UInt32 at = (done + i) * stride;
            if (channels == 1) {
                writeSample(firstOut, at, 0.5f * (s_scratchLeft[i] + s_scratchRight[i]), bytes, isFloat, fraction);
            } else {
                writeSample(firstOut, at, s_scratchLeft[i], bytes, isFloat, fraction);
                writeSample(secondOut, at + secondOffset, s_scratchRight[i], bytes, isFloat, fraction);
            }
        }
        done += count;
    }

    *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
}

static const SGAudioProcessor s_stemsProcessor = {
    prepareOutput,
    renderedCallback
};

} // namespace

void SGStemsInit(double sampleRate) {
    if (sampleRate <= 0) sampleRate = 44100.0;
    g_currentSampleRate.store(sampleRate, std::memory_order_relaxed);

    int rateInt = (int)sampleRate;
    separator_init(rateInt);
    scnet_engine_init(rateInt);
    spleeter_engine_init(rateInt);

    loadPreferences();

    bool stems = g_stemsEnabled.load(std::memory_order_relaxed);
    separator_enable(stems);
    spleeter_engine_set_enabled(stems);

    float v = g_stemVocals.load(std::memory_order_relaxed);
    float d = g_stemDrums.load(std::memory_order_relaxed);
    float b = g_stemBass.load(std::memory_order_relaxed);
    float o = g_stemOther.load(std::memory_order_relaxed);
    separator_set_stem_levels(v, b, d, o);
    spleeter_engine_set_stem_levels(v, d, b, o);

    int mode = g_stemMode.load(std::memory_order_relaxed);
    separator_set_mode((SeparatorMode)mode);

    g_initialized.store(true, std::memory_order_release);
    SGLog(@"stems: initialized at %.0f Hz", sampleRate);
}

void SGStemsSetSampleRate(double sampleRate) {
    if (sampleRate <= 0) return;
    if (g_currentSampleRate.load(std::memory_order_relaxed) == sampleRate && g_initialized.load(std::memory_order_relaxed)) return;
    SGStemsInit(sampleRate);
}

void SGStemsReset(void) {
    if (!g_initialized.load(std::memory_order_relaxed)) return;
    double rate = g_currentSampleRate.load(std::memory_order_relaxed);
    separator_release();
    scnet_engine_release();
    spleeter_engine_release();
    SGStemsInit(rate);
}

const SGAudioProcessor *SGStemsGetAudioProcessor(void) {
    return &s_stemsProcessor;
}

void SGStemsSetEnabled(BOOL enabled) {
    g_stemsEnabled.store(enabled, std::memory_order_release);
    separator_enable(enabled);
    spleeter_engine_set_enabled(enabled);
    if (enabled && (separator_get_mode() == SEPARATOR_MODE_NORMAL || g_stemMode.load(std::memory_order_relaxed) == SEPARATOR_MODE_NORMAL)) {
        separator_set_mode(SEPARATOR_MODE_CUSTOM);
        g_stemMode.store(SEPARATOR_MODE_CUSTOM, std::memory_order_relaxed);
        [NSUserDefaults.standardUserDefaults setInteger:SEPARATOR_MODE_CUSTOM forKey:SGKeyStemsMode];
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyStemsEnabled];
    [NSNotificationCenter.defaultCenter postNotificationName:SGStemsSettingsDidChangeNotification object:nil];
}

BOOL SGStemsIsEnabled(void) {
    return g_stemsEnabled.load(std::memory_order_relaxed);
}

BOOL SGStemsIsSpleeterReady(void) {
    return spleeter_engine_is_ready();
}

BOOL SGStemsIsSCNetReady(void) {
    return spleeter_engine_is_ready();
}

void SGStemsReloadSpleeter(void) {
    spleeter_engine_reload();
}

void SGStemsSetStemLevels(float vocals, float drums, float bass, float other) {
    vocals = std::max(0.0f, std::min(2.0f, vocals));
    drums = std::max(0.0f, std::min(2.0f, drums));
    bass = std::max(0.0f, std::min(2.0f, bass));
    other = std::max(0.0f, std::min(2.0f, other));

    g_stemVocals.store(vocals, std::memory_order_relaxed);
    g_stemDrums.store(drums, std::memory_order_relaxed);
    g_stemBass.store(bass, std::memory_order_relaxed);
    g_stemOther.store(other, std::memory_order_relaxed);

    if (vocals != 1.0f || drums != 1.0f || bass != 1.0f || other != 1.0f) {
        if (!g_stemsEnabled.load(std::memory_order_relaxed)) {
            g_stemsEnabled.store(true, std::memory_order_release);
            separator_enable(true);
            spleeter_engine_set_enabled(true);
        }
        if (separator_get_mode() == SEPARATOR_MODE_NORMAL) {
            separator_set_mode(SEPARATOR_MODE_CUSTOM);
            g_stemMode.store(SEPARATOR_MODE_CUSTOM, std::memory_order_relaxed);
        }
    }

    separator_set_stem_levels(vocals, bass, drums, other);
    spleeter_engine_set_stem_levels(vocals, drums, bass, other);

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setFloat:vocals forKey:SGKeyStemsVocals];
    [ud setFloat:drums forKey:SGKeyStemsDrums];
    [ud setFloat:bass forKey:SGKeyStemsBass];
    [ud setFloat:other forKey:SGKeyStemsOther];
    [NSNotificationCenter.defaultCenter postNotificationName:SGStemsSettingsDidChangeNotification object:nil];
}

void SGStemsGetStemLevels(float *vocals, float *drums, float *bass, float *other) {
    if (vocals) *vocals = g_stemVocals.load(std::memory_order_relaxed);
    if (drums) *drums = g_stemDrums.load(std::memory_order_relaxed);
    if (bass) *bass = g_stemBass.load(std::memory_order_relaxed);
    if (other) *other = g_stemOther.load(std::memory_order_relaxed);
}

void SGStemsGetStemMeters(float *vocals, float *drums, float *bass, float *other) {
    spleeter_engine_get_stem_meters(vocals, drums, bass, other);
}

void SGStemsSetSeparationMode(int mode) {
    g_stemMode.store(mode, std::memory_order_relaxed);
    separator_set_mode((SeparatorMode)mode);
    if (mode != SEPARATOR_MODE_NORMAL) {
        if (!g_stemsEnabled.load(std::memory_order_relaxed)) {
            g_stemsEnabled.store(true, std::memory_order_release);
            separator_enable(true);
            spleeter_engine_set_enabled(true);
        }
    }
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:SGKeyStemsMode];
    [NSNotificationCenter.defaultCenter postNotificationName:SGStemsSettingsDidChangeNotification object:nil];
}

int SGStemsGetSeparationMode(void) {
    return g_stemMode.load(std::memory_order_relaxed);
}

@interface SGStemsTrackWatcher : NSObject <SGPlayerStateObserver>
@property (nonatomic, copy) NSString *lastTrackURI;
@end

@implementation SGStemsTrackWatcher
- (instancetype)init {
    if ((self = [super init])) {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(handleSeek:)
                                                   name:SGPlayerPlaybackDidSeekNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)handleSeek:(NSNotification *)note {
    (void)note;
    spleeter_engine_clear();
    separator_clear();
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *uri = SGURIString(state.track.URI);
    if (self.lastTrackURI && uri && ![self.lastTrackURI isEqualToString:uri]) {
        spleeter_engine_clear();
        separator_clear();
    }
    self.lastTrackURI = uri;
}
@end

static SGStemsTrackWatcher *s_stemsTrackWatcher = nil;

// Auto-register into SGAudioPipeline upon tweak load
__attribute__((used, constructor)) static void SGStemsAutoRegister(void) {
    SGStemsInit(44100.0);
    [[SGSpleeterModelManager sharedManager] startDownloadIfNeeded];
    SGAudioPipelineRegister(SGAudioStageStems, SGStemsGetAudioProcessor());
    s_stemsTrackWatcher = [[SGStemsTrackWatcher alloc] init];
    SGAddPlayerStateObserver(s_stemsTrackWatcher);
    SGLog(@"stems: stage registered with audio pipeline");
}
