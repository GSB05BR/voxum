// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import TranscricaoCore
import TranscricaoEngines

/// Thread-safe sample accumulator written from the audio render thread.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    func append(_ s: [Float]) { lock.withLock { samples.append(contentsOf: s) } }
    var count: Int { lock.withLock { samples.count } }
    func drain() -> [Float] { lock.withLock { defer { samples = [] }; return samples } }
}

/// Captures the default input at 16 kHz mono Float32. The engine only runs
/// while recording so the macOS mic indicator is off otherwise.
@MainActor
final class AudioRecorder {
    static let maxSeconds: Double = 300

    private var engine: AVAudioEngine?
    private let buffer = SampleBuffer()
    var onLevel: ((Float) -> Void)?
    var onLimitReached: (() -> Void)?
    /// The audio device configuration changed mid-recording (engine stopped); treat like the limit.
    var onInterrupted: (() -> Void)?
    /// Bumped on every start/stop so late main-actor callbacks from an old recording are ignored.
    private var generation = 0
    private var configObserver: NSObjectProtocol?

    func start() throws {
        _ = buffer.drain()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let resampler = StreamingResampler(from: format) else {
            throw NSError(domain: AppIdentity.bundleID, code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Unsupported audio format.")])
        }
        generation += 1
        let gen = generation
        let buffer = self.buffer
        let maxSamples = Int(Self.maxSeconds * 16_000)
        var limitFired = false
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] pcm, _ in
            let samples = resampler.convert(pcm)
            guard !samples.isEmpty else { return }
            buffer.append(samples)
            var sum: Float = 0
            for s in samples { sum += s * s }
            let rms = (sum / Float(samples.count)).squareRoot()
            let reachedLimit = buffer.count >= maxSamples && !limitFired
            if reachedLimit { limitFired = true }
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.onLevel?(rms)
                if reachedLimit { self.onLimitReached?() }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.onInterrupted?()
            }
        }
    }

    func stop() -> [Float] {
        teardown()
        return buffer.drain()
    }

    func cancel() {
        teardown()
        _ = buffer.drain()
    }

    private func teardown() {
        generation += 1
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
