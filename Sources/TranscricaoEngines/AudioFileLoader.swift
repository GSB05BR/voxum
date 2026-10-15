// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import TranscricaoCore

public enum AudioFileError: Error, LocalizedError, Equatable {
    case emptyFile
    case bufferAllocationFailed
    case unsupportedFormat
    case conversionFailed(String)
    /// A video (or other media) without any audio track.
    case noAudioTrack
    /// Neither AVFoundation nor Core Audio can open it (not media, damaged, or a format this macOS
    /// cannot decode). `ogg`: an Ogg/Opus file (WhatsApp voice messages), named in the message.
    case unreadable(ogg: Bool)

    public var errorDescription: String? {
        switch self {
        case .emptyFile: return String(localized: "The audio file is empty.")
        case .bufferAllocationFailed: return String(localized: "Couldn't allocate the audio buffer.")
        case .unsupportedFormat: return String(localized: "Unsupported audio format.")
        case .conversionFailed(let detail): return String(localized: "Couldn't convert the audio: \(detail)")
        case .noAudioTrack: return String(localized: "This video has no audio track.")
        case .unreadable(ogg: true):
            return String(localized: "This Mac can't decode this Ogg/Opus audio (the format of WhatsApp voice messages). Convert it to .m4a or .mp3 and try again.")
        case .unreadable(ogg: false): return String(localized: "This file can't be opened as audio or video.")
        }
    }
}

public enum AudioFileLoader {
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Reads any audio file and converts it to 16 kHz mono Float32.
    public static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw AudioFileError.emptyFile }
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length))
        else { throw AudioFileError.bufferAllocationFailed }
        try file.read(into: input)
        return try convert(input)
    }

    public static func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        guard let converter = AVAudioConverter(from: input.format, to: targetFormat) else { throw AudioFileError.unsupportedFormat }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { throw AudioFileError.bufferAllocationFailed }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw AudioFileError.conversionFailed(error.localizedDescription) }
        if status == .error { throw AudioFileError.conversionFailed("status .error") }
        let ptr = output.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(output.frameLength)))
    }
}

/// Reads any file AVFoundation opens (m4a, mp3, wav, aiff, caf, flac, Ogg/Opus where macOS decodes
/// it, and the audio of mp4/mov videos) as 16 kHz mono Float32, a piece at a time: a long file is
/// never decoded whole (`FileTranscription` keeps about one minute in memory).
///
/// AVAssetReader first (it mixes every audio track down and resamples itself, and tells a video
/// without audio apart); a file AVFoundation cannot open as an asset is retried with Core Audio
/// (`AVAudioFile`), which knows a few more audio formats.
public final class AudioFileReader: AudioSampleSource {
    public let expectedSamples: Int?
    private var backend: Backend
    private var pending: [Float] = []
    private var produced = 0
    private var ended = false

    private enum Backend {
        case asset(AVAssetReader, AVAssetReaderOutput)
        case file(AVAudioFile, AVAudioConverter)
    }

    /// The extensions of Ogg files (the error then names the format).
    static let oggExtensions: Set<String> = ["ogg", "oga", "opus"]

    private init(backend: Backend, expectedSamples: Int?) {
        self.backend = backend
        self.expectedSamples = expectedSamples
    }

    /// AVFoundation or Core Audio can read Ogg files on this Mac (Ogg/Opus, newer macOS).
    public static let systemDecodesOgg: Bool = {
        if AVURLAsset.audiovisualTypes().contains(where: { $0.rawValue == "org.xiph.ogg-audio" }) { return true }
        var size: UInt32 = 0
        guard AudioFileGetGlobalInfoSize(kAudioFileGlobalInfo_ReadableTypes, 0, nil, &size) == noErr, size > 0 else { return false }
        var types = [AudioFileTypeID](repeating: 0, count: Int(size) / MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetGlobalInfo(kAudioFileGlobalInfo_ReadableTypes, 0, nil, &size, &types) == noErr else { return false }
        return types.contains(0x4F67_6766) // 'Oggf'
    }()

    /// Opens `url`; throws `AudioFileError` (`noAudioTrack`, `unreadable`) when there is no audio
    /// to read.
    /// `coreAudioOnly` skips AVAssetReader (tests compare both paths).
    public static func open(_ url: URL, coreAudioOnly: Bool = false) async throws -> AudioFileReader {
        let asset = AVURLAsset(url: url)
        var hasVideo = false
        do {
            let tracks = coreAudioOnly ? [] : try await asset.loadTracks(withMediaType: .audio)
            if !tracks.isEmpty {
                var seconds = 0.0
                for track in tracks { seconds = max(seconds, try await track.load(.timeRange).duration.seconds) }
                if seconds.isFinite, seconds <= 0 { throw AudioFileError.emptyFile }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: AudioFileLoader.targetFormat.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                ])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw AudioFileError.unsupportedFormat }
                reader.add(output)
                guard reader.startReading() else {
                    throw AudioFileError.conversionFailed(reader.error?.localizedDescription ?? "AVAssetReader")
                }
                let expected = seconds.isFinite && seconds > 0 ? Int(seconds * AudioFileLoader.targetFormat.sampleRate) : nil
                return AudioFileReader(backend: .asset(reader, output), expectedSamples: expected)
            }
            if !coreAudioOnly { hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty }
        } catch let error as AudioFileError {
            throw error
        } catch {
            // Not an asset AVFoundation knows: Core Audio may still read it (below).
        }
        if hasVideo { throw AudioFileError.noAudioTrack }
        guard let file = try? AVAudioFile(forReading: url),
              let converter = AVAudioConverter(from: file.processingFormat, to: AudioFileLoader.targetFormat)
        else {
            // The Ogg advice ("convert it") only where this Mac can't decode Ogg at all: here a
            // .opus that doesn't open is damaged, and converting is the wrong advice.
            throw AudioFileError.unreadable(ogg: oggExtensions.contains(url.pathExtension.lowercased()) && !systemDecodesOgg)
        }
        if file.processingFormat.channelCount > 1 { converter.downmix = true }
        let ratio = AudioFileLoader.targetFormat.sampleRate / file.processingFormat.sampleRate
        return AudioFileReader(backend: .file(file, converter), expectedSamples: Int(Double(file.length) * ratio))
    }

    public func read(maxSamples: Int) throws -> [Float] {
        let want = max(1, maxSamples)
        while pending.count < want, !ended {
            let more = try decodeMore(want)
            if more.isEmpty { ended = true } else { pending += more }
        }
        let n = min(want, pending.count)
        let out = Array(pending[..<n])
        pending.removeFirst(n)
        produced += n
        if out.isEmpty, produced == 0 { throw AudioFileError.emptyFile }
        return out
    }

    /// The next decoded samples; empty at the end.
    private func decodeMore(_ want: Int) throws -> [Float] {
        switch backend {
        case .asset(let reader, let output):
            while true {
                guard let buffer = output.copyNextSampleBuffer() else {
                    if reader.status == .failed {
                        throw AudioFileError.conversionFailed(reader.error?.localizedDescription ?? "AVAssetReader")
                    }
                    return []
                }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let bytes = CMBlockBufferGetDataLength(block)
                guard bytes > 0 else { continue }
                var samples = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
                let status = samples.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw AudioFileError.conversionFailed("CMBlockBuffer \(status)") }
                return samples
            }
        case .file(let file, let converter):
            let ratio = file.processingFormat.sampleRate / AudioFileLoader.targetFormat.sampleRate
            let frames = AVAudioFrameCount(max(1024, Double(want) * ratio))
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
                  let output = AVAudioPCMBuffer(pcmFormat: AudioFileLoader.targetFormat,
                                                frameCapacity: AVAudioFrameCount(Double(frames) / ratio) + 4096)
            else { throw AudioFileError.bufferAllocationFailed }
            // The converter may hold a read back (its filter latency): read on until it gives
            // samples, and flush it at the end of the file.
            while true {
                // Reading past the end throws (eofErr): check the position instead.
                let atEnd = file.framePosition >= file.length
                if atEnd { input.frameLength = 0 } else { try file.read(into: input, frameCount: frames) }
                var fed = false
                var error: NSError?
                output.frameLength = 0
                let status = converter.convert(to: output, error: &error) { _, state in
                    if atEnd { state.pointee = .endOfStream; return nil }
                    if fed { state.pointee = .noDataNow; return nil }
                    fed = true
                    state.pointee = .haveData
                    return input
                }
                if let error { throw AudioFileError.conversionFailed(error.localizedDescription) }
                if status == .error { throw AudioFileError.conversionFailed("status .error") }
                if output.frameLength > 0, let channel = output.floatChannelData {
                    return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
                }
                if atEnd { return [] }
            }
        }
    }
}
