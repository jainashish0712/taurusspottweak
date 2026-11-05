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
 * Audio Upscaler - AI-style audio enhancement
 *
 * Enhances low-bitrate/low-sample-rate audio by:
 * 1. Spectral Band Replication (SBR) - reconstructs high frequencies
 * 2. Harmonic extension - adds natural overtones
 * 3. Transient enhancement - sharpens attack transients
 *
 * Similar techniques used in HE-AAC and Sony DSEE Ultimate.
 */

#ifndef AUDIO_UPSCALER_H
#define AUDIO_UPSCALER_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize the audio upscaler
 * @param sample_rate Audio sample rate
 * @return 0 on success, -1 on failure
 */
int upscaler_init(int sample_rate);

/**
 * Release upscaler resources
 */
void upscaler_release(void);

/**
 * Enable/disable upscaling
 */
void upscaler_enable(bool enabled);

/**
 * Check if upscaling is enabled
 */
bool upscaler_is_enabled(void);

/**
 * Set upscaling intensity
 * @param intensity 0.0 = off, 1.0 = maximum enhancement
 */
void upscaler_set_intensity(float intensity);

/**
 * Set the cutoff frequency for SBR
 * Audio above this frequency is considered lost and will be reconstructed
 * @param frequency Cutoff in Hz (typically 14000-16000 for MP3s)
 */
void upscaler_set_sbr_cutoff(float frequency);

/**
 * Enable/disable transient enhancement
 */
void upscaler_set_transient_enhancement(bool enabled);

/**
 * Set harmonic extension amount
 * @param amount 0.0 = none, 1.0 = full harmonic extension
 */
void upscaler_set_harmonic_extension(float amount);

/**
 * Process stereo audio through upscaler
 * @param left Left channel samples (modified in-place)
 * @param right Right channel samples (modified in-place)
 * @param num_frames Number of frames to process
 */
void upscaler_process(float* left, float* right, int num_frames);

/**
 * Get detected audio quality
 * Returns estimated source quality based on spectral analysis
 * @return 0 = low (needs upscaling), 1 = medium, 2 = high (lossless)
 */
int upscaler_get_detected_quality(void);

#ifdef __cplusplus
}
#endif

#endif // AUDIO_UPSCALER_H
