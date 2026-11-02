// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// This file is part of nagare_dsp.
//
// nagare_dsp is free software: you can redistribute it and/or modify it under
// the terms of the GNU Affero General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.
//
// nagare_dsp is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details. You should have received a copy of it along with this
// program; if not, see <https://www.gnu.org/licenses/>.
//
// A commercial licence, without the AGPL's reciprocity requirement, is
// available from the copyright holder. See README.md.
//
// Portions of this project embed third-party data under permissive terms whose
// attribution requirements survive under either licence. See NOTICE.

/**
 * HRTF Processor - Spatial Audio via Head-Related Transfer Functions
 *
 * Implements binaural spatialization for headphone listening.
 * Creates the perception of sound coming from virtual speakers
 * positioned around the listener.
 *
 * Theory:
 * - HRTF describes how sound is filtered by head, ears, and torso
 * - HRIR (Head-Related Impulse Response) is the time-domain representation
 * - By convolving audio with HRIRs, we simulate spatial positioning
 *
 * Localization Cues:
 * - ITD (Interaural Time Difference): < 1.5 kHz, up to ~0.7ms
 * - ILD (Interaural Level Difference): > 1.5 kHz, up to ~20 dB
 * - Spectral cues from pinna (ear shape): elevation, front/back
 *
 * Copyright (c) 2025 Nagare
 */

#ifndef HRTF_PROCESSOR_H
#define HRTF_PROCESSOR_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize HRTF processor
 * @param sample_rate Audio sample rate
 * @return 0 on success
 */
int hrtf_init(int sample_rate);

/**
 * Release HRTF resources
 */
void hrtf_release(void);

/**
 * Enable/disable HRTF processing
 */
void hrtf_enable(bool enabled);

/**
 * Check if HRTF is enabled
 */
bool hrtf_is_enabled(void);

/**
 * Set virtual speaker angle (azimuth)
 * @param angle_degrees Angle in degrees (-90 to +90, 0 = front)
 *                      Typical stereo: ±30°
 */
void hrtf_set_speaker_angle(float angle_degrees);

/**
 * Set room size for early reflections
 * @param size 0.0 = anechoic, 1.0 = large room
 */
void hrtf_set_room_size(float size);

/**
 * Set distance from listener to virtual speakers
 * @param distance_meters Distance in meters (1.0 - 10.0)
 */
void hrtf_set_distance(float distance_meters);

/**
 * Process stereo audio through HRTF
 * Creates binaural output from stereo input
 * @param left Left channel input/output
 * @param right Right channel input/output
 * @param num_frames Number of frames to process
 */
void hrtf_process(float* left, float* right, int num_frames);

/**
 * Set HRTF preset
 * @param preset_id 0=Generic, 1=Small head, 2=Large head
 */
void hrtf_set_preset(int preset_id);

/**
 * Load custom HRIR data
 * @param left_hrir Left ear impulse response
 * @param right_hrir Right ear impulse response
 * @param length Length of HRIR in samples
 * @param azimuth Azimuth angle this HRIR represents
 * @return 0 on success
 */
int hrtf_load_custom_hrir(const float* left_hrir, const float* right_hrir,
                          int length, float azimuth);

#ifdef __cplusplus
}
#endif

#endif // HRTF_PROCESSOR_H
