// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// Spleeter Core ML Separator & Accelerated Spectral DSP
// Powered by Spleeter 4-Stem U-Net Core ML model & Apple Accelerate vDSP.

import Accelerate
import CoreML
import Foundation

public struct SGSpleeterSeparatedStems: Sendable {
    public let drums: [Float]   // interleaved stereo [L, R, L, R, ...]
    public let bass: [Float]
    public let other: [Float]
    public let vocals: [Float]

    public init(drums: [Float], bass: [Float], other: [Float], vocals: [Float]) {
        self.drums = drums
        self.bass = bass
        self.other = other
        self.vocals = vocals
    }
}

public enum SGSpleeterError: Error {
    case invalidModel
    case invalidInput
    case predictionFailed
}

/// Spleeter Spectrogram representation
public struct SGSpectrogram {
    public let realFrames: [[Float]]
    public let imagFrames: [[Float]]

    public init(realFrames: [[Float]], imagFrames: [[Float]]) {
        self.realFrames = realFrames
        self.imagFrames = imagFrames
    }
}

/// Accelerated vDSP STFT implementation conforming to Deezer Spleeter specifications
public final class SGSpleeterSTFT: @unchecked Sendable {
    public static let fftSize: Int = 4096
    public static let hopLength: Int = 1024
    public static let frequencyLimit: Int = 1024
    public static let timeFrames: Int = 216
    public static let chunkSamples: Int = 1024 * 215 // 220,160 samples (~4.992s at 44.1kHz)

    private let window: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>

    public init?() {
        self.window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningNormalized,
            count: SGSpleeterSTFT.fftSize,
            isHalfWindow: false
        )

        guard let fftInstance = vDSP.FFT(
            log2n: vDSP_Length(log2(Double(SGSpleeterSTFT.fftSize))),
            radix: .radix2,
            ofType: DSPSplitComplex.self
        ) else {
            return nil
        }
        self.fft = fftInstance
    }

    public func forward(waveform: [Float]) -> SGSpectrogram? {
        let pad = SGSpleeterSTFT.fftSize / 2
        var padded = [Float](repeating: 0.0, count: pad)
        padded.append(contentsOf: waveform)
        padded.append(contentsOf: [Float](repeating: 0.0, count: pad))

        let frameCount = (padded.count - SGSpleeterSTFT.fftSize) / SGSpleeterSTFT.hopLength + 1
        var realFrames: [[Float]] = []
        var imagFrames: [[Float]] = []
        realFrames.reserveCapacity(frameCount)
        imagFrames.reserveCapacity(frameCount)

        var realBuf = [Float](repeating: 0.0, count: SGSpleeterSTFT.fftSize / 2)
        var imagBuf = [Float](repeating: 0.0, count: SGSpleeterSTFT.fftSize / 2)

        for i in 0..<frameCount {
            let start = i * SGSpleeterSTFT.hopLength
            let frame = Array(padded[start..<(start + SGSpleeterSTFT.fftSize)])
            let windowed = vDSP.multiply(frame, window)

            realBuf.withUnsafeMutableBufferPointer { realPtr in
                imagBuf.withUnsafeMutableBufferPointer { imagPtr in
                    guard let rBase = realPtr.baseAddress, let iBase = imagPtr.baseAddress else { return }
                    var split = DSPSplitComplex(realp: rBase, imagp: iBase)

                    windowed.withUnsafeBufferPointer { inPtr in
                        guard let inBase = inPtr.baseAddress else { return }
                        inBase.withMemoryRebound(to: DSPComplex.self, capacity: SGSpleeterSTFT.fftSize / 2) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(SGSpleeterSTFT.fftSize / 2))
                        }
                        fft.forward(input: split, output: &split)
                    }
                }
            }

            // DC imaginary part is 0, halve DFT to match torch.stft
            imagBuf[0] = 0.0
            let rSlice = vDSP.multiply(0.5, Array(realBuf.prefix(SGSpleeterSTFT.frequencyLimit)))
            let iSlice = vDSP.multiply(0.5, Array(imagBuf.prefix(SGSpleeterSTFT.frequencyLimit)))
            realFrames.append(rSlice)
            imagFrames.append(iSlice)
        }

        return SGSpectrogram(realFrames: realFrames, imagFrames: imagFrames)
    }

    public func inverse(spectrogram: SGSpectrogram) -> [Float] {
        let frameCount = spectrogram.realFrames.count
        let outputLength = SGSpleeterSTFT.hopLength * (frameCount - 1) + SGSpleeterSTFT.fftSize
        var output = [Float](repeating: 0.0, count: outputLength)
        var windowSum = [Float](repeating: 0.0, count: outputLength)

        let halfFFT = SGSpleeterSTFT.fftSize / 2
        var realBuf = [Float](repeating: 0.0, count: halfFFT)
        var imagBuf = [Float](repeating: 0.0, count: halfFFT)
        var inverseTime = [Float](repeating: 0.0, count: SGSpleeterSTFT.fftSize)

        let scale = Float(1.0 / Float(SGSpleeterSTFT.fftSize))

        for (i, (rFrame, iFrame)) in zip(spectrogram.realFrames, spectrogram.imagFrames).enumerated() {
            realBuf.assign(repeating: 0.0)
            imagBuf.assign(repeating: 0.0)

            let count = min(rFrame.count, halfFFT)
            for k in 0..<count {
                realBuf[k] = rFrame[k]
                imagBuf[k] = iFrame[k]
            }

            realBuf.withUnsafeMutableBufferPointer { rPtr in
                imagBuf.withUnsafeMutableBufferPointer { iPtr in
                    guard let rBase = rPtr.baseAddress, let iBase = iPtr.baseAddress else { return }
                    var split = DSPSplitComplex(realp: rBase, imagp: iBase)
                    fft.inverse(input: split, output: &split)
                }
            }

            let scaledReal = vDSP.multiply(scale, realBuf)
            let scaledImag = vDSP.multiply(scale, imagBuf)

            for k in 0..<halfFFT {
                inverseTime[k * 2] = scaledReal[k]
                inverseTime[k * 2 + 1] = scaledImag[k]
            }

            let windowed = vDSP.multiply(inverseTime, window)
            let start = i * SGSpleeterSTFT.hopLength

            for j in 0..<SGSpleeterSTFT.fftSize {
                let idx = start + j
                if idx < outputLength {
                    output[idx] += windowed[j]
                    windowSum[idx] += window[j] * window[j]
                }
            }
        }

        // Window normalization
        for i in 0..<outputLength {
            if windowSum[i] > 1e-8 {
                output[i] /= windowSum[i]
            }
        }

        let pad = SGSpleeterSTFT.fftSize / 2
        let trimmedEnd = max(pad, outputLength - pad)
        return Array(output[pad..<trimmedEnd])
    }
}

/// Spleeter 4-Stem Model Separator Interface
public actor SGSpleeterSeparator {
    private let model: MLModel
    private let stft: SGSpleeterSTFT
    private let inputTensor: MLMultiArray
    private let featureProvider: MLDictionaryFeatureProvider

    public init(modelURL: URL) async throws {
        guard let stftInstance = SGSpleeterSTFT() else {
            throw SGSpleeterError.invalidModel
        }
        self.stft = stftInstance

        let config = MLModelConfiguration()
        config.computeUnits = .all
        config.allowLowPrecisionAccumulationOnGPU = true

        let loadedModel = try MLModel(contentsOf: modelURL, configuration: config)
        self.model = loadedModel

        // Input shape: [2, 1024, 216] (channels: 2, freq: 1024, time: 216)
        let shape: [NSNumber] = [2, NSNumber(value: SGSpleeterSTFT.frequencyLimit), NSNumber(value: SGSpleeterSTFT.timeFrames)]
        let tensor = try MLMultiArray(shape: shape, dataType: .float32)
        self.inputTensor = tensor
        self.featureProvider = try MLDictionaryFeatureProvider(dictionary: ["magnitude": tensor])
    }

    public func warmUp() async throws {
        let dummy = [Float](repeating: 0.0, count: SGSpleeterSTFT.chunkSamples * 2)
        _ = try await separate(stereoPcm: dummy)
    }

    public func separate(stereoPcm: [Float]) async throws -> SGSpleeterSeparatedStems {
        let expectedCount = SGSpleeterSTFT.chunkSamples * 2
        guard stereoPcm.count >= expectedCount else {
            throw SGSpleeterError.invalidInput
        }

        // De-interleave into Left and Right channels
        let chunkSamples = SGSpleeterSTFT.chunkSamples
        var leftPcm = [Float](repeating: 0.0, count: chunkSamples)
        var rightPcm = [Float](repeating: 0.0, count: chunkSamples)
        for i in 0..<chunkSamples {
            leftPcm[i] = stereoPcm[i * 2]
            rightPcm[i] = stereoPcm[i * 2 + 1]
        }

        // 1. Forward STFT
        guard let stftL = stft.forward(waveform: leftPcm),
              let stftR = stft.forward(waveform: rightPcm) else {
            throw SGSpleeterError.invalidInput
        }

        let timeFrames = min(stftL.realFrames.count, SGSpleeterSTFT.timeFrames)
        let freqBins = SGSpleeterSTFT.frequencyLimit

        // 2. Populate input magnitude tensor [2, 1024, 216]
        let inputPtr = inputTensor.dataPointer.assumingMemoryBound(to: Float.self)
        let chStride = freqBins * SGSpleeterSTFT.timeFrames

        for t in 0..<timeFrames {
            let rL = stftL.realFrames[t]
            let iL = stftL.imagFrames[t]
            let rR = stftR.realFrames[t]
            let iR = stftR.imagFrames[t]

            for f in 0..<freqBins {
                let magL = sqrt(rL[f] * rL[f] + iL[f] * iL[f])
                let magR = sqrt(rR[f] * rR[f] + iR[f] * iR[f])

                // index = ch * (1024 * 216) + f * 216 + t
                inputPtr[0 * chStride + f * SGSpleeterSTFT.timeFrames + t] = magL
                inputPtr[1 * chStride + f * SGSpleeterSTFT.timeFrames + t] = magR
            }
        }

        // 3. Core ML Model Prediction on Apple Neural Engine / GPU
        let prediction = try await model.prediction(from: featureProvider)

        guard let vocalsArray = prediction.featureValue(for: "vocalsMask")?.multiArrayValue,
              let drumsArray = prediction.featureValue(for: "drumsMask")?.multiArrayValue,
              let bassArray = prediction.featureValue(for: "bassMask")?.multiArrayValue,
              let otherArray = prediction.featureValue(for: "otherMask")?.multiArrayValue else {
            throw SGSpleeterError.predictionFailed
        }

        let vPtr = vocalsArray.dataPointer.assumingMemoryBound(to: Float.self)
        let dPtr = drumsArray.dataPointer.assumingMemoryBound(to: Float.self)
        let bPtr = bassArray.dataPointer.assumingMemoryBound(to: Float.self)
        let oPtr = otherArray.dataPointer.assumingMemoryBound(to: Float.self)

        // 4. Compute Deezer Spleeter Ratio Masks & Apply to STFT
        let epsilon: Float = 1e-10
        let epsQuarter: Float = 0.25e-10

        var vRealL = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var vImagL = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var dRealL = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var dImagL = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var bRealL = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var bImagL = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var oRealL = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var oImagL = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)

        var vRealR = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var vImagR = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var dRealR = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var dImagR = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var bRealR = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var bImagR = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var oRealR = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)
        var oImagR = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: timeFrames)

        for ch in 0..<2 {
            let chOffset = ch * chStride
            let inReal = (ch == 0) ? stftL.realFrames : stftR.realFrames
            let inImag = (ch == 0) ? stftL.imagFrames : stftR.imagFrames

            for t in 0..<timeFrames {
                let rSlice = inReal[t]
                let iSlice = inImag[t]

                for f in 0..<freqBins {
                    let idx = chOffset + f * SGSpleeterSTFT.timeFrames + t
                    let vm = vPtr[idx]
                    let dm = dPtr[idx]
                    let bm = bPtr[idx]
                    let om = oPtr[idx]

                    let vm2 = vm * vm
                    let dm2 = dm * dm
                    let bm2 = bm * bm
                    let om2 = om * om
                    let sumSq = vm2 + dm2 + bm2 + om2 + epsilon

                    // Spleeter exact ratio masks (guarantees sum == 1.0)
                    let rv = (vm2 + epsQuarter) / sumSq
                    let rd = (dm2 + epsQuarter) / sumSq
                    let rb = (bm2 + epsQuarter) / sumSq
                    let ro = (om2 + epsQuarter) / sumSq

                    let r = rSlice[f]
                    let i = iSlice[f]

                    if ch == 0 {
                        vRealL[t][f] = rv * r; vImagL[t][f] = rv * i
                        dRealL[t][f] = rd * r; dImagL[t][f] = rd * i
                        bRealL[t][f] = rb * r; bImagL[t][f] = rb * i
                        oRealL[t][f] = ro * r; oImagL[t][f] = ro * i
                    } else {
                        vRealR[t][f] = rv * r; vImagR[t][f] = rv * i
                        dRealR[t][f] = rd * r; dImagR[t][f] = rd * i
                        bRealR[t][f] = rb * r; bImagR[t][f] = rb * i
                        oRealR[t][f] = ro * r; oImagR[t][f] = ro * i
                    }
                }
            }
        }

        // 5. Inverse STFT for all 4 stems
        let vWaveL = stft.inverse(spectrogram: SGSpectrogram(realFrames: vRealL, imagFrames: vImagL))
        let vWaveR = stft.inverse(spectrogram: SGSpectrogram(realFrames: vRealR, imagFrames: vImagR))
        let dWaveL = stft.inverse(spectrogram: SGSpectrogram(realFrames: dRealL, imagFrames: dImagL))
        let dWaveR = stft.inverse(spectrogram: SGSpectrogram(realFrames: dRealR, imagFrames: dImagR))
        let bWaveL = stft.inverse(spectrogram: SGSpectrogram(realFrames: bRealL, imagFrames: bImagL))
        let bWaveR = stft.inverse(spectrogram: SGSpectrogram(realFrames: bRealR, imagFrames: bImagR))
        let oWaveL = stft.inverse(spectrogram: SGSpectrogram(realFrames: oRealL, imagFrames: oImagL))
        let oWaveR = stft.inverse(spectrogram: SGSpectrogram(realFrames: oRealR, imagFrames: oImagR))

        // 6. Interleave each stem into stereo
        let outFrames = min(chunkSamples, vWaveL.count, vWaveR.count)
        var outVocals = [Float](repeating: 0, count: outFrames * 2)
        var outDrums = [Float](repeating: 0, count: outFrames * 2)
        var outBass = [Float](repeating: 0, count: outFrames * 2)
        var outOther = [Float](repeating: 0, count: outFrames * 2)

        for i in 0..<outFrames {
            outVocals[i * 2] = vWaveL[i]; outVocals[i * 2 + 1] = vWaveR[i]
            outDrums[i * 2] = dWaveL[i];  outDrums[i * 2 + 1] = dWaveR[i]
            outBass[i * 2] = bWaveL[i];   outBass[i * 2 + 1] = bWaveR[i]
            outOther[i * 2] = oWaveL[i];  outOther[i * 2 + 1] = oWaveR[i]
        }

        return SGSpleeterSeparatedStems(drums: outDrums, bass: outBass, other: outOther, vocals: outVocals)
    }
}
