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
 * Source Separator - Real-time audio source separation
 *
 * Separates audio into component stems using spectral processing:
 * - Vocals (center-panned content)
 * - Instruments (side content)
 * - Bass (low frequency content)
 * - Drums/Transients (percussive content)
 *
 * Uses techniques:
 * - Mid/Side processing for vocal isolation
 * - Harmonic/Percussive Source Separation (HPSS)
 * - Spectral masking
 *
 * Lighter than neural network approaches but works in real-time.
 */

#ifndef SOURCE_SEPARATOR_H
#define SOURCE_SEPARATOR_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Separation modes
 */
typedef enum {
    SEPARATOR_MODE_NORMAL = 0,      // No separation, pass-through
    SEPARATOR_MODE_KARAOKE,         // Remove vocals (for singing along)
    SEPARATOR_MODE_VOCALS_ONLY,     // Isolate vocals only
    SEPARATOR_MODE_BASS_BOOST,      // Emphasize bass frequencies
    SEPARATOR_MODE_DRUMS_EMPHASIS,  // Emphasize percussive content
    SEPARATOR_MODE_INSTRUMENTAL,    // Remove vocals, keep all instruments
    SEPARATOR_MODE_CUSTOM           // Custom stem mix
} SeparatorMode;

/**
 * Initialize the source separator
 * @param sample_rate Audio sample rate
 * @return 0 on success, -1 on failure
 */
int separator_init(int sample_rate);

/**
 * Release separator resources
 */
void separator_release(void);

/**
 * Enable/disable source separation
 */
void separator_enable(bool enabled);

/**
 * Check if separation is enabled
 */
bool separator_is_enabled(void);

/**
 * Set separation mode
 */
void separator_set_mode(SeparatorMode mode);

/**
 * Get current separation mode
 */
SeparatorMode separator_get_mode(void);

/**
 * Set vocal removal strength
 * @param strength 0.0 = no removal, 1.0 = maximum removal
 */
void separator_set_vocal_removal_strength(float strength);

/**
 * Set center width for vocal detection
 * @param width 0.0 = exact center only, 1.0 = wide center
 */
void separator_set_center_width(float width);

/**
 * Set custom stem levels (for CUSTOM mode)
 * @param vocals Level for vocals (0.0 - 2.0, 1.0 = original)
 * @param bass Level for bass (0.0 - 2.0)
 * @param drums Level for drums/transients (0.0 - 2.0)
 * @param other Level for other instruments (0.0 - 2.0)
 */
void separator_set_stem_levels(float vocals, float bass, float drums, float other);

/**
 * Process stereo audio through separator
 * @param left Left channel samples (modified in-place)
 * @param right Right channel samples (modified in-place)
 * @param num_frames Number of frames to process
 */
void separator_process(float* left, float* right, int num_frames);

/**
 * Get current stem levels (for visualization)
 * @param vocals Output: current vocal level (0.0-1.0)
 * @param bass Output: current bass level (0.0-1.0)
 * @param drums Output: current drums level (0.0-1.0)
 * @param other Output: current other level (0.0-1.0)
 */
void separator_get_stem_levels(float* vocals, float* bass, float* drums, float* other);

#ifdef __cplusplus
}
#endif

#endif // SOURCE_SEPARATOR_H
