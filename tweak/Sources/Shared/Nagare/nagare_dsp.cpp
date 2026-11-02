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
 * Version 3.0 - 64-bit intermediate processing for precision
 * Version 2.0 - Fixed virtual bass, subharmonic, and gain staging
 *
 * Copyright (c) 2025 Nagare
 */

#include "nagare_dsp.h"
#include <cmath>
#include <cstring>
#include <algorithm>
#include <vector>
#include <complex>
#include <memory>

// A/B comparison switch. 0 = shipping behaviour. Build with
// -DNAGARE_AB_ORIGINAL=1 to reproduce the pre-audit DSP (crossfeed without
// the interaural delay) for listening comparisons. Ships as 0.
#ifndef NAGARE_AB_ORIGINAL
#define NAGARE_AB_ORIGINAL 0
#endif

// SIMD headers
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
    #include <arm_neon.h>
    #define USE_NEON 1
#elif defined(__SSE__) || defined(__SSE2__)
    #include <xmmintrin.h>
    #include <emmintrin.h>
    #define USE_SSE 1
#endif

namespace nagare {

// ============================================================================
// Denormal-flush helper — V8.1
// ============================================================================
// IIR filters can drift to subnormal floats (very small numbers near zero) when
// audio goes silent. On ARM/x86 those operands fall onto a slow microcode path
// — a 50× CPU spike per multiply — which causes audible glitches and battery
// drain. Setting FTZ (Flush-To-Zero) and DAZ (Denormals-Are-Zero) on the audio
// thread makes the FPU treat them as zero. Has to be set per-thread, not
// per-process, so we re-arm it at the top of every process() call. The cost
// is one register write; the savings are huge.
//
// Architecture notes:
//   - AArch64 (arm64-v8a): FPCR.FZ bit 24, accessed via MRS/MSR.
//   - AArch32 (armeabi-v7a): FPSCR.FZ bit 24, accessed via VMRS/VMSR — only
//     valid when the CPU has VFP/NEON (we require -mfpu=neon, so it does).
//   - x86/x86_64: MXCSR.FTZ bit 15 + .DAZ bit 6.
inline void enableDenormalFlushOnThisThread() {
#if defined(__aarch64__)
    uint64_t fpcr;
    asm volatile("mrs %0, fpcr" : "=r"(fpcr));
    fpcr |= (1ULL << 24);  // FZ
    asm volatile("msr fpcr, %0" : : "r"(fpcr));
#elif defined(__arm__) && (defined(__ARM_NEON) || defined(__VFP_FP__))
    uint32_t fpscr;
    asm volatile("vmrs %0, fpscr" : "=r"(fpscr));
    fpscr |= (1u << 24);  // FZ
    asm volatile("vmsr fpscr, %0" : : "r"(fpscr));
#elif defined(__SSE__) || defined(__SSE2__)
    unsigned int mxcsr = _mm_getcsr();
    mxcsr |= 0x8040;  // FTZ (bit 15) + DAZ (bit 6)
    _mm_setcsr(mxcsr);
#endif
}

// ============================================================================
// Constants
// ============================================================================

static constexpr float PI = 3.14159265358979323846f;
static constexpr float TWO_PI = 6.28318530717958647692f;
static constexpr int MAX_FFT_SIZE = 8192;
static constexpr int EQ_BANDS = 10;

// Q used by the 10-band graphic EQ. Bands keep this unless a caller overrides
// them through setEQBandParams (headphone correction does).
static constexpr float kDefaultEQQ = 1.0f;

// EQ band filter types, matching the three AutoEQ emits in ParametricEQ.txt:
// PK (peaking), LSC (low shelf), HSC (high shelf).
static constexpr int kEQTypePeaking   = 0;
static constexpr int kEQTypeLowShelf  = 1;
static constexpr int kEQTypeHighShelf = 2;

// Safe headroom to prevent inter-stage clipping
static constexpr float STAGE_HEADROOM = 0.95f;

// ============================================================================
// Utility Functions
// ============================================================================

inline float db_to_linear(float db) {
    return std::pow(10.0f, db / 20.0f);
}

inline float linear_to_db(float linear) {
    return 20.0f * std::log10(std::max(linear, 1e-10f));
}

// Double-precision versions for coefficient calculation (64-bit internal processing)
inline double db_to_linear_d(double db) {
    return std::pow(10.0, db / 20.0);
}

inline double linear_to_db_d(double linear) {
    return 20.0 * std::log10(std::max(linear, 1e-15));
}

inline float fast_tanh(float x) {
    // Approximation: tanh(x) ≈ x * (27 + x²) / (27 + 9x²)
    // Accurate to within 0.001 for |x| < 3
    float x2 = x * x;
    return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

inline float soft_clip(float x, float threshold = 0.9f) {
    if (x > threshold) {
        return threshold + (1.0f - threshold) * fast_tanh((x - threshold) / (1.0f - threshold));
    } else if (x < -threshold) {
        return -threshold - (1.0f - threshold) * fast_tanh((-x - threshold) / (1.0f - threshold));
    }
    return x;
}

// Soft saturation with even harmonics (tube-like)
inline float tube_saturate(float x, float drive) {
    // Asymmetric waveshaper for even harmonics
    float sign = (x >= 0) ? 1.0f : -1.0f;
    float abs_x = std::abs(x) * (1.0f + drive);
    // Soft knee saturation
    float saturated = abs_x / (1.0f + abs_x * 0.5f);
    // Add slight asymmetry for even harmonics
    return sign * saturated * (1.0f + 0.1f * x);
}

// ============================================================================
// Envelope Follower
// ============================================================================

class EnvelopeFollower {
public:
    void setParams(float attack_ms, float release_ms, float sample_rate) {
        // 64-bit coefficient calculation for precision
        attack_coeff = std::exp(-1.0 / (static_cast<double>(attack_ms) * 0.001 * sample_rate));
        release_coeff = std::exp(-1.0 / (static_cast<double>(release_ms) * 0.001 * sample_rate));
    }

    float process(float input) {
        double abs_input = std::abs(static_cast<double>(input));
        if (abs_input > envelope) {
            envelope = attack_coeff * envelope + (1.0 - attack_coeff) * abs_input;
        } else {
            envelope = release_coeff * envelope + (1.0 - release_coeff) * abs_input;
        }
        return static_cast<float>(envelope);
    }

    void reset() { envelope = 0; }
    float getEnvelope() const { return static_cast<float>(envelope); }

private:
    double envelope = 0;
    double attack_coeff = 0.9;
    double release_coeff = 0.9995;
};

// ============================================================================
// Biquad Filter (optimized)
// ============================================================================

// 64-bit precision coefficients — critical for cascaded EQ filter accuracy
struct BiquadCoeffs {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
};

// 64-bit state prevents precision loss through feedback loops
struct BiquadState {
    double x1 = 0, x2 = 0;  // Input history
    double y1 = 0, y2 = 0;  // Output history
};

class BiquadFilter {
public:
    // All coefficient calculations use double precision throughout
    void setLowShelf(float freq, float gain_db, float q, float sample_rate) {
        double A = std::pow(10.0, static_cast<double>(gain_db) / 40.0);
        double w0 = 6.283185307179586 * freq / sample_rate;
        double cos_w0 = std::cos(w0);
        double sin_w0 = std::sin(w0);
        double alpha = sin_w0 / (2.0 * q);
        double sqrtA = std::sqrt(A);

        double a0 = (A + 1) + (A - 1) * cos_w0 + 2 * sqrtA * alpha;
        coeffs.b0 = (A * ((A + 1) - (A - 1) * cos_w0 + 2 * sqrtA * alpha)) / a0;
        coeffs.b1 = (2 * A * ((A - 1) - (A + 1) * cos_w0)) / a0;
        coeffs.b2 = (A * ((A + 1) - (A - 1) * cos_w0 - 2 * sqrtA * alpha)) / a0;
        coeffs.a1 = (-2 * ((A - 1) + (A + 1) * cos_w0)) / a0;
        coeffs.a2 = ((A + 1) + (A - 1) * cos_w0 - 2 * sqrtA * alpha) / a0;
    }

    void setHighShelf(float freq, float gain_db, float q, float sample_rate) {
        double A = std::pow(10.0, static_cast<double>(gain_db) / 40.0);
        double w0 = 6.283185307179586 * freq / sample_rate;
        double cos_w0 = std::cos(w0);
        double sin_w0 = std::sin(w0);
        double alpha = sin_w0 / (2.0 * q);
        double sqrtA = std::sqrt(A);

        double a0 = (A + 1) - (A - 1) * cos_w0 + 2 * sqrtA * alpha;
        coeffs.b0 = (A * ((A + 1) + (A - 1) * cos_w0 + 2 * sqrtA * alpha)) / a0;
        coeffs.b1 = (-2 * A * ((A - 1) + (A + 1) * cos_w0)) / a0;
        coeffs.b2 = (A * ((A + 1) + (A - 1) * cos_w0 - 2 * sqrtA * alpha)) / a0;
        coeffs.a1 = (2 * ((A - 1) - (A + 1) * cos_w0)) / a0;
        coeffs.a2 = ((A + 1) - (A - 1) * cos_w0 - 2 * sqrtA * alpha) / a0;
    }

    void setPeaking(float freq, float gain_db, float q, float sample_rate) {
        double A = std::pow(10.0, static_cast<double>(gain_db) / 40.0);
        double w0 = 6.283185307179586 * freq / sample_rate;
        double cos_w0 = std::cos(w0);
        double sin_w0 = std::sin(w0);
        double alpha = sin_w0 / (2.0 * q);

        double a0 = 1.0 + alpha / A;
        coeffs.b0 = (1.0 + alpha * A) / a0;
        coeffs.b1 = (-2.0 * cos_w0) / a0;
        coeffs.b2 = (1.0 - alpha * A) / a0;
        coeffs.a1 = coeffs.b1;
        coeffs.a2 = (1.0 - alpha / A) / a0;
    }

    void setLowPass(float freq, float q, float sample_rate) {
        double w0 = 6.283185307179586 * freq / sample_rate;
        double cos_w0 = std::cos(w0);
        double sin_w0 = std::sin(w0);
        double alpha = sin_w0 / (2.0 * q);

        double a0 = 1.0 + alpha;
        coeffs.b0 = ((1.0 - cos_w0) / 2.0) / a0;
        coeffs.b1 = (1.0 - cos_w0) / a0;
        coeffs.b2 = coeffs.b0;
        coeffs.a1 = (-2.0 * cos_w0) / a0;
        coeffs.a2 = (1.0 - alpha) / a0;
    }

    void setHighPass(float freq, float q, float sample_rate) {
        double w0 = 6.283185307179586 * freq / sample_rate;
        double cos_w0 = std::cos(w0);
        double sin_w0 = std::sin(w0);
        double alpha = sin_w0 / (2.0 * q);

        double a0 = 1.0 + alpha;
        coeffs.b0 = ((1.0 + cos_w0) / 2.0) / a0;
        coeffs.b1 = (-(1.0 + cos_w0)) / a0;
        coeffs.b2 = coeffs.b0;
        coeffs.a1 = (-2.0 * cos_w0) / a0;
        coeffs.a2 = (1.0 - alpha) / a0;
    }

    void setBandPass(float freq, float q, float sample_rate) {
        double w0 = 6.283185307179586 * freq / sample_rate;
        double cos_w0 = std::cos(w0);
        double sin_w0 = std::sin(w0);
        double alpha = sin_w0 / (2.0 * q);

        double a0 = 1.0 + alpha;
        coeffs.b0 = alpha / a0;
        coeffs.b1 = 0;
        coeffs.b2 = -alpha / a0;
        coeffs.a1 = (-2.0 * cos_w0) / a0;
        coeffs.a2 = (1.0 - alpha) / a0;
    }

    // 64-bit internal processing with float I/O
    inline float process(float input) {
        double in = static_cast<double>(input);
        double output = coeffs.b0 * in + coeffs.b1 * state.x1 + coeffs.b2 * state.x2
                     - coeffs.a1 * state.y1 - coeffs.a2 * state.y2;

        // Denormal prevention
        if (std::abs(output) < 1e-30) output = 0;

        state.x2 = state.x1;
        state.x1 = in;
        state.y2 = state.y1;
        state.y1 = output;
        return static_cast<float>(output);
    }

    void reset() {
        state = BiquadState();
    }

private:
    BiquadCoeffs coeffs;
    BiquadState state;
};

// ============================================================================
// DC Blocker (removes DC offset from signal)
// ============================================================================

class DCBlocker {
public:
    void init(float sample_rate) {
        // 64-bit coefficient and state for feedback loop precision
        double cutoff_hz = 10.0;
        double w0 = 6.283185307179586 * cutoff_hz / sample_rate;
        coeff = (2.0 - w0) / (2.0 + w0);
    }

    float process(float input) {
        double in = static_cast<double>(input);
        double output = in - x1 + coeff * y1;
        x1 = in;
        y1 = output;
        return static_cast<float>(output);
    }

    void reset() {
        x1 = y1 = 0;
    }

private:
    double x1 = 0, y1 = 0;
    double coeff = 0.995;
};

// ============================================================================
// FFT (Cooley-Tukey, SIMD-optimized)
// ============================================================================

class FFT {
public:
    FFT(int size) : fft_size(size), log2n(0) {
        int n = size;
        while (n >>= 1) log2n++;

        // Pre-compute twiddle factors in double precision, store as float
        twiddles.resize(size / 2);
        for (int i = 0; i < size / 2; i++) {
            double angle = -6.283185307179586 * i / size;
            twiddles[i] = std::complex<float>(
                static_cast<float>(std::cos(angle)),
                static_cast<float>(std::sin(angle)));
        }

        // Pre-compute bit-reversal table
        bit_rev.resize(size);
        for (int i = 0; i < size; i++) {
            int rev = 0;
            for (int j = 0; j < log2n; j++) {
                rev |= ((i >> j) & 1) << (log2n - 1 - j);
            }
            bit_rev[i] = rev;
        }
    }

    void forward(const float* input, std::complex<float>* output) {
        // Bit-reversal permutation with windowing
        for (int i = 0; i < fft_size; i++) {
            float window = 0.5f * (1.0f - std::cos(TWO_PI * i / (fft_size - 1)));  // Hann window
            output[bit_rev[i]] = std::complex<float>(input[i] * window, 0);
        }

        // FFT butterflies
        for (int stage = 1; stage <= log2n; stage++) {
            int m = 1 << stage;
            int m2 = m >> 1;
            int step = fft_size / m;

            for (int k = 0; k < fft_size; k += m) {
                for (int j = 0; j < m2; j++) {
                    std::complex<float> t = twiddles[j * step] * output[k + j + m2];
                    output[k + j + m2] = output[k + j] - t;
                    output[k + j] = output[k + j] + t;
                }
            }
        }
    }

    void magnitude(const std::complex<float>* fft_out, float* mag_out, int num_bins) {
#if USE_NEON
        int i = 0;
        for (; i + 4 <= num_bins; i += 4) {
            float32x4_t real = {fft_out[i].real(), fft_out[i+1].real(), fft_out[i+2].real(), fft_out[i+3].real()};
            float32x4_t imag = {fft_out[i].imag(), fft_out[i+1].imag(), fft_out[i+2].imag(), fft_out[i+3].imag()};
            float32x4_t mag_sq = vmlaq_f32(vmulq_f32(real, real), imag, imag);
            // Newton-Raphson for accurate sqrt: sqrt(x) = x * rsqrt(x) with refinement
            float32x4_t rsqrt_est = vrsqrteq_f32(mag_sq);
            // One NR iteration: rsqrt = rsqrt * (3 - x * rsqrt^2) / 2
            float32x4_t rsqrt_sq = vmulq_f32(rsqrt_est, rsqrt_est);
            float32x4_t three = vdupq_n_f32(3.0f);
            float32x4_t half = vdupq_n_f32(0.5f);
            float32x4_t rsqrt_refined = vmulq_f32(vmulq_f32(rsqrt_est, vsubq_f32(three, vmulq_f32(mag_sq, rsqrt_sq))), half);
            float32x4_t mag = vmulq_f32(mag_sq, rsqrt_refined);
            vst1q_f32(&mag_out[i], mag);
        }
        for (; i < num_bins; i++) {
            mag_out[i] = std::abs(fft_out[i]);
        }
#elif USE_SSE
        int i = 0;
        for (; i + 4 <= num_bins; i += 4) {
            __m128 real = _mm_set_ps(fft_out[i+3].real(), fft_out[i+2].real(), fft_out[i+1].real(), fft_out[i].real());
            __m128 imag = _mm_set_ps(fft_out[i+3].imag(), fft_out[i+2].imag(), fft_out[i+1].imag(), fft_out[i].imag());
            __m128 mag_sq = _mm_add_ps(_mm_mul_ps(real, real), _mm_mul_ps(imag, imag));
            __m128 mag = _mm_sqrt_ps(mag_sq);
            _mm_storeu_ps(&mag_out[i], mag);
        }
        for (; i < num_bins; i++) {
            mag_out[i] = std::abs(fft_out[i]);
        }
#else
        for (int i = 0; i < num_bins; i++) {
            mag_out[i] = std::abs(fft_out[i]);
        }
#endif
    }

private:
    int fft_size;
    int log2n;
    std::vector<std::complex<float>> twiddles;
    std::vector<int> bit_rev;
};

// ============================================================================
// Compressor (with soft knee)
// ============================================================================

class Compressor {
public:
    void setParams(float threshold_db, float ratio, float attack_ms, float release_ms, float makeup_db, float sample_rate) {
        // 64-bit coefficient calculation
        threshold = db_to_linear_d(threshold_db);
        this->ratio = static_cast<double>(ratio);
        makeup = db_to_linear_d(makeup_db);
        attack_coeff = std::exp(-1.0 / (static_cast<double>(attack_ms) * 0.001 * sample_rate));
        release_coeff = std::exp(-1.0 / (static_cast<double>(release_ms) * 0.001 * sample_rate));
        rms_coeff = std::exp(-1.0 / (20.0 * 0.001 * sample_rate));
        knee_width = 0.5;
    }

    void process(float* left, float* right, int num_samples) {
        for (int i = 0; i < num_samples; i++) {
            // 64-bit RMS-style level detection
            double input_squared = static_cast<double>(left[i]) * left[i]
                                 + static_cast<double>(right[i]) * right[i];
            rms_state = rms_coeff * rms_state + (1.0 - rms_coeff) * input_squared;
            double input_level = std::sqrt(rms_state * 0.5);

            // Envelope follower
            if (input_level > envelope) {
                envelope = attack_coeff * envelope + (1.0 - attack_coeff) * input_level;
            } else {
                envelope = release_coeff * envelope + (1.0 - release_coeff) * input_level;
            }

            // Soft knee gain computation
            double gain = 1.0;
            double knee_start = threshold / (1.0 + knee_width);
            double knee_end = threshold * (1.0 + knee_width);

            if (envelope > knee_end) {
                double over_db = linear_to_db_d(envelope / threshold);
                double compressed_db = over_db / ratio;
                gain = db_to_linear_d(compressed_db - over_db);
            } else if (envelope > knee_start) {
                double knee_factor = (envelope - knee_start) / (knee_end - knee_start);
                double over_db = linear_to_db_d(envelope / threshold);
                double compressed_db = over_db / ratio;
                double full_gain = db_to_linear_d(compressed_db - over_db);
                gain = 1.0 + (full_gain - 1.0) * knee_factor * knee_factor;
            }

            // Smooth gain changes
            if (gain < current_gain) {
                current_gain = attack_coeff * current_gain + (1.0 - attack_coeff) * gain;
            } else {
                current_gain = release_coeff * current_gain + (1.0 - release_coeff) * gain;
            }

            // Apply gain with makeup (cast back to float for output)
            float gain_f = static_cast<float>(current_gain * makeup);
            left[i] *= gain_f;
            right[i] *= gain_f;
        }
    }

    void reset() {
        envelope = 0;
        current_gain = 1.0;
        rms_state = 0;
    }

private:
    double threshold = 0.5;
    double ratio = 4.0;
    double makeup = 1.0;
    double knee_width = 0.5;
    double attack_coeff = 0.9;
    double release_coeff = 0.9995;
    double envelope = 0;
    double current_gain = 1.0;
    double rms_state = 0;
    double rms_coeff = 0.9;
};

// ============================================================================
// Limiter — V8: True brick-wall with lookahead
// ============================================================================
//
// Why a real lookahead matters: a single-pass envelope follower with a 5 ms
// attack can't reduce gain *before* a transient arrives, so peaks leak through
// for the entire attack window. V7 papered over this by hard-clamping the
// output to ±1.0, which produced exactly the harshness the user complained
// about ("Android-level shitty"). V8 stores the audio in a small ring buffer
// and computes the gain reduction from a peak that is `lookahead` samples
// *ahead* of the sample we are emitting — so the gain has fully ramped down
// before the loud sample exits the delay line. The output never exceeds the
// ceiling, so no clipping (soft or hard) is needed at the end.
//
// 1.5 ms lookahead is the sweet spot: short enough to be inaudible (well under
// any latency you'd notice on a phone), long enough that a 1 ms attack ramp
// reaches the target before the peak emerges from the delay.

class Limiter {
public:
    void setParams(float ceiling_db, float release_ms, float sample_rate) {
        ceiling = db_to_linear_d(ceiling_db);
        sr = sample_rate;

        // 1.5 ms lookahead. Round to ≥1 sample.
        int la = static_cast<int>(0.0015 * sample_rate + 0.5);
        if (la < 1) la = 1;
        if (la > 4096) la = 4096;
        if (la != lookahead) {
            lookahead = la;
            delay_l.assign(lookahead, 0.0f);
            delay_r.assign(lookahead, 0.0f);
            peak_window.assign(lookahead, 0.0);
            delay_pos = 0;
            window_max = 0.0;
        }

        // Attack ramp = lookahead duration. The gain finishes ramping down
        // exactly as the loud sample reaches the output — no peak leakage.
        attack_coeff = std::exp(-1.0 / (static_cast<double>(lookahead)));
        release_coeff = std::exp(-1.0 / (static_cast<double>(release_ms) * 0.001 * sample_rate));
    }

    void process(float* left, float* right, int num_samples) {
        if (lookahead < 1) {
            // Fallback: not initialized, pass through with safety soft clip
            for (int i = 0; i < num_samples; i++) {
                left[i]  = soft_clip(left[i],  0.95f);
                right[i] = soft_clip(right[i], 0.95f);
            }
            return;
        }
        for (int i = 0; i < num_samples; i++) {
            // Sample entering the delay line
            float in_l = left[i];
            float in_r = right[i];

            // V9.2 — cubic Hermite intersample peak detection from V9.1 was
            // reverted because field reports said low-volume sound was
            // distorted. Hermite can overshoot the actual envelope on
            // specific signal shapes; the limiter then ramps gain on a
            // peak that never reaches the DAC, producing audible pumping.
            // Native-rate peak detection (V9.0) is back. Intersample peaks
            // are still controlled by the soft-clip safety net at 0.98 and
            // the lookahead window's exponential gain ramp.
            double in_peak = std::max(
                std::abs(static_cast<double>(in_l)),
                std::abs(static_cast<double>(in_r)));

            // Sample leaving the delay line — this is what we emit
            float out_l = delay_l[delay_pos];
            float out_r = delay_r[delay_pos];
            double leaving_peak = peak_window[delay_pos];

            // Replace slot
            delay_l[delay_pos] = in_l;
            delay_r[delay_pos] = in_r;
            peak_window[delay_pos] = in_peak;
            delay_pos = (delay_pos + 1) % lookahead;

            // Maintain max-of-window. Recompute when the leaving sample was
            // the current max (cheap because window is short).
            if (in_peak > window_max) {
                window_max = in_peak;
            } else if (leaving_peak >= window_max - 1e-9) {
                double m = 0.0;
                for (int k = 0; k < lookahead; k++) {
                    if (peak_window[k] > m) m = peak_window[k];
                }
                window_max = m;
            }

            // Target gain so window_max maps to ceiling
            double target_gain = 1.0;
            if (window_max > ceiling) {
                target_gain = ceiling / window_max;
            }

            // Smooth gain: ramp down over the lookahead window (so it's fully
            // attenuated by the time the peak exits), release slowly.
            if (target_gain < current_gain) {
                current_gain = attack_coeff * current_gain + (1.0 - attack_coeff) * target_gain;
            } else {
                current_gain = release_coeff * current_gain + (1.0 - release_coeff) * target_gain;
            }

            // Emit. With proper lookahead the output never exceeds ceiling, so
            // no clip needed; the soft_clip is a paranoid belt-and-suspenders
            // for the very first samples after init when the gain hasn't yet
            // converged — and is set above ceiling so it's a no-op in steady
            // state.
            float g = static_cast<float>(current_gain);
            left[i]  = soft_clip(out_l * g, 0.98f);
            right[i] = soft_clip(out_r * g, 0.98f);
        }
    }

    void reset() {
        std::fill(delay_l.begin(),    delay_l.end(),    0.0f);
        std::fill(delay_r.begin(),    delay_r.end(),    0.0f);
        std::fill(peak_window.begin(), peak_window.end(), 0.0);
        delay_pos = 0;
        window_max = 0.0;
        current_gain = 1.0;
    }

    int latencySamples() const { return lookahead; }

private:
    double ceiling = 0.84;            // -1.5 dBFS
    double attack_coeff = 0.97;
    double release_coeff = 0.9995;
    double current_gain = 1.0;
    double window_max = 0.0;
    double sr = 48000.0;
    int lookahead = 0;
    int delay_pos = 0;
    std::vector<float>  delay_l;
    std::vector<float>  delay_r;
    std::vector<double> peak_window;
};

// ============================================================================
// Reverb (Freeverb-style)
// ============================================================================

class AllPassDelay {
public:
    AllPassDelay(int delay_samples, float feedback = 0.5f)
        : buffer(delay_samples, 0), pos(0), feedback(feedback) {}

    float process(float input) {
        float buffered = buffer[pos];
        float output = -input + buffered;
        buffer[pos] = input + buffered * feedback;
        pos = (pos + 1) % buffer.size();
        return output;
    }

private:
    std::vector<float> buffer;
    size_t pos;
    float feedback;
};

class CombFilter {
public:
    CombFilter(int delay_samples, float feedback = 0.8f, float damping = 0.2f)
        : buffer(delay_samples, 0), pos(0), feedback(feedback), damping(damping), filter(0) {}

    float process(float input) {
        float output = buffer[pos];
        filter = output * (1.0f - damping) + filter * damping;
        buffer[pos] = input + filter * feedback;
        pos = (pos + 1) % buffer.size();
        return output;
    }

    void setFeedback(float fb) { feedback = fb; }
    void setDamping(float damp) { damping = damp; }

private:
    std::vector<float> buffer;
    size_t pos;
    float feedback;
    float damping;
    float filter;
};

class Reverb {
public:
    Reverb(float sample_rate) {
        const int comb_delays[] = {1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116};
        for (int i = 0; i < 8; i++) {
            int delay = static_cast<int>(comb_delays[i] * sample_rate / 44100.0f);
            combs_l.emplace_back(delay);
            combs_r.emplace_back(delay + 23);
        }

        const int allpass_delays[] = {225, 556, 441, 341};
        for (int i = 0; i < 4; i++) {
            int delay = static_cast<int>(allpass_delays[i] * sample_rate / 44100.0f);
            allpasses_l.emplace_back(delay);
            allpasses_r.emplace_back(delay + 13);
        }
    }

    void setParams(float room_size, float damping, float wet, float dry, float width) {
        this->room_size = room_size;
        this->damping = damping;
        this->wet = wet;
        this->dry = dry;
        this->width = width;

        float feedback = room_size * 0.28f + 0.7f;
        for (auto& comb : combs_l) {
            comb.setFeedback(feedback);
            comb.setDamping(damping);
        }
        for (auto& comb : combs_r) {
            comb.setFeedback(feedback);
            comb.setDamping(damping);
        }
    }

    void process(float* left, float* right, int num_samples) {
        for (int i = 0; i < num_samples; i++) {
            float input_l = left[i];
            float input_r = right[i];

            float comb_sum_l = 0, comb_sum_r = 0;
            for (auto& comb : combs_l) comb_sum_l += comb.process(input_l);
            for (auto& comb : combs_r) comb_sum_r += comb.process(input_r);

            // Scale comb output to prevent buildup
            comb_sum_l *= 0.125f;
            comb_sum_r *= 0.125f;

            float out_l = comb_sum_l;
            float out_r = comb_sum_r;
            for (auto& ap : allpasses_l) out_l = ap.process(out_l);
            for (auto& ap : allpasses_r) out_r = ap.process(out_r);

            float wet1 = wet * (width / 2.0f + 0.5f);
            float wet2 = wet * ((1.0f - width) / 2.0f);

            left[i] = out_l * wet1 + out_r * wet2 + input_l * dry;
            right[i] = out_r * wet1 + out_l * wet2 + input_r * dry;
        }
    }

private:
    std::vector<CombFilter> combs_l, combs_r;
    std::vector<AllPassDelay> allpasses_l, allpasses_r;
    float room_size = 0.5f, damping = 0.5f, wet = 0.3f, dry = 1.0f, width = 1.0f;
};

// ============================================================================
// V8.7 — Transient Shaper
// ============================================================================
//
// Detects attack transients (kicks, snares, plucks, vocal consonants) and
// applies a separate gain to the *attack* phase versus the *sustain* phase.
// Works on the difference between two envelope followers running at very
// different time constants:
//
//   fast envelope (≈3 ms attack / 50 ms release)  — tracks the audible
//                                                    transient burst
//   slow envelope (≈100 ms attack / 200 ms release) — tracks the sustained
//                                                     body of the sound
//
// When the fast envelope is significantly above the slow envelope we are in
// an attack burst; multiply by `(1 + attack)` to enhance punch, or by
// `(1 - attack)` to soften (`attack` ∈ [-1, 1]). When the fast envelope is
// near or below the slow envelope we are in the sustain region; multiply by
// `(1 + sustain)`.
//
// This is the canonical SPL Transient Designer / Waves Trans-X / fabfilter
// Pro-DS algorithm distilled to its essentials. No look-ahead — works
// causally because the attack is identified the moment fast > slow, which
// happens within 3 ms of the actual transient onset.
class TransientShaper {
public:
    void init(float sample_rate) {
        sr = sample_rate;
        setParams(0.0f, 0.0f);
        // Time constants — converted to per-sample IIR coefficients in setParams().
        recalcCoefficients();
    }

    /// `attack` and `sustain` ∈ [-1, 1]. Positive = enhance, negative = soften.
    void setParams(float attack, float sustain) {
        attack_amount  = std::clamp(attack,  -1.0f, 1.0f);
        sustain_amount = std::clamp(sustain, -1.0f, 1.0f);
    }

    void process(float* left, float* right, int n) {
        if (std::abs(attack_amount) < 1e-3f && std::abs(sustain_amount) < 1e-3f) {
            return;  // bypass when both at zero
        }
        for (int i = 0; i < n; i++) {
            // Mono detection signal (sum-and-half) feeds *both* channels.
            // Using the same gain on L and R preserves stereo image.
            float sample = 0.5f * (std::abs(left[i]) + std::abs(right[i]));

            // Fast envelope.
            if (sample > env_fast) {
                env_fast = atk_fast_a * env_fast + (1.0f - atk_fast_a) * sample;
            } else {
                env_fast = rel_fast_a * env_fast + (1.0f - rel_fast_a) * sample;
            }
            // Slow envelope.
            if (sample > env_slow) {
                env_slow = atk_slow_a * env_slow + (1.0f - atk_slow_a) * sample;
            } else {
                env_slow = rel_slow_a * env_slow + (1.0f - rel_slow_a) * sample;
            }

            // Attack-ness: how much fast exceeds slow, normalised. 0 in
            // sustain, →1 during a transient. The 1e-9 floor avoids divide-
            // by-zero during silence.
            float attackness = (env_fast - env_slow) / (env_slow + 1e-9f);
            attackness = std::clamp(attackness, 0.0f, 1.0f);

            // Crossfade between attack and sustain gain by attackness.
            float attack_gain  = 1.0f + attack_amount  * attackness * 1.5f;
            float sustain_gain = 1.0f + sustain_amount * (1.0f - attackness) * 0.8f;
            float gain = attack_gain * sustain_gain;
            // Clamp gain so we never push into clipping or full mute.
            gain = std::clamp(gain, 0.25f, 4.0f);

            left[i]  *= gain;
            right[i] *= gain;
        }
    }

    void reset() {
        env_fast = 0.0f;
        env_slow = 0.0f;
    }

private:
    void recalcCoefficients() {
        // Fast: ≈3 ms attack, 50 ms release. Slow: ≈100 ms / 200 ms.
        atk_fast_a = std::exp(-1.0f / (3.0f   * 0.001f * sr));
        rel_fast_a = std::exp(-1.0f / (50.0f  * 0.001f * sr));
        atk_slow_a = std::exp(-1.0f / (100.0f * 0.001f * sr));
        rel_slow_a = std::exp(-1.0f / (200.0f * 0.001f * sr));
    }

    float sr = 48000.0f;
    float attack_amount = 0.0f;
    float sustain_amount = 0.0f;
    float env_fast = 0.0f;
    float env_slow = 0.0f;
    float atk_fast_a = 0.97f, rel_fast_a = 0.999f;
    float atk_slow_a = 0.999f, rel_slow_a = 0.9995f;
};

// ============================================================================
// V8.4 — 2× Oversampling around nonlinear stages
// ============================================================================
//
// Waveshapers (tanh, polynomial, asymmetric saturation) generate harmonics.
// At a 48 kHz sample rate, any harmonic above 24 kHz folds back ("aliases")
// into the audible band as inharmonic frequencies that dirty the highs —
// especially noticeable on cymbals, vocal sibilance, hi-hats. The
// professional fix is to *oversample*: run the nonlinear stage at 2× (or 4×)
// the sample rate, lowpass-filter to remove the new harmonics that landed
// in [fs, 2·fs], then decimate back to fs.
//
// We use 2× — sufficient for tanh-class saturation where harmonics roll off
// fast. 4× would be cleaner but doubles CPU cost. Anti-alias filter is two
// cascaded Butterworth biquads (4th-order Linkwitz-Riley) cut at 0.45·fs to
// give meaningful attenuation by the original Nyquist while keeping audio-
// band ripple imperceptible.
//
// Caller passes a lambda that processes 2N samples in place; we sandwich it
// between zero-stuffed upsample and decimating lowpass.
class Oversampler2x {
public:
    void init(float sample_rate, int max_block) {
        sr_native = sample_rate;
        // Anti-alias / anti-imaging filter cutoff. 0.45·fs is a good
        // compromise: stops imaging spectra from creeping below fs/2 on
        // upsample, and stops fold-back into audio band on downsample.
        const float fc = sample_rate * 0.45f;
        const float fs2 = sample_rate * 2.0f;
        // Two cascaded Q=0.707 lowpass biquads ≈ 4th-order Butterworth
        // at fs2 (24 dB/oct rolloff at fc).
        upL_a.setLowPass(fc, 0.707f, fs2);
        upL_b.setLowPass(fc, 0.707f, fs2);
        upR_a.setLowPass(fc, 0.707f, fs2);
        upR_b.setLowPass(fc, 0.707f, fs2);
        dnL_a.setLowPass(fc, 0.707f, fs2);
        dnL_b.setLowPass(fc, 0.707f, fs2);
        dnR_a.setLowPass(fc, 0.707f, fs2);
        dnR_b.setLowPass(fc, 0.707f, fs2);
        if (max_block > buf_capacity) {
            buf_capacity = max_block;
            os_l.assign(2 * max_block, 0.0f);
            os_r.assign(2 * max_block, 0.0f);
        }
    }

    // Process `n` mono pairs of (left, right). Calls `processor(L, R, 2n)`
    // at 2× rate where L and R point to the oversampled scratch buffers.
    template<typename F>
    void process(float* left, float* right, int n, F&& processor) {
        if (n * 2 > buf_capacity * 2) {
            buf_capacity = n;
            os_l.assign(2 * n, 0.0f);
            os_r.assign(2 * n, 0.0f);
        }
        // Upsample 2×: insert a zero between each input sample, scale by 2
        // to compensate for the energy halving, then lowpass twice.
        for (int i = 0; i < n; i++) {
            float xL = left[i] * 2.0f;
            float xR = right[i] * 2.0f;
            // Even tap = sample, odd tap = zero (zero-stuffing).
            os_l[2 * i]     = upL_b.process(upL_a.process(xL));
            os_l[2 * i + 1] = upL_b.process(upL_a.process(0.0f));
            os_r[2 * i]     = upR_b.process(upR_a.process(xR));
            os_r[2 * i + 1] = upR_b.process(upR_a.process(0.0f));
        }
        // Process at 2× rate.
        processor(os_l.data(), os_r.data(), 2 * n);
        // Decimate 2×: filter then keep every other sample. Both samples
        // must pass through the filter to maintain its state correctly.
        for (int i = 0; i < n; i++) {
            float yL_a = dnL_b.process(dnL_a.process(os_l[2 * i]));
            float yL_b = dnL_b.process(dnL_a.process(os_l[2 * i + 1]));
            float yR_a = dnR_b.process(dnR_a.process(os_r[2 * i]));
            float yR_b = dnR_b.process(dnR_a.process(os_r[2 * i + 1]));
            (void)yL_b; (void)yR_b;  // discard odd samples
            left[i]  = yL_a;
            right[i] = yR_a;
        }
    }

    void reset() {
        upL_a.reset(); upL_b.reset(); upR_a.reset(); upR_b.reset();
        dnL_a.reset(); dnL_b.reset(); dnR_a.reset(); dnR_b.reset();
    }

private:
    float sr_native = 48000.0f;
    int buf_capacity = 0;
    BiquadFilter upL_a, upL_b, upR_a, upR_b;
    BiquadFilter dnL_a, dnL_b, dnR_a, dnR_b;
    std::vector<float> os_l, os_r;
};

// ============================================================================
// V8.3 — Loudness Compensation (Fletcher-Munson, ISO 226)
// ============================================================================
//
// The ear is non-linear with level. At low SPL the equal-loudness contours
// (Fletcher-Munson 1933, refined as ISO 226) bow upward at both ends — the
// ear is *less* sensitive to bass and treble at quiet levels than at the
// 80–85 dB SPL reference where most music is mixed.
//
// Practical consequence: when the listener turns the volume down, music
// progressively loses bass and treble *perceptually*, not because anything
// changed in the signal. The professional solution is a loudness-compensated
// volume control that boosts low and high shelves as level drops.
//
// We expose a single `amount` ∈ [0, 1]:
//   - 0 = bypass (flat — for reference monitoring at 80+ dB SPL)
//   - 1 = full ISO 226 60-phon compensation (~+6 dB low shelf at 100 Hz,
//         ~+3 dB high shelf at 10 kHz)
//
// The amount is meant to be driven by playback volume — quieter playback gets
// more compensation. The Kotlin layer maps `audioTrack.getVolume()` into this
// amount. We could read it ourselves but we don't have access to the
// AudioTrack here, so we keep this layer dumb and let the caller decide.
//
// Two cascaded shelving biquads per channel. Smoothed amount via the
// existing per-block parameter ramp so volume slider drags don't click.
class LoudnessCompensation {
public:
    void init(float sample_rate) {
        sr = sample_rate;
        // Coefficients are recalculated when amount changes.
        recalc(0.0f, 1.0f, 1.0f);
    }

    // Recompute shelf coefficients for the given compensation amount and
    // per-band balance factors. Balance ∈ [0, 1.5]: 1.0 = nominal Fletcher-
    // Munson curve, < 1.0 dampens that band (e.g. bass-heavy song doesn't
    // need extra bass), > 1.0 boosts that band (e.g. thin source).
    void recalc(float amount, float low_factor, float high_factor) {
        amount = std::clamp(amount, 0.0f, 1.0f);
        low_factor  = std::clamp(low_factor,  0.0f, 1.5f);
        high_factor = std::clamp(high_factor, 0.0f, 1.5f);
        // Shelf gains and corners fitted to ISO 226:2003.
        //
        // The requirement is the difference between the 60-phon and 80-phon
        // equal-loudness contours, relative to 1 kHz — i.e. what must be added
        // when material balanced at 80 phon is played at 60. Computed from the
        // standard's own formula it is +6.2 dB at 100 Hz, +8.2 at 50 Hz,
        // +10.5 at 20 Hz, and +1.4 at 10 kHz.
        //
        // The low shelf previously used a nominal 6 dB at a 100 Hz corner,
        // taking the 6.2 dB requirement at 100 Hz as the gain to set. That
        // conflates two different numbers: a shelf reaches only *half* its
        // nominal gain at its own corner frequency. It therefore delivered
        // +3.0 dB where +6.2 was needed, and the error grew outward —
        // -3.6 dB at 200 Hz, -4.5 dB at 20 Hz, for an RMS miss of 2.30 dB
        // across the band. Loudness compensation defaults on, so every user
        // has been getting roughly half the bass correction the standard
        // calls for.
        //
        // 9 dB at 150 Hz fits the measured requirement to 0.99 dB RMS. A grid
        // search found 8.5 dB @ 180 Hz marginally better at 0.93 dB, but only
        // by pushing the high shelf to 4.5 dB, and the high shelf is not what
        // was wrong: at 3 dB / 10 kHz it already delivers +1.50 dB against the
        // +1.42 required. Changing only the broken half keeps the fix
        // reviewable.
        float low_gain_db  = 9.0f * amount * low_factor;
        float high_gain_db = 3.0f * amount * high_factor;
        low_shelf_l.setLowShelf (150.0f,  low_gain_db,  0.707f, sr);
        low_shelf_r.setLowShelf (150.0f,  low_gain_db,  0.707f, sr);
        high_shelf_l.setHighShelf(10000.0f, high_gain_db, 0.707f, sr);
        high_shelf_r.setHighShelf(10000.0f, high_gain_db, 0.707f, sr);
        last_amount = amount;
        last_low = low_factor;
        last_high = high_factor;
    }

    void process(float* left, float* right, int n,
                 float current_amount, float low_factor, float high_factor) {
        // Refresh coefficients only when something has actually changed.
        if (std::abs(current_amount - last_amount) > 0.005f ||
            std::abs(low_factor   - last_low)    > 0.01f  ||
            std::abs(high_factor  - last_high)   > 0.01f) {
            recalc(current_amount, low_factor, high_factor);
        }
        for (int i = 0; i < n; i++) {
            float l = low_shelf_l.process(left[i]);
            float r = low_shelf_r.process(right[i]);
            left[i]  = high_shelf_l.process(l);
            right[i] = high_shelf_r.process(r);
        }
    }

    void reset() {
        low_shelf_l.reset();  low_shelf_r.reset();
        high_shelf_l.reset(); high_shelf_r.reset();
        last_amount = -1.0f;  // Force recalc on next process().
        last_low = -1.0f;
        last_high = -1.0f;
    }

private:
    float sr = 48000.0f;
    float last_amount = -1.0f;
    float last_low = -1.0f;
    float last_high = -1.0f;
    BiquadFilter low_shelf_l,  low_shelf_r;
    BiquadFilter high_shelf_l, high_shelf_r;
};

// ============================================================================
// DSP Engine (main processor) - Version 2.0 with fixed algorithms
// ============================================================================

class DSPEngine {
public:
    DSPEngine() : fft(nullptr), reverb(nullptr) {}

    void init(int sample_rate, int channels, int buffer_size) {
        this->sample_rate = sample_rate;
        this->channels = channels;
        this->buffer_size = buffer_size;

        // Calculate parameter smoothing coefficient (50ms ramp time)
        // Coefficient = exp(-1 / (ramp_time_ms * 0.001 * sample_rate))
        param_smooth_coeff = std::exp(-1.0f / (50.0f * 0.001f * sample_rate));

        fft = std::make_unique<FFT>(2048);
        reverb = std::make_unique<Reverb>(static_cast<float>(sample_rate));

        // Initialize EQ bands (10-band graphic defaults; per-band frequency and
        // Q can be overridden afterwards via setEQBandParams for parametric use)
        const float eq_freqs[] = {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
        for (int i = 0; i < EQ_BANDS; i++) {
            eq_freqs_[i] = eq_freqs[i];
            eq_gains_[i] = 0;
            eq_gains_target_[i] = 0;
            eq_q_[i] = kDefaultEQQ;
            eq_type_[i] = static_cast<float>(kEQTypePeaking);
            applyEQBand(i);
        }

        // Rebuild the preference shelves for this sample rate. Their
        // coefficients depend on it, and the engine is re-initialised whenever
        // a track's rate changes — without this the tilt would keep the
        // previous rate's coefficients and shift its corner frequencies.
        applyPreferenceTilt();
        setOutputHighPass(output_hp_freq_);  // same reasoning

        // Initialize effect filters
        bass_lp_l.setLowPass(120, 0.7f, sample_rate);
        bass_lp_r.setLowPass(120, 0.7f, sample_rate);
        bass_bp_l.setBandPass(80, 1.0f, sample_rate);
        bass_bp_r.setBandPass(80, 1.0f, sample_rate);

        exciter_hp_l.setHighPass(4000, 0.7f, sample_rate);
        exciter_hp_r.setHighPass(4000, 0.7f, sample_rate);

        air_hp_l.setHighPass(10000, 0.7f, sample_rate);
        air_hp_r.setHighPass(10000, 0.7f, sample_rate);

        crossfeed_lp_l.setLowPass(kCrossfeedCornerHz, 0.7f, sample_rate);
        crossfeed_lp_r.setLowPass(kCrossfeedCornerHz, 0.7f, sample_rate);
        // Force the direct-path compensation to be rebuilt: its coefficients
        // depend on sample_rate, and this runs on every rate change.
        crossfeed_comp_amount_ = -1.0f;

        // Interaural delay for the crossfeed path (see member declaration).
        // Rounded to the nearest sample and clamped to the ring buffer.
        crossfeed_delay_samples = std::min(
            static_cast<int>(kCrossfeedITDSeconds * sample_rate + 0.5f),
            kCrossfeedDelayCap - 1);
        std::fill(std::begin(crossfeed_delay_l), std::end(crossfeed_delay_l), 0.0f);
        std::fill(std::begin(crossfeed_delay_r), std::end(crossfeed_delay_r), 0.0f);
        crossfeed_delay_pos = 0;

        // Subsonic high-pass filter (20Hz, Butterworth Q=0.707)
        subsonic_hpf_l.setHighPass(20, 0.707f, sample_rate);
        subsonic_hpf_r.setHighPass(20, 0.707f, sample_rate);

        // DC blockers
        dc_blocker_l.init(sample_rate);
        dc_blocker_r.init(sample_rate);

        // Envelope followers for bass effects
        bass_env.setParams(5.0f, 50.0f, sample_rate);

        // Subharmonic oscillator
        sub_osc_freq = 40.0f;  // Fixed base frequency
        sub_osc_phase = 0;
        sub_osc_phase_inc = sub_osc_freq / sample_rate;

        // FFT buffer
        fft_buffer.resize(2048);
        fft_input_buffer.resize(2048);
        fft_output.resize(2048);
        fft_magnitudes.resize(1024);

        // Prime the limiter with a sane default ceiling so its lookahead buffer
        // is sized before any audio is processed. setLimiter() / device profiles
        // overwrite this almost immediately.
        limiter.setParams(-1.5f, 100.0f, static_cast<float>(sample_rate));
        limiter.reset();

        // V8.3 — loudness compensation initialised at 0 amount (transparent).
        // Host turns it up via nagare_loudness_comp_set().
        loudness_comp.init(static_cast<float>(sample_rate));

        // V8.4 — 2× oversampler initialised. Anti-alias filter coefficients
        // depend on sample rate; max_block sized generously since real
        // process() callbacks rarely exceed this.
        oversampler.init(static_cast<float>(sample_rate), 4096);

        // V8.7 — transient shaper (zero attack/sustain by default — bypass).
        transient_shaper.init(static_cast<float>(sample_rate));

        // Pre-warm every scratch buffer the audio thread touches, so the first
        // callback doesn't allocate either. Sized to the oversampler's max
        // block; resize() inside process() is then always a no-op.
        constexpr int kMaxBlock = 4096;
        proc_left.resize(kMaxBlock);
        proc_right.resize(kMaxBlock);
        scratch_l_.resize(kMaxBlock);
        scratch_r_.resize(kMaxBlock);
        dry_hp_l_.resize(kMaxBlock);
        dry_hp_r_.resize(kMaxBlock);

        initialized = true;
    }

    void release() {
        initialized = false;
        fft.reset();
        reverb.reset();
    }

    void process(const float* input, float* output, int num_frames) {
        if (!initialized) {
            std::memcpy(output, input, num_frames * channels * sizeof(float));
            return;
        }

        // V8.1: arm Flush-To-Zero on the audio thread. AudioTrack typically
        // calls process() from a dedicated worker thread, and that thread
        // doesn't inherit the FPCR/MXCSR settings of the thread that ran init.
        // We re-arm every callback for correctness; the cost is one register
        // write (~1 ns) and avoids 50× CPU spikes when the signal goes silent
        // and IIR filters drift into subnormal territory.
        enableDenormalFlushOnThisThread();

        // V6: Removed mutex from audio processing hot path to prevent priority inversion.
        // Parameter updates from UI thread are inherently safe here because:
        // 1. Bool/float writes are atomic on ARM/x86 (aligned 32-bit)
        // 2. All parameters are smoothed via param_smooth_coeff (50ms ramp)
        // 3. Worst case: one buffer sees a stale value, inaudible at 10ms buffers

        // Ensure every scratch buffer is large enough, in one place.
        //
        // This used to grow only proc_left/proc_right, while scratch_l_,
        // scratch_r_ and the exciter's dry_hp_ buffers were sized separately at
        // init and never revisited. The effect layers then called resize(n) on
        // them directly, which is a no-op while n stays under the init size and
        // a heap allocation the moment it does not — on the audio thread, where
        // an allocation can block on a lock inside the allocator and produce a
        // dropout.
        //
        // Growing them together here means the resize() calls further down are
        // provably no-ops rather than incidentally-usually-no-ops, and the
        // invariant is stated in exactly one place instead of being implied by
        // two constants that had to agree.
        if (num_frames > proc_buffer_size) {
            proc_left.resize(num_frames);
            proc_right.resize(num_frames);
            scratch_l_.resize(num_frames);
            scratch_r_.resize(num_frames);
            dry_hp_l_.resize(num_frames);
            dry_hp_r_.resize(num_frames);
            proc_buffer_size = num_frames;
        }

        // Deinterleave input into pre-allocated buffers
        float* left_ch = proc_left.data();
        float* right_ch = proc_right.data();
        for (int i = 0; i < num_frames; i++) {
            left_ch[i] = input[i * channels];
            right_ch[i] = (channels == 2) ? input[i * channels + 1] : input[i * channels];
        }

        // Update FFT buffer
        updateFFTBuffer(left_ch, right_ch, num_frames);

        // === Processing Chain with inter-stage limiting ===

        // Smooth ALL parameter transitions toward their targets.
        //
        // V8 fix: previously this used `param_smooth_coeff` (calibrated for
        // *per-sample* application) but applied it once per block, which made
        // the effective time constant `block_size` times too long — AI Tune
        // adjustments would take *minutes* to converge instead of 50 ms.
        // We now compute a per-block coefficient from the actual num_frames
        // so a 50 ms ramp behaves like a 50 ms ramp regardless of block size.
        float block_smooth_coeff = std::exp(
            -static_cast<float>(num_frames) / (sample_rate * 0.050f));
        float sc = block_smooth_coeff;
        float si = 1.0f - sc;
        virtual_bass_amount = sc * virtual_bass_amount + si * virtual_bass_target;
        exciter_amount = sc * exciter_amount + si * exciter_target;
        subharmonic_amount = sc * subharmonic_amount + si * subharmonic_target;
        tube_warmth_amount = sc * tube_warmth_amount + si * tube_warmth_target;
        tube_drive = sc * tube_drive + si * tube_drive_target;
        air_band_amount = sc * air_band_amount + si * air_band_target;
        crossfeed_amount = sc * crossfeed_amount + si * crossfeed_target;
        stereo_width = sc * stereo_width + si * stereo_width_target;
        loudness_comp_amount = sc * loudness_comp_amount + si * loudness_comp_target;

        // V9 — 20 ms ramps for transient shaper params and reverb wet/dry.
        // Faster than the 50 ms ramp above because these are preset-toggle
        // events (a few per minute), not AI Tune adjustments (continuous).
        // 20 ms is enough to mask the discontinuity below human perception
        // without dragging the preset switch into the audible region.
        float block_smooth_coeff_20 = std::exp(
            -static_cast<float>(num_frames) / (sample_rate * 0.020f));
        float sc20 = block_smooth_coeff_20;
        float si20 = 1.0f - sc20;
        transient_attack_current =
            sc20 * transient_attack_current + si20 * transient_attack_target;
        transient_sustain_current =
            sc20 * transient_sustain_current + si20 * transient_sustain_target;
        transient_shaper.setParams(transient_attack_current,
                                    transient_sustain_current);

        reverb_wet_current =
            sc20 * reverb_wet_current + si20 * reverb_wet_target;
        reverb_dry_current =
            sc20 * reverb_dry_current + si20 * reverb_dry_target;
        if (reverb) {
            reverb->setParams(reverb_room_size_set, reverb_damping_set,
                              reverb_wet_current, reverb_dry_current,
                              reverb_width_set);
        }

        // Smooth EQ band transitions (50ms ramp for dynamic EQ) — same fix
        if (eq_smooth_pending_) {
            bool still_ramping = false;
            for (int b = 0; b < EQ_BANDS; b++) {
                float diff = eq_gains_target_[b] - eq_gains_[b];
                if (std::abs(diff) > 0.01f) {
                    eq_gains_[b] = sc * eq_gains_[b] + si * eq_gains_target_[b];
                    applyEQBand(b);   // honours this band's filter type
                    still_ramping = true;
                } else if (eq_gains_[b] != eq_gains_target_[b]) {
                    eq_gains_[b] = eq_gains_target_[b];
                    applyEQBand(b);
                }
            }
            if (!still_ramping) eq_smooth_pending_ = false;
        }

        // V9 — true bypass short-circuit. When the "Pure" preset (or any
        // caller) sets chain_bypass, we skip the entire effect chain plus
        // input attenuation and loudness compensation. The signal still
        // flows through subsonic HPF → DC blocker → limiter so DC and
        // peaks are still controlled; everything else passes through.
        if (chain_bypass) {
            dbg_attenuation_db = 0.0f;
            dbg_cumulative_gain_db = 0.0f;
            dbg_low_band_db = 0.0f;
            dbg_mid_band_db = 0.0f;
            dbg_high_band_db = 0.0f;
            dbg_eq_peak_db = 0.0f;
            dbg_active_effects = 0;
        }

        // === Input Attenuation (prevent cumulative gain from overwhelming limiter) ===
        // V8: Band-aware attenuation. Effects operate in separate frequency bands
        // so they don't stack linearly on the same samples. Use max-of-bands
        // approach: only the loudest band's gain matters for peak calculation.
        if (!chain_bypass) {
            // Low band: virtual bass (<120Hz) + subharmonic (<80Hz) DO overlap
            // V6: Reduced estimates — effects are now cleaner with less gain
            float low_band_db = 0.0f;
            if (virtual_bass_enabled)  low_band_db += 3.0f * virtual_bass_amount;
            if (subharmonic_enabled)   low_band_db += 2.5f * subharmonic_amount;

            // Mid band: tube warmth (now unity-gain wet/dry) + reverb (diffuse)
            float mid_band_db = 0.0f;
            if (tube_warmth_enabled)   mid_band_db += 1.5f * tube_warmth_amount;
            if (reverb_enabled)        mid_band_db += 2.0f;

            // High band: exciter (>4kHz, now single-stage) + air band (>8kHz, clean boost)
            float high_band_db = 0.0f;
            if (exciter_enabled)       high_band_db += 2.0f * exciter_amount;
            if (air_band_enabled)      high_band_db += 1.5f * air_band_amount;

            // Loudness compensation. Its low shelf is nominally 9 dB scaled by
            // amount and the per-band balance factor, and a shelf reaches its
            // full gain below the corner — so this is real broadband gain, not
            // a narrow bump. It was absent from this budget entirely, which
            // went unnoticed while the stage defaulted off; the Enhanced mode
            // turns it on, so it now has to be counted.
            if (loudness_comp_enabled && loudness_comp_amount > 1e-3f) {
                low_band_db  += 9.0f * loudness_comp_amount * loudness_comp_low_factor;
                high_band_db += 3.0f * loudness_comp_amount * loudness_comp_high_factor;
            }

            // Listener preference tilt. Only boosts matter here; a listener who
            // asked for less bass has handed headroom back rather than spent
            // any.
            if (preference_bass_db_ > 0.0f)   low_band_db  += preference_bass_db_;
            if (preference_treble_db_ > 0.0f) high_band_db += preference_treble_db_;

            // Crossfeed contributes almost nothing, and counting its
            // compensation shelf at face value would be a mistake worth
            // explaining. That shelf looks like a +2.3 dB treble boost, but the
            // stage divides by (dry + wet) immediately afterwards precisely so
            // the two cancel: correlated content passes at unity by
            // construction, measured at -0.04 dB. Charging the budget the
            // shelf's nominal gain would attenuate the whole chain by over 2 dB
            // to pay for gain that is not there — quieter for nothing, which is
            // the opposite of the intent.
            //
            // Only decorrelated content can exceed unity here, and only
            // slightly, so a small allowance covers it.
            if (crossfeed_enabled && crossfeed_amount > 1e-3f) {
                high_band_db += 0.5f * crossfeed_amount;
            }

            // EQ: only count the single highest positive boost
            float eq_peak_db = 0.0f;
            if (eq_enabled) {
                for (int b = 0; b < EQ_BANDS; b++) {
                    if (eq_gains_[b] > eq_peak_db) {
                        eq_peak_db = eq_gains_[b];
                    }
                }
            }

            // Take the maximum across bands (they don't stack on same samples)
            // then add a fraction of the others for safety
            float max_band = low_band_db;
            if (mid_band_db > max_band) max_band = mid_band_db;
            if (high_band_db > max_band) max_band = high_band_db;
            if (eq_peak_db > max_band) max_band = eq_peak_db;

            // Effective gain: max band + 30% of the rest (conservative - bands overlap more than expected)
            float other_bands = (low_band_db + mid_band_db + high_band_db + eq_peak_db) - max_band;
            float cumulative_gain_db = max_band + other_bands * 0.30f;

            // Loudness normalisation is deliberately NOT counted here.
            //
            // It is tempting to add it — it is up to 12 dB of flat gain applied
            // after this point, with only the limiter downstream. But
            // attenuating the input by the normalisation gain would cancel the
            // feature exactly: pull the input down 10 dB, let normalisation put
            // 10 dB back, and no track has been levelled against any other.
            //
            // The reason it does not need counting is that this attenuation
            // already holds the chain to roughly unity. If the stages above are
            // all compensated, the signal arriving at the normalisation stage
            // still has approximately the file's own peak — which is precisely
            // the number its peak guard is computed from
            // (LoudnessNormalization.gainFor uses the track's measured true
            // peak against a -1 dBFS ceiling).
            //
            // That equivalence is what broke, and it is why Enhanced distorted
            // at high volume: loudness compensation, the preference tilt and
            // the crossfeed compensation shelf were all absent from this budget,
            // so their gain was never compensated. The signal reached
            // normalisation hotter than the file, the guard protected against
            // the wrong number, and the limiter ran hard. Counting them above
            // restores the assumption the guard depends on.

            // Store debug info for external query
            dbg_low_band_db = low_band_db;
            dbg_mid_band_db = mid_band_db;
            dbg_high_band_db = high_band_db;
            dbg_eq_peak_db = eq_peak_db;
            dbg_cumulative_gain_db = cumulative_gain_db;
            dbg_active_effects =
                (int)virtual_bass_enabled + (int)subharmonic_enabled +
                (int)tube_warmth_enabled + (int)exciter_enabled +
                (int)air_band_enabled + (int)reverb_enabled + (int)eq_enabled;

            // V8.5: combine per-song pre-attenuation (driven by AI Tune from
            // the SongAudioProfile — typically -1.5 dB for clipping risk or
            // already-loud masters) with the effect-driven cumulative gain
            // budget. Both are negative or zero, so we just add them.
            float effect_attn_db = 0.0f;
            if (cumulative_gain_db > 1.5f) {
                effect_attn_db = -(cumulative_gain_db - 1.0f);  // Keep 1 dB headroom
            }
            float total_attn_db = effect_attn_db + per_song_pregain_db;
            dbg_attenuation_db = total_attn_db;
            if (total_attn_db < -0.05f) {
                float attenuation = db_to_linear(total_attn_db);
                for (int i = 0; i < num_frames; i++) {
                    left_ch[i] *= attenuation;
                    right_ch[i] *= attenuation;
                }
            }
        }

        // 0. Subsonic filter (20Hz HPF - removes rumble/DC before any processing)
        for (int i = 0; i < num_frames; i++) {
            left_ch[i] = subsonic_hpf_l.process(left_ch[i]);
            right_ch[i] = subsonic_hpf_r.process(right_ch[i]);
        }

        // V9 — effect chain runs only when chain_bypass is off.
        if (!chain_bypass) {
            // 1. EQ (first, to shape tone before effects)
            if (eq_enabled) {
                processEQ(left_ch, right_ch, num_frames);
            }

            // 1.2 Listener preference tilt. Immediately after correction and
            // before every non-linear stage: the saturation and exciter blocks
            // generate harmonics from what they are fed, so the tonal balance
            // has to be final before they see it. Placing this later would
            // make the amount of generated harmonic content depend on the
            // preference setting, which is not what a taste control should do.
            // Runs independently of eq_enabled — it is a preference, not part
            // of the correction the EQ switch governs.
            processPreferenceTilt(left_ch, right_ch, num_frames);

            // 1.5 V8.7 — Transient Shaper. Runs between EQ and the saturation
            // stages so attack/sustain shaping happens on the EQ'd dry signal,
            // before harmonic generation could blur the transient envelopes.
            //
            // V9 — also process while ramping out (current > epsilon) so the
            // toggle-off transition isn't a hard snap.
            if (transient_shaper_enabled ||
                std::abs(transient_attack_current)  > 1e-3f ||
                std::abs(transient_sustain_current) > 1e-3f) {
                transient_shaper.process(left_ch, right_ch, num_frames);
            }

            // 2. Virtual Bass (psychoacoustic harmonics)
            if (virtual_bass_enabled) {
                processVirtualBass(left_ch, right_ch, num_frames);
            }

            // 3. Sub-harmonic (proper frequency divider)
            if (subharmonic_enabled) {
                processSubharmonic(left_ch, right_ch, num_frames);
            }

            // 4. Tube Warmth (even harmonic saturation)
            if (tube_warmth_enabled) {
                processTubeWarmth(left_ch, right_ch, num_frames);
            }

            // 5. Exciter (high frequency harmonics)
            if (exciter_enabled) {
                processExciter(left_ch, right_ch, num_frames);
            }

            // 6. Air Band (ultra-high frequency boost)
            if (air_band_enabled) {
                processAirBand(left_ch, right_ch, num_frames);
            }

            // 7. Stereo Width
            if (stereo_width_enabled) {
                processStereoWidth(left_ch, right_ch, num_frames);
            }

            // 8. Crossfeed (for headphones)
            if (crossfeed_enabled) {
                processCrossfeed(left_ch, right_ch, num_frames);
            }

            // 9. Compressor
            if (compressor_enabled) {
                compressor.process(left_ch, right_ch, num_frames);
            }

            // 10. Reverb. V9 — process while ramping out too (wet > epsilon)
            // so disabling room ambience fades cleanly instead of cutting.
            if (reverb && (reverb_enabled || reverb_wet_current > 1e-3f)) {
                reverb->process(left_ch, right_ch, num_frames);
            }

            // 11. Loudness compensation (Fletcher-Munson / ISO 226). Runs AFTER
            // all tonal effects but BEFORE the DC blocker + limiter so it sees
            // the same signal the user will hear. Cheap two-shelf biquad pair,
            // only active when amount > 0.
            if (loudness_comp_enabled && loudness_comp_amount > 1e-3f) {
                loudness_comp.process(left_ch, right_ch, num_frames,
                    loudness_comp_amount,
                    loudness_comp_low_factor,
                    loudness_comp_high_factor);
            }
        }

        // 11.5 Output high-pass — remove content the transducer cannot
        // reproduce.
        //
        // A phone speaker is a few millimetres across and rolls off steeply
        // below roughly 300 Hz; it radiates almost nothing down there. The
        // amplifier still tries. That energy becomes cone excursion and
        // intermodulation distortion rather than sound, and it eats the
        // headroom that everything audible has to share — so removing it makes
        // the midrange cleaner and lets the whole signal sit louder before the
        // limiter engages. Nothing is lost, because nothing was being heard.
        //
        // Placed here, after virtual bass rather than before it: the missing
        // fundamental works by generating harmonics *from* the low content, so
        // high-passing first would remove the very material the effect needs
        // and leave the listener with neither the fundamental nor its
        // substitute. Generate first, then discard the part that cannot be
        // played.
        //
        // Off (0 Hz) for every other output — headphones and line outputs
        // reproduce the bottom octaves perfectly well, and filtering there
        // would just be throwing music away.
        if (output_hp_active_) {
            for (int i = 0; i < num_frames; i++) {
                left_ch[i] = output_hp_l_.process(left_ch[i]);
                right_ch[i] = output_hp_r_.process(right_ch[i]);
            }
        }

        // 12. DC Blocker (remove any DC offset from effects)
        for (int i = 0; i < num_frames; i++) {
            left_ch[i] = dc_blocker_l.process(left_ch[i]);
            right_ch[i] = dc_blocker_r.process(right_ch[i]);
        }

        // 12.5 Loudness normalisation.
        //
        // A per-track gain that brings every song to the same perceived
        // loudness, from its measured BS.1770 integrated LUFS. Track-to-track
        // level jumps are among the most noticeable faults in a player — a
        // 1980s master followed by a modern one can differ by 10 dB or more,
        // which is a far larger insult than anything the effect chain
        // corrects.
        //
        // Placed after every effect and before the limiter. After, so the gain
        // does not change how much the effects are driven — a normalised quiet
        // track should sound like the same processing, louder, not like more
        // saturation. Before the limiter, so the limiter still catches
        // anything the gain pushes over.
        //
        // Smoothed rather than applied instantly: the value changes on track
        // change, and a step in gain is a click.
        if (norm_gain_target_ != norm_gain_current_ || norm_gain_current_ != 1.0f) {
            for (int i = 0; i < num_frames; i++) {
                norm_gain_current_ += (norm_gain_target_ - norm_gain_current_)
                                    * kNormGainSmoothing;
                left_ch[i]  *= norm_gain_current_;
                right_ch[i] *= norm_gain_current_;
            }
        }

        // 13. Limiter (always last - prevents clipping)
        if (limiter_enabled) {
            limiter.process(left_ch, right_ch, num_frames);
        }

        // Update meters
        updateMeters(left_ch, right_ch, num_frames);

        // Interleave output
        for (int i = 0; i < num_frames; i++) {
            output[i * channels] = left_ch[i];
            if (channels == 2) {
                output[i * channels + 1] = right_ch[i];
            }
        }
    }

    // --- Effect processing (Version 2.0 - Fixed) ---

    void applySoftClip(float* left, float* right, int n) {
        for (int i = 0; i < n; i++) {
            left[i] = soft_clip(left[i], STAGE_HEADROOM);
            right[i] = soft_clip(right[i], STAGE_HEADROOM);
        }
    }

    void processVirtualBass(float* left, float* right, int n) {
        // Psychoacoustic bass enhancement using "missing fundamental"
        // Generate harmonics that let the brain perceive bass even on small speakers
        // V5: Conservative harmonics — quality over quantity

        for (int i = 0; i < n; i++) {
            // Extract bass from each channel separately
            float bass_l = bass_lp_l.process(left[i]);
            float bass_r = bass_lp_r.process(right[i]);

            // Clamp bass to valid range for polynomial
            bass_l = std::clamp(bass_l, -1.0f, 1.0f);
            bass_r = std::clamp(bass_r, -1.0f, 1.0f);

            // Generate 2nd harmonic (full-wave rectification) - warmth and punch
            float harm2_l = bass_l * std::abs(bass_l);
            float harm2_r = bass_r * std::abs(bass_r);

            // Generate 3rd harmonic with gentle saturation — subtle growl
            float harm3_l = fast_tanh(bass_l * 1.5f) * 0.35f;
            float harm3_r = fast_tanh(bass_r * 1.5f) * 0.35f;

            // Mix: 2nd harmonic dominant for clean warmth, 3rd for subtle presence
            float enhancement_l = (harm2_l * 0.45f + harm3_l * 0.2f) * virtual_bass_amount;
            float enhancement_r = (harm2_r * 0.45f + harm3_r * 0.2f) * virtual_bass_amount;

            left[i] += enhancement_l;
            right[i] += enhancement_r;
        }
    }

    void processSubharmonic(float* left, float* right, int n) {
        // Proper subharmonic synthesis using envelope-controlled oscillator
        // V6: Pitch-tracking subharmonic - tracks fundamental from bass signal

        for (int i = 0; i < n; i++) {
            // Bandpass to isolate bass frequencies
            float bass_l = bass_bp_l.process(left[i]);
            float bass_r = bass_bp_r.process(right[i]);
            float bass_mono = (bass_l + bass_r) * 0.5f;

            // Get envelope of bass signal
            float env = bass_env.process(bass_mono);

            // Zero-crossing pitch detection for subharmonic tracking
            if (sub_prev_sample <= 0.0f && bass_mono > 0.0f) {
                // Positive zero crossing detected
                if (sub_zc_count > 0) {
                    float period_samples = static_cast<float>(sub_samples_since_zc);
                    if (period_samples > 0.0f) {
                        float detected_freq = static_cast<float>(sample_rate) / period_samples;
                        // Only track if in musical bass range (60-300 Hz)
                        if (detected_freq >= 60.0f && detected_freq <= 300.0f) {
                            // Subharmonic = half the fundamental, clamped to 25-80 Hz
                            float target_freq = std::clamp(detected_freq * 0.5f, 25.0f, 80.0f);
                            // Smooth frequency transition to avoid clicks
                            sub_osc_freq += (target_freq - sub_osc_freq) * 0.1f;
                            sub_osc_phase_inc = sub_osc_freq / static_cast<float>(sample_rate);
                        }
                    }
                }
                sub_zc_count++;
                sub_samples_since_zc = 0;
            }
            sub_samples_since_zc++;
            sub_prev_sample = bass_mono;

            // Generate subharmonic oscillator
            sub_osc_phase += sub_osc_phase_inc;
            if (sub_osc_phase >= 1.0f) sub_osc_phase -= 1.0f;

            // Sine wave with slight triangle blend for presence
            float sub_sine = std::sin(sub_osc_phase * TWO_PI);
            float sub_tri = (sub_osc_phase < 0.5f) ? (sub_osc_phase * 4.0f - 1.0f) : (3.0f - sub_osc_phase * 4.0f);
            float sub_osc = sub_sine * 0.85f + sub_tri * 0.15f;

            // Modulate by envelope with increased gain
            float sub = sub_osc * env * subharmonic_amount * 0.7f;

            // Soft clip for warmth instead of hard clamp
            sub = fast_tanh(sub * 1.5f) * 0.6f;

            left[i] += sub;
            right[i] += sub;
        }
    }

    void processEQ(float* left, float* right, int n) {
        for (int i = 0; i < n; i++) {
            float l = left[i], r = right[i];
            for (int b = 0; b < EQ_BANDS; b++) {
                l = eq_bands_l[b].process(l);
                r = eq_bands_r[b].process(r);
            }
            left[i] = l;
            right[i] = r;
        }
    }

    /// Listener preference tilt, applied after correction.
    ///
    /// Olive, Welti & McMullin (AES 134th Convention, paper 8867) found
    /// listeners do not agree on one target. Segmenting preference ratings
    /// produced three classes: about 64% preferred the Harman target as it
    /// stands, about 15% wanted appreciably more bass, and about 21% wanted
    /// less. That is not noise to be averaged away — the minority groups are a
    /// third of listeners between them, and for them the "correct" curve is
    /// audibly wrong.
    ///
    /// This is deliberately a separate stage from the ten correction bands
    /// rather than more of them. Correction removes a headphone's measured
    /// error; preference is a taste applied on top. Keeping them apart means a
    /// profile is never displaced by a preference setting, the tilt survives
    /// switching headphones, and neither can silently eat the other's slots.
    ///
    /// A high shelf is provided alongside the low one, but the three researched
    /// classes leave it at zero: they differ in bass only. Olive's separate
    /// work on *personalisation* prescribes bass and treble together, which is
    /// a different result and must not be conflated with the class
    /// segmentation. The shelf stays so a future sourced curve has somewhere to
    /// go, not because these presets use it.
    void processPreferenceTilt(float* left, float* right, int n) {
        if (!preference_tilt_active_) return;
        for (int i = 0; i < n; i++) {
            left[i]  = pref_treble_l_.process(pref_bass_l_.process(left[i]));
            right[i] = pref_treble_r_.process(pref_bass_r_.process(right[i]));
        }
    }

    void applyPreferenceTilt() {
        // Corner frequencies follow the Harman target's own shelving regions:
        // the bass shelf pivots around 105 Hz and the treble shelf around
        // 2.5 kHz, which is where the class differences in Olive's data lie.
        pref_bass_l_.setLowShelf(105.0f, preference_bass_db_, 0.7f, sample_rate);
        pref_bass_r_.setLowShelf(105.0f, preference_bass_db_, 0.7f, sample_rate);
        pref_treble_l_.setHighShelf(2500.0f, preference_treble_db_, 0.7f, sample_rate);
        pref_treble_r_.setHighShelf(2500.0f, preference_treble_db_, 0.7f, sample_rate);

        // Skip the stage entirely when flat: four biquads per sample is a real
        // cost for a guaranteed no-op.
        preference_tilt_active_ =
            (preference_bass_db_ != 0.0f) || (preference_treble_db_ != 0.0f);
    }

    void processTubeWarmth(float* left, float* right, int n) {
        // V5: Single-stage subtle tube saturation — warmth without distortion
        // V8.4: 2× oversampled — tanh-class waveshaping above ~6 kHz folds
        // even-order harmonics back into the audio band as inharmonic
        // intermodulation; oversampling moves those spurious products above
        // the original Nyquist where the decimation filter kills them.
        // Wet/dry crossfade stays at the native rate (it's linear, doesn't
        // alias).
        if (n <= 0) return;

        // Snapshot wet/dry mix at native rate; the saturator only modifies
        // the wet path.
        const float wet = tube_warmth_amount;
        if (wet < 1e-4f) return;  // bypass — saves the oversample cost.
        const float dry = 1.0f - wet;
        const float drive = 1.0f + tube_drive * 0.5f;
        const float td = tube_drive * 0.5f;

        // The oversampler works in place, so the wet path needs its own copy.
        // scratch_l_/r_ are grown alongside proc_left/right at the top of
        // process(), so this resize can only ever shrink the reported size —
        // it never reallocates, and nothing here touches the heap.
        scratch_l_.resize(n);
        scratch_r_.resize(n);
        std::memcpy(scratch_l_.data(), left,  n * sizeof(float));
        std::memcpy(scratch_r_.data(), right, n * sizeof(float));

        oversampler.process(scratch_l_.data(), scratch_r_.data(), n,
            [drive, td](float* L, float* R, int n2) {
                for (int i = 0; i < n2; i++) {
                    L[i] = tube_saturate(L[i] * drive, td);
                    R[i] = tube_saturate(R[i] * drive, td);
                }
            });

        // Wet/dry crossfade at the native rate.
        for (int i = 0; i < n; i++) {
            left[i]  = scratch_l_[i] * wet + left[i]  * dry;
            right[i] = scratch_r_[i] * wet + right[i] * dry;
        }
    }

    void processExciter(float* left, float* right, int n) {
        // Aural exciter - generates harmonics in the high frequency range.
        //
        // V5: Single-stage gentle harmonic generation — presence without harshness.
        // V9: 2× oversampled. The exciter is the only saturation stage that
        // had a genuine aliasing problem: with the HPF at 4 kHz feeding tanh,
        // 2nd and 3rd harmonics land at 8/12 kHz (audible) and 4th–5th at
        // 16/20 kHz, plus aliasing products from the fundamental near 4 kHz
        // (which fold back below 4 kHz at the original Nyquist). On bright
        // material — cymbals, sibilance, hi-hats — this was the dirty "splash"
        // the audit called out. Now the tanh runs at 2× the rate; the
        // anti-alias filter in Oversampler2x kills anything above 0.45·fs
        // before decimation, so the harmonics that land in [fs, 2·fs] never
        // come home.
        //
        // virtualBass and subharmonic deliberately stay at native rate. Their
        // nonlinear math operates on <120 Hz / <80 Hz bandlimited input, so
        // all generated harmonics land below 1 kHz — well below Nyquist on
        // every supported sample rate. Oversampling them would cost CPU for
        // no audible quality gain.
        if (n <= 0) return;
        const float amount = exciter_amount;
        if (amount < 1e-4f) return;

        // HPF isolates the highs at native rate. Filter state stays at fs
        // — oversampling the HPF would change its cutoff calibration.
        scratch_l_.resize(n);
        scratch_r_.resize(n);
        for (int i = 0; i < n; i++) {
            scratch_l_[i] = exciter_hp_l.process(left[i]);
            scratch_r_[i] = exciter_hp_r.process(right[i]);
        }

        // Snapshot the dry HPF signal for harmonic extraction after the
        // saturator runs (harmonic = saturated - dry). Copies into
        // pre-allocated members; resize() is a no-op once warmed up, so no
        // allocation happens on the audio thread.
        dry_hp_l_.resize(n);
        dry_hp_r_.resize(n);
        std::memcpy(dry_hp_l_.data(), scratch_l_.data(), n * sizeof(float));
        std::memcpy(dry_hp_r_.data(), scratch_r_.data(), n * sizeof(float));

        // Oversample just the saturator. Drive matches the pre-V9 value
        // (1 + amount) so the tonal character is preserved.
        const float drive = 1.0f + amount;
        oversampler.process(scratch_l_.data(), scratch_r_.data(), n,
            [drive](float* L, float* R, int n2) {
                for (int i = 0; i < n2; i++) {
                    L[i] = fast_tanh(L[i] * drive);
                    R[i] = fast_tanh(R[i] * drive);
                }
            });

        // Add only the new harmonics back to the signal at native rate.
        for (int i = 0; i < n; i++) {
            float harm_l = (scratch_l_[i] - dry_hp_l_[i]) * amount * 0.4f;
            float harm_r = (scratch_r_[i] - dry_hp_r_[i]) * amount * 0.4f;
            left[i]  += harm_l;
            right[i] += harm_r;
        }
    }

    void processAirBand(float* left, float* right, int n) {
        // Air band - boosts ultra-high frequencies for "air" and "sparkle"
        // V5: Clean shelf boost — no saturation, no added distortion
        for (int i = 0; i < n; i++) {
            // High-pass at 10kHz+ for ultra-high frequencies
            float air_l = air_hp_l.process(left[i]);
            float air_r = air_hp_r.process(right[i]);

            // Clean gain boost (no saturation — air band should be transparent)
            left[i] += air_l * air_band_amount * 0.6f;
            right[i] += air_r * air_band_amount * 0.6f;
        }
    }

    void processStereoWidth(float* left, float* right, int n) {
        // Mid-Side stereo width adjustment
        for (int i = 0; i < n; i++) {
            float mid = (left[i] + right[i]) * 0.5f;
            float side = (left[i] - right[i]) * 0.5f;

            // Adjust side level (width > 1 = wider, width < 1 = narrower)
            side *= stereo_width;

            // Reconstruct L/R
            left[i] = mid + side;
            right[i] = mid - side;
        }
    }

    void processCrossfeed(float* left, float* right, int n) {
        // Headphone crossfeed (bs2b-inspired) — simulates speaker listening on
        // headphones, reducing the in-head localisation and listening fatigue
        // that hard-panned stereo causes over cans.
        //
        // Two head effects are modelled, per Audio Engineering §25.2.2:
        //   1. head shadow  — the far-ear path is low-passed (800 Hz here)
        //   2. interaural time delay — the far-ear path arrives ~261 µs later
        // Filter first, then delay, matching Figure 25.1.
        const float wet = crossfeed_amount;
        const float dry = 1.0f - wet * 0.65f;  // Proportional dry reduction for loudness balance
        const int delay = NAGARE_AB_ORIGINAL ? 0 : crossfeed_delay_samples;

        // Keep the tonal balance of centred content intact.
        //
        // Nearly everything that matters in a mix is panned centre — lead
        // vocal, bass, kick, snare. For that content both channels are
        // identical, so the "opposite channel" being blended in is a
        // low-passed copy of the signal itself: lows sum, highs do not, and
        // the result is a broad spectral tilt. Measured at the 0.30 default it
        // was +0.8 dB at 50 Hz against -1.9 dB at 12 kHz, a 2.7 dB tilt, rising
        // to 7.2 dB at amount 0.70.
        //
        // Toole & Olive (1988) put the audibility of a *broad* deviation near
        // 0.25 dB, so that tilt was an order of magnitude above threshold — and
        // it is the one error class this whole engine is organised around
        // avoiding. Crossfeed is a spatial control; it has no business acting
        // as a tone control.
        //
        // The fix makes the direct path complement the crossfeed path instead
        // of being a flat attenuation. The direct signal gets a high shelf of
        // exactly (dry+wet)/dry above the crossfeed corner, and the sum is
        // normalised by 1/(dry+wet). For correlated content that gives unity
        // at DC and unity above the corner. The spatial effect is untouched:
        // decorrelated content still crosses over, still with the interaural
        // delay.
        updateCrossfeedCompensation(wet, dry);
        const float norm = crossfeed_norm_;

        for (int i = 0; i < n; i++) {
            // 1. Head shadow on the signal crossing to the opposite ear.
            const float l_filt = crossfeed_lp_l.process(left[i]);
            const float r_filt = crossfeed_lp_r.process(right[i]);

            // 2. Interaural delay, via a small power-of-two ring buffer.
            crossfeed_delay_l[crossfeed_delay_pos] = l_filt;
            crossfeed_delay_r[crossfeed_delay_pos] = r_filt;
            const int read = (crossfeed_delay_pos - delay) & kCrossfeedDelayMask;
            const float l_to_r = crossfeed_delay_l[read] * wet;
            const float r_to_l = crossfeed_delay_r[read] * wet;
            crossfeed_delay_pos = (crossfeed_delay_pos + 1) & kCrossfeedDelayMask;

            // 3. Direct path, shelved to complement what the crossfeed adds.
            const float l_direct = crossfeed_comp_l_.process(left[i]);
            const float r_direct = crossfeed_comp_r_.process(right[i]);

            left[i]  = (l_direct * dry + r_to_l) * norm;
            right[i] = (r_direct * dry + l_to_r) * norm;
        }
    }

    /// Rebuild the direct-path compensation for the current wet/dry mix.
    ///
    /// Only recomputed when the amount actually moves — the crossfeed amount is
    /// parameter-smoothed, so this is called every buffer, and designing two
    /// biquads per buffer for a value that has not changed would be wasted work
    /// on the audio thread.
    void updateCrossfeedCompensation(float wet, float dry) {
        if (std::fabs(wet - crossfeed_comp_amount_) < 1e-4f) return;
        crossfeed_comp_amount_ = wet;

        const float sum = dry + wet;
        if (dry <= 1e-6f || sum <= 1e-6f) {
            crossfeed_norm_ = 1.0f;
            crossfeed_comp_l_.setHighShelf(kCrossfeedCornerHz, 0.0f, 0.7f, sample_rate);
            crossfeed_comp_r_.setHighShelf(kCrossfeedCornerHz, 0.0f, 0.7f, sample_rate);
            return;
        }

        // Above the corner the crossfed copy has died away, so the direct path
        // alone must reach the same level the summed pair reaches at DC.
        const float boost_db = 20.0f * std::log10(sum / dry);
        crossfeed_comp_l_.setHighShelf(kCrossfeedCornerHz, boost_db, 0.7f, sample_rate);
        crossfeed_comp_r_.setHighShelf(kCrossfeedCornerHz, boost_db, 0.7f, sample_rate);
        crossfeed_norm_ = 1.0f / sum;
    }

    void updateFFTBuffer(const float* left, const float* right, int n) {
        for (int i = 0; i < n; i++) {
            fft_buffer[fft_write_pos] = (left[i] + right[i]) * 0.5f;
            fft_write_pos = (fft_write_pos + 1) % fft_buffer.size();
        }
    }

    void updateMeters(const float* left, const float* right, int n) {
        float peak_l = 0, peak_r = 0;
        for (int i = 0; i < n; i++) {
            peak_l = std::max(peak_l, std::abs(left[i]));
            peak_r = std::max(peak_r, std::abs(right[i]));
        }

        // Smooth meters (fast attack, slow release)
        if (peak_l > level_l) {
            level_l = 0.5f * level_l + 0.5f * peak_l;
        } else {
            level_l = 0.95f * level_l + 0.05f * peak_l;
        }
        if (peak_r > level_r) {
            level_r = 0.5f * level_r + 0.5f * peak_r;
        } else {
            level_r = 0.95f * level_r + 0.05f * peak_r;
        }

        // Peak hold
        if (peak_l > peak_hold_l) peak_hold_l = peak_l;
        if (peak_r > peak_hold_r) peak_hold_r = peak_r;
    }

    // --- Getters/Setters ---

    void setEQEnabled(bool enabled) { eq_enabled = enabled; }
    void setEQBand(int band, float gain_db) {
        if (band < 0 || band >= EQ_BANDS) return;
        eq_gains_[band] = gain_db;
        eq_gains_target_[band] = gain_db;
        applyEQBand(band);
    }

    /// Fully reconfigure one band: filter type, centre frequency, gain and Q.
    ///
    /// Used for headphone correction, where the profile specifies all four.
    /// Passing them through instead of forcing peaking filters onto fixed
    /// frequencies at Q=1 is the difference between reproducing a measured
    /// correction and approximating it.
    ///
    /// `type` is one of kEQTypePeaking / kEQTypeLowShelf / kEQTypeHighShelf.
    void setEQBandParams(int band, float freq, float gain_db, float q, int type) {
        if (band < 0 || band >= EQ_BANDS) return;
        // Keep the filter stable: clamp below Nyquist and to a sane Q range.
        const float nyquist = static_cast<float>(sample_rate) * 0.5f;
        eq_freqs_[band] = std::clamp(freq, 10.0f, nyquist * 0.95f);
        eq_q_[band] = std::clamp(q, 0.1f, 10.0f);
        eq_gains_[band] = gain_db;
        eq_gains_target_[band] = gain_db;
        eq_type_[band] = static_cast<float>(type);
        applyEQBand(band);
    }

    /// Set the loudness-normalisation gain in dB.
    ///
    /// Clamped to +/-12 dB. The cap matters in both directions: a very quiet
    /// track would otherwise be lifted until its noise floor became audible,
    /// and a heavily limited modern master would be pulled down so far that it
    /// sounds lifeless next to everything else. Beyond about 12 dB the right
    /// answer is that the two recordings genuinely are different, not that one
    /// needs fixing.
    void setNormalizationGain(float gain_db) {
        const float clamped = std::clamp(gain_db, -12.0f, 12.0f);
        norm_gain_target_ = std::pow(10.0f, clamped / 20.0f);
    }

    /// Jump straight to the target instead of ramping. Used when playback
    /// starts, where there is no previous level to glide from and the ramp
    /// would just be an audible fade-in.
    void snapNormalizationGain() { norm_gain_current_ = norm_gain_target_; }

    /// Set the output high-pass corner in Hz. 0 (or anything below 20)
    /// disables the stage entirely.
    ///
    /// Q is 0.707 — Butterworth, maximally flat. A resonant corner would put a
    /// bump right where a small speaker is already straining, which is the
    /// opposite of the point.
    void setOutputHighPass(float freq_hz) {
        output_hp_freq_ = std::clamp(freq_hz, 0.0f, 1000.0f);
        output_hp_active_ = output_hp_freq_ >= 20.0f;
        if (output_hp_active_) {
            output_hp_l_.setHighPass(output_hp_freq_, 0.707f, sample_rate);
            output_hp_r_.setHighPass(output_hp_freq_, 0.707f, sample_rate);
        }
    }

    /// Set the listener-preference tilt in dB.
    ///
    /// Clamped to the span Olive's data actually covers. The classes sit at
    /// roughly +4 to +6 dB and -2 dB of bass, so allowing ±12 dB here would
    /// not be "more choice" — it would be a tone control masquerading as
    /// research, and at that depth it undoes the correction it sits on top of.
    void setPreferenceTilt(float bass_db, float treble_db) {
        preference_bass_db_ = std::clamp(bass_db, -6.0f, 6.0f);
        preference_treble_db_ = std::clamp(treble_db, -6.0f, 6.0f);
        applyPreferenceTilt();
    }

    /// Push one band's stored parameters into both channel filters, honouring
    /// its filter type. Central so the smoothing path and the setters cannot
    /// drift apart.
    void applyEQBand(int band) {
        const int type = static_cast<int>(eq_type_[band]);
        const float f = eq_freqs_[band];
        const float g = eq_gains_[band];
        const float q = eq_q_[band];
        switch (type) {
            case kEQTypeLowShelf:
                eq_bands_l[band].setLowShelf(f, g, q, sample_rate);
                eq_bands_r[band].setLowShelf(f, g, q, sample_rate);
                break;
            case kEQTypeHighShelf:
                eq_bands_l[band].setHighShelf(f, g, q, sample_rate);
                eq_bands_r[band].setHighShelf(f, g, q, sample_rate);
                break;
            default:
                eq_bands_l[band].setPeaking(f, g, q, sample_rate);
                eq_bands_r[band].setPeaking(f, g, q, sample_rate);
                break;
        }
    }

    /// Restore the default 10-band graphic layout (fixed ISO centres, Q=1,
    /// flat). Called when headphone correction is switched off so the manual
    /// EQ behaves normally again.
    void resetEQBandLayout() {
        const float defaults[] = {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
        for (int i = 0; i < EQ_BANDS; i++) {
            eq_freqs_[i] = defaults[i];
            eq_q_[i] = kDefaultEQQ;
            eq_gains_[i] = 0.0f;
            eq_gains_target_[i] = 0.0f;
            eq_type_[i] = static_cast<float>(kEQTypePeaking);
            applyEQBand(i);
        }
        eq_smooth_pending_ = false;
    }

    // Smooth setter for real-time dynamic EQ (50ms ramp)
    void setEQBandsSmooth(const float* gains) {
        for (int i = 0; i < EQ_BANDS; i++) {
            eq_gains_target_[i] = gains[i];
        }
        eq_smooth_pending_ = true;
    }

    void getGainDebug(float* output, int max_values) const {
        if (output == nullptr || max_values < 7) return;
        output[0] = dbg_attenuation_db;
        output[1] = dbg_cumulative_gain_db;
        output[2] = dbg_low_band_db;
        output[3] = dbg_mid_band_db;
        output[4] = dbg_high_band_db;
        output[5] = dbg_eq_peak_db;
        output[6] = (float)dbg_active_effects;
    }

    void setCompressorEnabled(bool enabled) { compressor_enabled = enabled; }
    void setCompressor(float threshold, float ratio, float attack, float release, float makeup) {
        compressor.setParams(threshold, ratio, attack, release, makeup, sample_rate);
    }

    void setLimiterEnabled(bool enabled) { limiter_enabled = enabled; }
    void setLimiter(float ceiling, float release) {
        limiter.setParams(ceiling, release, sample_rate);
    }

    // V9 — true bypass. Skips input attenuation, per-song pregain, all
    // effect stages, and loudness compensation; subsonic HPF, DC blocker
    // and limiter still run because they are the safety/clean-up layer.
    void setChainBypass(bool enabled) { chain_bypass = enabled; }

    void setStereoWidthEnabled(bool enabled) { stereo_width_enabled = enabled; }
    void setStereoWidth(float width) { stereo_width_target = std::clamp(width, 0.0f, 2.0f); }

    void setCrossfeedEnabled(bool enabled) { crossfeed_enabled = enabled; }
    void setCrossfeed(float amount) { crossfeed_target = std::clamp(amount, 0.0f, 1.0f); }

    void setVirtualBassEnabled(bool enabled) { virtual_bass_enabled = enabled; }
    void setVirtualBass(float amount, float freq) {
        virtual_bass_target = std::clamp(amount, 0.0f, 1.0f);
        bass_lp_l.setLowPass(freq, 0.7f, sample_rate);
        bass_lp_r.setLowPass(freq, 0.7f, sample_rate);
    }

    // Smooth setter for real-time adaptation (50ms ramp)
    void setVirtualBassSmooth(float amount) {
        virtual_bass_target = std::clamp(amount, 0.0f, 1.0f);
    }

    void setSubharmonicEnabled(bool enabled) { subharmonic_enabled = enabled; }
    void setSubharmonic(float amount) {
        subharmonic_target = std::clamp(amount, 0.0f, 1.0f);
    }

    void setTubeWarmthEnabled(bool enabled) { tube_warmth_enabled = enabled; }
    void setTubeWarmth(float amount, float drive) {
        tube_warmth_target = std::clamp(amount, 0.0f, 1.0f);
        tube_drive_target = std::clamp(drive, 0.0f, 1.0f);
    }

    void setExciterEnabled(bool enabled) { exciter_enabled = enabled; }
    void setExciter(float amount, float freq) {
        exciter_target = std::clamp(amount, 0.0f, 1.0f);
        exciter_hp_l.setHighPass(freq, 0.7f, sample_rate);
        exciter_hp_r.setHighPass(freq, 0.7f, sample_rate);
    }

    // Smooth setter for real-time adaptation (50ms ramp)
    void setExciterSmooth(float amount) {
        exciter_target = std::clamp(amount, 0.0f, 1.0f);
    }

    void setAirBandEnabled(bool enabled) { air_band_enabled = enabled; }
    void setAirBand(float amount) {
        air_band_target = std::clamp(amount, 0.0f, 1.0f);
    }

    // V8.3 — loudness compensation setters
    void setLoudnessCompEnabled(bool enabled) { loudness_comp_enabled = enabled; }
    void setLoudnessCompAmount(float amount) {
        loudness_comp_target = std::clamp(amount, 0.0f, 1.0f);
    }
    bool isLoudnessCompEnabled() const { return loudness_comp_enabled; }
    float getLoudnessCompAmount() const { return loudness_comp_target; }

    // V8.5 — per-band balance for loudness compensation. AI Tune writes these
    // from the SongAudioProfile so the curve respects what's already in the
    // mix. low_factor = 1.0 means nominal +6 dB low shelf; 0.5 halves it.
    void setLoudnessCompBalance(float low_factor, float high_factor) {
        loudness_comp_low_factor  = std::clamp(low_factor,  0.0f, 1.5f);
        loudness_comp_high_factor = std::clamp(high_factor, 0.0f, 1.5f);
    }

    // V8.5 — per-song pre-attenuation (dB, 0 or negative). Combined with the
    // effect-driven cumulative-gain budget. Use this for clipping-risk and
    // already-loud masters from SongAudioProfile.outputGainReduction.
    void setPerSongPregainDb(float db) {
        per_song_pregain_db = std::min(db, 0.0f);
    }

    // V8.7 — transient shaper setters. attack/sustain ∈ [-1, 1].
    // V9 — setters write *targets*; the engine ramps the live values over
    // 20 ms in process(). Stops the audible snap when a preset switch
    // jumps Energetic's attack=+0.30 to Pure's 0.0.
    void setTransientShaperEnabled(bool enabled) {
        transient_shaper_enabled = enabled;
        if (!enabled) {
            transient_attack_target = 0.0f;
            transient_sustain_target = 0.0f;
            transient_shaper.reset();
        }
    }
    void setTransientShaperParams(float attack, float sustain) {
        transient_attack_target  = std::clamp(attack,  -1.0f, 1.0f);
        transient_sustain_target = std::clamp(sustain, -1.0f, 1.0f);
    }

    void setReverbEnabled(bool enabled) {
        reverb_enabled = enabled;
        if (!enabled) reverb_wet_target = 0.0f;
    }
    // V9 — wet/dry targets are smoothed in process(); room_size/damping/width
    // still apply immediately (recomputing comb feedback every block is
    // expensive and these don't audibly snap on their own).
    void setReverb(float room_size, float damping, float wet, float dry, float width) {
        reverb_wet_target = wet;
        reverb_dry_target = dry;
        reverb_room_size_set = room_size;
        reverb_damping_set = damping;
        reverb_width_set = width;
        if (reverb) {
            // Apply current (not target) wet/dry so the actual change rides
            // the ramp; room_size/damping/width snap because comb state needs
            // them now.
            reverb->setParams(room_size, damping,
                              reverb_wet_current, reverb_dry_current, width);
        }
    }

    int getFFT(float* output, int fft_size) {
        if (!fft || fft_size != 2048) return 0;

        // Use pre-allocated buffer (fft_input_buffer) instead of per-call allocation
        for (int i = 0; i < 2048; i++) {
            fft_input_buffer[i] = fft_buffer[(fft_write_pos + i) % 2048];
        }

        fft->forward(fft_input_buffer.data(), fft_output.data());
        fft->magnitude(fft_output.data(), output, fft_size / 2);

        return fft_size / 2;
    }

    void getLevels(float* left_db, float* right_db) {
        *left_db = linear_to_db(level_l);
        *right_db = linear_to_db(level_r);
    }

    void getPeaks(float* left_db, float* right_db) {
        *left_db = linear_to_db(peak_hold_l);
        *right_db = linear_to_db(peak_hold_r);
    }

    void resetPeaks() {
        peak_hold_l = 0;
        peak_hold_r = 0;
    }

    // ============ Device Profile Types ============
    enum class DeviceProfile {
        HEADPHONES_WIRED,
        HEADPHONES_BLUETOOTH,
        SPEAKER_PHONE,
        SPEAKER_EXTERNAL,
        USB_DAC,
        DEFAULT
    };

    DeviceProfile current_profile = DeviceProfile::DEFAULT;

    /**
     * Apply a device-specific audio profile.
     * Different output devices need different processing.
     *
     * This is called from Kotlin when output device changes or Smart Enhance is enabled.
     */
    void applyDeviceProfile(int profile_id) {
        DeviceProfile profile = static_cast<DeviceProfile>(profile_id);
        current_profile = profile;

        switch (profile) {
            case DeviceProfile::HEADPHONES_WIRED:
                applyHeadphonesWiredProfile();
                break;
            case DeviceProfile::HEADPHONES_BLUETOOTH:
                applyHeadphonesBluetoothProfile();
                break;
            case DeviceProfile::SPEAKER_PHONE:
                applySpeakerPhoneProfile();
                break;
            case DeviceProfile::SPEAKER_EXTERNAL:
                applySpeakerExternalProfile();
                break;
            case DeviceProfile::USB_DAC:
                applyUSBDACProfile();
                break;
            default:
                applyDefaultProfile();
                break;
        }
    }

    /**
     * Wired Headphones Profile - Full processing, crossfeed beneficial
     * V7: Transparent limiting, clean effects
     */
    void applyHeadphonesWiredProfile() {
        // Bass: Warm low end without excess gain
        setVirtualBassEnabled(true);
        setVirtualBass(0.35f, 100);
        setSubharmonicEnabled(true);
        setSubharmonic(0.18f);

        // Spatial: Natural soundstage with speaker-like crossfeed
        setStereoWidthEnabled(true);
        setStereoWidth(1.15f);
        setCrossfeedEnabled(true);
        setCrossfeed(0.22f);

        // Coloration: Subtle analog warmth
        setTubeWarmthEnabled(true);
        setTubeWarmth(0.25f, 0.20f);

        // Highs: Gentle presence and air
        setExciterEnabled(true);
        setExciter(0.22f, 4000);
        setAirBandEnabled(true);
        setAirBand(0.25f);

        // Dynamics: Transparent limiter — input attenuation handles gain staging
        setCompressorEnabled(false);
        setLimiterEnabled(true);
        setLimiter(-1.5f, 100);
    }

    /**
     * Bluetooth Headphones Profile - Account for codec compression
     * V7: Transparent limiting, clean effects
     */
    void applyHeadphonesBluetoothProfile() {
        // Bass: Compensate BT low-end rolloff
        setVirtualBassEnabled(true);
        setVirtualBass(0.40f, 100);
        setSubharmonicEnabled(true);
        setSubharmonic(0.18f);

        // Spatial: Soundstage with crossfeed
        setStereoWidthEnabled(true);
        setStereoWidth(1.15f);
        setCrossfeedEnabled(true);
        setCrossfeed(0.20f);

        // Coloration: Warmth to counter BT harshness
        setTubeWarmthEnabled(true);
        setTubeWarmth(0.28f, 0.20f);

        // Highs: Compensate BT high-frequency rolloff
        setExciterEnabled(true);
        setExciter(0.25f, 4500);
        setAirBandEnabled(true);
        setAirBand(0.28f);

        // Dynamics: Transparent limiter — input attenuation handles gain staging
        setCompressorEnabled(false);
        setLimiterEnabled(true);
        setLimiter(-1.5f, 100);
    }

    /**
     * Phone Speaker Profile - Optimized for tiny drivers
     * V7: Transparent limiting, clean effects
     */
    void applySpeakerPhoneProfile() {
        // Bass: Psychoacoustic bass for tiny speakers
        setVirtualBassEnabled(true);
        setVirtualBass(0.50f, 150);
        setSubharmonicEnabled(false);     // Speaker can't reproduce sub-bass

        // Spatial: Narrow for mono compatibility
        setStereoWidthEnabled(true);
        setStereoWidth(0.95f);
        setCrossfeedEnabled(false);

        // Coloration: Warm character to tame harsh phone speakers
        setTubeWarmthEnabled(true);
        setTubeWarmth(0.25f, 0.20f);

        // Highs: Controlled (phone speakers can be harsh)
        setExciterEnabled(false);
        setAirBandEnabled(true);
        setAirBand(0.15f);

        // Dynamics: Gentle compression for tiny speaker
        setCompressorEnabled(true);
        setCompressor(-16.0f, 2.5f, 20.0f, 150.0f, 1.5f);
        setLimiterEnabled(true);
        setLimiter(-1.5f, 80);
    }

    /**
     * External Speaker Profile - Full range, room filling
     * V7: Transparent limiting, clean effects
     */
    void applySpeakerExternalProfile() {
        // Bass: Full low end
        setVirtualBassEnabled(true);
        setVirtualBass(0.35f, 100);
        setSubharmonicEnabled(true);
        setSubharmonic(0.20f);

        // Spatial: Natural wide stereo
        setStereoWidthEnabled(true);
        setStereoWidth(1.12f);
        setCrossfeedEnabled(false);

        // Coloration: Subtle warmth
        setTubeWarmthEnabled(true);
        setTubeWarmth(0.22f, 0.18f);

        // Highs: Presence and sparkle
        setExciterEnabled(true);
        setExciter(0.20f, 4500);
        setAirBandEnabled(true);
        setAirBand(0.22f);

        // Dynamics: Gentle compression for room fill
        setCompressorEnabled(true);
        setCompressor(-18.0f, 2.0f, 25.0f, 150.0f, 1.5f);
        setLimiterEnabled(true);
        setLimiter(-1.5f, 100);
    }

    /**
     * USB DAC Profile - Audiophile mode with refined enhancement
     * V7: Transparent limiting, clean effects
     */
    void applyUSBDACProfile() {
        // Bass: Subtle warmth
        setVirtualBassEnabled(true);
        setVirtualBass(0.18f, 80);
        setSubharmonicEnabled(false);

        // Spatial: Natural with refined crossfeed
        setStereoWidthEnabled(true);
        setStereoWidth(1.05f);
        setCrossfeedEnabled(true);
        setCrossfeed(0.18f);

        // Coloration: Refined analog warmth
        setTubeWarmthEnabled(true);
        setTubeWarmth(0.18f, 0.15f);

        // Highs: Subtle detail enhancement
        setExciterEnabled(true);
        setExciter(0.15f, 5000);
        setAirBandEnabled(true);
        setAirBand(0.15f);

        // Dynamics: Transparent limiter
        setCompressorEnabled(false);
        setLimiterEnabled(true);
        setLimiter(-1.0f, 150);
    }

    /**
     * Default/Fallback Profile - Rich enhancement
     * V7: Transparent limiting, clean effects
     */
    void applyDefaultProfile() {
        // Bass: Warm low end
        setVirtualBassEnabled(true);
        setVirtualBass(0.30f, 100);
        setSubharmonicEnabled(true);
        setSubharmonic(0.15f);

        // Spatial: Slight enhancement
        setStereoWidthEnabled(true);
        setStereoWidth(1.10f);
        setCrossfeedEnabled(false);

        // Coloration: Subtle warmth
        setTubeWarmthEnabled(true);
        setTubeWarmth(0.22f, 0.18f);

        // Highs: Gentle presence
        setExciterEnabled(true);
        setExciter(0.20f, 4500);
        setAirBandEnabled(true);
        setAirBand(0.22f);

        // Dynamics: Transparent limiter — input attenuation handles gain staging
        setCompressorEnabled(false);
        setLimiterEnabled(true);
        setLimiter(-1.5f, 100);
    }

    /**
     * Disable all processing - true bypass
     */
    void disableAllProcessing() {
        setVirtualBassEnabled(false);
        setSubharmonicEnabled(false);
        setStereoWidthEnabled(false);
        setStereoWidth(1.0f);
        setCrossfeedEnabled(false);
        setTubeWarmthEnabled(false);
        setExciterEnabled(false);
        setAirBandEnabled(false);
        setCompressorEnabled(false);
        setLimiterEnabled(false);
        eq_enabled = false;
        reverb_enabled = false;
    }

    void setSmartEnhance(bool enabled, float intensity) {
        // Smart Enhance V3 - Device-aware processing
        // intensity is now just for future use (e.g., "gentle" vs "aggressive" presets)
        intensity = std::clamp(intensity, 0.0f, 1.0f);

        if (enabled) {
            // Apply current device profile (set by Kotlin side)
            // If no profile was set, use default
            if (current_profile == DeviceProfile::DEFAULT) {
                applyDefaultProfile();
            }
            // Profile already applied by applyDeviceProfile()
        } else {
            disableAllProcessing();
        }
    }

    bool hasSIMD() const {
#if USE_NEON || USE_SSE
        return true;
#else
        return false;
#endif
    }

private:
    bool initialized = false;
    int sample_rate = 44100;
    int channels = 2;
    int buffer_size = 1024;

    // V9 — true chain bypass. When true, process() runs only the load-bearing
    // pre/post stages (20 Hz subsonic HPF → DC blocker → limiter). All effects,
    // input attenuation, per-song pregain, and loudness compensation are
    // skipped entirely. The "Pure" preset uses this so it's a genuine
    // reference rather than effects-with-zero-amount.
    bool chain_bypass = false;

    // EQ
    bool eq_enabled = false;
    // Loudness normalisation gain (linear), see the call site in process().
    // One-pole smoothing at roughly 20 ms so a track change ramps rather than
    // steps.
    static constexpr float kNormGainSmoothing = 0.0005f;
    float norm_gain_target_ = 1.0f;
    float norm_gain_current_ = 1.0f;

    // Output high-pass, set from the current output device. 0 Hz = off.
    BiquadFilter output_hp_l_, output_hp_r_;
    float output_hp_freq_ = 0.0f;
    bool output_hp_active_ = false;

    // Listener-preference tilt. Separate from the correction bands on purpose
    // — see processPreferenceTilt.
    BiquadFilter pref_bass_l_, pref_bass_r_;
    BiquadFilter pref_treble_l_, pref_treble_r_;
    float preference_bass_db_ = 0.0f;
    float preference_treble_db_ = 0.0f;
    bool preference_tilt_active_ = false;

    BiquadFilter eq_bands_l[EQ_BANDS];
    BiquadFilter eq_bands_r[EQ_BANDS];
    float eq_freqs_[EQ_BANDS];
    float eq_gains_[EQ_BANDS];
    float eq_gains_target_[EQ_BANDS];  // Target for smooth ramping
    bool eq_smooth_pending_ = false;   // Whether smooth EQ transition is active

    // Per-band Q. Defaults to 1.0 (the old hardcoded value), which keeps the
    // 10-band graphic behaviour identical for EQ presets and manual use.
    //
    // It exists so headphone correction can be reproduced properly. AutoEQ
    // profiles are parametric — "+3.2 dB at 5500 Hz, Q 1.80" — and squashing
    // them onto fixed frequencies with a fixed Q both misplaces the correction
    // and flattens it. Profiles here use 6-8 bands, so with per-band frequency
    // and Q they map onto the 10 slots exactly, with nothing approximated.
    float eq_q_[EQ_BANDS];

    // Per-band filter type. Real headphone corrections are not peaking-only:
    // an AutoEQ profile typically opens with a low shelf and closes with a
    // high shelf, e.g. for the Sony WH-1000XM5:
    //
    //   Filter 1:  LSC  Fc 105 Hz    Gain -3.2 dB  Q 0.70
    //   Filter 6:  HSC  Fc 10000 Hz  Gain +4.9 dB  Q 0.70
    //
    // Rendering those as peaking filters is not an approximation, it is a
    // different correction: a shelf lifts or cuts everything beyond its corner,
    // a peak only touches a band around it. Getting the two shelves wrong
    // leaves the entire bottom and top of the response uncorrected.
    float eq_type_[EQ_BANDS];   // see kEQType* below

    // Dynamics
    bool compressor_enabled = false;
    Compressor compressor;
    bool limiter_enabled = false;
    Limiter limiter;

    // V8.3 — loudness compensation (Fletcher-Munson / ISO 226). Off by default;
    // amount comes from the host (typically driven by playback volume so quiet
    // listening gets more compensation than loud listening).
    bool loudness_comp_enabled = false;
    float loudness_comp_amount = 0.0f;
    float loudness_comp_target = 0.0f;
    // V8.5 — per-band balance factors so the song profile can shape the
    // compensation: a bass-heavy song doesn't need more bass; a bright song
    // doesn't need more air. AI Tune writes these from the SongAudioProfile.
    float loudness_comp_low_factor = 1.0f;
    float loudness_comp_high_factor = 1.0f;
    LoudnessCompensation loudness_comp;

    // V8.5 — per-song pre-attenuation in dB (always ≤ 0). AI Tune writes this
    // from `SongAudioProfile.outputGainReduction` when a track is at risk of
    // clipping (truePeak > 0.995) or already loud (LUFS > -8). Combined with
    // the effect-driven cumulative-gain attenuation in process() so peaks
    // never reach the limiter at full level.
    float per_song_pregain_db = 0.0f;

    // V8.4 — anti-alias 2× oversampler shared by tube warmth and exciter
    // saturators. One instance is enough because the saturators run
    // sequentially in the chain (filter state carries between them).
    Oversampler2x oversampler;

    // V8.7 — transient shaper (separate attack and sustain control). Off by
    // default; host enables and sets attack/sustain ∈ [-1, 1] per taste.
    // V9 — parameter targets get smoothed over a 20 ms ramp so preset
    // changes don't audibly "snap" the transient shaping. The actual
    // setParams() call is driven from those smoothed currents each block.
    bool transient_shaper_enabled = false;
    TransientShaper transient_shaper;
    float transient_attack_current = 0.0f, transient_attack_target = 0.0f;
    float transient_sustain_current = 0.0f, transient_sustain_target = 0.0f;

    // V9 — reverb wet/dry levels ramp toward target over 20 ms. Other
    // reverb params (room_size, damping, width) still apply immediately
    // because they recompute comb feedback / lowpass state — ramping them
    // would require recomputing inner-filter coeffs every block, which is
    // expensive and inaudible benefit. wet/dry are simple mix scalars and
    // are the user-toggled ones, so smoothing them eliminates the "snap"
    // when the Immersive ↔ Pure transition pulls reverb in/out.
    float reverb_wet_current = 0.0f, reverb_wet_target = 0.0f;
    float reverb_dry_current = 1.0f, reverb_dry_target = 1.0f;
    float reverb_room_size_set = 0.5f;
    float reverb_damping_set = 0.5f;
    float reverb_width_set = 1.0f;

    // V8.4 — scratch buffers used by oversampled saturators to hold the
    // pre-mix wet path so the dry signal isn't double-filtered.
    std::vector<float> scratch_l_;
    std::vector<float> scratch_r_;
    // Dry snapshot of the high-passed signal, used by the exciter to extract
    // "saturated - dry" harmonics. Pre-allocated members rather than
    // block-local vectors: constructing a std::vector inside the audio
    // callback can hit the allocator, and malloc is not real-time safe —
    // lock contention or a page fault there shows up as an audible dropout.
    std::vector<float> dry_hp_l_;
    std::vector<float> dry_hp_r_;

    // Spatial
    bool stereo_width_enabled = false;
    float stereo_width = 1.0f;
    float stereo_width_target = 1.0f;
    bool crossfeed_enabled = false;
    float crossfeed_amount = 0.3f;
    float crossfeed_target = 0.3f;
    BiquadFilter crossfeed_lp_l;  // Separate filters for L and R
    BiquadFilter crossfeed_lp_r;

    // Interaural time delay on the crossfeed path.
    //
    // Audio Engineering (Sinclair), §25.2.2 "Cross-Blending": the head has two
    // effects on the far-ear signal — it baffles high frequencies AND it
    // introduces a time delay. Circuits that add the delay on top of the HF
    // absorption are "reported to be more effective, lending a more natural
    // out-of-the-head sound". Figure 25.1 shows the signal path as
    // filter -> delay. We previously implemented only the filter.
    //
    // ITD for a source at ±30° (the standard stereo triangle), Woodworth
    // spherical-head model:  t = (r/c)(θ + sin θ)
    //   r = 0.0875 m (half a 17.5 cm head), c = 343 m/s, θ = 30° = 0.5236 rad
    //   t = (0.0875/343)(0.5236 + 0.5) ≈ 261 µs   (~12.5 samples @ 48 kHz)
    static constexpr int kCrossfeedDelayCap  = 64;  // power of two, 1.33 ms @ 48 kHz
    static constexpr int kCrossfeedDelayMask = kCrossfeedDelayCap - 1;
    static constexpr float kCrossfeedITDSeconds = 0.000261f;

    /// Corner of the head-shadow low-pass, and of the matching compensation
    /// shelf on the direct path. The two must agree or the correction lands in
    /// the wrong place.
    static constexpr float kCrossfeedCornerHz = 800.0f;

    // Direct-path compensation — see processCrossfeed.
    BiquadFilter crossfeed_comp_l_, crossfeed_comp_r_;
    float crossfeed_comp_amount_ = -1.0f;   // forces a build on first use
    float crossfeed_norm_ = 1.0f;
    float crossfeed_delay_l[kCrossfeedDelayCap] = {0.0f};
    float crossfeed_delay_r[kCrossfeedDelayCap] = {0.0f};
    int crossfeed_delay_pos = 0;
    int crossfeed_delay_samples = 0;

    // Bass
    bool virtual_bass_enabled = false;
    float virtual_bass_amount = 0.5f;
    float virtual_bass_target = 0.5f;  // Target for smooth ramping
    BiquadFilter bass_lp_l;
    BiquadFilter bass_lp_r;
    BiquadFilter bass_bp_l;
    BiquadFilter bass_bp_r;

    bool subharmonic_enabled = false;
    float subharmonic_amount = 0.3f;
    float subharmonic_target = 0.3f;
    EnvelopeFollower bass_env;
    float sub_osc_phase = 0;
    float sub_osc_phase_inc = 0;
    float sub_osc_freq = 40.0f;
    // V6: Pitch tracking state
    float sub_prev_sample = 0.0f;
    int sub_samples_since_zc = 0;
    int sub_zc_count = 0;

    // Harmonics
    bool tube_warmth_enabled = false;
    float tube_warmth_amount = 0.3f;
    float tube_warmth_target = 0.3f;
    float tube_drive = 0.3f;
    float tube_drive_target = 0.3f;

    bool exciter_enabled = false;
    float exciter_amount = 0.2f;
    float exciter_target = 0.2f;  // Target for smooth ramping
    BiquadFilter exciter_hp_l;
    BiquadFilter exciter_hp_r;

    // Parameter smoothing coefficient (50ms ramp at 44.1kHz)
    float param_smooth_coeff = 0.999f;  // Calculated in init()

    bool air_band_enabled = false;
    float air_band_amount = 0.3f;
    float air_band_target = 0.3f;
    BiquadFilter air_hp_l;
    BiquadFilter air_hp_r;

    // Subsonic filter (20Hz HPF - removes subsonic energy before effects)
    BiquadFilter subsonic_hpf_l;
    BiquadFilter subsonic_hpf_r;

    // DC blocking
    DCBlocker dc_blocker_l;
    DCBlocker dc_blocker_r;

    // Reverb
    bool reverb_enabled = false;
    std::unique_ptr<Reverb> reverb;

    // FFT
    std::unique_ptr<FFT> fft;
    std::vector<float> fft_buffer;
    std::vector<float> fft_input_buffer;  // Pre-allocated for getFFT()
    std::vector<std::complex<float>> fft_output;
    std::vector<float> fft_magnitudes;
    int fft_write_pos = 0;

    // Meters
    float level_l = 0, level_r = 0;
    float peak_hold_l = 0, peak_hold_r = 0;

    // Debug info (written in process(), read by nagare_get_gain_debug())
    float dbg_low_band_db = 0;
    float dbg_mid_band_db = 0;
    float dbg_high_band_db = 0;
    float dbg_eq_peak_db = 0;
    float dbg_cumulative_gain_db = 0;
    float dbg_attenuation_db = 0;
    int   dbg_active_effects = 0;

    // Pre-allocated processing buffers (avoids allocation in hot path)
    std::vector<float> proc_left;
    std::vector<float> proc_right;
    int proc_buffer_size = 0;
};

// ============================================================================
// Global Instance
// ============================================================================

static DSPEngine g_engine;
static bool g_initialized = false;

} // namespace nagare

// ============================================================================
// C API Implementation
// ============================================================================

extern "C" {

int nagare_init(int sample_rate, int channels, int buffer_size) {
    if (nagare::g_initialized) {
        // V7: Support re-initialization for different sample rates.
        // All biquad filter coefficients depend on sample rate — without reinit,
        // filter frequencies are wrong when switching between songs at different rates.
        nagare::g_engine.release();
        nagare::g_initialized = false;
    }
    nagare::g_engine.init(sample_rate, channels, buffer_size);
    nagare::g_initialized = true;
    return 0;
}

void nagare_release(void) {
    if (!nagare::g_initialized) return;
    nagare::g_engine.release();
    nagare::g_initialized = false;
}

const char* nagare_version(void) {
    return "Nagare DSP 9.2.0";  // V9.2: reverted V9.1 cubic-Hermite true-peak (caused low-volume distortion); loudness comp default on; dynamic version readout in Settings
}

// Apply device-specific audio profile
// profile_id: 0=HEADPHONES_WIRED, 1=HEADPHONES_BLUETOOTH, 2=SPEAKER_PHONE,
//             3=SPEAKER_EXTERNAL, 4=USB_DAC, 5=DEFAULT
void nagare_apply_device_profile(int profile_id) {
    nagare::g_engine.applyDeviceProfile(profile_id);
}

// Disable all processing (true bypass)
void nagare_disable_all(void) {
    nagare::g_engine.disableAllProcessing();
}

bool nagare_has_simd(void) {
    return nagare::g_engine.hasSIMD();
}

void nagare_process(const float* input, float* output, int num_samples) {
    if (!nagare::g_initialized) return;
    nagare::g_engine.process(input, output, num_samples);
}

void nagare_process_inplace(float* samples, int num_samples) {
    nagare_process(samples, samples, num_samples);
}

// EQ
void nagare_eq_enable(bool enabled) {
    nagare::g_engine.setEQEnabled(enabled);
}

void nagare_eq_set_band(int band, float gain_db) {
    nagare::g_engine.setEQBand(band, gain_db);
}

void nagare_eq_set_bands(const float* gains) {
    for (int i = 0; i < nagare::EQ_BANDS; i++) {
        nagare::g_engine.setEQBand(i, gains[i]);
    }
}

void nagare_eq_set_bands_smooth(const float* gains) {
    nagare::g_engine.setEQBandsSmooth(gains);
}

void nagare_eq_set_band_params(int band, float freq, float gain_db, float q) {
    // Previously this discarded `freq` and `q` and only set the gain, which
    // made the documented parametric API a no-op — headphone corrections were
    // being folded onto fixed centres at Q=1 and losing both their placement
    // and their depth. Now it does what the header says.
    nagare::g_engine.setEQBandParams(band, freq, gain_db, q, nagare::kEQTypePeaking);
}

void nagare_set_preference_tilt(float bass_db, float treble_db) {
    nagare::g_engine.setPreferenceTilt(bass_db, treble_db);
}

void nagare_set_output_highpass(float freq_hz) {
    nagare::g_engine.setOutputHighPass(freq_hz);
}

void nagare_set_normalization_gain(float gain_db, int snap) {
    nagare::g_engine.setNormalizationGain(gain_db);
    if (snap) nagare::g_engine.snapNormalizationGain();
}

void nagare_eq_set_band_full(int band, float freq, float gain_db, float q, int type) {
    nagare::g_engine.setEQBandParams(band, freq, gain_db, q, type);
}

void nagare_eq_reset_band_layout(void) {
    nagare::g_engine.resetEQBandLayout();
}

// Compressor
void nagare_compressor_enable(bool enabled) {
    nagare::g_engine.setCompressorEnabled(enabled);
}

void nagare_compressor_set(float threshold, float ratio, float attack, float release, float makeup_gain) {
    nagare::g_engine.setCompressor(threshold, ratio, attack, release, makeup_gain);
}

// Limiter
void nagare_limiter_enable(bool enabled) {
    nagare::g_engine.setLimiterEnabled(enabled);
}

void nagare_limiter_set(float ceiling, float release) {
    nagare::g_engine.setLimiter(ceiling, release);
}

// V9 — true chain bypass (Pure preset reference path).
void nagare_chain_bypass(bool enabled) {
    nagare::g_engine.setChainBypass(enabled);
}

// Spatial
void nagare_stereo_width_enable(bool enabled) {
    nagare::g_engine.setStereoWidthEnabled(enabled);
}

void nagare_stereo_width_set(float width) {
    nagare::g_engine.setStereoWidth(width);
}

void nagare_crossfeed_enable(bool enabled) {
    nagare::g_engine.setCrossfeedEnabled(enabled);
}

void nagare_crossfeed_set(float amount) {
    nagare::g_engine.setCrossfeed(amount);
}

// Bass
void nagare_virtual_bass_enable(bool enabled) {
    nagare::g_engine.setVirtualBassEnabled(enabled);
}

void nagare_virtual_bass_set(float amount, float frequency) {
    nagare::g_engine.setVirtualBass(amount, frequency);
}

// Smooth setter for real-time adaptation (50ms ramp)
void nagare_virtual_bass_set_smooth(float amount) {
    nagare::g_engine.setVirtualBassSmooth(amount);
}

void nagare_subharmonic_enable(bool enabled) {
    nagare::g_engine.setSubharmonicEnabled(enabled);
}

void nagare_subharmonic_set(float amount) {
    nagare::g_engine.setSubharmonic(amount);
}

// Harmonics
void nagare_tube_warmth_enable(bool enabled) {
    nagare::g_engine.setTubeWarmthEnabled(enabled);
}

void nagare_tube_warmth_set(float amount, float drive) {
    nagare::g_engine.setTubeWarmth(amount, drive);
}

void nagare_exciter_enable(bool enabled) {
    nagare::g_engine.setExciterEnabled(enabled);
}

void nagare_exciter_set(float amount, float frequency) {
    nagare::g_engine.setExciter(amount, frequency);
}

// Smooth setter for real-time adaptation (50ms ramp)
void nagare_exciter_set_smooth(float amount) {
    nagare::g_engine.setExciterSmooth(amount);
}

void nagare_air_band_enable(bool enabled) {
    nagare::g_engine.setAirBandEnabled(enabled);
}

void nagare_air_band_set(float amount) {
    nagare::g_engine.setAirBand(amount);
}

// Reverb
void nagare_reverb_enable(bool enabled) {
    nagare::g_engine.setReverbEnabled(enabled);
}

void nagare_reverb_set(float room_size, float damping, float wet_level, float dry_level, float width) {
    nagare::g_engine.setReverb(room_size, damping, wet_level, dry_level, width);
}

// V8.3 — Loudness compensation (Fletcher-Munson / ISO 226).
// Caller is expected to set amount = 1 - playback_volume so the boost grows
// as the listener turns the volume down. amount ∈ [0, 1].
void nagare_loudness_comp_enable(bool enabled) {
    nagare::g_engine.setLoudnessCompEnabled(enabled);
}

void nagare_loudness_comp_set(float amount) {
    nagare::g_engine.setLoudnessCompAmount(amount);
}

// V8.5 — per-band balance + per-song pre-attenuation
void nagare_loudness_comp_set_balance(float low_factor, float high_factor) {
    nagare::g_engine.setLoudnessCompBalance(low_factor, high_factor);
}

void nagare_per_song_pregain_set(float db) {
    nagare::g_engine.setPerSongPregainDb(db);
}

// V8.7 — Transient Shaper
void nagare_transient_shaper_enable(bool enabled) {
    nagare::g_engine.setTransientShaperEnabled(enabled);
}

void nagare_transient_shaper_set(float attack, float sustain) {
    nagare::g_engine.setTransientShaperParams(attack, sustain);
}

// FFT
int nagare_get_fft(float* output, int fft_size) {
    return nagare::g_engine.getFFT(output, fft_size);
}

void nagare_get_bands(float* bands, int num_bands) {
    float fft[1024];
    int bins = nagare::g_engine.getFFT(fft, 2048);
    if (bins == 0) return;

    // V6: Logarithmic band binning (Bark-scale inspired)
    // Each band covers a frequency range that doubles (approximately)
    // giving more resolution to bass and less to treble, matching human hearing
    for (int b = 0; b < num_bands; b++) {
        // Logarithmic bin boundaries: bin = bins * (2^(b/num_bands) - 1) / (2^1 - 1)
        float frac_lo = (std::pow(2.0f, static_cast<float>(b) / num_bands) - 1.0f);
        float frac_hi = (std::pow(2.0f, static_cast<float>(b + 1) / num_bands) - 1.0f);
        int bin_lo = static_cast<int>(frac_lo * bins);
        int bin_hi = static_cast<int>(frac_hi * bins);
        bin_lo = std::clamp(bin_lo, 0, bins - 1);
        bin_hi = std::clamp(bin_hi, bin_lo + 1, bins);

        float sum = 0;
        int count = bin_hi - bin_lo;
        for (int i = bin_lo; i < bin_hi; i++) {
            sum += fft[i];
        }
        bands[b] = (count > 0) ? sum / count : 0.0f;
    }
}

// Meters
void nagare_get_levels(float* left_db, float* right_db) {
    nagare::g_engine.getLevels(left_db, right_db);
}

void nagare_get_peaks(float* left_db, float* right_db) {
    nagare::g_engine.getPeaks(left_db, right_db);
}

void nagare_reset_peaks(void) {
    nagare::g_engine.resetPeaks();
}

// Smart Enhance
void nagare_smart_enhance_enable(bool enabled) {
    nagare::g_engine.setSmartEnhance(enabled, 1.0f);
}

void nagare_smart_enhance_set_intensity(float intensity) {
    nagare::g_engine.setSmartEnhance(true, intensity);
}

void nagare_get_gain_debug(float* output, int max_values) {
    nagare::g_engine.getGainDebug(output, max_values);
}

} // extern "C"
