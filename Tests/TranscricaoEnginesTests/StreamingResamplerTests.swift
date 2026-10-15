// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import XCTest
@testable import TranscricaoEngines

final class StreamingResamplerTests: XCTestCase {
    func tone(rate: Double, channels: AVAudioChannelCount, hz: Double, seconds: Double,
                      chunk: Int) -> (AVAudioFormat, [AVAudioPCMBuffer]) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: channels, interleaved: false)!
        let total = Int(rate * seconds)
        var buffers: [AVAudioPCMBuffer] = []
        var n = 0
        while n < total {
            let len = min(chunk, total - n)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(len))!
            b.frameLength = AVAudioFrameCount(len)
            for c in 0..<Int(channels) {
                for i in 0..<len {
                    b.floatChannelData![c][i] = Float(0.5 * sin(2 * .pi * hz * Double(n + i) / rate))
                }
            }
            buffers.append(b)
            n += len
        }
        return (format, buffers)
    }

    private func run(rate: Double, channels: AVAudioChannelCount) throws -> [Float] {
        let (format, buffers) = tone(rate: rate, channels: channels, hz: 440, seconds: 1, chunk: 2048)
        let r = try XCTUnwrap(StreamingResampler(from: format))
        return buffers.flatMap { r.convert($0) }
    }

    func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    func testStereo48kBecomes16kMono() throws {
        let out = try run(rate: 48_000, channels: 2)
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 400)
        // 0.5 amplitude sine => RMS ~0.354, preserved after resampling (skip filter warm-up).
        XCTAssertEqual(rms(out[1000...]), 0.354, accuracy: 0.03)
    }

    func testMono48kBecomes16kMono() throws {
        let out = try run(rate: 48_000, channels: 1)
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 400)
        XCTAssertEqual(rms(out[1000...]), 0.354, accuracy: 0.03)
    }

    func testToneFrequencyIsPreserved() throws {
        let out = try run(rate: 44_100, channels: 1)
        let seg = Array(out[2000..<14000])
        var crossings = 0
        for i in 1..<seg.count where seg[i - 1] < 0 && seg[i] >= 0 { crossings += 1 }
        let hz = Double(crossings) / (Double(seg.count) / 16_000)
        XCTAssertEqual(hz, 440, accuracy: 10)
    }
}

extension StreamingResamplerTests {
    func testStereoWithSilentLeftChannelIsNotDropped() throws {
        let (format, buffers) = tone(rate: 48_000, channels: 2, hz: 440, seconds: 1, chunk: 2048)
        for b in buffers {
            for i in 0..<Int(b.frameLength) { b.floatChannelData![0][i] = 0 }
        }
        let r = try XCTUnwrap(StreamingResampler(from: format))
        let out = buffers.flatMap { r.convert($0) }
        XCTAssertGreaterThan(rms(out[1000...]), 0.1)
    }
}
