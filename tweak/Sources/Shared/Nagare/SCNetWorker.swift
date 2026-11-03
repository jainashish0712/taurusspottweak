// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Raka-Saka
//
// SCNet Background Worker
// Asynchronous chunk scheduler, lookahead queue, and crossfading for SCNet Core ML inference.

import Foundation

public typealias SCNetWriteCallback = @convention(c) (
    UnsafePointer<Float>?, // drums
    UnsafePointer<Float>?, // bass
    UnsafePointer<Float>?, // other
    UnsafePointer<Float>?, // vocals
    Int32                  // numFrames
) -> Void

@available(iOS 18.0, macOS 27.0, *)
private final class SCNetWorkerSession: @unchecked Sendable {
    static let shared = SCNetWorkerSession()

    private var separator: SCNetSeparator?
    private var modelPath: String?
    private var isRunning = false
    private var isModelReady = false

    private let queue = DispatchQueue(label: "com.spoti.pw.scnet.worker", qos: .userInitiated)
    private var inputPcm: [Float] = []
    private let inputLock = NSLock()

    private var writeCallback: SCNetWriteCallback?

    // Chunk size: 486,400 samples (~11.0s at 44.1kHz)
    // Hop size: 352,800 samples (~8.0s) -> Overlap: 133,600 samples (~3.0s)
    private let chunkSize = SCNetSpectralDSP.chunkSamples
    private let hopSize = 352800
    private var overlapSize: Int { chunkSize - hopSize }

    private var prevDrumsTail: [Float] = []
    private var prevBassTail: [Float] = []
    private var prevOtherTail: [Float] = []
    private var prevVocalsTail: [Float] = []

    func start(modelPath: String, callback: @escaping SCNetWriteCallback) {
        self.writeCallback = callback
        self.modelPath = modelPath
        self.isRunning = true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                let url = URL(fileURLWithPath: modelPath)
                let sep = try await SCNetSeparator(modelURL: url)
                try await sep.warmUp()
                self.separator = sep
                self.isModelReady = true
                self.scheduleNextChunk()
            } catch {
                NSLog("[spotifyglass] SCNet failed to initialize: %@", String(describing: error))
                self.isModelReady = false
            }
        }
    }

    func stop() {
        isRunning = false
        isModelReady = false
        separator = nil
        inputLock.lock()
        inputPcm.removeAll(keepingCapacity: true)
        prevDrumsTail.removeAll()
        prevBassTail.removeAll()
        prevOtherTail.removeAll()
        prevVocalsTail.removeAll()
        inputLock.unlock()
    }

    func isReady() -> Bool {
        return isModelReady
    }

    func pushAudio(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        guard isRunning else { return }
        inputLock.lock()
        inputPcm.reserveCapacity(inputPcm.count + frames * 2)
        for i in 0..<frames {
            inputPcm.append(left[i])
            inputPcm.append(right[i])
        }
        let available = inputPcm.count / 2
        inputLock.unlock()

        if available >= chunkSize && isModelReady {
            queue.async { [weak self] in
                self?.processPendingAudio()
            }
        }
    }

    private func processPendingAudio() {
        guard isRunning, isModelReady, let separator = separator else { return }

        var chunkToProcess: [Float] = []
        inputLock.lock()
        if inputPcm.count >= chunkSize * 2 {
            chunkToProcess = Array(inputPcm[0..<(chunkSize * 2)])
            // Advance by hop size (preserving overlap)
            inputPcm.removeFirst(hopSize * 2)
        }
        inputLock.unlock()

        guard chunkToProcess.count == chunkSize * 2 else { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                let stems = try await separator.separate(stereoPcm: chunkToProcess)
                self.emitStemsWithCrossfade(stems: stems)
                self.processPendingAudio() // check if more audio queued
            } catch {
                NSLog("[spotifyglass] SCNet inference error: %@", String(describing: error))
            }
        }
    }

    private func emitStemsWithCrossfade(stems: SCNetSeparatedStems) {
        guard let callback = writeCallback else { return }

        let overlap = self.overlapSize
        let hop = self.hopSize

        // We emit 'hop' frames to the output callback
        var outDrums = [Float](repeating: 0, count: hop * 2)
        var outBass = [Float](repeating: 0, count: hop * 2)
        var outOther = [Float](repeating: 0, count: hop * 2)
        var outVocals = [Float](repeating: 0, count: hop * 2)

        let hasPrev = prevDrumsTail.count == overlap * 2

        for i in 0..<hop {
            if i < overlap && hasPrev {
                let weight = Float(i) / Float(overlap)
                let inv = 1.0 - weight
                for ch in 0..<2 {
                    let idx = i * 2 + ch
                    outDrums[idx] = prevDrumsTail[idx] * inv + stems.drums[idx] * weight
                    outBass[idx] = prevBassTail[idx] * inv + stems.bass[idx] * weight
                    outOther[idx] = prevOtherTail[idx] * inv + stems.other[idx] * weight
                    outVocals[idx] = prevVocalsTail[idx] * inv + stems.vocals[idx] * weight
                }
            } else {
                for ch in 0..<2 {
                    let idx = i * 2 + ch
                    outDrums[idx] = stems.drums[idx]
                    outBass[idx] = stems.bass[idx]
                    outOther[idx] = stems.other[idx]
                    outVocals[idx] = stems.vocals[idx]
                }
            }
        }

        // Save new tail for next chunk's overlap
        let tailStart = hop * 2
        let tailEnd = (hop + overlap) * 2
        prevDrumsTail = Array(stems.drums[tailStart..<tailEnd])
        prevBassTail = Array(stems.bass[tailStart..<tailEnd])
        prevOtherTail = Array(stems.other[tailStart..<tailEnd])
        prevVocalsTail = Array(stems.vocals[tailStart..<tailEnd])

        // Deliver separated stems to C callback
        outDrums.withUnsafeBufferPointer { dPtr in
            outBass.withUnsafeBufferPointer { bPtr in
                outOther.withUnsafeBufferPointer { oPtr in
                    outVocals.withUnsafeBufferPointer { vPtr in
                        callback(dPtr.baseAddress, bPtr.baseAddress, oPtr.baseAddress, vPtr.baseAddress, Int32(hop))
                    }
                }
            }
        }
    }

    private func scheduleNextChunk() {
        inputLock.lock()
        let available = inputPcm.count / 2
        inputLock.unlock()

        if available >= chunkSize {
            queue.async { [weak self] in
                self?.processPendingAudio()
            }
        }
    }
}

// C-compatible bridge exports
@_cdecl("SCNetWorkerStart")
public func scnetWorkerStart(_ modelPath: UnsafePointer<CChar>?, _ callback: SCNetWriteCallback?) -> Int32 {
    guard #available(iOS 18.0, macOS 27.0, *), let modelPath, let callback else { return 0 }
    let path = String(cString: modelPath)
    SCNetWorkerSession.shared.start(modelPath: path, callback: callback)
    return 1
}

@_cdecl("SCNetWorkerStop")
public func scnetWorkerStop() {
    if #available(iOS 18.0, macOS 27.0, *) {
        SCNetWorkerSession.shared.stop()
    }
}

@_cdecl("SCNetWorkerIsReady")
public func scnetWorkerIsReady() -> Int32 {
    if #available(iOS 18.0, macOS 27.0, *) {
        return SCNetWorkerSession.shared.isReady() ? 1 : 0
    }
    return 0
}

@_cdecl("SCNetWorkerPushAudio")
public func scnetWorkerPushAudio(_ left: UnsafePointer<Float>?, _ right: UnsafePointer<Float>?, _ frames: Int32) {
    guard #available(iOS 18.0, macOS 27.0, *), let left, let right, frames > 0 else { return }
    SCNetWorkerSession.shared.pushAudio(left: left, right: right, frames: Int(frames))
}
