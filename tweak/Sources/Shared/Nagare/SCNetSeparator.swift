// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// SCNet Core ML Separator
// High-performance Core ML interface for SCNet Base 4-Stem Audio Separation.

import CoreML
import Foundation

public struct SCNetSeparatedStems {
    public let drums: [Float]
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

public enum SCNetError: Error {
    case invalidModel
    case invalidInput
    case predictionFailed
}

@available(iOS 18.0, macOS 27.0, *)
public actor SCNetSeparator {
    private let model: MLModel
    private let dsp: SCNetSpectralDSP
    private let inputTensor: MLMultiArray
    private let featureProvider: MLDictionaryFeatureProvider

    public init(modelURL: URL) async throws {
        guard let dsp = SCNetSpectralDSP() else {
            throw SCNetError.invalidModel
        }
        self.dsp = dsp

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        config.allowLowPrecisionAccumulationOnGPU = true

        let loadedModel = try await MLModel.load(contentsOf: modelURL, configuration: config)
        self.model = loadedModel

        // Input shape: [1, 4, 2049, 476]
        let shape: [NSNumber] = [1, 4, NSNumber(value: SCNetSpectralDSP.freqBins), NSNumber(value: SCNetSpectralDSP.timeFrames)]
        let tensor = try MLMultiArray(shape: shape, dataType: .float32)
        self.inputTensor = tensor
        self.featureProvider = try MLDictionaryFeatureProvider(dictionary: ["spectrogram": tensor])
    }

    public func warmUp() async throws {
        let dummy = [Float](repeating: 0.0, count: SCNetSpectralDSP.chunkSamples * 2)
        _ = try await separate(stereoPcm: dummy)
    }

    public func separate(stereoPcm: [Float]) async throws -> SCNetSeparatedStems {
        guard stereoPcm.count >= SCNetSpectralDSP.chunkSamples * 2 else {
            throw SCNetError.invalidInput
        }

        // 1. Encode PCM to STFT Spectrogram
        let tensorPtr = UnsafeMutableBufferPointer<Float>(
            start: inputTensor.dataPointer.assumingMemoryBound(to: Float.self),
            count: inputTensor.count
        )
        guard dsp.encode(interleavedStereo: stereoPcm, into: tensorPtr) else {
            throw SCNetError.invalidInput
        }

        // 2. Run Core ML Prediction on GPU
        let prediction = try model.prediction(from: featureProvider)
        guard let outputFeature = prediction.featureValue(for: "separated")?.multiArrayValue else {
            throw SCNetError.predictionFailed
        }

        // 3. Decode 4 discrete stems from output [1, 16, 2049, 476]
        let outPtr = UnsafeBufferPointer<Float>(
            start: outputFeature.dataPointer.assumingMemoryBound(to: Float.self),
            count: outputFeature.count
        )

        // Stems mapping: 0 = Drums, 1 = Bass, 2 = Other, 3 = Vocals
        let drums = dsp.decode(sourceIndex: 0, from: outPtr)
        let bass = dsp.decode(sourceIndex: 1, from: outPtr)
        let other = dsp.decode(sourceIndex: 2, from: outPtr)
        let vocals = dsp.decode(sourceIndex: 3, from: outPtr)

        return SCNetSeparatedStems(drums: drums, bass: bass, other: other, vocals: vocals)
    }
}
