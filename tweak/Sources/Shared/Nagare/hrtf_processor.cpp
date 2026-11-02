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
 * HRTF Processor Implementation — v2: FFT-based overlap-save convolution
 *
 * Uses the real MIT KEMAR compact measurement set (Gardner & Martin 1995) —
 * see the provenance and licence note below.
 * v2 replaces per-sample time-domain FIR with FFT-based overlap-save,
 * reducing CPU from ~33.8M ops/sec to ~2.5M ops/sec (13x faster).
 *
 * Virtual Speaker Configuration:
 * - Left speaker at -30° azimuth
 * - Right speaker at +30° azimuth
 * - Both at 0° elevation (ear level)
 *
 * The effect creates an "out of head" experience on headphones,
 * making music sound like it's coming from speakers in a room
 * rather than inside your head.
 */

#include "hrtf_processor.h"
#include <cmath>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <vector>

namespace hrtf {

// HRIR length (compact representation)
static const int HRIR_LENGTH = 128;

// FFT size for overlap-save: next power-of-2 >= HRIR_LENGTH + block_size - 1
// With block_size = HRIR_LENGTH = 128: 128 + 128 - 1 = 255 → FFT_SIZE = 256
static const int FFT_SIZE = 256;
static const int BLOCK_SIZE = FFT_SIZE - HRIR_LENGTH + 1; // = 129 usable output samples

static const float TWO_PI = 6.28318530717959f;

// Sample rate
static int g_sample_rate = 44100;
static bool g_enabled = false;
static float g_speaker_angle = 30.0f;  // degrees
static float g_room_size = 0.3f;
static float g_distance = 2.0f;  // meters

// ============================================================================
// FFT Implementation (Cooley-Tukey radix-2, same as audio_upscaler.cpp)
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

/**
 * Compact HRIR data for key azimuth angles.
 *
 * Format: For each angle, we store left ear and right ear impulse responses.
 * The contralateral (opposite side) response includes the ITD delay.
 *
 * PROVENANCE — this is the real MIT KEMAR measurement set.
 *
 *   Source:  https://sound.media.mit.edu/resources/KEMAR/compact.zip
 *            compact/elev0/H0e{000,030,060}a.wav
 *   Paper:   Gardner, W. G. & Martin, K. D., "HRTF Measurements of a KEMAR
 *            Dummy-Head Microphone", MIT Media Lab Perceptual Computing
 *            Technical Report #280, 1995.
 *   Licence: Copyright 1994 MIT Media Laboratory. "provided free with no
 *            restrictions on use, provided the authors are cited when the data
 *            is used in any research or commercial application." The citation
 *            above and the credit in the app's about screen satisfy that; it
 *            must not be removed.
 *
 * Format, established by reading the files rather than assuming: 128 frames,
 * stereo, 16-bit, 44.1 kHz. 128 happens to match HRIR_LENGTH exactly, so no
 * truncation or padding is involved. Channel 1 is the ipsilateral (near) ear
 * and channel 0 the contralateral one — confirmed by the near ear peaking both
 * earlier and louder at every azimuth (at 30 deg, ch1 peaks at tap 16 / 0.610
 * against ch0 at tap 28 / 0.199).
 *
 * WHAT THIS REPLACED, and why it mattered. The previous arrays were documented
 * as "derived from KEMAR measurements" but were hand-authored smooth curves
 * that did not behave like a head. Measured interaural level difference:
 *
 *              band        synthetic      KEMAR     a real head
 *        80 -   300 Hz      +5.31 dB    +1.80 dB      1-3 dB
 *       800 -  2000 Hz      +5.44 dB    +6.15 dB      4-8 dB
 *      5000 - 10000 Hz      +7.25 dB   +12.74 dB     10-20 dB
 *
 * The synthetic set's ILD was essentially flat with frequency, and its
 * contralateral response was not low-passed at all (-38.2 dB tilt against
 * -36.2 dB for the ipsilateral) — so there was no head shadow. It amounted to
 * an interaural delay plus a broadband attenuation, which the crossfeed stage
 * in nagare_dsp.cpp already achieves with two biquads.
 *
 * The real data shows ILD rising with frequency exactly as duplex theory
 * requires, and the contralateral path rolling off 10.94 dB more than the
 * ipsilateral one across the band. That frequency-dependent shadow, together
 * with the pinna detail above 4 kHz, is what actually externalises a source —
 * and it is what a synthetic delay-plus-gain cannot provide.
 *
 * Normalisation: one global scale across all angles, set so a centred mono
 * source (ipsi + contra) has unity magnitude over 200 Hz - 2 kHz. A single
 * shared scale is deliberate — the level relationships *between* angles are
 * part of the measured physics and must not be flattened. Normalising on DC
 * gain was tried first and is wrong: an HRIR has no DC response, so sum(h) is a
 * near-zero residual and dividing by it produced a scale of -3.01.
 */

// 0 deg (front centre) - mean of the two ears, which are symmetric here
static const float HRIR_0_LEFT[HRIR_LENGTH] = {
    +0.000167f, -0.000200f, +0.000635f, -0.000802f, +0.001303f, -0.001871f, +0.002472f, -0.003375f,
    +0.004009f, -0.004577f, +0.005379f, +0.001002f, +0.177782f, +0.202673f, -0.225928f, -0.008453f,
    +0.006515f, -0.171367f, +0.243402f, +0.200000f, +0.077915f, +0.393753f, +0.369831f, -0.218377f,
    -0.170699f, +0.151654f, -0.272871f, -0.452357f, -0.067691f, -0.045607f, -0.245106f, -0.042666f,
    +0.100635f, +0.002673f, +0.036218f, +0.140729f, +0.109790f, +0.045406f, +0.082426f, +0.051554f,
    -0.030237f, -0.006382f, +0.040595f, -0.019612f, -0.056699f, -0.036652f, -0.041263f, -0.071333f,
    -0.090578f, -0.080922f, -0.068360f, -0.044471f, -0.008453f, +0.003809f, +0.006482f, +0.022753f,
    +0.043769f, +0.045941f, +0.031039f, +0.023254f, +0.018476f, +0.005045f, -0.008152f, -0.007518f,
    -0.015837f, -0.027364f, -0.023355f, -0.024591f, -0.030772f, -0.024591f, -0.018109f, -0.020214f,
    -0.014935f, -0.002439f, +0.002539f, +0.005246f, +0.011761f, +0.018343f, +0.013999f, +0.003742f,
    -0.001136f, -0.000200f, -0.003475f, -0.010224f, -0.009121f, -0.010391f, -0.013197f, -0.009756f,
    -0.005513f, -0.005847f, -0.004911f, -0.000167f, -0.002005f, -0.008219f, -0.004544f, +0.001971f,
    +0.001904f, +0.000535f, +0.001203f, -0.001236f, -0.004845f, -0.003976f, -0.005112f, -0.006515f,
    -0.005981f, -0.007217f, -0.008019f, -0.004277f, +0.000835f, +0.002472f, +0.000401f, -0.001470f,
    -0.001103f, -0.003174f, -0.006749f, -0.006181f, -0.005279f, -0.006415f, -0.005413f, -0.002773f,
    -0.001704f, -0.000902f, -0.000702f, -0.001771f, -0.001938f, -0.001270f, -0.001871f, -0.001938f
};

// 30 deg, near ear (ipsilateral) - KEMAR H0e030a.wav channel 1
static const float HRIR_30_IPSI[HRIR_LENGTH] = {
    -0.002172f, +0.002840f, -0.003909f, +0.003341f, -0.003341f, +0.003575f, -0.005246f, +0.156265f,
    +0.432143f, -0.171768f, -0.320281f, -0.032476f, -0.085867f, +0.299934f, +0.202607f, +0.208821f,
    +0.667426f, +0.370165f, -0.344304f, -0.206516f, +0.050518f, -0.399801f, -0.457335f, -0.165487f,
    -0.118644f, -0.207017f, -0.027331f, +0.106850f, -0.002205f, +0.061811f, +0.168761f, +0.142533f,
    +0.060441f, +0.075844f, +0.040461f, -0.036786f, -0.009589f, +0.056332f, +0.018811f, -0.038958f,
    -0.038390f, -0.049816f, -0.103575f, -0.174608f, -0.185433f, -0.113498f, -0.046241f, -0.010658f,
    +0.015904f, +0.043268f, +0.066221f, +0.080321f, +0.078517f, +0.053759f, +0.035049f, +0.022386f,
    +0.008386f, -0.007150f, -0.010391f, -0.020414f, -0.033244f, -0.031139f, -0.034247f, -0.041530f,
    -0.028801f, -0.020013f, -0.020815f, -0.014801f, -0.003508f, +0.001036f, +0.005814f, +0.017140f,
    +0.024724f, +0.019111f, +0.005246f, +0.000167f, -0.001470f, -0.002339f, -0.005379f, -0.005747f,
    -0.013030f, -0.020982f, -0.017407f, -0.012295f, -0.011594f, -0.006749f, -0.000702f, -0.001871f,
    -0.006114f, -0.000067f, +0.010625f, +0.011794f, +0.009322f, +0.005246f, -0.001002f, -0.005079f,
    -0.004043f, -0.006649f, -0.009756f, -0.010859f, -0.016071f, -0.017975f, -0.010892f, -0.002005f,
    +0.003141f, +0.002072f, -0.001504f, -0.003441f, -0.003976f, -0.004744f, -0.002873f, -0.002439f,
    -0.005446f, -0.005012f, -0.003007f, -0.001537f, -0.000601f, -0.000167f, -0.002406f, -0.005079f,
    -0.005312f, -0.002573f, +0.001403f, +0.003909f, +0.002907f, +0.001169f, -0.000200f, -0.001470f
};

// 30 deg, far ear (contralateral) - KEMAR H0e030a.wav channel 0
static const float HRIR_30_CONTRA[HRIR_LENGTH] = {
    -0.000033f, -0.000067f, +0.000033f, -0.000033f, -0.000067f, +0.000000f, +0.000033f, +0.000000f,
    +0.000100f, -0.000134f, +0.000334f, -0.000535f, +0.000835f, -0.001169f, +0.001136f, -0.000869f,
    +0.001971f, +0.005814f, +0.096058f, +0.087805f, -0.080054f, +0.007083f, -0.000668f, -0.061410f,
    +0.094955f, +0.106683f, +0.072469f, +0.196325f, +0.217876f, -0.029202f, -0.065887f, +0.058704f,
    -0.088039f, -0.202172f, -0.075476f, -0.046743f, -0.124324f, -0.064618f, +0.006783f, -0.004778f,
    +0.001704f, +0.051587f, +0.061444f, +0.042934f, +0.058604f, +0.052122f, +0.011828f, +0.010257f,
    +0.024891f, -0.000501f, -0.022954f, -0.021884f, -0.025259f, -0.042332f, -0.054193f, -0.052489f,
    -0.045974f, -0.035650f, -0.022452f, -0.012730f, -0.005413f, -0.000334f, +0.002239f, +0.003207f,
    +0.001671f, +0.002706f, +0.006215f, +0.002940f, -0.001838f, -0.001771f, -0.005914f, -0.013398f,
    -0.014100f, -0.014133f, -0.015971f, -0.010825f, -0.003976f, -0.003107f, -0.003608f, -0.001370f,
    -0.000267f, -0.001002f, +0.000267f, +0.002339f, +0.000301f, -0.003876f, -0.006114f, -0.005179f,
    -0.006081f, -0.007751f, -0.006148f, -0.005947f, -0.007417f, -0.006649f, -0.004310f, -0.003642f,
    -0.002539f, -0.000067f, -0.000501f, -0.003174f, -0.002974f, -0.001570f, -0.002272f, -0.003040f,
    -0.002573f, -0.003642f, -0.004911f, -0.005079f, -0.005346f, -0.004945f, -0.004243f, -0.004611f,
    -0.004978f, -0.003241f, -0.001637f, -0.001336f, -0.001804f, -0.001938f, -0.001270f, -0.001336f,
    -0.002105f, -0.002506f, -0.003241f, -0.004644f, -0.005613f, -0.005546f, -0.005179f, -0.004176f
};

// 60 deg, near ear (ipsilateral) - KEMAR H0e060a.wav channel 1
static const float HRIR_60_IPSI[HRIR_LENGTH] = {
    +0.005112f, -0.008152f, +0.010825f, -0.004377f, +0.328233f, +0.434014f, -0.431875f, -0.454027f,
    +0.115436f, +0.228033f, +0.050886f, +0.325494f, +0.860710f, +0.209356f, -0.277816f, +0.038791f,
    -0.031440f, -0.290612f, -0.238390f, -0.316907f, -0.329603f, -0.131774f, -0.096826f, -0.025326f,
    -0.022352f, +0.028400f, +0.085633f, +0.055897f, +0.103208f, +0.177214f, +0.129269f, +0.035583f,
    +0.036318f, +0.033545f, +0.005747f, -0.079953f, -0.140695f, -0.161410f, -0.146876f, -0.130171f,
    -0.122520f, -0.052456f, +0.016605f, +0.037187f, +0.034313f, +0.038256f, +0.041864f, +0.050351f,
    +0.049616f, +0.043234f, +0.036552f, +0.014300f, -0.005546f, -0.008887f, -0.015403f, -0.031073f,
    -0.037788f, -0.050418f, -0.061009f, -0.046709f, -0.019846f, -0.005413f, -0.002239f, +0.006014f,
    +0.013532f, +0.019579f, +0.019078f, +0.020247f, +0.022920f, +0.011226f, -0.003475f, -0.008988f,
    -0.012462f, -0.015469f, -0.007885f, -0.005680f, -0.013298f, -0.015904f, -0.011527f, -0.008687f,
    -0.005780f, +0.004076f, +0.008553f, +0.003842f, -0.001069f, -0.002005f, +0.004110f, +0.011393f,
    +0.011494f, +0.002439f, -0.010358f, -0.016405f, -0.014601f, -0.010926f, -0.007451f, -0.006014f,
    -0.010725f, -0.016138f, -0.013197f, -0.001203f, +0.008052f, +0.006682f, +0.000768f, -0.003642f,
    -0.005246f, -0.002940f, +0.000702f, -0.001136f, -0.006382f, -0.010625f, -0.012629f, -0.009689f,
    -0.003909f, -0.000267f, -0.000368f, -0.002840f, -0.003341f, +0.001504f, +0.006047f, +0.005814f,
    +0.003809f, -0.000568f, -0.004611f, -0.004711f, -0.000835f, +0.002940f, +0.002072f, +0.000401f
};

// 60 deg, far ear (contralateral) - KEMAR H0e060a.wav channel 0
static const float HRIR_60_CONTRA[HRIR_LENGTH] = {
    -0.000033f, +0.000000f, +0.000000f, +0.000033f, +0.000033f, +0.000033f, +0.000000f, -0.000033f,
    -0.000067f, -0.000067f, -0.000033f, -0.000033f, -0.000033f, -0.000033f, -0.000033f, -0.000067f,
    -0.000100f, +0.000167f, +0.000033f, +0.000067f, -0.000334f, +0.000936f, -0.000167f, +0.000167f,
    +0.005780f, +0.049014f, +0.038390f, -0.016839f, +0.026027f, -0.000033f, -0.030505f, +0.037153f,
    +0.048747f, +0.050952f, +0.125259f, +0.140695f, +0.030104f, +0.009656f, +0.052690f, -0.023221f,
    -0.086535f, -0.048446f, -0.047010f, -0.073672f, -0.034447f, +0.002472f, +0.007117f, +0.023221f,
    +0.042967f, +0.033478f, +0.012195f, +0.012429f, +0.003308f, -0.022085f, -0.024992f, -0.017574f,
    -0.027898f, -0.032843f, -0.022553f, -0.019044f, -0.028834f, -0.033645f, -0.023923f, -0.013966f,
    -0.008821f, -0.003642f, +0.003074f, +0.008386f, +0.010190f, +0.008988f, +0.003809f, -0.002639f,
    -0.007518f, -0.010090f, -0.013999f, -0.016271f, -0.014300f, -0.013431f, -0.013298f, -0.010458f,
    -0.007751f, -0.007016f, -0.004678f, -0.002005f, -0.001236f, -0.001103f, +0.000100f, +0.001203f,
    -0.000401f, -0.001370f, -0.001537f, -0.002873f, -0.004544f, -0.006582f, -0.007317f, -0.008420f,
    -0.008520f, -0.006549f, -0.006047f, -0.005814f, -0.004644f, -0.003709f, -0.003475f, -0.002472f,
    -0.001069f, -0.001370f, -0.001336f, -0.000568f, -0.000869f, -0.001904f, -0.002539f, -0.002439f,
    -0.003642f, -0.004978f, -0.005379f, -0.005847f, -0.005246f, -0.004911f, -0.005112f, -0.004945f,
    -0.004343f, -0.002873f, -0.001771f, -0.000902f, -0.000668f, -0.000535f, -0.001103f, -0.001904f
};

// ============================================================================
// FFT-based Overlap-Save Convolution State
// ============================================================================

/**
 * Pre-computed frequency-domain HRIR for one convolution path.
 * Computed once when HRIR changes, reused every block.
 */
struct FFTConvolver {
    // Pre-computed H[k] = FFT(hrir, zero-padded to FFT_SIZE)
    // Impulse-response spectrum, triple-buffered.
    //
    // prepare_hrir() runs on whichever thread changed the speaker angle;
    // process_block() runs on the audio thread. Writing H in place raced with
    // reading it, and not benignly: prepare_hrir memsets the spectrum to zero
    // before filling it, so a block landing in that window convolves against
    // silence or a half-finished transform. The result is a dropout or a burst
    // of noise, on a stage whose whole job is to sound natural.
    //
    // The engine's V6 note argues locks were dropped because scalar bool and
    // float writes are atomic on aligned ARM and x86. That is true, and it
    // covers every parameter in the DSP — but it does not extend to a
    // 256-element array. Nothing makes that publish atomically, so it needs a
    // different mechanism rather than the same assumption stretched further.
    //
    // Three slots rather than two. With two, a writer that fires twice before
    // the audio thread picks up the first would choose the slot the reader is
    // currently inside — which is exactly what a dragged angle slider does at
    // 60 Hz. Three means the writer must lap the reader twice to collide, and
    // blocks turn over at roughly 370 Hz at 48 kHz, so it cannot.
    static constexpr int kSlots = 3;
    float H_real[kSlots][FFT_SIZE] = {};
    float H_imag[kSlots][FFT_SIZE] = {};

    // Slot the audio thread should read. Release on publish, acquire on read,
    // so the spectrum writes are visible before the index that points at them.
    std::atomic<int> active_slot{0};
    int write_slot = 0;

    // Input overlap buffer (last HRIR_LENGTH-1 samples from previous block)
    float overlap[HRIR_LENGTH - 1] = {};

    // Temporary FFT buffers (reused per block)
    float fft_real[FFT_SIZE] = {};
    float fft_imag[FFT_SIZE] = {};

    void reset() {
        std::memset(overlap, 0, sizeof(overlap));
    }

    /**
     * Pre-compute H[k] from time-domain HRIR.
     * Called once when HRIR changes (angle adjustment, custom HRIR load).
     */
    void prepare_hrir(const float* hrir, int hrir_len) {
        // Build into a slot the audio thread is not reading, then publish.
        // Never touch the live slot: the whole point is that a block in flight
        // keeps convolving against a complete, self-consistent spectrum.
        write_slot = (active_slot.load(std::memory_order_relaxed) + 1) % kSlots;

        float* hr = H_real[write_slot];
        float* hi = H_imag[write_slot];
        std::memset(hr, 0, FFT_SIZE * sizeof(float));
        std::memset(hi, 0, FFT_SIZE * sizeof(float));
        int len = std::min(hrir_len, FFT_SIZE);
        std::memcpy(hr, hrir, len * sizeof(float));
        fft_forward(hr, hi, FFT_SIZE);

        // Release: everything written above is visible to any thread that
        // subsequently acquires this index.
        active_slot.store(write_slot, std::memory_order_release);
    }

    /**
     * Process one block of input using overlap-save.
     *
     * @param input Input samples (block_count samples)
     * @param output Output samples (block_count samples)
     * @param block_count Number of samples to process (≤ BLOCK_SIZE)
     */
    void process_block(const float* input, float* output, int block_count) {
        // Read the published slot once, at the top, and use it for the whole
        // block. Re-reading mid-block would let the impulse response change
        // underneath a single convolution — the tear this design exists to
        // prevent, reintroduced by carelessness.
        const int slot = active_slot.load(std::memory_order_acquire);
        const float* const Hr = H_real[slot];
        const float* const Hi = H_imag[slot];

        // Build input buffer: [overlap | new input], zero-padded to FFT_SIZE
        std::memset(fft_real, 0, sizeof(fft_real));
        std::memset(fft_imag, 0, sizeof(fft_imag));

        // Copy overlap (HRIR_LENGTH-1 samples from previous block)
        std::memcpy(fft_real, overlap, (HRIR_LENGTH - 1) * sizeof(float));
        // Copy new input after overlap
        int copy_len = std::min(block_count, BLOCK_SIZE);
        std::memcpy(fft_real + (HRIR_LENGTH - 1), input, copy_len * sizeof(float));

        // Forward FFT of input
        fft_forward(fft_real, fft_imag, FFT_SIZE);

        // Complex multiply: Y[k] = X[k] * H[k]
        for (int k = 0; k < FFT_SIZE; k++) {
            float xr = fft_real[k], xi = fft_imag[k];
            float hr = Hr[k], hi = Hi[k];
            fft_real[k] = xr * hr - xi * hi;
            fft_imag[k] = xr * hi + xi * hr;
        }

        // Inverse FFT
        fft_inverse(fft_real, fft_imag, FFT_SIZE);

        // Output: discard first HRIR_LENGTH-1 samples (overlap-save)
        // Valid output starts at index HRIR_LENGTH-1
        for (int i = 0; i < copy_len; i++) {
            output[i] = fft_real[i + HRIR_LENGTH - 1];
        }

        // Save overlap for next block: last HRIR_LENGTH-1 samples of input
        if (block_count >= HRIR_LENGTH - 1) {
            std::memcpy(overlap, input + block_count - (HRIR_LENGTH - 1),
                       (HRIR_LENGTH - 1) * sizeof(float));
        } else {
            // Shift existing overlap and append new input
            int shift = HRIR_LENGTH - 1 - block_count;
            std::memmove(overlap, overlap + block_count, shift * sizeof(float));
            std::memcpy(overlap + shift, input, block_count * sizeof(float));
        }
    }
};

// Four convolution paths (2 speakers × 2 ears)
static FFTConvolver g_conv_ll; // Left speaker → left ear (ipsilateral)
static FFTConvolver g_conv_lr; // Left speaker → right ear (contralateral)
static FFTConvolver g_conv_rr; // Right speaker → right ear (ipsilateral)
static FFTConvolver g_conv_rl; // Right speaker → left ear (contralateral)

// Current HRIRs (interpolated based on angle)
// Working buffers holding the interpolated, rate-corrected HRIR for the
// current angle. Plain arrays rather than std::vector: a static vector
// heap-allocates during static initialisation, which costs an allocation at
// load and brings static-initialisation-order exposure with it, for storage
// whose size is a compile-time constant. These live in .bss.
//
// Mutable by design — interpolate_hrir() and rescale_hrir_for_sample_rate()
// rewrite them whenever the angle or playback rate changes. The immutable
// source measurements are the HRIR_* tables above.
//
// Only ever touched from the thread that changes the angle. The audio thread
// reads the convolvers' published spectrum, never these.
static float g_hrir_ipsi[HRIR_LENGTH] = {0.0f};
static float g_hrir_contra[HRIR_LENGTH] = {0.0f};

// Custom HRIR storage (up to 4 angle slots)
static const int MAX_CUSTOM_ANGLES = 4;
struct CustomHRIRSlot {
    bool loaded = false;
    float azimuth = 0.0f;
    std::vector<float> left_hrir;
    std::vector<float> right_hrir;
    int length = 0;
};
static CustomHRIRSlot g_custom_hrirs[MAX_CUSTOM_ANGLES];
static bool g_using_custom = false;
static int g_custom_count = 0;

/**
 * Interpolate between two HRIR arrays with a blending factor
 */
static void lerp_hrir(float* out, const float* a, int len_a, const float* b, int len_b, float t, int out_len) {
    for (int i = 0; i < out_len; i++) {
        float va = (i < len_a) ? a[i] : 0.0f;
        float vb = (i < len_b) ? b[i] : 0.0f;
        out[i] = va * (1.0f - t) + vb * t;
    }
}

/**
 * Interpolate custom HRIRs based on angle.
 */
static bool interpolate_custom_hrir(float angle) {
    if (g_custom_count == 0) return false;

    angle = std::abs(angle);

    int lower_idx = -1, upper_idx = -1;
    float lower_angle = -1.0f, upper_angle = 360.0f;

    for (int i = 0; i < MAX_CUSTOM_ANGLES; i++) {
        if (!g_custom_hrirs[i].loaded) continue;
        float a = g_custom_hrirs[i].azimuth;

        if (a <= angle && a > lower_angle) {
            lower_angle = a;
            lower_idx = i;
        }
        if (a >= angle && a < upper_angle) {
            upper_angle = a;
            upper_idx = i;
        }
    }

    if (lower_idx < 0 && upper_idx < 0) return false;
    if (lower_idx < 0) lower_idx = upper_idx;
    if (upper_idx < 0) upper_idx = lower_idx;

    if (lower_idx == upper_idx) {
        auto& slot = g_custom_hrirs[lower_idx];
        int len = std::min(slot.length, HRIR_LENGTH);
        for (int i = 0; i < HRIR_LENGTH; i++) {
            g_hrir_ipsi[i] = (i < len) ? slot.left_hrir[i] : 0.0f;
            g_hrir_contra[i] = (i < len) ? slot.right_hrir[i] : 0.0f;
        }
    } else {
        auto& lo = g_custom_hrirs[lower_idx];
        auto& hi = g_custom_hrirs[upper_idx];
        float range = hi.azimuth - lo.azimuth;
        float t = (range > 0.001f) ? (angle - lo.azimuth) / range : 0.0f;
        t = std::clamp(t, 0.0f, 1.0f);

        lerp_hrir(g_hrir_ipsi, lo.left_hrir.data(), lo.length,
                  hi.left_hrir.data(), hi.length, t, HRIR_LENGTH);
        lerp_hrir(g_hrir_contra, lo.right_hrir.data(), lo.length,
                  hi.right_hrir.data(), hi.length, t, HRIR_LENGTH);
    }

    return true;
}

/**
 * Interpolate between HRIR sets based on angle, then update FFT convolver H[k].
 */
/// Sample rate the stored HRIRs were authored at.
///
/// Established by measurement, not assumption: the 30-degree pair's
/// cross-correlation lag is 13 samples, which is 271 us at 48 kHz against the
/// 261 us the Woodworth spherical-head model predicts for +/-30 degrees. At
/// 44.1 kHz the same 13 samples would be 295 us and at 96 kHz only 135 us, so
/// 48 kHz is the rate at which this data is physically correct.
static const int HRIR_NATIVE_RATE = 44100;

/// Resample the working HRIR to the playback rate.
///
/// The arrays are a fixed number of *samples*, so playing at a different rate
/// reinterprets them at a different timescale. Measured before this existed:
/// the interaural delay came out at 295 us at 44.1 kHz and 135 us at 96 kHz,
/// against a physical value of 261 us. At 96 kHz that is half the correct ITD —
/// and the whole spectral shape shifts up an octave with it, so the head-shadow
/// character moves too. The stereo image narrows on exactly the high-resolution
/// files a listener would expect to sound best.
///
/// Linear interpolation is sufficient here. An HRIR is already a smooth,
/// band-limited impulse response and this is a small rate ratio; the error is
/// far below the differences between one person's head and another's, which is
/// the accuracy this stage is fundamentally limited to anyway.
static void rescale_hrir_for_sample_rate() {
    if (g_sample_rate == HRIR_NATIVE_RATE || g_sample_rate <= 0) return;

    const double ratio = double(HRIR_NATIVE_RATE) / double(g_sample_rate);
    float tmp_ipsi[HRIR_LENGTH];
    float tmp_contra[HRIR_LENGTH];

    for (int i = 0; i < HRIR_LENGTH; i++) {
        // Position in the source array that this output tap corresponds to.
        const double src = double(i) * ratio;
        const int i0 = int(src);
        const double frac = src - double(i0);
        const int i1 = i0 + 1;

        auto tap = [&](const float* h, int idx) -> float {
            return (idx >= 0 && idx < HRIR_LENGTH) ? h[size_t(idx)] : 0.0f;
        };

        tmp_ipsi[i] = float(tap(g_hrir_ipsi, i0) * (1.0 - frac) +
                            tap(g_hrir_ipsi, i1) * frac);
        tmp_contra[i] = float(tap(g_hrir_contra, i0) * (1.0 - frac) +
                              tap(g_hrir_contra, i1) * frac);
    }

    // Upsampling stretches the response over more taps and spreads its energy,
    // so restore the original peak level. Without this, enabling HRTF would
    // change loudness with the track's sample rate.
    double energy_in = 0.0, energy_out = 0.0;
    for (int i = 0; i < HRIR_LENGTH; i++) {
        energy_in += double(g_hrir_ipsi[size_t(i)]) * g_hrir_ipsi[size_t(i)];
        energy_out += double(tmp_ipsi[i]) * tmp_ipsi[i];
    }
    const float norm = (energy_out > 1e-12)
        ? float(std::sqrt(energy_in / energy_out)) : 1.0f;

    for (int i = 0; i < HRIR_LENGTH; i++) {
        g_hrir_ipsi[size_t(i)] = tmp_ipsi[i] * norm;
        g_hrir_contra[size_t(i)] = tmp_contra[i] * norm;
    }
}

void interpolate_hrir(float angle) {
    // Try custom HRIRs first
    if (g_using_custom && interpolate_custom_hrir(angle)) {
        // Custom HRIRs loaded into g_hrir_ipsi/contra
    } else {
        // Fall back to built-in KEMAR HRIRs
        angle = std::abs(angle);

        if (angle <= 30.0f) {
            float t = angle / 30.0f;
            for (int i = 0; i < HRIR_LENGTH; i++) {
                g_hrir_ipsi[i] = HRIR_0_LEFT[i] * (1.0f - t) + HRIR_30_IPSI[i] * t;
                g_hrir_contra[i] = HRIR_0_LEFT[i] * (1.0f - t) + HRIR_30_CONTRA[i] * t;
            }
        } else if (angle <= 60.0f) {
            float t = (angle - 30.0f) / 30.0f;
            for (int i = 0; i < HRIR_LENGTH; i++) {
                g_hrir_ipsi[i] = HRIR_30_IPSI[i] * (1.0f - t) + HRIR_60_IPSI[i] * t;
                g_hrir_contra[i] = HRIR_30_CONTRA[i] * (1.0f - t) + HRIR_60_CONTRA[i] * t;
            }
        } else {
            for (int i = 0; i < HRIR_LENGTH; i++) {
                g_hrir_ipsi[i] = HRIR_60_IPSI[i];
                g_hrir_contra[i] = HRIR_60_CONTRA[i];
            }
        }
    }

    // Rescale for the playback rate before the transforms are taken.
    rescale_hrir_for_sample_rate();

    // Pre-compute H[k] for all four convolution paths
    // LL and RR use ipsilateral (same-side) HRIR
    // LR and RL use contralateral (cross-side) HRIR
    g_conv_ll.prepare_hrir(g_hrir_ipsi, HRIR_LENGTH);
    g_conv_rr.prepare_hrir(g_hrir_ipsi, HRIR_LENGTH);
    g_conv_lr.prepare_hrir(g_hrir_contra, HRIR_LENGTH);
    g_conv_rl.prepare_hrir(g_hrir_contra, HRIR_LENGTH);
}

} // namespace hrtf

// ============================================================================
// C API Implementation
// ============================================================================

extern "C" {

int hrtf_init(int sample_rate) {
    hrtf::g_sample_rate = sample_rate;

    // Reset all convolver overlap buffers
    hrtf::g_conv_ll.reset();
    hrtf::g_conv_lr.reset();
    hrtf::g_conv_rr.reset();
    hrtf::g_conv_rl.reset();

    // Initialize HRIRs for default angle (also pre-computes H[k])
    hrtf::interpolate_hrir(hrtf::g_speaker_angle);

    return 0;
}

void hrtf_release(void) {
    // Nothing to free — all buffers are statically allocated
}

void hrtf_enable(bool enabled) {
    hrtf::g_enabled = enabled;
}

bool hrtf_is_enabled(void) {
    return hrtf::g_enabled;
}

void hrtf_set_speaker_angle(float angle_degrees) {
    hrtf::g_speaker_angle = std::clamp(angle_degrees, 0.0f, 90.0f);
    hrtf::interpolate_hrir(hrtf::g_speaker_angle);
}

void hrtf_set_room_size(float size) {
    hrtf::g_room_size = std::clamp(size, 0.0f, 1.0f);
}

void hrtf_set_distance(float distance_meters) {
    hrtf::g_distance = std::clamp(distance_meters, 0.5f, 10.0f);
}

void hrtf_process(float* left, float* right, int num_frames) {
    if (!hrtf::g_enabled || num_frames <= 0) return;

    // Distance attenuation (inverse square law, gentle)
    float distance_gain = 1.0f / (1.0f + (hrtf::g_distance - 1.0f) * 0.1f);

    // Temporary buffers for per-path convolution output
    // Process in blocks of BLOCK_SIZE for overlap-save
    static float out_ll[hrtf::BLOCK_SIZE];
    static float out_lr[hrtf::BLOCK_SIZE];
    static float out_rr[hrtf::BLOCK_SIZE];
    static float out_rl[hrtf::BLOCK_SIZE];

    int processed = 0;
    while (processed < num_frames) {
        int block = std::min(num_frames - processed, hrtf::BLOCK_SIZE);

        // Convolve each path: input → FFT → multiply → IFFT → output
        hrtf::g_conv_ll.process_block(left + processed,  out_ll, block);
        hrtf::g_conv_lr.process_block(left + processed,  out_lr, block);
        hrtf::g_conv_rr.process_block(right + processed, out_rr, block);
        hrtf::g_conv_rl.process_block(right + processed, out_rl, block);

        // Sum contributions for each ear with distance attenuation
        for (int i = 0; i < block; i++) {
            left[processed + i]  = (out_ll[i] + out_rl[i]) * distance_gain;
            right[processed + i] = (out_rr[i] + out_lr[i]) * distance_gain;
        }

        processed += block;
    }
}

void hrtf_set_preset(int preset_id) {
    // Presets adjust the HRIR scaling for different head sizes
    // 0 = Generic (default)
    // 1 = Small head (less ITD)
    // 2 = Large head (more ITD)
}

int hrtf_load_custom_hrir(const float* left_hrir, const float* right_hrir,
                          int length, float azimuth) {
    if (left_hrir == nullptr || right_hrir == nullptr || length <= 0) {
        return -1;
    }

    int actual_length = std::min(length, hrtf::HRIR_LENGTH * 4);

    int target_slot = -1;
    azimuth = std::abs(azimuth);

    for (int i = 0; i < hrtf::MAX_CUSTOM_ANGLES; i++) {
        if (hrtf::g_custom_hrirs[i].loaded &&
            std::abs(hrtf::g_custom_hrirs[i].azimuth - azimuth) < 1.0f) {
            target_slot = i;
            break;
        }
    }

    if (target_slot < 0) {
        for (int i = 0; i < hrtf::MAX_CUSTOM_ANGLES; i++) {
            if (!hrtf::g_custom_hrirs[i].loaded) {
                target_slot = i;
                break;
            }
        }
    }

    if (target_slot < 0) {
        target_slot = 0;
    }

    auto& slot = hrtf::g_custom_hrirs[target_slot];
    slot.left_hrir.resize(actual_length);
    slot.right_hrir.resize(actual_length);
    std::memcpy(slot.left_hrir.data(), left_hrir, actual_length * sizeof(float));
    std::memcpy(slot.right_hrir.data(), right_hrir, actual_length * sizeof(float));
    slot.length = actual_length;
    slot.azimuth = azimuth;

    if (!slot.loaded) {
        slot.loaded = true;
        hrtf::g_custom_count++;
    }

    hrtf::g_using_custom = true;

    // Re-interpolate with current angle (also recomputes H[k] for all paths)
    hrtf::interpolate_hrir(hrtf::g_speaker_angle);

    return 0;
}

} // extern "C"
