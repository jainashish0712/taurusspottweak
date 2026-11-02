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
 * Polyphase FIR resampler.
 *
 * Why this exists
 * ---------------
 * AudioTrack was being opened at each file's own sample rate. On a device
 * whose output clock runs at 48 kHz — which is nearly all of them — that means
 * AudioFlinger resamples every 44.1 kHz track itself, inside the system mixer,
 * after the app has finished with it. The whole DSP chain runs at high quality
 * and the last, most destructive conversion happens somewhere we cannot reach
 * or measure.
 *
 * Doing the conversion here instead means:
 *   - we choose the quality, not the platform
 *   - AudioTrack can be opened at the device's native rate, so the system
 *     resampler is bypassed entirely (rates match, samples pass through)
 *   - it is a precondition for AAudio EXCLUSIVE mode, which locks the output
 *     to the device rate
 *
 * Design
 * ------
 * Rational L/M conversion by polyphase decomposition of a windowed-sinc
 * low-pass. 44100 -> 48000 reduces to 147:160.
 *
 * Conceptually: upsample by L (zero-stuff), low-pass, decimate by M. Done
 * directly that is enormously wasteful — the filter would run at L times the
 * sample rate and multiply mostly by zeros. Polyphase decomposition splits the
 * prototype filter into L sub-filters and evaluates only the one whose phase is
 * needed for each output sample, so cost is taps-per-phase multiply-accumulates
 * per output sample regardless of L.
 *
 * The prototype is a Kaiser-windowed sinc. Kaiser is used because beta gives
 * direct control of the stopband: beta 10 lands near -100 dB, which puts
 * aliasing well below the noise floor of any 16-bit source.
 *
 * Cutoff sits at 0.5 * min(1/L, 1/M) scaled by kCutoffScale, i.e. slightly
 * below the lower Nyquist of the two rates, leaving a transition band so the
 * passband stays flat to ~20 kHz on a 44.1 kHz source.
 */

#ifndef POLYPHASE_RESAMPLER_H
#define POLYPHASE_RESAMPLER_H

#include <vector>

namespace nagare {

class PolyphaseResampler {
public:
    /// Taps evaluated per output sample, per channel. Each phase's sub-filter
    /// runs at the *input* rate, so this is effectively the filter length in
    /// input samples — which is what sets the transition width.
    ///
    /// 44.1 -> 48 kHz is a demanding case: the passband must stay flat to
    /// 20 kHz while the stopband starts at the 22.05 kHz Nyquist, a transition
    /// of only ~2 kHz. For a Kaiser window the required length is roughly
    /// (A - 8) / (2.285 * 2*pi * df), which for 100 dB over 2 kHz at 44.1 kHz
    /// comes to about 128 taps. 32 was far too few — the transition sprawled
    /// down into the audible band and dulled everything above 5 kHz.
    ///
    /// 128 MACs per sample per channel is ~12M MAC/s at 48 kHz stereo, which
    /// is negligible beside the effect chain in front of it.
    static constexpr int kTapsPerPhase = 128;

    /// Kaiser beta. Higher is more stopband rejection and a wider transition.
    /// 10 lands near -100 dB.
    static constexpr double kKaiserBeta = 10.0;

    /// Cutoff as a fraction of the lower Nyquist, placing the -6 dB point just
    /// under 21 kHz for a 44.1 kHz source. Combined with the tap count above
    /// that keeps the passband flat through 20 kHz and puts the stopband at
    /// the Nyquist.
    static constexpr double kCutoffScale = 0.95;

    PolyphaseResampler() = default;

    /// Prepare for in_rate -> out_rate on `channels` interleaved channels.
    /// Safe to call repeatedly; rebuilds only when the configuration changes.
    /// Returns false if the arguments are unusable.
    bool init(int in_rate, int out_rate, int channels);

    /// True when a conversion is actually required. When the rates already
    /// match, callers should skip this stage entirely rather than run a
    /// pass-through — an identity FIR is still an FIR.
    bool isActive() const { return active_; }

    int inputRate() const { return in_rate_; }
    int outputRate() const { return out_rate_; }

    /// Largest number of output frames `process` can emit for `in_frames`.
    /// Use it to size the destination buffer.
    int maxOutputFrames(int in_frames) const;

    /// Convert `in_frames` interleaved frames. Returns frames written to `out`.
    /// Filter state carries across calls, so block boundaries are seamless.
    int process(const float* in, int in_frames, float* out, int max_out_frames);

    /// Drop filter history. Call on seek or track change so the tail of the
    /// previous audio cannot bleed into the next.
    void reset();

private:
    void buildKernel();

    bool active_ = false;
    int in_rate_ = 0;
    int out_rate_ = 0;
    int channels_ = 0;

    int L_ = 1;              // interpolation factor (out_rate / gcd)
    int M_ = 1;              // decimation factor  (in_rate  / gcd)

    // Polyphase kernel, L phases of kTapsPerPhase coefficients.
    std::vector<float> phases_;      // size L_ * kTapsPerPhase

    // Per-channel delay line of the most recent input samples.
    std::vector<float> history_;     // size channels_ * kTapsPerPhase
    int hist_pos_ = 0;

    // Position of the next output sample on the upsampled grid, expressed
    // relative to the newest input sample. Kept in [0, L) by subtracting L as
    // each input frame is consumed, so it never grows and never drifts.
    int acc_ = 0;
};

} // namespace nagare

// ---------------------------------------------------------------------------
// C API for the JNI layer.
//
// A single process-wide instance, matching how the rest of the DSP is exposed.
// Threading contract, which the caller must honour:
//
//   nagare_resampler_init   — control thread, only while the playback loop is
//                             stopped. It reallocates the kernel and history,
//                             which cannot be done under a running audio
//                             thread.
//   nagare_resampler_process— audio thread only.
//   nagare_resampler_reset  — any thread, at any time. It does not touch the
//                             buffers directly; it raises a flag that the
//                             audio thread acts on at the top of its next
//                             process() call. Seeks arrive from the UI thread
//                             mid-playback, so a direct memset there would be
//                             a data race on the history ring.
// ---------------------------------------------------------------------------
extern "C" {

/// Returns 1 if a conversion is needed, 0 if the rates match (caller should
/// skip the stage), -1 on bad arguments.
int nagare_resampler_init(int in_rate, int out_rate, int channels);

int nagare_resampler_is_active();

/// Upper bound on frames `process` can emit; size the output buffer with this.
int nagare_resampler_max_output_frames(int in_frames);

/// Returns frames written. Audio thread only.
int nagare_resampler_process(const float* in, int in_frames,
                             float* out, int max_out_frames);

/// Request that filter history be dropped before the next block. Safe from
/// any thread.
void nagare_resampler_reset();

} // extern "C"

#endif // POLYPHASE_RESAMPLER_H
