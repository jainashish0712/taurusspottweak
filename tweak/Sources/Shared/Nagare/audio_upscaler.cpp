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
 * Audio Upscaler Implementation
 *
 * Implements spectral enhancement for compressed audio using:
 * - Spectral Band Replication (SBR): Copies/modulates low frequencies to high
 * - Harmonic Extension: Adds natural overtones to enhance presence
 * - Transient Enhancement: Sharpens attack transients
 *
 * Based on psychoacoustic principles similar to HE-AAC SBR and Sony DSEE.
 */

#include "audio_upscaler.h"
#include <cmath>
#include <cstring>
#include <algorithm>

// ============================================================================
// Constants
// ============================================================================

static constexpr int MAX_FFT_SIZE = 2048;
static constexpr int FFT_SIZE = 1024;
static constexpr int HOP_SIZE = FFT_SIZE / 4;  // 75% overlap
static constexpr int NUM_BANDS = 32;

static constexpr float PI = 3.14159265358979323846f;
static constexpr float TWO_PI = 2.0f * PI;

// ============================================================================
// Upscaler State
// ============================================================================

struct UpscalerState {
    bool initialized;
    bool enabled;
    int sample_rate;
    float intensity;
    float sbr_cutoff;
    float harmonic_amount;
    bool transient_enabled;
    int detected_quality;

    // FFT buffers
    float window[FFT_SIZE];
    float fft_real[MAX_FFT_SIZE];
    float fft_imag[MAX_FFT_SIZE];

    // STFT overlap buffers - sized for overlap-add
    float input_left[FFT_SIZE];
    float input_right[FFT_SIZE];
    float output_left[FFT_SIZE];   // Output accumulator for overlap-add
    float output_right[FFT_SIZE];
    int input_pos;                  // Position in input buffer (0 to HOP_SIZE-1)
    int output_read_pos;            // How many samples we've output from current frame

    // Spectral analysis
    float band_energy[NUM_BANDS];
    float prev_band_energy[NUM_BANDS];

    // Transient detection
    float prev_energy;

    // Startup tracking - no blending until first FFT frame completes
    bool has_valid_output;
};

static UpscalerState g_upscaler;

// ============================================================================
// Helper Functions
// ============================================================================

// Simple in-place FFT (Cooley-Tukey radix-2 DIT)
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

// Inverse FFT
static void fft_inverse(float* real, float* imag, int n) {
    // Conjugate
    for (int i = 0; i < n; i++) {
        imag[i] = -imag[i];
    }

    fft_forward(real, imag, n);

    // Conjugate and scale
    float scale = 1.0f / n;
    for (int i = 0; i < n; i++) {
        real[i] *= scale;
        imag[i] = -imag[i] * scale;
    }
}

// Hann window
static void create_hann_window(float* window, int size) {
    for (int i = 0; i < size; i++) {
        window[i] = 0.5f * (1.0f - cosf(TWO_PI * i / (size - 1)));
    }
}

// Get magnitude from complex
static inline float get_magnitude(float real, float imag) {
    return sqrtf(real * real + imag * imag);
}

// Get phase from complex
static inline float get_phase(float real, float imag) {
    return atan2f(imag, real);
}

// ============================================================================
// Spectral Band Replication
// ============================================================================

// Detect the cutoff frequency where HF content is missing
static float detect_sbr_cutoff(float* magnitudes, int num_bins, int sample_rate) {
    float bin_freq = (float)sample_rate / FFT_SIZE;
    int max_bin = num_bins / 2;

    // Find where energy drops significantly (likely compression cutoff)
    float total_energy = 0.0f;
    for (int i = 0; i < max_bin; i++) {
        total_energy += magnitudes[i];
    }

    if (total_energy < 0.001f) return (float)sample_rate / 2;

    // Look for the frequency where energy drops below threshold
    float avg_energy = total_energy / max_bin;
    float threshold = avg_energy * 0.1f;  // 10% of average

    int cutoff_bin = max_bin;
    int consecutive_low = 0;

    for (int i = max_bin / 2; i < max_bin; i++) {
        if (magnitudes[i] < threshold) {
            consecutive_low++;
            if (consecutive_low > 5) {
                cutoff_bin = i - 5;
                break;
            }
        } else {
            consecutive_low = 0;
        }
    }

    return cutoff_bin * bin_freq;
}

// Apply spectral band replication
static void apply_sbr(float* real, float* imag, int num_bins, float cutoff_freq,
                      int sample_rate, float intensity) {
    float bin_freq = (float)sample_rate / FFT_SIZE;
    int cutoff_bin = (int)(cutoff_freq / bin_freq);
    int max_bin = num_bins / 2;

    if (cutoff_bin >= max_bin - 10) return;  // Nothing to replicate

    // Source range: frequencies below cutoff
    int source_start = cutoff_bin / 2;
    int source_end = cutoff_bin;
    int source_width = source_end - source_start;

    if (source_width < 4) return;

    // Replicate to fill frequencies above cutoff
    for (int i = cutoff_bin; i < max_bin; i++) {
        // Map target bin to source bin
        int offset = i - cutoff_bin;
        int source_idx = source_start + (offset % source_width);

        // Get source magnitude and phase
        float src_mag = get_magnitude(real[source_idx], imag[source_idx]);
        float src_phase = get_phase(real[source_idx], imag[source_idx]);

        // Apply frequency-dependent attenuation
        // Higher frequencies get attenuated more (natural rolloff)
        float freq_ratio = (float)i / max_bin;
        float attenuation = 1.0f - freq_ratio * 0.7f;  // -7dB at Nyquist
        attenuation *= attenuation;  // Squared for steeper rolloff

        // Modulate phase slightly to avoid pure harmonicity
        float phase_mod = src_phase + (float)i * 0.1f;

        // Calculate new components
        float new_mag = src_mag * attenuation * intensity * 0.5f;

        // Add to existing (don't replace)
        real[i] += new_mag * cosf(phase_mod);
        imag[i] += new_mag * sinf(phase_mod);
    }

    // Mirror for negative frequencies
    for (int i = 1; i < max_bin; i++) {
        real[num_bins - i] = real[i];
        imag[num_bins - i] = -imag[i];
    }
}

// ============================================================================
// Harmonic Extension
// ============================================================================

static void apply_harmonic_extension(float* real, float* imag, int num_bins,
                                     float amount, int sample_rate) {
    if (amount < 0.01f) return;

    float bin_freq = (float)sample_rate / FFT_SIZE;
    int max_bin = num_bins / 2;

    // Find prominent frequencies and add their harmonics
    float magnitudes[MAX_FFT_SIZE / 2];
    for (int i = 0; i < max_bin; i++) {
        magnitudes[i] = get_magnitude(real[i], imag[i]);
    }

    // Find spectral peaks
    for (int i = 2; i < max_bin / 4; i++) {
        if (magnitudes[i] > magnitudes[i-1] &&
            magnitudes[i] > magnitudes[i+1] &&
            magnitudes[i] > magnitudes[i-2] * 1.5f) {

            float peak_mag = magnitudes[i];
            float peak_phase = get_phase(real[i], imag[i]);

            // Add 2nd and 3rd harmonics
            for (int h = 2; h <= 3; h++) {
                int harm_bin = i * h;
                if (harm_bin < max_bin) {
                    // Harmonic amplitude decreases with order
                    float harm_mag = peak_mag * amount / (h * h);
                    float harm_phase = peak_phase * h;  // Phase follows fundamental

                    // Only add if harmonic is quieter than fundamental
                    if (magnitudes[harm_bin] < harm_mag * 2) {
                        real[harm_bin] += harm_mag * cosf(harm_phase);
                        imag[harm_bin] += harm_mag * sinf(harm_phase);
                    }
                }
            }
        }
    }
}

// ============================================================================
// Transient Enhancement
// ============================================================================

static float detect_transient(float* samples, int num_samples) {
    // Simple energy-based transient detection
    float energy = 0.0f;
    for (int i = 0; i < num_samples; i++) {
        energy += samples[i] * samples[i];
    }
    energy /= num_samples;

    float diff = energy - g_upscaler.prev_energy;
    g_upscaler.prev_energy = energy * 0.9f + g_upscaler.prev_energy * 0.1f;

    // Transient if energy increased significantly
    if (diff > g_upscaler.prev_energy * 0.5f && energy > 0.001f) {
        return std::min(diff / (g_upscaler.prev_energy + 0.001f), 3.0f);
    }

    return 0.0f;
}

static void apply_transient_enhancement(float* real, float* imag, int num_bins,
                                        float transient_strength) {
    if (transient_strength < 0.1f) return;

    int max_bin = num_bins / 2;

    // Enhance high frequencies during transients
    // This sharpens the attack
    float enhancement = 1.0f + transient_strength * 0.3f;

    int start_bin = max_bin / 4;  // Start from ~5kHz
    for (int i = start_bin; i < max_bin; i++) {
        float freq_factor = (float)(i - start_bin) / (max_bin - start_bin);
        float gain = 1.0f + (enhancement - 1.0f) * freq_factor;
        real[i] *= gain;
        imag[i] *= gain;
    }
}

// ============================================================================
// Quality Detection
// ============================================================================

static int analyze_audio_quality(float* magnitudes, int num_bins, int sample_rate) {
    float bin_freq = (float)sample_rate / FFT_SIZE;
    int max_bin = num_bins / 2;

    // Measure energy in different bands
    float low_energy = 0.0f;    // 0-4kHz
    float mid_energy = 0.0f;    // 4-10kHz
    float high_energy = 0.0f;   // 10kHz+

    int low_end = (int)(4000.0f / bin_freq);
    int mid_end = (int)(10000.0f / bin_freq);

    for (int i = 1; i < max_bin; i++) {
        if (i < low_end) {
            low_energy += magnitudes[i];
        } else if (i < mid_end) {
            mid_energy += magnitudes[i];
        } else {
            high_energy += magnitudes[i];
        }
    }

    // Normalize
    if (low_end > 0) low_energy /= low_end;
    if (mid_end > low_end) mid_energy /= (mid_end - low_end);
    if (max_bin > mid_end) high_energy /= (max_bin - mid_end);

    // Quality score based on HF content relative to LF
    if (low_energy < 0.001f) return 1;  // Silent or very quiet

    float hf_ratio = (high_energy + 0.0001f) / (low_energy + 0.0001f);
    float mf_ratio = (mid_energy + 0.0001f) / (low_energy + 0.0001f);

    // Good quality audio has more consistent energy across spectrum
    if (hf_ratio > 0.15f && mf_ratio > 0.3f) {
        return 2;  // High quality (lossless)
    } else if (hf_ratio > 0.05f && mf_ratio > 0.15f) {
        return 1;  // Medium quality (320kbps MP3)
    } else {
        return 0;  // Low quality (needs upscaling)
    }
}

// ============================================================================
// Public API
// ============================================================================

int upscaler_init(int sample_rate) {
    memset(&g_upscaler, 0, sizeof(g_upscaler));

    g_upscaler.sample_rate = sample_rate;
    g_upscaler.enabled = false;
    g_upscaler.intensity = 0.5f;
    g_upscaler.sbr_cutoff = -1.0f;  // Auto-detect
    g_upscaler.harmonic_amount = 0.3f;
    g_upscaler.transient_enabled = true;
    g_upscaler.detected_quality = 1;
    g_upscaler.input_pos = 0;
    g_upscaler.output_read_pos = 0;
    g_upscaler.has_valid_output = false;

    create_hann_window(g_upscaler.window, FFT_SIZE);

    g_upscaler.initialized = true;
    return 0;
}

void upscaler_release(void) {
    g_upscaler.initialized = false;
}

void upscaler_enable(bool enabled) {
    g_upscaler.enabled = enabled;
}

bool upscaler_is_enabled(void) {
    return g_upscaler.enabled;
}

void upscaler_set_intensity(float intensity) {
    g_upscaler.intensity = std::max(0.0f, std::min(1.0f, intensity));
}

void upscaler_set_sbr_cutoff(float frequency) {
    g_upscaler.sbr_cutoff = frequency;
}

void upscaler_set_transient_enhancement(bool enabled) {
    g_upscaler.transient_enabled = enabled;
}

void upscaler_set_harmonic_extension(float amount) {
    g_upscaler.harmonic_amount = std::max(0.0f, std::min(1.0f, amount));
}

// Process one channel through STFT with spectral modifications
static void process_channel_stft(float* input_buf, float* output_buf,
                                  float* fft_real, float* fft_imag, float* window,
                                  int sample_rate, float sbr_cutoff,
                                  float intensity, float harmonic_amount,
                                  int* detected_quality) {
    // Apply analysis window
    for (int i = 0; i < FFT_SIZE; i++) {
        fft_real[i] = input_buf[i] * window[i];
        fft_imag[i] = 0.0f;
    }

    // Forward FFT
    fft_forward(fft_real, fft_imag, FFT_SIZE);

    // Get magnitudes for analysis
    float magnitudes[FFT_SIZE / 2];
    for (int i = 0; i < FFT_SIZE / 2; i++) {
        magnitudes[i] = get_magnitude(fft_real[i], fft_imag[i]);
    }

    // Detect audio quality
    *detected_quality = analyze_audio_quality(magnitudes, FFT_SIZE, sample_rate);

    // Detect SBR cutoff if not manually set
    float cutoff = sbr_cutoff;
    if (cutoff <= 0) {
        cutoff = detect_sbr_cutoff(magnitudes, FFT_SIZE, sample_rate);
    }

    // Apply spectral band replication - scaled by detected quality
    // Low quality: full intensity, Medium: 75%, High: 25% (subtle enhancement)
    float quality_scale = (*detected_quality == 0) ? 1.0f :
                          (*detected_quality == 1) ? 0.75f : 0.25f;
    apply_sbr(fft_real, fft_imag, FFT_SIZE, cutoff, sample_rate,
              intensity * quality_scale);

    // Apply harmonic extension - also scaled by quality
    float harmonic_scale = (*detected_quality == 0) ? 1.0f :
                           (*detected_quality == 1) ? 0.8f : 0.4f;
    apply_harmonic_extension(fft_real, fft_imag, FFT_SIZE,
                            harmonic_amount * intensity * harmonic_scale, sample_rate);

    // Inverse FFT
    fft_inverse(fft_real, fft_imag, FFT_SIZE);

    // Apply synthesis window and accumulate to output (overlap-add)
    // With Hann window and 75% overlap, the normalization is 1.0 (windows sum to unity)
    for (int i = 0; i < FFT_SIZE; i++) {
        output_buf[i] += fft_real[i] * window[i];
    }
}

void upscaler_process(float* left, float* right, int num_frames) {
    if (!g_upscaler.initialized || !g_upscaler.enabled) return;
    if (num_frames <= 0 || left == nullptr || right == nullptr) return;

    UpscalerState& s = g_upscaler;

    // Process in chunks that align with our hop size for efficiency
    // For each input sample, we output one processed sample
    for (int n = 0; n < num_frames; n++) {
        // Store input sample in circular buffer position
        s.input_left[s.input_pos] = left[n];
        s.input_right[s.input_pos] = right[n];

        // Get output sample from overlap buffer at same position
        // This gives us the sum of all overlapping frames at this position
        float proc_l = s.output_left[s.input_pos];
        float proc_r = s.output_right[s.input_pos];

        // Clear for next round of accumulation
        s.output_left[s.input_pos] = 0.0f;
        s.output_right[s.input_pos] = 0.0f;

        s.input_pos++;

        // When input buffer is full, process a frame and shift
        if (s.input_pos >= FFT_SIZE) {
            // Process left channel - output accumulates into output buffer
            process_channel_stft(s.input_left, s.output_left,
                               s.fft_real, s.fft_imag, s.window,
                               s.sample_rate, s.sbr_cutoff,
                               s.intensity, s.harmonic_amount,
                               &s.detected_quality);

            // Process right channel
            process_channel_stft(s.input_right, s.output_right,
                               s.fft_real, s.fft_imag, s.window,
                               s.sample_rate, s.sbr_cutoff,
                               s.intensity, s.harmonic_amount,
                               &s.detected_quality);

            // Shift both buffers by HOP_SIZE
            memmove(s.input_left, s.input_left + HOP_SIZE,
                   (FFT_SIZE - HOP_SIZE) * sizeof(float));
            memmove(s.input_right, s.input_right + HOP_SIZE,
                   (FFT_SIZE - HOP_SIZE) * sizeof(float));
            memmove(s.output_left, s.output_left + HOP_SIZE,
                   (FFT_SIZE - HOP_SIZE) * sizeof(float));
            memmove(s.output_right, s.output_right + HOP_SIZE,
                   (FFT_SIZE - HOP_SIZE) * sizeof(float));

            // Clear the end of output buffer (new accumulation region)
            memset(s.output_left + (FFT_SIZE - HOP_SIZE), 0, HOP_SIZE * sizeof(float));
            memset(s.output_right + (FFT_SIZE - HOP_SIZE), 0, HOP_SIZE * sizeof(float));

            s.input_pos = FFT_SIZE - HOP_SIZE;
            s.has_valid_output = true;
        }

        // Only blend after first FFT frame has been processed
        // (before that, output buffer is all zeros → volume drop)
        if (s.has_valid_output) {
            // Blend processed with original
            float blend = s.intensity * 0.6f;

            // Soft clip processed signal
            proc_l = std::max(-1.0f, std::min(1.0f, proc_l));
            proc_r = std::max(-1.0f, std::min(1.0f, proc_r));

            // Output blended result
            left[n] = left[n] * (1.0f - blend) + proc_l * blend;
            right[n] = right[n] * (1.0f - blend) + proc_r * blend;
        }
    }
}

int upscaler_get_detected_quality(void) {
    return g_upscaler.detected_quality;
}
