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
 * Source Separator Implementation
 *
 * Real-time audio source separation using:
 * - Mid/Side (M/S) processing for center channel extraction
 * - STFT spectral processing for frequency-based separation
 * - Harmonic/Percussive Source Separation (HPSS) concepts
 *
 * Center-panned vocals appear in the Mid channel (L+R).
 * Side content (panned instruments) appears in the Side channel (L-R).
 */

#include "source_separator.h"
#include <cmath>
#include <cstring>
#include <algorithm>

// ============================================================================
// Constants
// ============================================================================

static constexpr int FFT_SIZE = 2048;
static constexpr int HOP_SIZE = FFT_SIZE / 4;  // 75% overlap
static constexpr float PI = 3.14159265358979323846f;
static constexpr float TWO_PI = 2.0f * PI;

// Frequency ranges (in bins at 44.1kHz with 2048 FFT)
static constexpr int BASS_CUTOFF_BIN = 10;     // ~215 Hz
static constexpr int VOCAL_LOW_BIN = 15;       // ~322 Hz
static constexpr int VOCAL_HIGH_BIN = 400;     // ~8.6 kHz

// ============================================================================
// State
// ============================================================================

struct SeparatorState {
    bool initialized;
    bool enabled;
    int sample_rate;
    SeparatorMode mode;

    // Parameters
    float vocal_removal_strength;
    float center_width;
    float vocal_level;
    float bass_level;
    float drums_level;
    float other_level;

    // FFT
    float window[FFT_SIZE];
    float fft_real_l[FFT_SIZE];
    float fft_imag_l[FFT_SIZE];
    float fft_real_r[FFT_SIZE];
    float fft_imag_r[FFT_SIZE];

    // Mid/Side
    float mid_real[FFT_SIZE];
    float mid_imag[FFT_SIZE];
    float side_real[FFT_SIZE];
    float side_imag[FFT_SIZE];

    // STFT overlap buffers
    float input_buffer_left[FFT_SIZE];
    float input_buffer_right[FFT_SIZE];
    float output_buffer_left[FFT_SIZE];
    float output_buffer_right[FFT_SIZE];
    int buffer_pos;

    // HPSS: Previous frame for percussive detection
    float prev_mag_l[FFT_SIZE / 2];
    float prev_mag_r[FFT_SIZE / 2];

    // Stem level meters
    float meter_vocals;
    float meter_bass;
    float meter_drums;
    float meter_other;

    bool has_valid_output;
};

static SeparatorState g_separator;

// ============================================================================
// FFT
// ============================================================================

static void fft_forward(float* real, float* imag, int n) {
    // Bit reversal
    int j = 0;
    for (int i = 0; i < n - 1; i++) {
        if (i < j) {
            std::swap(real[i], real[j]);
            std::swap(imag[i], imag[j]);
        }
        int k = n >> 1;
        while (k <= j) {
            j -= k;
            k >>= 1;
        }
        j += k;
    }

    // FFT butterflies
    for (int len = 2; len <= n; len *= 2) {
        float angle = -TWO_PI / len;
        float wreal = 1.0f;
        float wimag = 0.0f;
        float wpreal = cosf(angle);
        float wpimag = sinf(angle);

        for (int i = 0; i < len / 2; i++) {
            for (int k = i; k < n; k += len) {
                int k2 = k + len / 2;
                float treal = wreal * real[k2] - wimag * imag[k2];
                float timag = wreal * imag[k2] + wimag * real[k2];
                real[k2] = real[k] - treal;
                imag[k2] = imag[k] - timag;
                real[k] += treal;
                imag[k] += timag;
            }
            float temp = wreal;
            wreal = wreal * wpreal - wimag * wpimag;
            wimag = temp * wpimag + wimag * wpreal;
        }
    }
}

static void fft_inverse(float* real, float* imag, int n) {
    for (int i = 0; i < n; i++) {
        imag[i] = -imag[i];
    }

    fft_forward(real, imag, n);

    float scale = 1.0f / n;
    for (int i = 0; i < n; i++) {
        real[i] *= scale;
        imag[i] = -imag[i] * scale;
    }
}

static void create_hann_window(float* window, int size) {
    for (int i = 0; i < size; i++) {
        window[i] = 0.5f * (1.0f - cosf(TWO_PI * i / (size - 1)));
    }
}

static inline float get_magnitude(float real, float imag) {
    return sqrtf(real * real + imag * imag);
}

// ============================================================================
// Mid/Side Processing
// ============================================================================

static void stereo_to_ms(float* l_real, float* l_imag, float* r_real, float* r_imag,
                         float* m_real, float* m_imag, float* s_real, float* s_imag,
                         int size) {
    for (int i = 0; i < size; i++) {
        // Mid = (L + R) / 2
        m_real[i] = (l_real[i] + r_real[i]) * 0.5f;
        m_imag[i] = (l_imag[i] + r_imag[i]) * 0.5f;

        // Side = (L - R) / 2
        s_real[i] = (l_real[i] - r_real[i]) * 0.5f;
        s_imag[i] = (l_imag[i] - r_imag[i]) * 0.5f;
    }
}

static void ms_to_stereo(float* m_real, float* m_imag, float* s_real, float* s_imag,
                         float* l_real, float* l_imag, float* r_real, float* r_imag,
                         int size) {
    for (int i = 0; i < size; i++) {
        // L = M + S
        l_real[i] = m_real[i] + s_real[i];
        l_imag[i] = m_imag[i] + s_imag[i];

        // R = M - S
        r_real[i] = m_real[i] - s_real[i];
        r_imag[i] = m_imag[i] - s_imag[i];
    }
}

// ============================================================================
// Separation Methods
// ============================================================================

// Karaoke: Remove center-panned vocals
static void apply_karaoke(SeparatorState& s) {
    int half = FFT_SIZE / 2;
    float strength = s.vocal_removal_strength;
    float width = s.center_width;

    for (int i = 0; i < half; i++) {
        // Only process vocal frequency range
        if (i >= VOCAL_LOW_BIN && i <= VOCAL_HIGH_BIN) {
            // Calculate how "center-panned" this frequency is
            float mid_mag = get_magnitude(s.mid_real[i], s.mid_imag[i]);
            float side_mag = get_magnitude(s.side_real[i], s.side_imag[i]);

            float total = mid_mag + side_mag + 0.0001f;
            float center_ratio = mid_mag / total;

            // If center-panned (vocal), reduce mid channel
            if (center_ratio > (1.0f - width) * 0.5f) {
                float reduction = 1.0f - (strength * center_ratio);
                reduction = std::max(0.0f, reduction);

                s.mid_real[i] *= reduction;
                s.mid_imag[i] *= reduction;
            }
        }
    }

    // Mirror for negative frequencies
    for (int i = 1; i < half; i++) {
        s.mid_real[FFT_SIZE - i] = s.mid_real[i];
        s.mid_imag[FFT_SIZE - i] = -s.mid_imag[i];
    }
}

// Vocals only: Isolate center-panned vocals
static void apply_vocals_only(SeparatorState& s) {
    int half = FFT_SIZE / 2;
    float strength = s.vocal_removal_strength;

    for (int i = 0; i < half; i++) {
        if (i >= VOCAL_LOW_BIN && i <= VOCAL_HIGH_BIN) {
            // Keep mid, remove side
            float mid_mag = get_magnitude(s.mid_real[i], s.mid_imag[i]);
            float side_mag = get_magnitude(s.side_real[i], s.side_imag[i]);

            float total = mid_mag + side_mag + 0.0001f;
            float center_ratio = mid_mag / total;

            // Reduce side channel for center-panned content
            float side_reduction = strength * center_ratio;
            s.side_real[i] *= (1.0f - side_reduction);
            s.side_imag[i] *= (1.0f - side_reduction);
        } else {
            // Outside vocal range: reduce both
            float reduction = 1.0f - strength * 0.7f;
            s.mid_real[i] *= reduction;
            s.mid_imag[i] *= reduction;
            s.side_real[i] *= reduction;
            s.side_imag[i] *= reduction;
        }
    }

    // Mirror for negative frequencies
    for (int i = 1; i < half; i++) {
        s.mid_real[FFT_SIZE - i] = s.mid_real[i];
        s.mid_imag[FFT_SIZE - i] = -s.mid_imag[i];
        s.side_real[FFT_SIZE - i] = s.side_real[i];
        s.side_imag[FFT_SIZE - i] = -s.side_imag[i];
    }
}

// Bass boost: Emphasize low frequencies
static void apply_bass_boost(SeparatorState& s, float boost_db) {
    int half = FFT_SIZE / 2;
    float boost_linear = powf(10.0f, boost_db / 20.0f);

    for (int i = 0; i < BASS_CUTOFF_BIN && i < half; i++) {
        // Smooth rolloff
        float factor = boost_linear;
        if (i > BASS_CUTOFF_BIN / 2) {
            float t = (float)(i - BASS_CUTOFF_BIN / 2) / (BASS_CUTOFF_BIN / 2);
            factor = boost_linear + (1.0f - boost_linear) * t;
        }

        s.mid_real[i] *= factor;
        s.mid_imag[i] *= factor;
        s.side_real[i] *= factor;
        s.side_imag[i] *= factor;
    }

    // Mirror
    for (int i = 1; i < BASS_CUTOFF_BIN && i < half; i++) {
        s.mid_real[FFT_SIZE - i] = s.mid_real[i];
        s.mid_imag[FFT_SIZE - i] = -s.mid_imag[i];
        s.side_real[FFT_SIZE - i] = s.side_real[i];
        s.side_imag[FFT_SIZE - i] = -s.side_imag[i];
    }
}

// Drums emphasis: Enhance transients using spectral flux
static void apply_drums_emphasis(SeparatorState& s, float emphasis) {
    int half = FFT_SIZE / 2;

    for (int i = 0; i < half; i++) {
        float mag_l = get_magnitude(s.fft_real_l[i], s.fft_imag_l[i]);
        float mag_r = get_magnitude(s.fft_real_r[i], s.fft_imag_r[i]);

        // Spectral flux: how much did magnitude change from last frame?
        float flux_l = std::max(0.0f, mag_l - s.prev_mag_l[i]);
        float flux_r = std::max(0.0f, mag_r - s.prev_mag_r[i]);

        // High flux = transient (drums)
        float transient_l = flux_l / (s.prev_mag_l[i] + 0.0001f);
        float transient_r = flux_r / (s.prev_mag_r[i] + 0.0001f);

        // Emphasize transients
        float boost_l = 1.0f + emphasis * std::min(transient_l, 2.0f);
        float boost_r = 1.0f + emphasis * std::min(transient_r, 2.0f);

        s.fft_real_l[i] *= boost_l;
        s.fft_imag_l[i] *= boost_l;
        s.fft_real_r[i] *= boost_r;
        s.fft_imag_r[i] *= boost_r;

        // Store for next frame
        s.prev_mag_l[i] = mag_l;
        s.prev_mag_r[i] = mag_r;
    }

    // Mirror
    for (int i = 1; i < half; i++) {
        s.fft_real_l[FFT_SIZE - i] = s.fft_real_l[i];
        s.fft_imag_l[FFT_SIZE - i] = -s.fft_imag_l[i];
        s.fft_real_r[FFT_SIZE - i] = s.fft_real_r[i];
        s.fft_imag_r[FFT_SIZE - i] = -s.fft_imag_r[i];
    }
}

// Custom stem mix
static void apply_custom_mix(SeparatorState& s) {
    int half = FFT_SIZE / 2;

    for (int i = 0; i < half; i++) {
        float mid_gain = 1.0f;
        float side_gain = 1.0f;

        // Bass region
        if (i < BASS_CUTOFF_BIN) {
            mid_gain = s.bass_level;
            side_gain = s.bass_level;
        }
        // Vocal region (center-panned)
        else if (i >= VOCAL_LOW_BIN && i <= VOCAL_HIGH_BIN) {
            // Apply vocal level to mid, other level to side
            mid_gain = s.vocal_level;
            side_gain = s.other_level;
        }
        // Other
        else {
            mid_gain = s.other_level;
            side_gain = s.other_level;
        }

        // Spectral flux transient detection for drums/percussive stem
        float mag_l = get_magnitude(s.fft_real_l[i], s.fft_imag_l[i]);
        float mag_r = get_magnitude(s.fft_real_r[i], s.fft_imag_r[i]);
        float avg_mag = 0.5f * (mag_l + mag_r);
        float prev_mag = 0.5f * (s.prev_mag_l[i] + s.prev_mag_r[i]);
        float flux = std::max(0.0f, avg_mag - prev_mag);
        float transient = std::min(1.0f, flux / (prev_mag + 0.0001f));

        float eff_mid = (1.0f - transient) * mid_gain + transient * s.drums_level;
        float eff_side = (1.0f - transient) * side_gain + transient * s.drums_level;

        s.mid_real[i] *= eff_mid;
        s.mid_imag[i] *= eff_mid;
        s.side_real[i] *= eff_side;
        s.side_imag[i] *= eff_side;
    }

    // Mirror
    for (int i = 1; i < half; i++) {
        s.mid_real[FFT_SIZE - i] = s.mid_real[i];
        s.mid_imag[FFT_SIZE - i] = -s.mid_imag[i];
        s.side_real[FFT_SIZE - i] = s.side_real[i];
        s.side_imag[FFT_SIZE - i] = -s.side_imag[i];
    }
}

// Update stem level meters
static void update_meters(SeparatorState& s) {
    int half = FFT_SIZE / 2;
    float vocals = 0.0f, bass = 0.0f, drums = 0.0f, other = 0.0f;

    for (int i = 0; i < half; i++) {
        float mid_mag = get_magnitude(s.mid_real[i], s.mid_imag[i]);
        float side_mag = get_magnitude(s.side_real[i], s.side_imag[i]);

        if (i < BASS_CUTOFF_BIN) {
            bass += mid_mag + side_mag;
        } else if (i >= VOCAL_LOW_BIN && i <= VOCAL_HIGH_BIN) {
            vocals += mid_mag;
            other += side_mag;
        } else {
            other += mid_mag + side_mag;
        }

        // Transients for drums
        float flux_l = std::max(0.0f, get_magnitude(s.fft_real_l[i], s.fft_imag_l[i]) - s.prev_mag_l[i]);
        drums += flux_l;
    }

    // Normalize and smooth
    float norm = 1.0f / half;
    s.meter_vocals = s.meter_vocals * 0.9f + vocals * norm * 0.1f;
    s.meter_bass = s.meter_bass * 0.9f + bass * norm * 0.1f;
    s.meter_drums = s.meter_drums * 0.9f + drums * norm * 2.0f * 0.1f;
    s.meter_other = s.meter_other * 0.9f + other * norm * 0.1f;
}

// ============================================================================
// Main Processing
// ============================================================================

static void process_frame(SeparatorState& s) {
    // Apply window and FFT to left channel
    for (int i = 0; i < FFT_SIZE; i++) {
        s.fft_real_l[i] = s.input_buffer_left[i] * s.window[i];
        s.fft_imag_l[i] = 0.0f;
    }
    fft_forward(s.fft_real_l, s.fft_imag_l, FFT_SIZE);

    // Apply window and FFT to right channel
    for (int i = 0; i < FFT_SIZE; i++) {
        s.fft_real_r[i] = s.input_buffer_right[i] * s.window[i];
        s.fft_imag_r[i] = 0.0f;
    }
    fft_forward(s.fft_real_r, s.fft_imag_r, FFT_SIZE);

    // Convert to Mid/Side
    stereo_to_ms(s.fft_real_l, s.fft_imag_l, s.fft_real_r, s.fft_imag_r,
                 s.mid_real, s.mid_imag, s.side_real, s.side_imag, FFT_SIZE);

    // Apply separation based on mode
    switch (s.mode) {
        case SEPARATOR_MODE_KARAOKE:
        case SEPARATOR_MODE_INSTRUMENTAL:
            apply_karaoke(s);
            break;

        case SEPARATOR_MODE_VOCALS_ONLY:
            apply_vocals_only(s);
            break;

        case SEPARATOR_MODE_BASS_BOOST:
            apply_bass_boost(s, 6.0f);  // +6dB bass boost
            break;

        case SEPARATOR_MODE_DRUMS_EMPHASIS:
            apply_drums_emphasis(s, 0.5f);
            // Convert M/S back to L/R for drums processing
            ms_to_stereo(s.mid_real, s.mid_imag, s.side_real, s.side_imag,
                        s.fft_real_l, s.fft_imag_l, s.fft_real_r, s.fft_imag_r, FFT_SIZE);
            // Skip the M/S to stereo below
            goto inverse_fft;

        case SEPARATOR_MODE_CUSTOM:
            apply_custom_mix(s);
            break;

        default:
            // Normal mode: pass through
            break;
    }

    // Update meters
    update_meters(s);

    // Convert back to stereo
    ms_to_stereo(s.mid_real, s.mid_imag, s.side_real, s.side_imag,
                 s.fft_real_l, s.fft_imag_l, s.fft_real_r, s.fft_imag_r, FFT_SIZE);

inverse_fft:
    // Inverse FFT
    fft_inverse(s.fft_real_l, s.fft_imag_l, FFT_SIZE);
    fft_inverse(s.fft_real_r, s.fft_imag_r, FFT_SIZE);

    // Apply window, overlap-add, and normalize 75% Hann overlap (sum(w^2) = 1.5 => scale = 2/3)
    constexpr float norm_scale = 2.0f / 3.0f;
    for (int i = 0; i < FFT_SIZE; i++) {
        s.output_buffer_left[i] += s.fft_real_l[i] * s.window[i] * norm_scale;
        s.output_buffer_right[i] += s.fft_real_r[i] * s.window[i] * norm_scale;
    }
}

// ============================================================================
// Public API
// ============================================================================

int separator_init(int sample_rate) {
    memset(&g_separator, 0, sizeof(g_separator));

    g_separator.sample_rate = sample_rate;
    g_separator.enabled = false;
    g_separator.mode = SEPARATOR_MODE_NORMAL;

    g_separator.vocal_removal_strength = 0.8f;
    g_separator.center_width = 0.3f;
    g_separator.vocal_level = 1.0f;
    g_separator.bass_level = 1.0f;
    g_separator.drums_level = 1.0f;
    g_separator.other_level = 1.0f;

    create_hann_window(g_separator.window, FFT_SIZE);

    g_separator.initialized = true;
    return 0;
}

void separator_release(void) {
    g_separator.initialized = false;
}

void separator_enable(bool enabled) {
    g_separator.enabled = enabled;
}

bool separator_is_enabled(void) {
    return g_separator.enabled;
}

void separator_set_mode(SeparatorMode mode) {
    g_separator.mode = mode;
}

SeparatorMode separator_get_mode(void) {
    return g_separator.mode;
}

void separator_set_vocal_removal_strength(float strength) {
    g_separator.vocal_removal_strength = std::max(0.0f, std::min(1.0f, strength));
}

void separator_set_center_width(float width) {
    g_separator.center_width = std::max(0.0f, std::min(1.0f, width));
}

void separator_set_stem_levels(float vocals, float bass, float drums, float other) {
    g_separator.vocal_level = std::max(0.0f, std::min(2.0f, vocals));
    g_separator.bass_level = std::max(0.0f, std::min(2.0f, bass));
    g_separator.drums_level = std::max(0.0f, std::min(2.0f, drums));
    g_separator.other_level = std::max(0.0f, std::min(2.0f, other));
}

void separator_process(float* left, float* right, int num_frames) {
    if (!g_separator.initialized || !g_separator.enabled) return;
    if (num_frames <= 0 || left == nullptr || right == nullptr) return;
    if (g_separator.mode == SEPARATOR_MODE_NORMAL) return;

    SeparatorState& s = g_separator;

    for (int n = 0; n < num_frames; n++) {
        s.input_buffer_left[s.buffer_pos] = left[n];
        s.input_buffer_right[s.buffer_pos] = right[n];

        float proc_l = s.output_buffer_left[s.buffer_pos];
        float proc_r = s.output_buffer_right[s.buffer_pos];

        s.output_buffer_left[s.buffer_pos] = 0.0f;
        s.output_buffer_right[s.buffer_pos] = 0.0f;

        s.buffer_pos++;

        if (s.buffer_pos >= FFT_SIZE) {
            process_frame(s);

            memmove(s.input_buffer_left, s.input_buffer_left + HOP_SIZE,
                    (FFT_SIZE - HOP_SIZE) * sizeof(float));
            memmove(s.input_buffer_right, s.input_buffer_right + HOP_SIZE,
                    (FFT_SIZE - HOP_SIZE) * sizeof(float));

            memmove(s.output_buffer_left, s.output_buffer_left + HOP_SIZE,
                    (FFT_SIZE - HOP_SIZE) * sizeof(float));
            memmove(s.output_buffer_right, s.output_buffer_right + HOP_SIZE,
                    (FFT_SIZE - HOP_SIZE) * sizeof(float));

            memset(s.output_buffer_left + (FFT_SIZE - HOP_SIZE), 0, HOP_SIZE * sizeof(float));
            memset(s.output_buffer_right + (FFT_SIZE - HOP_SIZE), 0, HOP_SIZE * sizeof(float));

            s.buffer_pos = FFT_SIZE - HOP_SIZE;
            s.has_valid_output = true;
        }

        if (s.has_valid_output) {
            left[n] = proc_l;
            right[n] = proc_r;
        }
    }
}

void separator_get_stem_levels(float* vocals, float* bass, float* drums, float* other) {
    if (vocals) *vocals = g_separator.meter_vocals;
    if (bass) *bass = g_separator.meter_bass;
    if (drums) *drums = g_separator.meter_drums;
    if (other) *other = g_separator.meter_other;
}
