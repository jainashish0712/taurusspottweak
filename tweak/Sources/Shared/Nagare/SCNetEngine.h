// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// SCNet Real-Time Engine C/C++ Interface

#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Engine lifecycle
int scnet_engine_init(int sample_rate);
void scnet_engine_release(void);

// Enable / Disable
void scnet_engine_set_enabled(bool enabled);
bool scnet_engine_is_enabled(void);
bool scnet_engine_is_ready(void);

// Real-time Stem Faders (0.0 to 2.0, 1.0 = 100%)
void scnet_engine_set_stem_levels(float vocals, float drums, float bass, float other);
void scnet_engine_get_stem_levels(float* vocals, float* drums, float* bass, float* other);

// Real-time CoreAudio Render Callback
void scnet_engine_process(float* left, float* right, int num_frames);

#ifdef __cplusplus
}
#endif
