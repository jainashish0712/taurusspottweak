#import "SGNagareDSPBridge.h"
#import "nagare_dsp.h"
#import "hrtf_processor.h"
#import "polyphase_resampler.h"
#import "audio_upscaler.h"
#import "dynamic_restorer.h"

#import "Core/SGPrefs.h"
#import "Core/SGLog.h"
#import "Shared/Audio/SGAudioPipeline.h"
#import "Shared/Player/PlayerState.h"
#include <atomic>
#include <cmath>
#include <algorithm>

NSNotificationName const SGNagareSettingsDidChangeNotification = @"SGNagareSettingsDidChangeNotification";

// Preference keys
#define SGKeyNagareUpscalerEnabled      @"spotifyglass.nagare.upscaler.enabled"
#define SGKeyNagareUpscalerIntensity    @"spotifyglass.nagare.upscaler.intensity"
#define SGKeyNagareUpscalerCutoff       @"spotifyglass.nagare.upscaler.cutoff"

#define SGKeyNagareRestorerEnabled      @"spotifyglass.nagare.restorer.enabled"
#define SGKeyNagareRestorerIntensity    @"spotifyglass.nagare.restorer.intensity"
#define SGKeyNagareRestorerExpansion    @"spotifyglass.nagare.restorer.expansion"
#define SGKeyNagareRestorerTransient    @"spotifyglass.nagare.restorer.transient"

#define SGKeyNagareHRTFEnabled          @"spotifyglass.nagare.hrtf.enabled"
#define SGKeyNagareHRTFAngle            @"spotifyglass.nagare.hrtf.angle"
#define SGKeyNagareHRTFPreset           @"spotifyglass.nagare.hrtf.preset"
#define SGKeyNagareHRTFRoom             @"spotifyglass.nagare.hrtf.room"
#define SGKeyNagareHRTFDistance         @"spotifyglass.nagare.hrtf.distance"

#define SGKeyNagareCoreEnabled          @"spotifyglass.nagare.core.enabled"
#define SGKeyNagareSmartEnhanceEnabled  @"spotifyglass.nagare.smart.enabled"
#define SGKeyNagareSmartIntensity       @"spotifyglass.nagare.smart.intensity"
#define SGKeyNagareVirtualBassEnabled   @"spotifyglass.nagare.virtualbass.enabled"
#define SGKeyNagareVirtualBassAmount    @"spotifyglass.nagare.virtualbass.amount"
#define SGKeyNagareVirtualBassFreq      @"spotifyglass.nagare.virtualbass.freq"
#define SGKeyNagareSubharmonicEnabled   @"spotifyglass.nagare.subharmonic.enabled"
#define SGKeyNagareSubharmonicAmount    @"spotifyglass.nagare.subharmonic.amount"
#define SGKeyNagareTubeEnabled          @"spotifyglass.nagare.tube.enabled"
#define SGKeyNagareTubeAmount           @"spotifyglass.nagare.tube.amount"
#define SGKeyNagareTubeDrive            @"spotifyglass.nagare.tube.drive"
#define SGKeyNagareExciterEnabled       @"spotifyglass.nagare.exciter.enabled"
#define SGKeyNagareExciterAmount        @"spotifyglass.nagare.exciter.amount"
#define SGKeyNagareExciterFreq          @"spotifyglass.nagare.exciter.freq"
#define SGKeyNagareAirBandEnabled       @"spotifyglass.nagare.airband.enabled"
#define SGKeyNagareAirBandAmount        @"spotifyglass.nagare.airband.amount"
#define SGKeyNagareStereoWidthEnabled   @"spotifyglass.nagare.stereowidth.enabled"
#define SGKeyNagareStereoWidthAmount    @"spotifyglass.nagare.stereowidth.amount"
#define SGKeyNagareCrossfeedEnabled     @"spotifyglass.nagare.crossfeed.enabled"
#define SGKeyNagareCrossfeedAmount      @"spotifyglass.nagare.crossfeed.amount"
#define SGKeyNagareReverbEnabled        @"spotifyglass.nagare.reverb.enabled"
#define SGKeyNagareReverbRoom           @"spotifyglass.nagare.reverb.room"
#define SGKeyNagareReverbDamping        @"spotifyglass.nagare.reverb.damping"
#define SGKeyNagareReverbWet            @"spotifyglass.nagare.reverb.wet"
#define SGKeyNagareReverbDry            @"spotifyglass.nagare.reverb.dry"
#define SGKeyNagareReverbWidth          @"spotifyglass.nagare.reverb.width"
#define SGKeyNagareTransientEnabled     @"spotifyglass.nagare.transient.enabled"
#define SGKeyNagareTransientAttack      @"spotifyglass.nagare.transient.attack"
#define SGKeyNagareTransientSustain     @"spotifyglass.nagare.transient.sustain"
#define SGKeyNagareLoudnessCompEnabled  @"spotifyglass.nagare.loudness.enabled"
#define SGKeyNagareLoudnessCompAmount   @"spotifyglass.nagare.loudness.amount"

namespace {

std::atomic<bool> g_initialized{false};
std::atomic<double> g_currentSampleRate{44100.0};

// Upscaler state
std::atomic<bool> g_upscalerEnabled{false};
std::atomic<float> g_upscalerIntensity{0.5f};
std::atomic<float> g_upscalerCutoff{15000.0f};

// Restorer state
std::atomic<bool> g_restorerEnabled{false};
std::atomic<float> g_restorerIntensity{0.5f};
std::atomic<float> g_restorerExpansion{1.4f};
std::atomic<float> g_restorerTransient{0.5f};

// HRTF state
std::atomic<bool> g_hrtfEnabled{false};
std::atomic<float> g_hrtfAngle{30.0f};
std::atomic<int> g_hrtfPreset{0};
std::atomic<float> g_hrtfRoom{0.3f};
std::atomic<float> g_hrtfDistance{1.5f};

// Core DSP state
std::atomic<bool> g_coreDSPEnabled{false};
std::atomic<bool> g_smartEnhanceEnabled{false};
std::atomic<float> g_smartIntensity{0.5f};

std::atomic<bool> g_vibeEnabled{false};
std::atomic<float> g_vibeAmount{0.5f};
std::atomic<float> g_vibeFreq{120.0f};

std::atomic<bool> g_tubeEnabled{false};
std::atomic<float> g_tubeAmount{0.4f};
std::atomic<float> g_tubeDrive{0.3f};

std::atomic<bool> g_exciterEnabled{false};
std::atomic<float> g_exciterAmount{0.3f};
std::atomic<float> g_exciterFreq{4000.0f};

std::atomic<bool> g_airBandEnabled{false};
std::atomic<float> g_airBandAmount{0.3f};

std::atomic<bool> g_stereoWidthEnabled{false};
std::atomic<float> g_stereoWidthAmount{1.2f};

std::atomic<bool> g_crossfeedEnabled{false};
std::atomic<float> g_crossfeedAmount{0.3f};

std::atomic<bool> g_reverbEnabled{false};
std::atomic<float> g_reverbRoom{0.5f};
std::atomic<float> g_reverbDamping{0.5f};
std::atomic<float> g_reverbWet{0.2f};
std::atomic<float> g_reverbDry{0.8f};
std::atomic<float> g_reverbWidth{1.0f};

std::atomic<bool> g_transientEnabled{false};
std::atomic<float> g_transientAttack{0.0f};
std::atomic<float> g_transientSustain{0.0f};

std::atomic<bool> g_loudnessCompEnabled{false};
std::atomic<float> g_loudnessCompAmount{0.5f};

// Audio format tracking
std::atomic<uint64_t> g_layout{0};
std::atomic<double> g_rateBits{44100.0};

// Static scratch for interleaving
static constexpr int kMaxScratchFrames = 2048;
static float s_interleaved[kMaxScratchFrames * 2];
static float s_scratchLeft[kMaxScratchFrames];
static float s_scratchRight[kMaxScratchFrames];

void loadPreferences() {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    if ([ud objectForKey:SGKeyNagareUpscalerEnabled]) {
        g_upscalerEnabled.store([ud boolForKey:SGKeyNagareUpscalerEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareUpscalerIntensity]) {
        g_upscalerIntensity.store([ud floatForKey:SGKeyNagareUpscalerIntensity], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareUpscalerCutoff]) {
        g_upscalerCutoff.store([ud floatForKey:SGKeyNagareUpscalerCutoff], std::memory_order_relaxed);
    }

    if ([ud objectForKey:SGKeyNagareRestorerEnabled]) {
        g_restorerEnabled.store([ud boolForKey:SGKeyNagareRestorerEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareRestorerIntensity]) {
        g_restorerIntensity.store([ud floatForKey:SGKeyNagareRestorerIntensity], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareRestorerExpansion]) {
        g_restorerExpansion.store([ud floatForKey:SGKeyNagareRestorerExpansion], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareRestorerTransient]) {
        g_restorerTransient.store([ud floatForKey:SGKeyNagareRestorerTransient], std::memory_order_relaxed);
    }

    if ([ud objectForKey:SGKeyNagareHRTFEnabled]) {
        g_hrtfEnabled.store([ud boolForKey:SGKeyNagareHRTFEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareHRTFAngle]) {
        g_hrtfAngle.store([ud floatForKey:SGKeyNagareHRTFAngle], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareHRTFPreset]) {
        g_hrtfPreset.store((int)[ud integerForKey:SGKeyNagareHRTFPreset], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareHRTFRoom]) {
        g_hrtfRoom.store([ud floatForKey:SGKeyNagareHRTFRoom], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareHRTFDistance]) {
        g_hrtfDistance.store([ud floatForKey:SGKeyNagareHRTFDistance], std::memory_order_relaxed);
    }

    if ([ud objectForKey:SGKeyNagareCoreEnabled]) {
        g_coreDSPEnabled.store([ud boolForKey:SGKeyNagareCoreEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareSmartEnhanceEnabled]) {
        g_smartEnhanceEnabled.store([ud boolForKey:SGKeyNagareSmartEnhanceEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareSmartIntensity]) {
        g_smartIntensity.store([ud floatForKey:SGKeyNagareSmartIntensity], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareVirtualBassEnabled]) {
        g_vibeEnabled.store([ud boolForKey:SGKeyNagareVirtualBassEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareVirtualBassAmount]) {
        g_vibeAmount.store([ud floatForKey:SGKeyNagareVirtualBassAmount], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareVirtualBassFreq]) {
        g_vibeFreq.store([ud floatForKey:SGKeyNagareVirtualBassFreq], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareTubeEnabled]) {
        g_tubeEnabled.store([ud boolForKey:SGKeyNagareTubeEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareTubeAmount]) {
        g_tubeAmount.store([ud floatForKey:SGKeyNagareTubeAmount], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareTubeDrive]) {
        g_tubeDrive.store([ud floatForKey:SGKeyNagareTubeDrive], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareExciterEnabled]) {
        g_exciterEnabled.store([ud boolForKey:SGKeyNagareExciterEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareExciterAmount]) {
        g_exciterAmount.store([ud floatForKey:SGKeyNagareExciterAmount], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareExciterFreq]) {
        g_exciterFreq.store([ud floatForKey:SGKeyNagareExciterFreq], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareAirBandEnabled]) {
        g_airBandEnabled.store([ud boolForKey:SGKeyNagareAirBandEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareAirBandAmount]) {
        g_airBandAmount.store([ud floatForKey:SGKeyNagareAirBandAmount], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareStereoWidthEnabled]) {
        g_stereoWidthEnabled.store([ud boolForKey:SGKeyNagareStereoWidthEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareStereoWidthAmount]) {
        g_stereoWidthAmount.store([ud floatForKey:SGKeyNagareStereoWidthAmount], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareCrossfeedEnabled]) {
        g_crossfeedEnabled.store([ud boolForKey:SGKeyNagareCrossfeedEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareCrossfeedAmount]) {
        g_crossfeedAmount.store([ud floatForKey:SGKeyNagareCrossfeedAmount], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareReverbEnabled]) {
        g_reverbEnabled.store([ud boolForKey:SGKeyNagareReverbEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareReverbRoom]) {
        g_reverbRoom.store([ud floatForKey:SGKeyNagareReverbRoom], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareReverbDamping]) {
        g_reverbDamping.store([ud floatForKey:SGKeyNagareReverbDamping], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareReverbWet]) {
        g_reverbWet.store([ud floatForKey:SGKeyNagareReverbWet], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareReverbDry]) {
        g_reverbDry.store([ud floatForKey:SGKeyNagareReverbDry], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareReverbWidth]) {
        g_reverbWidth.store([ud floatForKey:SGKeyNagareReverbWidth], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareTransientEnabled]) {
        g_transientEnabled.store([ud boolForKey:SGKeyNagareTransientEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareTransientAttack]) {
        g_transientAttack.store([ud floatForKey:SGKeyNagareTransientAttack], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareTransientSustain]) {
        g_transientSustain.store([ud floatForKey:SGKeyNagareTransientSustain], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareLoudnessCompEnabled]) {
        g_loudnessCompEnabled.store([ud boolForKey:SGKeyNagareLoudnessCompEnabled], std::memory_order_relaxed);
    }
    if ([ud objectForKey:SGKeyNagareLoudnessCompAmount]) {
        g_loudnessCompAmount.store([ud floatForKey:SGKeyNagareLoudnessCompAmount], std::memory_order_relaxed);
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

    SGNagareDSPSetSampleRate(format.mSampleRate);
    SGLog(@"nagare dsp: output configured at %.0f Hz, %u channels", format.mSampleRate, (unsigned)format.mChannelsPerFrame);
}

OSStatus renderedCallback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                          UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)timestamp;
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;

    bool upscaler = g_upscalerEnabled.load(std::memory_order_acquire);
    bool restorer = g_restorerEnabled.load(std::memory_order_acquire);
    bool hrtf = g_hrtfEnabled.load(std::memory_order_acquire);
    bool core = g_coreDSPEnabled.load(std::memory_order_acquire);

    if (!upscaler && !restorer && !hrtf && !core) return noErr;

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

        // 1. Audio Upscaler (SBR / DSEE)
        if (upscaler) {
            upscaler_process(left, right, frames);
        }

        // 2. Dynamic Restorer
        if (restorer) {
            restorer_process(left, right, frames);
        }

        // 3. Core DSP Chain (interleaved stereo processing)
        if (core) {
            for (UInt32 done = 0; done < frames;) {
                UInt32 count = std::min(frames - done, (UInt32)kMaxScratchFrames);
                for (UInt32 i = 0; i < count; i++) {
                    s_interleaved[2 * i] = left[done + i];
                    s_interleaved[2 * i + 1] = right[done + i];
                }
                nagare_process(s_interleaved, s_interleaved, count);
                for (UInt32 i = 0; i < count; i++) {
                    left[done + i] = s_interleaved[2 * i];
                    right[done + i] = s_interleaved[2 * i + 1];
                }
                done += count;
            }
        }

        // 4. HRTF Binaural Spatialization
        if (hrtf) {
            hrtf_process(left, right, frames);
        }

        // Hard brickwall safety limiter & NaN/Inf protection
        for (UInt32 i = 0; i < frames; i++) {
            if (std::isnan(left[i]) || std::isinf(left[i])) left[i] = 0.0f;
            else left[i] = std::max(-1.0f, std::min(1.0f, left[i]));
            if (std::isnan(right[i]) || std::isinf(right[i])) right[i] = 0.0f;
            else right[i] = std::max(-1.0f, std::min(1.0f, right[i]));
        }

        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

    // Fallback path: interleaved or 16-bit integer PCM
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

        if (upscaler) {
            upscaler_process(s_scratchLeft, s_scratchRight, count);
        }
        if (restorer) {
            restorer_process(s_scratchLeft, s_scratchRight, count);
        }
        if (core) {
            for (UInt32 i = 0; i < count; i++) {
                s_interleaved[2 * i] = s_scratchLeft[i];
                s_interleaved[2 * i + 1] = s_scratchRight[i];
            }
            nagare_process(s_interleaved, s_interleaved, count);
            for (UInt32 i = 0; i < count; i++) {
                s_scratchLeft[i] = s_interleaved[2 * i];
                s_scratchRight[i] = s_interleaved[2 * i + 1];
            }
        }
        if (hrtf) {
            hrtf_process(s_scratchLeft, s_scratchRight, count);
        }

        // Hard brickwall safety limiter & NaN/Inf protection
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

static const SGAudioProcessor s_nagareProcessor = {
    prepareOutput,
    renderedCallback
};

} // namespace

void SGNagareDSPInit(double sampleRate) {
    if (sampleRate <= 0) sampleRate = 44100.0;
    g_currentSampleRate.store(sampleRate, std::memory_order_relaxed);

    int rateInt = (int)sampleRate;
    nagare_init(rateInt, 2, 512);
    upscaler_init(rateInt);
    restorer_init(rateInt);
    hrtf_init(rateInt);

    loadPreferences();

    bool core = g_coreDSPEnabled.load(std::memory_order_relaxed);
    if (core) {
        if (g_smartEnhanceEnabled.load(std::memory_order_relaxed)) {
            nagare_smart_enhance_enable(true);
            nagare_smart_enhance_set_intensity(g_smartIntensity.load(std::memory_order_relaxed));
        }
        if (g_vibeEnabled.load(std::memory_order_relaxed)) {
            nagare_virtual_bass_enable(true);
            nagare_virtual_bass_set(g_vibeAmount.load(std::memory_order_relaxed), g_vibeFreq.load(std::memory_order_relaxed));
        }
        if (g_tubeEnabled.load(std::memory_order_relaxed)) {
            nagare_tube_warmth_enable(true);
            nagare_tube_warmth_set(g_tubeAmount.load(std::memory_order_relaxed), g_tubeDrive.load(std::memory_order_relaxed));
        }
        if (g_exciterEnabled.load(std::memory_order_relaxed)) {
            nagare_exciter_enable(true);
            nagare_exciter_set(g_exciterAmount.load(std::memory_order_relaxed), g_exciterFreq.load(std::memory_order_relaxed));
        }
        if (g_airBandEnabled.load(std::memory_order_relaxed)) {
            nagare_air_band_enable(true);
            nagare_air_band_set(g_airBandAmount.load(std::memory_order_relaxed));
        }
        if (g_stereoWidthEnabled.load(std::memory_order_relaxed)) {
            nagare_stereo_width_enable(true);
            nagare_stereo_width_set(g_stereoWidthAmount.load(std::memory_order_relaxed));
        }
        if (g_crossfeedEnabled.load(std::memory_order_relaxed)) {
            nagare_crossfeed_enable(true);
            nagare_crossfeed_set(g_crossfeedAmount.load(std::memory_order_relaxed));
        }
        if (g_reverbEnabled.load(std::memory_order_relaxed)) {
            nagare_reverb_enable(true);
            nagare_reverb_set(g_reverbRoom.load(std::memory_order_relaxed),
                              g_reverbDamping.load(std::memory_order_relaxed),
                              g_reverbWet.load(std::memory_order_relaxed),
                              g_reverbDry.load(std::memory_order_relaxed),
                              g_reverbWidth.load(std::memory_order_relaxed));
        }
        if (g_transientEnabled.load(std::memory_order_relaxed)) {
            nagare_transient_shaper_enable(true);
            nagare_transient_shaper_set(g_transientAttack.load(std::memory_order_relaxed), g_transientSustain.load(std::memory_order_relaxed));
        }
        if (g_loudnessCompEnabled.load(std::memory_order_relaxed)) {
            nagare_loudness_comp_enable(true);
            nagare_loudness_comp_set(g_loudnessCompAmount.load(std::memory_order_relaxed));
        }
    }

    if (g_upscalerEnabled.load(std::memory_order_relaxed)) {
        upscaler_enable(true);
        upscaler_set_intensity(g_upscalerIntensity.load(std::memory_order_relaxed));
        upscaler_set_sbr_cutoff(g_upscalerCutoff.load(std::memory_order_relaxed));
    }
    if (g_restorerEnabled.load(std::memory_order_relaxed)) {
        restorer_enable(true);
        restorer_set_intensity(g_restorerIntensity.load(std::memory_order_relaxed));
        restorer_set_expansion_ratio(g_restorerExpansion.load(std::memory_order_relaxed));
        restorer_set_transient_amount(g_restorerTransient.load(std::memory_order_relaxed));
    }
    if (g_hrtfEnabled.load(std::memory_order_relaxed)) {
        hrtf_enable(true);
        hrtf_set_speaker_angle(g_hrtfAngle.load(std::memory_order_relaxed));
        hrtf_set_preset(g_hrtfPreset.load(std::memory_order_relaxed));
        hrtf_set_room_size(g_hrtfRoom.load(std::memory_order_relaxed));
        hrtf_set_distance(g_hrtfDistance.load(std::memory_order_relaxed));
    }

    g_initialized.store(true, std::memory_order_release);
    SGLog(@"nagare dsp: initialized at %.0f Hz", sampleRate);
}

void SGNagareDSPSetSampleRate(double sampleRate) {
    if (sampleRate <= 0) return;
    if (g_currentSampleRate.load(std::memory_order_relaxed) == sampleRate && g_initialized.load(std::memory_order_relaxed)) return;
    SGNagareDSPInit(sampleRate);
}

void SGNagareDSPReset(void) {
    if (!g_initialized.load(std::memory_order_relaxed)) return;
    double rate = g_currentSampleRate.load(std::memory_order_relaxed);
    nagare_release();
    upscaler_release();
    restorer_release();
    hrtf_release();
    SGNagareDSPInit(rate);
}

const SGAudioProcessor *SGNagareDSPGetAudioProcessor(void) {
    return &s_nagareProcessor;
}

// Audio Upscaler
void SGNagareSetUpscalerEnabled(BOOL enabled) {
    g_upscalerEnabled.store(enabled, std::memory_order_release);
    upscaler_enable(enabled);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareUpscalerEnabled];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsUpscalerEnabled(void) {
    return g_upscalerEnabled.load(std::memory_order_relaxed);
}

void SGNagareSetUpscalerIntensity(float intensity) {
    intensity = std::max(0.0f, std::min(1.0f, intensity));
    g_upscalerIntensity.store(intensity, std::memory_order_relaxed);
    upscaler_set_intensity(intensity);
    [NSUserDefaults.standardUserDefaults setFloat:intensity forKey:SGKeyNagareUpscalerIntensity];
}

float SGNagareGetUpscalerIntensity(void) {
    return g_upscalerIntensity.load(std::memory_order_relaxed);
}

void SGNagareSetUpscalerCutoff(float cutoffHz) {
    cutoffHz = std::max(4000.0f, std::min(22000.0f, cutoffHz));
    g_upscalerCutoff.store(cutoffHz, std::memory_order_relaxed);
    upscaler_set_sbr_cutoff(cutoffHz);
    [NSUserDefaults.standardUserDefaults setFloat:cutoffHz forKey:SGKeyNagareUpscalerCutoff];
}

int SGNagareGetDetectedSourceQuality(void) {
    return (int)upscaler_get_detected_quality();
}

// Dynamic Restorer
void SGNagareSetRestorerEnabled(BOOL enabled) {
    g_restorerEnabled.store(enabled, std::memory_order_release);
    restorer_enable(enabled);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareRestorerEnabled];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsRestorerEnabled(void) {
    return g_restorerEnabled.load(std::memory_order_relaxed);
}

void SGNagareSetRestorerIntensity(float intensity) {
    intensity = std::max(0.0f, std::min(1.0f, intensity));
    g_restorerIntensity.store(intensity, std::memory_order_relaxed);
    restorer_set_intensity(intensity);
    [NSUserDefaults.standardUserDefaults setFloat:intensity forKey:SGKeyNagareRestorerIntensity];
}

float SGNagareGetRestorerIntensity(void) {
    return g_restorerIntensity.load(std::memory_order_relaxed);
}

void SGNagareSetRestorerExpansion(float ratio) {
    ratio = std::max(1.0f, std::min(3.0f, ratio));
    g_restorerExpansion.store(ratio, std::memory_order_relaxed);
    restorer_set_expansion_ratio(ratio);
    [NSUserDefaults.standardUserDefaults setFloat:ratio forKey:SGKeyNagareRestorerExpansion];
}

void SGNagareSetRestorerTransient(float amount) {
    amount = std::max(0.0f, std::min(1.0f, amount));
    g_restorerTransient.store(amount, std::memory_order_relaxed);
    restorer_set_transient_amount(amount);
    [NSUserDefaults.standardUserDefaults setFloat:amount forKey:SGKeyNagareRestorerTransient];
}

// Binaural Spatial HRTF
void SGNagareSetHRTFEnabled(BOOL enabled) {
    g_hrtfEnabled.store(enabled, std::memory_order_release);
    hrtf_enable(enabled);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareHRTFEnabled];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsHRTFEnabled(void) {
    return g_hrtfEnabled.load(std::memory_order_relaxed);
}

void SGNagareSetHRTFAngle(float angleDegrees) {
    angleDegrees = std::max(-90.0f, std::min(90.0f, angleDegrees));
    g_hrtfAngle.store(angleDegrees, std::memory_order_relaxed);
    hrtf_set_speaker_angle(angleDegrees);
    [NSUserDefaults.standardUserDefaults setFloat:angleDegrees forKey:SGKeyNagareHRTFAngle];
}

float SGNagareGetHRTFAngle(void) {
    return g_hrtfAngle.load(std::memory_order_relaxed);
}

void SGNagareSetHRTFPreset(int preset) {
    g_hrtfPreset.store(preset, std::memory_order_relaxed);
    hrtf_set_preset(preset);
    [NSUserDefaults.standardUserDefaults setInteger:preset forKey:SGKeyNagareHRTFPreset];
}

void SGNagareSetHRTFRoomSize(float size) {
    size = std::max(0.0f, std::min(1.0f, size));
    g_hrtfRoom.store(size, std::memory_order_relaxed);
    hrtf_set_room_size(size);
    [NSUserDefaults.standardUserDefaults setFloat:size forKey:SGKeyNagareHRTFRoom];
}

void SGNagareSetHRTFDistance(float meters) {
    meters = std::max(0.5f, std::min(5.0f, meters));
    g_hrtfDistance.store(meters, std::memory_order_relaxed);
    hrtf_set_distance(meters);
    [NSUserDefaults.standardUserDefaults setFloat:meters forKey:SGKeyNagareHRTFDistance];
}

// Core DSP Chain
void SGNagareSetCoreDSPEnabled(BOOL enabled) {
    g_coreDSPEnabled.store(enabled, std::memory_order_release);
    if (!enabled) {
        nagare_smart_enhance_enable(false);
        nagare_virtual_bass_enable(false);
        nagare_tube_warmth_enable(false);
        nagare_exciter_enable(false);
        nagare_air_band_enable(false);
        nagare_stereo_width_enable(false);
        nagare_crossfeed_enable(false);
        nagare_reverb_enable(false);
        nagare_transient_shaper_enable(false);
        nagare_loudness_comp_enable(false);
    } else {
        if (g_smartEnhanceEnabled.load(std::memory_order_relaxed)) nagare_smart_enhance_enable(true);
        if (g_vibeEnabled.load(std::memory_order_relaxed)) nagare_virtual_bass_enable(true);
        if (g_tubeEnabled.load(std::memory_order_relaxed)) nagare_tube_warmth_enable(true);
        if (g_exciterEnabled.load(std::memory_order_relaxed)) nagare_exciter_enable(true);
        if (g_airBandEnabled.load(std::memory_order_relaxed)) nagare_air_band_enable(true);
        if (g_stereoWidthEnabled.load(std::memory_order_relaxed)) nagare_stereo_width_enable(true);
        if (g_crossfeedEnabled.load(std::memory_order_relaxed)) nagare_crossfeed_enable(true);
        if (g_reverbEnabled.load(std::memory_order_relaxed)) nagare_reverb_enable(true);
        if (g_transientEnabled.load(std::memory_order_relaxed)) nagare_transient_shaper_enable(true);
        if (g_loudnessCompEnabled.load(std::memory_order_relaxed)) nagare_loudness_comp_enable(true);
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareCoreEnabled];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsCoreDSPEnabled(void) {
    return g_coreDSPEnabled.load(std::memory_order_relaxed);
}

void SGNagareSetSmartEnhance(BOOL enabled, float intensity) {
    intensity = std::max(0.0f, std::min(1.0f, intensity));
    g_smartEnhanceEnabled.store(enabled, std::memory_order_relaxed);
    g_smartIntensity.store(intensity, std::memory_order_relaxed);
    nagare_smart_enhance_enable(enabled);
    nagare_smart_enhance_set_intensity(intensity);
    if (enabled && !g_coreDSPEnabled.load(std::memory_order_relaxed)) {
        g_coreDSPEnabled.store(true, std::memory_order_release);
        [NSUserDefaults.standardUserDefaults setBool:true forKey:SGKeyNagareCoreEnabled];
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareSmartEnhanceEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:intensity forKey:SGKeyNagareSmartIntensity];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsSmartEnhanceEnabled(void) {
    return g_smartEnhanceEnabled.load(std::memory_order_relaxed);
}

float SGNagareGetSmartIntensity(void) {
    return g_smartIntensity.load(std::memory_order_relaxed);
}

void SGNagareSetVirtualBass(BOOL enabled, float amount, float freq) {
    amount = std::max(0.0f, std::min(1.0f, amount));
    freq = std::max(60.0f, std::min(250.0f, freq));
    g_vibeEnabled.store(enabled, std::memory_order_relaxed);
    g_vibeAmount.store(amount, std::memory_order_relaxed);
    g_vibeFreq.store(freq, std::memory_order_relaxed);
    nagare_virtual_bass_enable(enabled);
    nagare_virtual_bass_set(amount, freq);
    if (enabled && !g_coreDSPEnabled.load(std::memory_order_relaxed)) {
        g_coreDSPEnabled.store(true, std::memory_order_release);
        [NSUserDefaults.standardUserDefaults setBool:true forKey:SGKeyNagareCoreEnabled];
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareVirtualBassEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:amount forKey:SGKeyNagareVirtualBassAmount];
    [NSUserDefaults.standardUserDefaults setFloat:freq forKey:SGKeyNagareVirtualBassFreq];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsVirtualBassEnabled(void) {
    return g_vibeEnabled.load(std::memory_order_relaxed);
}

float SGNagareGetVirtualBassIntensity(void) {
    return g_vibeAmount.load(std::memory_order_relaxed);
}

void SGNagareSetSubharmonic(BOOL enabled, float amount) {
    amount = std::max(0.0f, std::min(1.0f, amount));
    nagare_subharmonic_enable(enabled);
    nagare_subharmonic_set(amount);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareSubharmonicEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:amount forKey:SGKeyNagareSubharmonicAmount];
}

void SGNagareSetTubeWarmth(BOOL enabled, float amount, float drive) {
    amount = std::max(0.0f, std::min(1.0f, amount));
    drive = std::max(0.0f, std::min(1.0f, drive));
    g_tubeEnabled.store(enabled, std::memory_order_relaxed);
    g_tubeAmount.store(amount, std::memory_order_relaxed);
    g_tubeDrive.store(drive, std::memory_order_relaxed);
    nagare_tube_warmth_enable(enabled);
    nagare_tube_warmth_set(amount, drive);
    if (enabled && !g_coreDSPEnabled.load(std::memory_order_relaxed)) {
        g_coreDSPEnabled.store(true, std::memory_order_release);
        [NSUserDefaults.standardUserDefaults setBool:true forKey:SGKeyNagareCoreEnabled];
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareTubeEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:amount forKey:SGKeyNagareTubeAmount];
    [NSUserDefaults.standardUserDefaults setFloat:drive forKey:SGKeyNagareTubeDrive];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsTubeWarmthEnabled(void) {
    return g_tubeEnabled.load(std::memory_order_relaxed);
}

float SGNagareGetTubeWarmthIntensity(void) {
    return g_tubeAmount.load(std::memory_order_relaxed);
}

void SGNagareSetExciter(BOOL enabled, float amount, float freq) {
    amount = std::max(0.0f, std::min(1.0f, amount));
    freq = std::max(2000.0f, std::min(12000.0f, freq));
    g_exciterEnabled.store(enabled, std::memory_order_relaxed);
    g_exciterAmount.store(amount, std::memory_order_relaxed);
    g_exciterFreq.store(freq, std::memory_order_relaxed);
    nagare_exciter_enable(enabled);
    nagare_exciter_set(amount, freq);
    if (enabled && !g_coreDSPEnabled.load(std::memory_order_relaxed)) {
        g_coreDSPEnabled.store(true, std::memory_order_release);
        [NSUserDefaults.standardUserDefaults setBool:true forKey:SGKeyNagareCoreEnabled];
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareExciterEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:amount forKey:SGKeyNagareExciterAmount];
    [NSUserDefaults.standardUserDefaults setFloat:freq forKey:SGKeyNagareExciterFreq];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsExciterEnabled(void) {
    return g_exciterEnabled.load(std::memory_order_relaxed);
}

float SGNagareGetExciterIntensity(void) {
    return g_exciterAmount.load(std::memory_order_relaxed);
}

void SGNagareSetAirBand(BOOL enabled, float amount) {
    amount = std::max(0.0f, std::min(1.0f, amount));
    g_airBandEnabled.store(enabled, std::memory_order_relaxed);
    g_airBandAmount.store(amount, std::memory_order_relaxed);
    nagare_air_band_enable(enabled);
    nagare_air_band_set(amount);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareAirBandEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:amount forKey:SGKeyNagareAirBandAmount];
}

void SGNagareSetStereoWidth(BOOL enabled, float width) {
    width = std::max(0.0f, std::min(2.5f, width));
    g_stereoWidthEnabled.store(enabled, std::memory_order_relaxed);
    g_stereoWidthAmount.store(width, std::memory_order_relaxed);
    nagare_stereo_width_enable(enabled);
    nagare_stereo_width_set(width);
    if (enabled && !g_coreDSPEnabled.load(std::memory_order_relaxed)) {
        g_coreDSPEnabled.store(true, std::memory_order_release);
        [NSUserDefaults.standardUserDefaults setBool:true forKey:SGKeyNagareCoreEnabled];
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareStereoWidthEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:width forKey:SGKeyNagareStereoWidthAmount];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsStereoWidthEnabled(void) {
    return g_stereoWidthEnabled.load(std::memory_order_relaxed);
}

float SGNagareGetStereoWidth(void) {
    return g_stereoWidthAmount.load(std::memory_order_relaxed);
}

void SGNagareSetCrossfeed(BOOL enabled, float amount) {
    amount = std::max(0.0f, std::min(1.0f, amount));
    g_crossfeedEnabled.store(enabled, std::memory_order_relaxed);
    g_crossfeedAmount.store(amount, std::memory_order_relaxed);
    nagare_crossfeed_enable(enabled);
    nagare_crossfeed_set(amount);
    if (enabled && !g_coreDSPEnabled.load(std::memory_order_relaxed)) {
        g_coreDSPEnabled.store(true, std::memory_order_release);
        [NSUserDefaults.standardUserDefaults setBool:true forKey:SGKeyNagareCoreEnabled];
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareCrossfeedEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:amount forKey:SGKeyNagareCrossfeedAmount];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsCrossfeedEnabled(void) {
    return g_crossfeedEnabled.load(std::memory_order_relaxed);
}

float SGNagareGetCrossfeedAmount(void) {
    return g_crossfeedAmount.load(std::memory_order_relaxed);
}

void SGNagareSetReverb(BOOL enabled, float roomSize, float damping, float wet, float dry, float width) {
    roomSize = std::max(0.0f, std::min(1.0f, roomSize));
    damping = std::max(0.0f, std::min(1.0f, damping));
    wet = std::max(0.0f, std::min(1.0f, wet));
    dry = std::max(0.0f, std::min(1.0f, dry));
    width = std::max(0.0f, std::min(1.0f, width));

    g_reverbEnabled.store(enabled, std::memory_order_relaxed);
    g_reverbRoom.store(roomSize, std::memory_order_relaxed);
    g_reverbDamping.store(damping, std::memory_order_relaxed);
    g_reverbWet.store(wet, std::memory_order_relaxed);
    g_reverbDry.store(dry, std::memory_order_relaxed);
    g_reverbWidth.store(width, std::memory_order_relaxed);

    nagare_reverb_enable(enabled);
    nagare_reverb_set(roomSize, damping, wet, dry, width);
    if (enabled && !g_coreDSPEnabled.load(std::memory_order_relaxed)) {
        g_coreDSPEnabled.store(true, std::memory_order_release);
        [NSUserDefaults.standardUserDefaults setBool:true forKey:SGKeyNagareCoreEnabled];
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareReverbEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:roomSize forKey:SGKeyNagareReverbRoom];
    [NSUserDefaults.standardUserDefaults setFloat:damping forKey:SGKeyNagareReverbDamping];
    [NSUserDefaults.standardUserDefaults setFloat:wet forKey:SGKeyNagareReverbWet];
    [NSUserDefaults.standardUserDefaults setFloat:dry forKey:SGKeyNagareReverbDry];
    [NSUserDefaults.standardUserDefaults setFloat:width forKey:SGKeyNagareReverbWidth];
    [NSNotificationCenter.defaultCenter postNotificationName:SGNagareSettingsDidChangeNotification object:nil];
}

BOOL SGNagareIsReverbEnabled(void) {
    return g_reverbEnabled.load(std::memory_order_relaxed);
}

float SGNagareGetReverbIntensity(void) {
    return g_reverbWet.load(std::memory_order_relaxed);
}

void SGNagareSetTransientShaper(BOOL enabled, float attack, float sustain) {
    attack = std::max(-1.0f, std::min(1.0f, attack));
    sustain = std::max(-1.0f, std::min(1.0f, sustain));
    g_transientEnabled.store(enabled, std::memory_order_relaxed);
    g_transientAttack.store(attack, std::memory_order_relaxed);
    g_transientSustain.store(sustain, std::memory_order_relaxed);
    nagare_transient_shaper_enable(enabled);
    nagare_transient_shaper_set(attack, sustain);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareTransientEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:attack forKey:SGKeyNagareTransientAttack];
    [NSUserDefaults.standardUserDefaults setFloat:sustain forKey:SGKeyNagareTransientSustain];
}

void SGNagareSetLoudnessComp(BOOL enabled, float amount) {
    amount = std::max(0.0f, std::min(1.0f, amount));
    g_loudnessCompEnabled.store(enabled, std::memory_order_relaxed);
    g_loudnessCompAmount.store(amount, std::memory_order_relaxed);
    nagare_loudness_comp_enable(enabled);
    nagare_loudness_comp_set(amount);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SGKeyNagareLoudnessCompEnabled];
    [NSUserDefaults.standardUserDefaults setFloat:amount forKey:SGKeyNagareLoudnessCompAmount];
}

void SGNagareSetEQEnabled(BOOL enabled) {
    nagare_eq_enable(enabled);
}

void SGNagareSetEQBands(const float *gains10) {
    if (gains10) nagare_eq_set_bands_smooth(gains10);
}

void SGNagareSetDeviceProfile(int profileId) {
    nagare_apply_device_profile(profileId);
}

void SGNagareGetFFTMagnitudes(float *output, int fftSize) {
    if (output && fftSize > 0) nagare_get_fft(output, fftSize);
}

// Auto-register into SGAudioPipeline upon tweak load
__attribute__((used, constructor)) static void SGNagareDSPAutoRegister(void) {
    SGNagareDSPInit(44100.0);
    SGAudioPipelineRegister(SGAudioStageNagare, SGNagareDSPGetAudioProcessor());
    SGLog(@"nagare dsp: stage registered with audio pipeline");
}
