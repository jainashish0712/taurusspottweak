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
 * Nagare DSP - High-Performance Audio Processing Library
 *
 * Native C++ implementation with SIMD optimization (NEON/SSE)
 * for maximum performance on mobile devices.
 *
 * Copyright (c) 2025 Nagare
 */

#ifndef NAGARE_DSP_H
#define NAGARE_DSP_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Library Initialization
// ============================================================================

/**
 * Initialize the DSP engine
 * @param sample_rate Audio sample rate (e.g., 44100, 48000)
 * @param channels Number of channels (1 = mono, 2 = stereo)
 * @param buffer_size Processing buffer size in samples
 * @return 0 on success, negative on error
 */
int nagare_init(int sample_rate, int channels, int buffer_size);

/**
 * Release all DSP resources
 */
void nagare_release(void);

/**
 * Get the DSP engine version string
 */
const char* nagare_version(void);

/**
 * Check if SIMD (NEON/SSE) is available
 */
bool nagare_has_simd(void);

// ============================================================================
// Main Processing
// ============================================================================

/**
 * Process audio samples through the entire DSP chain
 * @param input Input samples (interleaved stereo: L0,R0,L1,R1,...)
 * @param output Output samples (same format)
 * @param num_samples Number of samples per channel
 */
void nagare_process(const float* input, float* output, int num_samples);

/**
 * Process audio in-place
 * @param samples Audio samples (interleaved stereo)
 * @param num_samples Number of samples per channel
 */
void nagare_process_inplace(float* samples, int num_samples);

// ============================================================================
// Equalizer (10-band parametric)
// ============================================================================

/**
 * Enable/disable the equalizer
 */
void nagare_eq_enable(bool enabled);

/**
 * Set EQ band gain
 * @param band Band index (0-9)
 * @param gain_db Gain in decibels (-12 to +12)
 */
void nagare_eq_set_band(int band, float gain_db);

/**
 * Set all EQ bands at once
 * @param gains Array of 10 gain values in dB
 */
void nagare_eq_set_bands(const float* gains);

/**
 * Set all EQ band gains with smooth 50ms ramping (for dynamic EQ during playback)
 * @param gains Array of 10 gain values in decibels
 */
void nagare_eq_set_bands_smooth(const float* gains);

/**
 * Set EQ band parameters (for parametric EQ)
 * @param band Band index
 * @param freq Center frequency in Hz
 * @param gain_db Gain in decibels
 * @param q Q factor (bandwidth)
 */
void nagare_eq_set_band_params(int band, float freq, float gain_db, float q);

/** EQ band filter types, matching AutoEQ's ParametricEQ.txt notation. */
#define NAGARE_EQ_PEAKING     0   /* PK  */
#define NAGARE_EQ_LOW_SHELF   1   /* LSC */
#define NAGARE_EQ_HIGH_SHELF  2   /* HSC */

/**
 * Configure one EQ band completely: filter type, centre frequency, gain, Q.
 *
 * Headphone correction profiles are not peaking-only. A typical AutoEQ profile
 * opens with a low shelf and closes with a high shelf — for the Sony WH-1000XM5,
 * a -3.2 dB low shelf at 105 Hz and a +4.9 dB high shelf at 10 kHz. Rendering
 * those as peaking filters leaves the extremes of the response uncorrected,
 * because a shelf acts on everything beyond its corner while a peak does not.
 *
 * @param type one of NAGARE_EQ_PEAKING / NAGARE_EQ_LOW_SHELF / NAGARE_EQ_HIGH_SHELF
 */
void nagare_eq_set_band_full(int band, float freq, float gain_db, float q, int type);

/// Listener-preference tilt, in dB, applied after headphone correction.
///
/// Olive, Welti & McMullin (AES 134, paper 8867) segmented listener preference
/// into three classes rather than one target: roughly 64% preferred the Harman
/// curve, 15% wanted considerably more bass, 21% wanted less. Both ends move
/// together in their data, so treble is set alongside bass.
///
/// Kept separate from the ten correction bands: correction removes a measured
/// error, this expresses a taste on top of it, and neither should consume the
/// other's filter slots. Both values are clamped to +/-6 dB.
void nagare_set_preference_tilt(float bass_db, float treble_db);

/// Output high-pass corner in Hz; 0 disables it.
///
/// Set from the current output device. A phone speaker radiates almost nothing
/// below ~300 Hz but the amplifier still drives it, turning that energy into
/// excursion, intermodulation distortion and lost headroom rather than sound.
/// Removing it makes the audible range cleaner and louder. Left off for
/// headphones and line outputs, which reproduce the bottom octaves properly.
void nagare_set_output_highpass(float freq_hz);

/// Loudness-normalisation gain in dB, derived from a track's measured BS.1770
/// integrated loudness. Clamped to +/-12 dB and smoothed over ~20 ms; pass
/// snap=1 when starting playback so it takes effect immediately rather than
/// fading in. Applied after all effects and before the limiter.
void nagare_set_normalization_gain(float gain_db, int snap);

/**
 * Restore the default 10-band graphic layout: fixed ISO centre frequencies,
 * Q = 1.0, all gains flat. Call this when parametric use (headphone
 * correction) ends so the manual EQ behaves as a normal graphic EQ again.
 */
void nagare_eq_reset_band_layout(void);

// ============================================================================
// Dynamic Processing
// ============================================================================

/**
 * Enable/disable the compressor
 */
void nagare_compressor_enable(bool enabled);

/**
 * Set compressor parameters
 * @param threshold Threshold in dB (e.g., -20)
 * @param ratio Compression ratio (e.g., 4.0 for 4:1)
 * @param attack Attack time in ms
 * @param release Release time in ms
 * @param makeup_gain Makeup gain in dB
 */
void nagare_compressor_set(float threshold, float ratio, float attack, float release, float makeup_gain);

/**
 * Enable/disable the limiter
 */
void nagare_limiter_enable(bool enabled);

/**
 * Set limiter parameters
 * @param ceiling Maximum output level (e.g., -0.3 dB)
 * @param release Release time in ms
 */
void nagare_limiter_set(float ceiling, float release);

/**
 * V9 — true chain bypass. When enabled, process() runs only the
 * load-bearing pre/post stages: 20 Hz subsonic HPF → DC blocker → limiter.
 * Effects, input attenuation, per-song pregain, and loudness compensation
 * are all skipped. The "Pure" preset uses this so it's a real reference
 * rather than effects-with-zero-amount. Other presets must clear it.
 */
void nagare_chain_bypass(bool enabled);

// ============================================================================
// Spatial Audio
// ============================================================================

/**
 * Enable/disable stereo widener
 */
void nagare_stereo_width_enable(bool enabled);

/**
 * Set stereo width
 * @param width Width factor (0.0 = mono, 1.0 = normal, 2.0 = extra wide)
 */
void nagare_stereo_width_set(float width);

/**
 * Enable/disable crossfeed (for headphones)
 */
void nagare_crossfeed_enable(bool enabled);

/**
 * Set crossfeed amount
 * @param amount Crossfeed amount (0.0 to 1.0)
 */
void nagare_crossfeed_set(float amount);

// ============================================================================
// Bass Enhancement
// ============================================================================

/**
 * Enable/disable virtual bass (psychoacoustic bass enhancement)
 */
void nagare_virtual_bass_enable(bool enabled);

/**
 * Set virtual bass parameters
 * @param amount Enhancement amount (0.0 to 1.0)
 * @param frequency Cutoff frequency for bass detection (default 120 Hz)
 */
void nagare_virtual_bass_set(float amount, float frequency);

/**
 * Set virtual bass amount with smooth ramping (50ms) for real-time adaptation
 * @param amount Enhancement amount (0.0 to 1.0)
 */
void nagare_virtual_bass_set_smooth(float amount);

/**
 * Enable/disable sub-harmonic synthesizer
 */
void nagare_subharmonic_enable(bool enabled);

/**
 * Set sub-harmonic amount
 * @param amount Sub-harmonic level (0.0 to 1.0)
 */
void nagare_subharmonic_set(float amount);

// ============================================================================
// Harmonic Enhancement
// ============================================================================

/**
 * Enable/disable tube warmth (harmonic saturation)
 */
void nagare_tube_warmth_enable(bool enabled);

/**
 * Set tube warmth parameters
 * @param amount Warmth amount (0.0 to 1.0)
 * @param drive Drive/saturation level (0.0 to 1.0)
 */
void nagare_tube_warmth_set(float amount, float drive);

/**
 * Enable/disable exciter (high-frequency enhancement)
 */
void nagare_exciter_enable(bool enabled);

/**
 * Set exciter parameters
 * @param amount Exciter amount (0.0 to 1.0)
 * @param frequency Cutoff frequency (default 4000 Hz)
 */
void nagare_exciter_set(float amount, float frequency);

/**
 * Set exciter amount with smooth ramping (50ms) for real-time adaptation
 * @param amount Exciter amount (0.0 to 1.0)
 */
void nagare_exciter_set_smooth(float amount);

/**
 * Enable/disable air band (ultra-high frequency boost)
 */
void nagare_air_band_enable(bool enabled);

/**
 * Set air band amount
 * @param amount Air band amount (0.0 to 1.0)
 */
void nagare_air_band_set(float amount);

// ============================================================================
// Loudness Compensation (Fletcher-Munson / ISO 226) — V8.3
// ============================================================================
// The ear's frequency response flattens with level. At quiet listening (below
// the 80 dB SPL mixing reference) the spectrum sounds bass- and treble-light.
// This engine applies a low-shelf + high-shelf bump that scales with `amount`
// to undo the shift. Drive `amount` from 1 - normalized_volume so quieter
// playback gets more compensation. amount ∈ [0, 1].

void nagare_loudness_comp_enable(bool enabled);
void nagare_loudness_comp_set(float amount);

// V8.5: per-band balance lets a song profile shape the curve — pass low_factor
// < 1.0 for bass-heavy material, high_factor < 1.0 for bright material so we
// don't pile on what's already there. Both default to 1.0 (nominal curve).
void nagare_loudness_comp_set_balance(float low_factor, float high_factor);

// V8.5: per-song pre-attenuation. AI Tune drives this from
// `SongAudioProfile.outputGainReduction` (typically -1.5 dB for tracks at
// `truePeak > 0.995` or `LUFS > -8`). Always 0 or negative.
void nagare_per_song_pregain_set(float db);

// ============================================================================
// V8.7 — Transient Shaper
// ============================================================================
// Detects attack transients via dual envelope followers (3 ms vs 100 ms
// attack). Attack/sustain ∈ [-1, 1]: positive = enhance, negative = soften.
// Bypassed when both at 0.
void nagare_transient_shaper_enable(bool enabled);
void nagare_transient_shaper_set(float attack, float sustain);

// ============================================================================
// Reverb
// ============================================================================

/**
 * Enable/disable reverb
 */
void nagare_reverb_enable(bool enabled);

/**
 * Set reverb parameters
 * @param room_size Room size (0.0 to 1.0)
 * @param damping High frequency damping (0.0 to 1.0)
 * @param wet_level Wet signal level (0.0 to 1.0)
 * @param dry_level Dry signal level (0.0 to 1.0)
 * @param width Stereo width (0.0 to 1.0)
 */
void nagare_reverb_set(float room_size, float damping, float wet_level, float dry_level, float width);

// ============================================================================
// FFT Analysis (for visualizers)
// ============================================================================

/**
 * Get FFT magnitude spectrum
 * @param output Output array for magnitudes (size = fft_size/2)
 * @param fft_size FFT size (must be power of 2, e.g., 2048)
 * @return Number of bins written
 */
int nagare_get_fft(float* output, int fft_size);

/**
 * Get frequency bands (for visualizer)
 * @param bands Output array for band levels
 * @param num_bands Number of bands to compute
 */
void nagare_get_bands(float* bands, int num_bands);

// ============================================================================
// Audio Analysis
// ============================================================================

/**
 * Get current audio levels
 * @param left_db Left channel level in dB
 * @param right_db Right channel level in dB
 */
void nagare_get_levels(float* left_db, float* right_db);

/**
 * Get peak levels (with hold)
 * @param left_db Left channel peak in dB
 * @param right_db Right channel peak in dB
 */
void nagare_get_peaks(float* left_db, float* right_db);

/**
 * Reset peak meters
 */
void nagare_reset_peaks(void);

// ============================================================================
// Smart Enhance (One-touch optimization)
// ============================================================================

/**
 * Enable/disable Smart Enhance
 * Applies a carefully tuned combination of all effects
 */
void nagare_smart_enhance_enable(bool enabled);

/**
 * Set Smart Enhance intensity
 * @param intensity 0.0 = subtle, 1.0 = maximum
 */
void nagare_smart_enhance_set_intensity(float intensity);

// ============================================================================
// Device-Aware Profiles (V3)
// ============================================================================

/**
 * Apply a device-specific audio profile.
 * Different output devices need different processing:
 *
 * @param profile_id Profile ID:
 *   0 = HEADPHONES_WIRED   - Full processing, crossfeed beneficial
 *   1 = HEADPHONES_BLUETOOTH - Conservative for codec compatibility
 *   2 = SPEAKER_PHONE      - Virtual bass harmonics, no crossfeed
 *   3 = SPEAKER_EXTERNAL   - Full range, room acoustics
 *   4 = USB_DAC            - Minimal processing (audiophile)
 *   5 = DEFAULT            - Conservative fallback
 */
void nagare_apply_device_profile(int profile_id);

/**
 * Disable all processing for true bypass.
 * Audio passes through completely unmodified.
 */
void nagare_disable_all(void);

// ============================================================================
// Preset System — REMOVED in V9
// ============================================================================
// Previously declared nagare_load_preset / nagare_get_settings_json /
// nagare_apply_settings_json. Their C++ bodies were stubs (`return false;`
// and `return 0;`) — no JSON encoder/decoder, no preset table. Presets are
// handled in Dart (`audio_presets.dart`), which calls the individual
// effect setters. The native preset API never had a real implementation,
// so it was deleted rather than left as a confusing placeholder.

// ============================================================================
// Debug Info
// ============================================================================

/**
 * Get gain debug info from the last process() call
 * @param output Float array of at least 7 values:
 *   [0] attenuation_db - actual attenuation applied (negative or 0)
 *   [1] cumulative_gain_db - estimated total gain
 *   [2] low_band_db - bass effect gain estimate
 *   [3] mid_band_db - mid effect gain estimate
 *   [4] high_band_db - high effect gain estimate
 *   [5] eq_peak_db - highest EQ boost
 *   [6] active_effects - number of enabled effects
 * @param max_values Size of output array (must be >= 7)
 */
void nagare_get_gain_debug(float* output, int max_values);

#ifdef __cplusplus
}
#endif

#endif // NAGARE_DSP_H
