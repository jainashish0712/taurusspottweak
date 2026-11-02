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

#include "polyphase_resampler.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <numeric>

namespace nagare {

namespace {

constexpr double kPi = 3.14159265358979323846;

/// Zeroth-order modified Bessel function of the first kind, for the Kaiser
/// window. The series converges quickly for the beta range we use.
double besselI0(double x) {
    double sum = 1.0;
    double term = 1.0;
    const double half_x_sq = (x * x) * 0.25;
    for (int k = 1; k < 64; ++k) {
        term *= half_x_sq / (double(k) * double(k));
        sum += term;
        if (term < sum * 1e-16) break;
    }
    return sum;
}

double sinc(double x) {
    if (std::fabs(x) < 1e-12) return 1.0;
    const double pix = kPi * x;
    return std::sin(pix) / pix;
}

} // namespace

bool PolyphaseResampler::init(int in_rate, int out_rate, int channels) {
    if (in_rate <= 0 || out_rate <= 0 || channels <= 0 || channels > 2) {
        active_ = false;
        return false;
    }

    // Already configured this way — keep the running state.
    if (in_rate == in_rate_ && out_rate == out_rate_ && channels == channels_) {
        return true;
    }

    in_rate_ = in_rate;
    out_rate_ = out_rate;
    channels_ = channels;

    if (in_rate == out_rate) {
        // Nothing to do. Callers check isActive() and skip the stage, so we
        // never spend cycles convolving a signal with an identity kernel.
        active_ = false;
        phases_.clear();
        history_.clear();
        return true;
    }

    const int g = std::gcd(in_rate, out_rate);
    L_ = out_rate / g;   // e.g. 48000/300 = 160
    M_ = in_rate / g;    // e.g. 44100/300 = 147

    buildKernel();

    history_.assign(size_t(channels_) * kTapsPerPhase, 0.0f);
    hist_pos_ = 0;
    acc_ = 0;
    active_ = true;
    return true;
}

void PolyphaseResampler::buildKernel() {
    // Prototype low-pass, evaluated on the upsampled grid. Cutoff is the lower
    // of the two Nyquist limits (so we neither alias on decimation nor pass
    // images from interpolation), backed off by kCutoffScale for a transition
    // band.
    const double cutoff = kCutoffScale * 0.5 / double(std::max(L_, M_));
    const double norm_i0_beta = besselI0(kKaiserBeta);

    const int total_taps = L_ * kTapsPerPhase;
    const double half = double(total_taps - 1) * 0.5;

    phases_.assign(size_t(total_taps), 0.0f);

    // Build in prototype order first, then deinterleave into phases.
    std::vector<double> proto(static_cast<size_t>(total_taps), 0.0);
    for (int n = 0; n < total_taps; ++n) {
        const double t = double(n) - half;

        // Kaiser window
        const double r = t / half;                      // -1 .. +1
        const double arg = 1.0 - r * r;
        const double w = besselI0(kKaiserBeta * std::sqrt(std::max(0.0, arg))) / norm_i0_beta;

        // Windowed sinc, scaled by L because interpolation by zero-stuffing
        // divides amplitude by L.
        proto[size_t(n)] = 2.0 * cutoff * sinc(2.0 * cutoff * t) * w * double(L_);
    }

    // Normalise each phase so DC gain is exactly 1 for every output position.
    // Without this the conversion has a small periodic amplitude ripple —
    // inaudible in isolation but exactly the sort of thing that accumulates.
    for (int p = 0; p < L_; ++p) {
        double sum = 0.0;
        for (int k = 0; k < kTapsPerPhase; ++k) {
            const int idx = k * L_ + p;
            if (idx < total_taps) sum += proto[size_t(idx)];
        }
        const double scale = (std::fabs(sum) > 1e-12) ? (1.0 / sum) : 1.0;
        for (int k = 0; k < kTapsPerPhase; ++k) {
            const int idx = k * L_ + p;
            if (idx < total_taps) {
                phases_[size_t(p) * kTapsPerPhase + size_t(k)] =
                    float(proto[size_t(idx)] * scale);
            }
        }
    }
}

int PolyphaseResampler::maxOutputFrames(int in_frames) const {
    if (!active_ || in_frames <= 0) return in_frames > 0 ? in_frames : 0;
    // Each input frame advances the grid by L; each output consumes M.
    // Add one for a partial step already banked in phase_acc_.
    return static_cast<int>((static_cast<long long>(in_frames) * L_) / M_) + 2;
}

int PolyphaseResampler::process(const float* in, int in_frames,
                                float* out, int max_out_frames) {
    if (!active_ || in == nullptr || out == nullptr || in_frames <= 0) return 0;

    const int taps = kTapsPerPhase;
    int written = 0;

    for (int i = 0; i < in_frames; ++i) {
        // Push this frame into the per-channel history ring.
        for (int c = 0; c < channels_; ++c) {
            history_[size_t(c) * taps + size_t(hist_pos_)] = in[i * channels_ + c];
        }
        hist_pos_ = (hist_pos_ + 1) % taps;

        // Conceptually the input sits on a grid upsampled by L, and outputs are
        // taken every M positions along it. Having just consumed input i, the
        // grid positions it covers are [i*L, (i+1)*L). `acc_` is the next
        // output's position measured from i*L, so it is directly the polyphase
        // phase index — and any output falling in this span has acc_ < L.
        while (acc_ < L_) {
            if (written >= max_out_frames) {
                // Caller's buffer is full; leave acc_ untouched so the next
                // call resumes exactly here.
                return written;
            }

            const int phase = acc_;
            const float* coeffs = &phases_[size_t(phase) * taps];

            for (int c = 0; c < channels_; ++c) {
                const float* hist = &history_[size_t(c) * taps];
                float acc = 0.0f;
                // Walk the ring backwards from the newest sample.
                int idx = hist_pos_ - 1;
                if (idx < 0) idx += taps;
                for (int k = 0; k < taps; ++k) {
                    acc += hist[idx] * coeffs[k];
                    if (--idx < 0) idx += taps;
                }
                out[written * channels_ + c] = acc;
            }
            ++written;
            acc_ += M_;      // step to the next output position on the grid
        }
        acc_ -= L_;          // rebase onto the next input sample
    }
    return written;
}

void PolyphaseResampler::reset() {
    std::fill(history_.begin(), history_.end(), 0.0f);
    hist_pos_ = 0;
    acc_ = 0;
}

} // namespace nagare

// ---------------------------------------------------------------------------
// C API — see the threading contract in the header.
// ---------------------------------------------------------------------------
namespace {
nagare::PolyphaseResampler g_resampler;

// Seeks come from the UI thread while the audio thread may be inside
// process(). Clearing the history there would be a race on the ring buffer, so
// the request is recorded here and honoured by the audio thread instead.
std::atomic<bool> g_reset_pending{false};
}  // namespace

extern "C" {

int nagare_resampler_init(int in_rate, int out_rate, int channels) {
    if (!g_resampler.init(in_rate, out_rate, channels)) return -1;
    g_reset_pending.store(false, std::memory_order_relaxed);
    return g_resampler.isActive() ? 1 : 0;
}

int nagare_resampler_is_active() {
    return g_resampler.isActive() ? 1 : 0;
}

int nagare_resampler_max_output_frames(int in_frames) {
    return g_resampler.maxOutputFrames(in_frames);
}

int nagare_resampler_process(const float* in, int in_frames,
                             float* out, int max_out_frames) {
    if (g_reset_pending.exchange(false, std::memory_order_acquire)) {
        g_resampler.reset();
    }
    return g_resampler.process(in, in_frames, out, max_out_frames);
}

void nagare_resampler_reset() {
    g_reset_pending.store(true, std::memory_order_release);
}

}  // extern "C"
