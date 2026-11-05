// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// Spleeter Real-Time Engine C/C++ Interface

#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Engine lifecycle
int spleeter_engine_init(int sample_rate);
void spleeter_engine_release(void);

// Enable / Disable
void spleeter_engine_set_enabled(bool enabled);
bool spleeter_engine_is_enabled(void);
bool spleeter_engine_is_ready(void);

// Real-time Stem Faders (0.0 to 2.0, 1.0 = 100%)
void spleeter_engine_set_stem_levels(float vocals, float drums, float bass, float other);
void spleeter_engine_get_stem_levels(float* vocals, float* drums, float* bass, float* other);
void spleeter_engine_get_stem_meters(float* vocals, float* drums, float* bass, float* other);
void spleeter_engine_clear(void);
void spleeter_engine_reload(void);

// Real-time CoreAudio Render Callback
void spleeter_engine_process(float* left, float* right, int num_frames);

#ifdef __cplusplus
}
#endif
