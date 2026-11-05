// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// SCNet Real-Time Engine Implementation

#import "SCNetEngine.h"
#import "SCNetModelManager.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>
#include <algorithm>

extern "C" {
int32_t SCNetWorkerStart(const char *modelPath, void (*callback)(const float*, const float*, const float*, const float*, int32_t));
void SCNetWorkerStop(void);
void SCNetWorkerReset(void);
int32_t SCNetWorkerIsReady(void);
void SCNetWorkerPushAudio(const float *left, const float *right, int32_t frames);
}

// Circular ring buffer capacity: ~12 seconds of stereo audio (12 * 44100 = 529200 frames)
static constexpr uint32_t kRingCapacity = 524288; // 2^19 frames
static constexpr uint32_t kRingMask = kRingCapacity - 1;

struct SCNetRingBuffer {
    std::vector<float> drums;   // interleaved stereo [L, R, ...]
    std::vector<float> bass;
    std::vector<float> other;
    std::vector<float> vocals;
    std::atomic<uint32_t> writeHead{0};
    std::atomic<uint32_t> readHead{0};

    void init() {
        drums.assign(kRingCapacity * 2, 0.0f);
        bass.assign(kRingCapacity * 2, 0.0f);
        other.assign(kRingCapacity * 2, 0.0f);
        vocals.assign(kRingCapacity * 2, 0.0f);
        writeHead.store(0, std::memory_order_relaxed);
        readHead.store(0, std::memory_order_relaxed);
    }

    void clear() {
        writeHead.store(0, std::memory_order_relaxed);
        readHead.store(0, std::memory_order_relaxed);
    }

    uint32_t availableToRead() const {
        uint32_t w = writeHead.load(std::memory_order_acquire);
        uint32_t r = readHead.load(std::memory_order_relaxed);
        return (w >= r) ? (w - r) : (kRingCapacity - (r - w));
    }
};

static SCNetRingBuffer g_ring;
static std::atomic<bool> g_enabled{false};
static std::atomic<bool> g_workerActive{false};
static int g_sampleRate = 44100;

// Fader levels (0.0 to 2.0, default 1.0)
static std::atomic<float> g_vocal_target{1.0f};
static std::atomic<float> g_drums_target{1.0f};
static std::atomic<float> g_bass_target{1.0f};
static std::atomic<float> g_other_target{1.0f};

// Real-time meter RMS levels (0.0 to 1.0)
static std::atomic<float> g_meter_vocals{0.0f};
static std::atomic<float> g_meter_drums{0.0f};
static std::atomic<float> g_meter_bass{0.0f};
static std::atomic<float> g_meter_other{0.0f};

// Smoothed faders for render thread
static float s_cur_vocal = 1.0f;
static float s_cur_drums = 1.0f;
static float s_cur_bass = 1.0f;
static float s_cur_other = 1.0f;

// Crossfade between passthrough and stems to avoid clicks
static float s_stemsMixRatio = 0.0f; // 0.0 = passthrough, 1.0 = full separated stems

static void onStemsReceived(const float* drums, const float* bass, const float* other, const float* vocals, int32_t numFrames) {
    if (!drums || !bass || !other || !vocals || numFrames <= 0) return;

    uint32_t w = g_ring.writeHead.load(std::memory_order_relaxed);
    for (int32_t i = 0; i < numFrames; i++) {
        uint32_t idx = (w & kRingMask) * 2;
        g_ring.drums[idx]     = drums[i * 2];
        g_ring.drums[idx + 1] = drums[i * 2 + 1];

        g_ring.bass[idx]      = bass[i * 2];
        g_ring.bass[idx + 1]  = bass[i * 2 + 1];

        g_ring.other[idx]     = other[i * 2];
        g_ring.other[idx + 1] = other[i * 2 + 1];

        g_ring.vocals[idx]    = vocals[i * 2];
        g_ring.vocals[idx + 1]= vocals[i * 2 + 1];

        w++;
    }
    g_ring.writeHead.store(w, std::memory_order_release);
}

int scnet_engine_init(int sample_rate) {
    g_sampleRate = (sample_rate > 0) ? sample_rate : 44100;
    g_ring.init();
    s_cur_vocal = 1.0f;
    s_cur_drums = 1.0f;
    s_cur_bass = 1.0f;
    s_cur_other = 1.0f;
    s_stemsMixRatio = 0.0f;

    // Listen for model download completion
    [NSNotificationCenter.defaultCenter addObserverForName:SCNetModelStatusDidChangeNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification * _Nonnull note) {
        if (g_enabled.load(std::memory_order_relaxed) && SCNetModelManager.sharedManager.isModelReady) {
            if (!g_workerActive.load(std::memory_order_relaxed)) {
                NSURL *url = SCNetModelManager.sharedManager.modelURL;
                if (url) {
                    SCNetWorkerStart(url.path.UTF8String, onStemsReceived);
                    g_workerActive.store(true, std::memory_order_relaxed);
                }
            }
        }
    }];

    return 0;
}

void scnet_engine_release(void) {
    scnet_engine_set_enabled(false);
    g_ring.clear();
}

void scnet_engine_set_enabled(bool enabled) {
    g_enabled.store(enabled, std::memory_order_relaxed);
    if (enabled) {
        if (SCNetModelManager.sharedManager.isModelReady) {
            if (!g_workerActive.load(std::memory_order_relaxed)) {
                NSURL *url = SCNetModelManager.sharedManager.modelURL;
                if (url) {
                    SCNetWorkerStart(url.path.UTF8String, onStemsReceived);
                    g_workerActive.store(true, std::memory_order_relaxed);
                }
            }
        } else {
            [SCNetModelManager.sharedManager startDownloadIfNeeded];
        }
    } else {
        if (g_workerActive.load(std::memory_order_relaxed)) {
            SCNetWorkerStop();
            g_workerActive.store(false, std::memory_order_relaxed);
        }
        g_ring.clear();
    }
}

bool scnet_engine_is_enabled(void) {
    return g_enabled.load(std::memory_order_relaxed);
}

bool scnet_engine_is_ready(void) {
    return SCNetModelManager.sharedManager.isModelReady && SCNetWorkerIsReady();
}

void scnet_engine_set_stem_levels(float vocals, float drums, float bass, float other) {
    g_vocal_target.store(std::max(0.0f, std::min(2.0f, vocals)), std::memory_order_relaxed);
    g_drums_target.store(std::max(0.0f, std::min(2.0f, drums)), std::memory_order_relaxed);
    g_bass_target.store(std::max(0.0f, std::min(2.0f, bass)), std::memory_order_relaxed);
    g_other_target.store(std::max(0.0f, std::min(2.0f, other)), std::memory_order_relaxed);
}

void scnet_engine_get_stem_levels(float* vocals, float* drums, float* bass, float* other) {
    if (vocals) *vocals = g_vocal_target.load(std::memory_order_relaxed);
    if (drums) *drums = g_drums_target.load(std::memory_order_relaxed);
    if (bass) *bass = g_bass_target.load(std::memory_order_relaxed);
    if (other) *other = g_other_target.load(std::memory_order_relaxed);
}

void scnet_engine_clear(void) {
    g_ring.clear();
    SCNetWorkerReset();
    g_meter_vocals.store(0.0f, std::memory_order_relaxed);
    g_meter_drums.store(0.0f, std::memory_order_relaxed);
    g_meter_bass.store(0.0f, std::memory_order_relaxed);
    g_meter_other.store(0.0f, std::memory_order_relaxed);
}

void scnet_engine_get_stem_meters(float* vocals, float* drums, float* bass, float* other) {
    if (vocals) *vocals = g_meter_vocals.load(std::memory_order_relaxed);
    if (drums) *drums = g_meter_drums.load(std::memory_order_relaxed);
    if (bass) *bass = g_meter_bass.load(std::memory_order_relaxed);
    if (other) *other = g_meter_other.load(std::memory_order_relaxed);
}

void scnet_engine_process(float* left, float* right, int num_frames) {
    if (!left || !right || num_frames <= 0) return;

    if (!g_enabled.load(std::memory_order_relaxed)) {
        s_stemsMixRatio = 0.0f;
        return;
    }

    // Push input audio to SCNet worker lookahead queue
    SCNetWorkerPushAudio(left, right, num_frames);

    uint32_t available = g_ring.availableToRead();
    bool hasStems = (available >= (uint32_t)num_frames);

    // Target crossfade ratio: 1.0 if stems available, 0.0 if waiting for buffer
    float targetMix = hasStems ? 1.0f : 0.0f;

    // Smoothing coefficient: ~30ms filter
    const float alpha = 1.0f - expf(-1.0f / (g_sampleRate * 0.030f));

    float v_tgt = g_vocal_target.load(std::memory_order_relaxed);
    float d_tgt = g_drums_target.load(std::memory_order_relaxed);
    float b_tgt = g_bass_target.load(std::memory_order_relaxed);
    float o_tgt = g_other_target.load(std::memory_order_relaxed);

    uint32_t r = g_ring.readHead.load(std::memory_order_relaxed);
    float sum_v = 0.0f, sum_d = 0.0f, sum_b = 0.0f, sum_o = 0.0f;

    for (int i = 0; i < num_frames; i++) {
        // Smooth fader adjustments
        s_cur_vocal += alpha * (v_tgt - s_cur_vocal);
        s_cur_drums += alpha * (d_tgt - s_cur_drums);
        s_cur_bass  += alpha * (b_tgt - s_cur_bass);
        s_cur_other += alpha * (o_tgt - s_cur_other);
        s_stemsMixRatio += alpha * (targetMix - s_stemsMixRatio);

        float orig_l = left[i];
        float orig_r = right[i];

        if (hasStems) {
            uint32_t idx = (r & kRingMask) * 2;
            float dl = g_ring.drums[idx],     dr = g_ring.drums[idx + 1];
            float bl = g_ring.bass[idx],      br = g_ring.bass[idx + 1];
            float ol = g_ring.other[idx],     orr= g_ring.other[idx + 1];
            float vl = g_ring.vocals[idx],    vr = g_ring.vocals[idx + 1];
            r++;

            sum_v += vl * vl + vr * vr;
            sum_d += dl * dl + dr * dr;
            sum_b += bl * bl + br * br;
            sum_o += ol * ol + orr * orr;

            // Mixed stem audio
            float mixed_l = s_cur_vocal * vl + s_cur_drums * dl + s_cur_bass * bl + s_cur_other * ol;
            float mixed_r = s_cur_vocal * vr + s_cur_drums * dr + s_cur_bass * br + s_cur_other * orr;

            // Crossfade with original passthrough
            left[i]  = (1.0f - s_stemsMixRatio) * orig_l + s_stemsMixRatio * mixed_l;
            right[i] = (1.0f - s_stemsMixRatio) * orig_r + s_stemsMixRatio * mixed_r;
        }
    }

    if (hasStems) {
        g_ring.readHead.store(r, std::memory_order_release);
        if (num_frames > 0) {
            float rms_v = sqrtf(sum_v / (2.0f * num_frames));
            float rms_d = sqrtf(sum_d / (2.0f * num_frames));
            float rms_b = sqrtf(sum_b / (2.0f * num_frames));
            float rms_o = sqrtf(sum_o / (2.0f * num_frames));
            g_meter_vocals.store(g_meter_vocals.load(std::memory_order_relaxed) * 0.8f + rms_v * 0.2f, std::memory_order_relaxed);
            g_meter_drums.store(g_meter_drums.load(std::memory_order_relaxed) * 0.8f + rms_d * 0.2f, std::memory_order_relaxed);
            g_meter_bass.store(g_meter_bass.load(std::memory_order_relaxed) * 0.8f + rms_b * 0.2f, std::memory_order_relaxed);
            g_meter_other.store(g_meter_other.load(std::memory_order_relaxed) * 0.8f + rms_o * 0.2f, std::memory_order_relaxed);
        }
    }
}
