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
 * Dynamic Range Restorer - Neural-inspired dynamic range restoration
 *
 * Counteracts the "loudness wars" by restoring dynamics to over-compressed audio.
 * Uses intelligent transient detection and expansion to bring back "life" to
 * heavily mastered recordings.
 *
 * Features:
 * - Detects over-compressed audio automatically
 * - Multi-band expansion for frequency-specific restoration
 * - Transient enhancement to restore "punch"
 * - Loudness normalization to maintain consistent volume
 *
 * Based on psychoacoustic research on perceived loudness and dynamics.
 */

#ifndef DYNAMIC_RESTORER_H
#define DYNAMIC_RESTORER_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize the dynamic restorer
 * @param sample_rate Audio sample rate
 * @return 0 on success, -1 on failure
 */
int restorer_init(int sample_rate);

/**
 * Release restorer resources
 */
void restorer_release(void);

/**
 * Enable/disable dynamic restoration
 */
void restorer_enable(bool enabled);

/**
 * Check if restoration is enabled
 */
bool restorer_is_enabled(void);

/**
 * Set restoration intensity
 * @param intensity 0.0 = off, 1.0 = maximum restoration
 */
void restorer_set_intensity(float intensity);

/**
 * Set expansion ratio
 * @param ratio 1.0 = no expansion, 2.0 = 2:1 expansion, etc.
 */
void restorer_set_expansion_ratio(float ratio);

/**
 * Set threshold below which expansion begins
 * @param threshold_db Threshold in dB (typically -20 to -10)
 */
void restorer_set_threshold(float threshold_db);

/**
 * Enable/disable transient enhancement
 * Enhances attack transients for more "punch"
 */
void restorer_set_transient_enhancement(bool enabled);

/**
 * Set transient enhancement amount
 * @param amount 0.0 = none, 1.0 = maximum
 */
void restorer_set_transient_amount(float amount);

/**
 * Enable/disable loudness normalization
 * Maintains perceived loudness after expansion
 */
void restorer_set_normalize(bool enabled);

/**
 * Set target loudness (LUFS)
 * @param lufs Target loudness (typically -14 to -16 LUFS for streaming)
 */
void restorer_set_target_loudness(float lufs);

/**
 * Process stereo audio through restorer
 * @param left Left channel samples (modified in-place)
 * @param right Right channel samples (modified in-place)
 * @param num_frames Number of frames to process
 */
void restorer_process(float* left, float* right, int num_frames);

/**
 * Get detected dynamic range
 * @return Estimated dynamic range in dB (higher = more dynamic)
 */
float restorer_get_detected_dynamic_range(void);

/**
 * Get current gain reduction/expansion
 * @return Current gain change in dB
 */
float restorer_get_current_gain(void);

/**
 * Get compression detection score
 * @return 0.0 = dynamic, 1.0 = heavily compressed
 */
float restorer_get_compression_score(void);

#ifdef __cplusplus
}
#endif

#endif // DYNAMIC_RESTORER_H
