// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation

/// One AVAudioConverter per recording so the resampler keeps its filter state
/// across tap buffers (a fresh converter per buffer causes boundary artifacts).
public final class StreamingResampler: @unchecked Sendable {
    private let converter: AVAudioConverter

    public init?(from format: AVAudioFormat) {
        guard let c = AVAudioConverter(from: format, to: AudioFileLoader.targetFormat) else { return nil }
        if format.channelCount > 1 { c.downmix = true } // average channels instead of taking channel 0
        converter = c
    }

    public func convert(_ input: AVAudioPCMBuffer) -> [Float] {
        let ratio = AudioFileLoader.targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioFileLoader.targetFormat,
                                            frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil } // keep stream open
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
