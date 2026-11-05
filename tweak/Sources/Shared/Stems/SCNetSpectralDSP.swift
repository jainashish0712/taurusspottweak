// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// SCNet Spectral DSP (Accelerate vDSP STFT / iSTFT)
// High-performance hardware-accelerated time-frequency transforms for SCNet.

import Accelerate
import Foundation

@available(iOS 18.0, macOS 27.0, *)
public final class SCNetSpectralDSP: @unchecked Sendable {
    public static let fftSize = 4096
    public static let hopSize = 1024
    public static let timeFrames = 476
    public static let freqBins = 2049
    public static let padSamples = 2048 // fftSize / 2
    public static let chunkSamples = (timeFrames - 1) * hopSize // 486,400 samples (~11.0s at 44.1kHz)

    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private let window: [Float]
    private let normScale: Float

    // Reusable buffers
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var outRealBuffer: [Float]
    private var outImagBuffer: [Float]
    private var overlapAccumulator: [Float]
    private var overlapWeights: [Float]

    public init?() {
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD) else {
            return nil
        }
        guard let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .INVERSE) else {
            vDSP_DFT_DestroySetup(forward)
            return nil
        }
        self.forwardSetup = forward
        self.inverseSetup = inverse

        // Periodic Hann window: 0.5 * (1 - cos(2 * pi * n / N))
        let nFft = Float(Self.fftSize)
        self.window = (0..<Self.fftSize).map { n in
            0.5 * (1.0 - cos(2.0 * Float.pi * Float(n) / nFft))
        }

        // Forward normalization for PyTorch normalized=True: 1 / sqrt(N)
        self.normScale = 1.0 / sqrt(nFft)

        self.realBuffer = [Float](repeating: 0, count: Self.fftSize)
        self.imagBuffer = [Float](repeating: 0, count: Self.fftSize)
        self.outRealBuffer = [Float](repeating: 0, count: Self.fftSize)
        self.outImagBuffer = [Float](repeating: 0, count: Self.fftSize)

        let totalLength = Self.timeFrames * Self.hopSize + Self.fftSize
        self.overlapAccumulator = [Float](repeating: 0, count: totalLength)

        var weights = [Float](repeating: 0, count: totalLength)
        for frame in 0..<Self.timeFrames {
            let offset = frame * Self.hopSize
            for n in 0..<Self.fftSize {
                let w = self.window[n]
                weights[offset + n] += w * w
            }
        }
        self.overlapWeights = weights
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    /// Encodes stereo PCM [L0, R0, L1, R1, ...] into planar float buffer [1, 4, 2049, 476]
    /// Channels: 0: L_real, 1: L_imag, 2: R_real, 3: R_imag
    public func encode(interleavedStereo pcm: [Float], into outSpectrum: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard pcm.count >= Self.chunkSamples * 2 else { return false }
        guard outSpectrum.count >= 4 * Self.freqBins * Self.timeFrames else { return false }

        let nSamples = Self.chunkSamples
        let strideChannel = Self.freqBins * Self.timeFrames
        let strideBin = Self.timeFrames

        for channel in 0..<2 {
            let baseChannelIndex = channel * 2

            for frame in 0..<Self.timeFrames {
                let frameStart = frame * Self.hopSize - Self.padSamples

                // Populate windowed real buffer with reflection padding at boundaries
                for n in 0..<Self.fftSize {
                    var idx = frameStart + n
                    if idx < 0 {
                        idx = -idx
                    } else if idx >= nSamples {
                        idx = 2 * nSamples - 2 - idx
                    }
                    if idx < 0 { idx = 0 }
                    if idx >= nSamples { idx = nSamples - 1 }

                    realBuffer[n] = pcm[idx * 2 + channel] * window[n]
                    imagBuffer[n] = 0.0
                }

                // Execute FFT
                vDSP_DFT_Execute(forwardSetup, realBuffer, imagBuffer, &outRealBuffer, &outImagBuffer)

                // Write normalized frequency bins into planar tensor [channel, bin, frame]
                for bin in 0..<Self.freqBins {
                    let outPosReal = (baseChannelIndex * strideChannel) + (bin * strideBin) + frame
                    let outPosImag = ((baseChannelIndex + 1) * strideChannel) + (bin * strideBin) + frame

                    outSpectrum[outPosReal] = outRealBuffer[bin] * normScale
                    outSpectrum[outPosImag] = outImagBuffer[bin] * normScale
                }
            }
        }
        return true
    }

    /// Decodes stem from output tensor [1, 16, 2049, 476] for a specific source index (0..3)
    /// sourceIndex: 0 = Drums, 1 = Bass, 2 = Other, 3 = Vocals
    /// Returns interleaved stereo PCM [L0, R0, L1, R1, ...] of length chunkSamples * 2
    public func decode(sourceIndex: Int, from tensor: UnsafeBufferPointer<Float>) -> [Float] {
        var outputStereo = [Float](repeating: 0, count: Self.chunkSamples * 2)
        guard sourceIndex >= 0 && sourceIndex < 4 else { return outputStereo }

        let strideSource = 4 * Self.freqBins * Self.timeFrames
        let strideChannel = Self.freqBins * Self.timeFrames
        let strideBin = Self.timeFrames
        let sourceBase = sourceIndex * strideSource

        // Inverse scaling: sqrt(N) / N = 1 / sqrt(N) = normScale
        let ifftScale = normScale

        for channel in 0..<2 {
            let chBase = sourceBase + (channel * 2 * strideChannel)
            let imagChBase = chBase + strideChannel

            // Clear overlap accumulator
            overlapAccumulator.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length($0.count)) }

            for frame in 0..<Self.timeFrames {
                // Populate bins
                for bin in 0..<Self.freqBins {
                    let posReal = chBase + (bin * strideBin) + frame
                    let posImag = imagChBase + (bin * strideBin) + frame

                    realBuffer[bin] = tensor[posReal]
                    imagBuffer[bin] = tensor[posImag]

                    // Conjugate symmetry for negative frequencies
                    if bin > 0 && bin < Self.freqBins - 1 {
                        let negBin = Self.fftSize - bin
                        realBuffer[negBin] = realBuffer[bin]
                        imagBuffer[negBin] = -imagBuffer[bin]
                    }
                }
                imagBuffer[0] = 0.0
                imagBuffer[Self.freqBins - 1] = 0.0

                // Execute Inverse FFT
                vDSP_DFT_Execute(inverseSetup, realBuffer, imagBuffer, &outRealBuffer, &outImagBuffer)

                // Overlap-add into accumulator
                let offset = frame * Self.hopSize
                for n in 0..<Self.fftSize {
                    overlapAccumulator[offset + n] += outRealBuffer[n] * window[n] * ifftScale
                }
            }

            // Normalize and extract valid samples
            for i in 0..<Self.chunkSamples {
                let accIdx = i + Self.padSamples
                let weight = max(overlapWeights[accIdx], 1e-4)
                outputStereo[i * 2 + channel] = overlapAccumulator[accIdx] / weight
            }
        }

        return outputStereo
    }
}
