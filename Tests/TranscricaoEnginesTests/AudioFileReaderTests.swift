// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import XCTest
@testable import TranscricaoEngines

/// The file reader on every format (fixtures/audio/formats: the 5.2 s `say` clip correcao.wav,
/// re-encoded) and on files with nothing to read.
final class AudioFileReaderTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/audio")
    static let seconds = 5.22

    private func readAll(_ reader: AudioFileReader, step: Int = 16_000) throws -> [Float] {
        var all: [Float] = []
        while true {
            let piece = try reader.read(maxSamples: step)
            XCTAssertLessThanOrEqual(piece.count, step)
            if piece.isEmpty { return all }
            all += piece
        }
    }

    private func rms(_ s: [Float]) -> Float { (s.reduce(0) { $0 + $1 * $1 } / Float(max(1, s.count))).squareRoot() }

    func testEveryFormatIsReadAsTheSameAudio() async throws {
        let reference = try AudioFileLoader.load16kMono(Self.fixtures.appendingPathComponent("correcao.wav"))
        for name in ["correcao.wav", "formats/correcao.m4a", "formats/correcao.mp3", "formats/correcao.mp4",
                     "formats/correcao.opus", "formats/correcao.ogg"] {
            let url = Self.fixtures.appendingPathComponent(name)
            let reader: AudioFileReader
            do {
                reader = try await AudioFileReader.open(url)
            } catch AudioFileError.unreadable(ogg: true) {
                // Older macOS without Ogg/Opus: the app shows the Ogg message (checked below).
                continue
            }
            let samples = try readAll(reader)
            let seconds = Double(samples.count) / 16_000
            XCTAssertEqual(seconds, Self.seconds, accuracy: 0.15, name)
            XCTAssertEqual(Double(reader.expectedSamples ?? 0) / 16_000, Self.seconds, accuracy: 0.3, name)
            XCTAssertEqual(rms(samples), rms(reference), accuracy: rms(reference) * 0.25, name)
        }
    }

    func testCoreAudioReadsTheSameAudio() async throws {
        for name in ["correcao.wav", "formats/correcao.m4a", "formats/correcao.opus"] {
            let url = Self.fixtures.appendingPathComponent(name)
            guard let viaAsset = try? await AudioFileReader.open(url),
                  let viaCoreAudio = try? await AudioFileReader.open(url, coreAudioOnly: true) else { continue }
            let a = try readAll(viaAsset), b = try readAll(viaCoreAudio, step: 7_000)
            XCTAssertEqual(Double(a.count), Double(b.count), accuracy: 16_000 * 0.05, name)
            XCTAssertEqual(rms(a), rms(b), accuracy: rms(a) * 0.1, name)
        }
    }

    func testAVideoWithoutAudioSaysSo() async {
        do {
            _ = try await AudioFileReader.open(Self.fixtures.appendingPathComponent("formats/video-sem-audio.mov"))
            XCTFail("a video without audio must not open")
        } catch {
            XCTAssertEqual(error as? AudioFileError, .noAudioTrack)
            XCTAssertEqual(error.localizedDescription, "This video has no audio track.")
        }
    }

    func testFilesThatAreNotMedia() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, ogg) in [("notes.mp3", false), ("voice.opus", true), ("voice.OGG", true), ("empty.wav", false)] {
            let url = dir.appendingPathComponent(name)
            try Data(name == "empty.wav" ? [] : Array("not audio at all".utf8)).write(to: url)
            do {
                _ = try await AudioFileReader.open(url)
                XCTFail("\(name) must not open")
            } catch {
                // The Ogg advice only where the system can't decode Ogg; otherwise the file is damaged.
                XCTAssertEqual(error as? AudioFileError, .unreadable(ogg: ogg && !AudioFileReader.systemDecodesOgg), name)
            }
        }
        XCTAssertTrue(AudioFileError.unreadable(ogg: true).localizedDescription.contains("Ogg/Opus"))
        // A valid file with no audio frames.
        let silent = dir.appendingPathComponent("zero.caf")
        _ = try AVAudioFile(forWriting: silent, settings: AudioFileLoader.targetFormat.settings)
        do {
            let reader = try await AudioFileReader.open(silent)
            _ = try reader.read(maxSamples: 1000)
            XCTFail("an audio file without frames is empty")
        } catch {
            XCTAssertTrue([AudioFileError.emptyFile, .unreadable(ogg: false)].contains(error as? AudioFileError), "\(error)")
        }
    }
}
