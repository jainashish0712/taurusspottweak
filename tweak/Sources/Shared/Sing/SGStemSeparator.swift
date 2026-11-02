import CoreML
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum SGStemError: Error {
    case invalidModel, invalidInput, invalidOutput
}

enum SGStemShape {
    static let fftSize = 2048, stftHop = 441, stftFrames = 201
    static let bins = fftSize / 2 + 1
    static let windowFrames = (stftFrames - 1) * stftHop   // 88200, two seconds at 44.1 kHz
    // [1, real and imaginary of each bin for each channel, frame, 2].
    static let spectrum: [Int] = [1, bins * 2, stftFrames, 2]
    static let spectrumCount = spectrum.reduce(1, *)
}

@available(iOS 18.0, macOS 27.0, *)
actor SGStemSeparator {
    let windowFrames = SGStemShape.windowFrames
    private let cpu: MLModel
    private var neural: MLModel?         // nil when it could not be loaded; the CPU model then does everything
    private var neuralFailed = false     // a Neural Engine / GPU prediction failed
    private var lastAccelerated: Bool?
    private let dsp: SGStemSpectralDSP
    private let tensor: MLMultiArray
    private let provider: MLDictionaryFeatureProvider
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(modelURL: URL) async throws {
        let cpuOnly = MLModelConfiguration()
        cpuOnly.computeUnits = .cpuOnly
        let cpu = try await MLModel.load(contentsOf: modelURL, configuration: cpuOnly)
        try Task.checkCancellation()
        let shape = SGStemShape.spectrum.map(NSNumber.init(value:))
        let description = cpu.modelDescription
        guard description.stateDescriptionsByName.isEmpty,
              description.inputDescriptionsByName.count == 1,
              let input = description.inputDescriptionsByName["spectrum"]?.multiArrayConstraint,
              input.shape == shape,
              (input.dataType == .float32 || input.dataType == .float16) else { throw SGStemError.invalidModel }

        let tensor = try MLMultiArray(shape: shape, dataType: .float32)
        guard tensor.strides.map(\.intValue) == Self.strides else { throw SGStemError.invalidInput }
        self.tensor = tensor
        self.provider = try MLDictionaryFeatureProvider(dictionary: ["spectrum": tensor])
        self.cpu = cpu
        self.dsp = try SGStemSpectralDSP()

        // Configure hardware acceleration: ANE + GPU heterogeneous compute
        let accelerated = MLModelConfiguration()
        accelerated.computeUnits = .all
        accelerated.allowLowPrecisionAccumulationOnGPU = true
        do {
            self.neural = try await MLModel.load(contentsOf: modelURL, configuration: accelerated)
        } catch {
            try Task.checkCancellation()
            // Fall back to cpuAndNeuralEngine if .all encounters an error
            let aneOnly = MLModelConfiguration()
            aneOnly.computeUnits = .cpuAndNeuralEngine
            do {
                self.neural = try await MLModel.load(contentsOf: modelURL, configuration: aneOnly)
            } catch {
                NSLog("[spotifyglass] Sing ANE/GPU acceleration unavailable: %@", String(describing: error))
            }
        }
    }

    // A packed row-major tensor: what encode writes and decode reads.
    private static let strides: [Int] = SGStemShape.spectrum.indices.map {
        SGStemShape.spectrum[($0 + 1)...].reduce(1, *)
    }

    func warmUp() async throws {
        try encode([Float](repeating: 0, count: windowFrames * 2))
        _ = try predictResult(accelerated: false)
        if neural != nil, await foreground() { _ = try predictResult(accelerated: true) }
    }

    func stems(for pcm: [Float]) async throws -> SG4Stems {
        guard pcm.count == windowFrames * 2, pcm.allSatisfy(\.isFinite) else { throw SGStemError.invalidInput }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let active = neural != nil ? await foreground() : false
        if !active { neuralFailed = false }
        try encode(pcm)
        let accelerated = active && !neuralFailed
        if lastAccelerated != accelerated {
            NSLog("[spotifyglass] Sing Core ML compute policy: %@", accelerated ? "foreground ANE/GPU accelerated" : "CPU only")
            lastAccelerated = accelerated
        }
        let result = try predictResult(accelerated: accelerated)
        try Task.checkCancellation()

        // 1. Vocals
        let vocals: [Float]
        if let vArr = result.featureValue(for: "vocals_spectrum")?.multiArrayValue {
            vocals = try decodeSpectrum(vArr)
        } else if let vArr = result.featureValue(for: "vocals")?.multiArrayValue {
            vocals = try decodeSpectrum(vArr)
        } else {
            throw SGStemError.invalidOutput
        }

        // 2. Drums
        let drums: [Float]
        if let dArr = result.featureValue(for: "drums_spectrum")?.multiArrayValue {
            drums = try decodeSpectrum(dArr)
        } else if let dArr = result.featureValue(for: "drums")?.multiArrayValue {
            drums = try decodeSpectrum(dArr)
        } else {
            drums = [Float](repeating: 0, count: pcm.count)
        }

        // 3. Bass
        let bass: [Float]
        if let bArr = result.featureValue(for: "bass_spectrum")?.multiArrayValue {
            bass = try decodeSpectrum(bArr)
        } else if let bArr = result.featureValue(for: "bass")?.multiArrayValue {
            bass = try decodeSpectrum(bArr)
        } else {
            bass = [Float](repeating: 0, count: pcm.count)
        }

        // 4. Other
        let other: [Float]
        if let oArr = result.featureValue(for: "other_spectrum")?.multiArrayValue {
            other = try decodeSpectrum(oArr)
        } else if let oArr = result.featureValue(for: "other")?.multiArrayValue {
            other = try decodeSpectrum(oArr)
        } else {
            // Compute residual: other = original - (vocals + drums + bass)
            var rem = [Float](repeating: 0, count: pcm.count)
            for i in 0..<pcm.count {
                rem[i] = pcm[i] - (vocals[i] + drums[i] + bass[i])
            }
            other = rem
        }

        return SG4Stems(vocals: vocals, drums: drums, bass: bass, other: other)
    }

    func vocals(for pcm: [Float]) async throws -> [Float] {
        return try await stems(for: pcm).vocals
    }

    private func acquire() async {
        if running { await withCheckedContinuation { waiters.append($0) } }
        else { running = true }
    }

    private func release() {
        if waiters.isEmpty { running = false }
        else { waiters.removeFirst().resume() }
    }

    private func foreground() async -> Bool {
        #if canImport(UIKit)
        return await MainActor.run { UIApplication.shared.applicationState == .active }
        #else
        return true
        #endif
    }

    private func encode(_ pcm: [Float]) throws {
        try dsp.encode(pcm, into: UnsafeMutableBufferPointer(
            start: tensor.dataPointer.assumingMemoryBound(to: Float.self), count: tensor.count))
    }

    private func predictResult(accelerated: Bool) throws -> MLFeatureProvider {
        try Task.checkCancellation()
        let result: MLFeatureProvider
        if accelerated, let neural {
            do { result = try neural.prediction(from: provider) }
            catch {
                try Task.checkCancellation()
                neuralFailed = true
                NSLog("[spotifyglass] Sing using CPU after Neural Engine/GPU prediction failed: %@", String(describing: error))
                result = try cpu.prediction(from: provider)
            }
        } else { result = try cpu.prediction(from: provider) }
        return result
    }

    private func decodeSpectrum(_ output: MLMultiArray) throws -> [Float] {
        guard output.shape.map(\.intValue) == SGStemShape.spectrum,
              output.dataType == .float32 || output.dataType == .float16 else { throw SGStemError.invalidOutput }
        let strides = output.strides.map(\.intValue)
        var spectrum = [Float](repeating: 0, count: SGStemShape.spectrumCount)
        for row in 0..<SGStemShape.spectrum[1] {
            for frame in 0..<SGStemShape.spectrum[2] {
                for component in 0..<SGStemShape.spectrum[3] {
                    let source = row * strides[1] + frame * strides[2] + component * strides[3]
                    let target = (row * SGStemShape.spectrum[2] + frame) * SGStemShape.spectrum[3] + component
                    spectrum[target] = output.dataType == .float32
                        ? output.dataPointer.assumingMemoryBound(to: Float.self)[source]
                        : Float(output.dataPointer.assumingMemoryBound(to: Float16.self)[source])
                }
            }
        }
        return try spectrum.withUnsafeBufferPointer { try dsp.decode($0) }
    }
}
