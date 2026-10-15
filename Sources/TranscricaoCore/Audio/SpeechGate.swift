// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Decides whether a captured clip is worth sending to Whisper.
/// Uses the loudest short window rather than the clip-wide RMS so a long
/// recording with a little speech is not mistaken for silence.
public struct SpeechGate: Sendable {
    public var sampleRate: Double
    public var minDuration: Double
    public var minPeakRMS: Float
    public var windowSeconds: Double

    public init(sampleRate: Double = 16_000, minDuration: Double = 0.4,
                minPeakRMS: Float = 0.01, windowSeconds: Double = 0.1) {
        self.sampleRate = sampleRate
        self.minDuration = minDuration
        self.minPeakRMS = minPeakRMS
        self.windowSeconds = windowSeconds
    }

    public func shouldTranscribe(_ samples: [Float]) -> Bool {
        guard Double(samples.count) / sampleRate >= minDuration else { return false }
        let window = max(1, Int(windowSeconds * sampleRate))
        return Self.peakWindowRMS(samples, windowSize: window) >= minPeakRMS
    }

    public static func peakWindowRMS(_ samples: [Float], windowSize: Int) -> Float {
        guard !samples.isEmpty, windowSize > 0 else { return 0 }
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(start + windowSize, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            peak = max(peak, (sum / Float(end - start)).squareRoot())
            start = end
        }
        return peak
    }
}
