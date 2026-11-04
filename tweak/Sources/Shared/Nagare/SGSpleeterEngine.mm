// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// Spleeter Real-Time Engine Implementation

#import "SGSpleeterEngine.h"
#import "SGSpleeterModelManager.h"
#include "source_separator.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>
#include <algorithm>

extern "C" {
int32_t SGSpleeterWorkerStart(const char *modelPath, void (*callback)(const float*, const float*, const float*, const float*, int32_t));
void SGSpleeterWorkerStop(void);
void SGSpleeterWorkerReset(void);
int32_t SGSpleeterWorkerIsReady(void);
void SGSpleeterWorkerPushAudio(const float *left, const float *right, int32_t frames);
}

// Circular ring buffer capacity: ~11.8 seconds of stereo audio (2^19 frames)
static constexpr uint32_t kRingCapacity = 524288;
static constexpr uint32_t kRingMask = kRingCapacity - 1;

struct SGSpleeterRingBuffer {
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

static SGSpleeterRingBuffer g_ring;
static std::atomic<bool> g_enabled{false};
static std::atomic<bool> g_workerActive{false};

// Target stem gains
static std::atomic<float> g_targetVocals{1.0f};
static std::atomic<float> g_targetDrums{1.0f};
static std::atomic<float> g_targetBass{1.0f};
static std::atomic<float> g_targetOther{1.0f};

static id s_modelObserver = nil;

static void spleeter_write_callback(const float *d, const float *b, const float *o, const float *v, int32_t frames) {
    if (!d || !b || !o || !v || frames <= 0) return;

    uint32_t w = g_ring.writeHead.load(std::memory_order_relaxed);
    for (int i = 0; i < frames; i++) {
        uint32_t idx = (w + (uint32_t)i) & kRingMask;
        g_ring.drums[idx * 2] = d[i * 2];
        g_ring.drums[idx * 2 + 1] = d[i * 2 + 1];

        g_ring.bass[idx * 2] = b[i * 2];
        g_ring.bass[idx * 2 + 1] = b[i * 2 + 1];

        g_ring.other[idx * 2] = o[i * 2];
        g_ring.other[idx * 2 + 1] = o[i * 2 + 1];

        g_ring.vocals[idx * 2] = v[i * 2];
        g_ring.vocals[idx * 2 + 1] = v[i * 2 + 1];
    }
    g_ring.writeHead.store((w + (uint32_t)frames) & kRingMask, std::memory_order_release);
}

static void try_start_worker() {
    SGSpleeterModelManager *mgr = [SGSpleeterModelManager sharedManager];
    if (!mgr.isModelReady) {
        [mgr startDownloadIfNeeded];
        return;
    }

    NSURL *url = mgr.modelURL;
    if (!url) return;

    if (!g_workerActive.load(std::memory_order_relaxed)) {
        if (SGSpleeterWorkerStart([url.path UTF8String], spleeter_write_callback)) {
            g_workerActive.store(true, std::memory_order_relaxed);
        }
    }
}

int spleeter_engine_init(int sample_rate) {
    (void)sample_rate;
    g_ring.init();

    if (!s_modelObserver) {
        s_modelObserver = [NSNotificationCenter.defaultCenter addObserverForName:SGSpleeterModelStatusDidChangeNotification
                                                                          object:nil
                                                                           queue:nil
                                                                      usingBlock:^(NSNotification * _Nonnull note) {
            SGSpleeterModelManager *mgr = [SGSpleeterModelManager sharedManager];
            if (mgr.isModelReady) {
                try_start_worker();
            }
        }];
    }

    try_start_worker();
    return 1;
}

void spleeter_engine_release(void) {
    if (s_modelObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:s_modelObserver];
        s_modelObserver = nil;
    }
    SGSpleeterWorkerStop();
    g_workerActive.store(false, std::memory_order_relaxed);
    g_ring.clear();
}

void spleeter_engine_set_enabled(bool enabled) {
    g_enabled.store(enabled, std::memory_order_release);
    if (enabled) {
        try_start_worker();
    } else {
        spleeter_engine_clear();
    }
}

bool spleeter_engine_is_enabled(void) {
    return g_enabled.load(std::memory_order_relaxed);
}

bool spleeter_engine_is_ready(void) {
    return g_workerActive.load(std::memory_order_relaxed) && SGSpleeterWorkerIsReady();
}

void spleeter_engine_set_stem_levels(float vocals, float drums, float bass, float other) {
    g_targetVocals.store(std::max(0.0f, std::min(2.0f, vocals)), std::memory_order_relaxed);
    g_targetDrums.store(std::max(0.0f, std::min(2.0f, drums)), std::memory_order_relaxed);
    g_targetBass.store(std::max(0.0f, std::min(2.0f, bass)), std::memory_order_relaxed);
    g_targetOther.store(std::max(0.0f, std::min(2.0f, other)), std::memory_order_relaxed);
}

void spleeter_engine_get_stem_levels(float* vocals, float* drums, float* bass, float* other) {
    if (vocals) *vocals = g_targetVocals.load(std::memory_order_relaxed);
    if (drums) *drums = g_targetDrums.load(std::memory_order_relaxed);
    if (bass) *bass = g_targetBass.load(std::memory_order_relaxed);
    if (other) *other = g_targetOther.load(std::memory_order_relaxed);
}

void spleeter_engine_get_stem_meters(float* vocals, float* drums, float* bass, float* other) {
    // Report real-time synchronous RMS meters directly from the active DSP separator
    separator_get_stem_levels(vocals, bass, drums, other);
}

void spleeter_engine_clear(void) {
    SGSpleeterWorkerReset();
    g_ring.clear();
    separator_clear();
}

void spleeter_engine_reload(void) {
    SGSpleeterWorkerStop();
    g_workerActive.store(false, std::memory_order_relaxed);
    spleeter_engine_clear();
    try_start_worker();
}

void spleeter_engine_process(float* left, float* right, int num_frames) {
    if (!left || !right || num_frames <= 0) return;
    if (!g_enabled.load(std::memory_order_relaxed)) return;

    // Process in real time with 11.6ms STFT overlap (zero output delay line, zero overlap/repeat)
    separator_process(left, right, num_frames);
}
