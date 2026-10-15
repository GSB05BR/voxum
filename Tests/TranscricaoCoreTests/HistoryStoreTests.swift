// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class HistoryStoreTests: XCTestCase {
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
    }

    func entry(_ s: String) -> DictationResult {
        DictationResult(date: Date(timeIntervalSince1970: 1_000), raw: s, final: s.uppercased(),
                        aiEnabled: true, usedFallback: false,
                        timings: StageTimings(transcribe: 0.1, process: 0.2, total: 0.3))
    }

    func testAppendNewestFirstAndPersists() {
        let h = HistoryStore(fileURL: url)
        h.append(entry("a")); h.append(entry("b"))
        XCTAssertEqual(h.entries.map(\.raw), ["b", "a"])
        let reloaded = HistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.map(\.raw), ["b", "a"])
    }

    func testLimit() {
        let h = HistoryStore(fileURL: url, limit: 3)
        for s in ["a", "b", "c", "d"] { h.append(entry(s)) }
        XCTAssertEqual(h.entries.map(\.raw), ["d", "c", "b"])
    }

    func testReadsEntriesWrittenBeforeFallbackReasonExisted() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = """
        [{"date":"2026-10-13T15:00:00Z","raw":"a","final":"A","aiEnabled":true,"usedFallback":true,
          "timings":{"transcribe":0.1,"process":0.2,"total":0.3}}]
        """
        try Data(old.utf8).write(to: url)
        let h = HistoryStore(fileURL: url)
        XCTAssertEqual(h.entries.map(\.raw), ["a"])
        XCTAssertNil(h.entries.first?.fallbackReason)
    }

    func testFallbackReasonRoundTrips() {
        let h = HistoryStore(fileURL: url)
        var e = entry("a"); e.usedFallback = true; e.fallbackReason = .truncated
        h.append(e)
        XCTAssertEqual(HistoryStore(fileURL: url).entries.first?.fallbackReason, .truncated)
    }

    func testCorruptFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(HistoryStore(fileURL: url).entries.count, 0)
    }
}
