// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

/// Virtual time: `sleep` advances it at once.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 100
    var now: TimeInterval { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    var clock: CopyClock { CopyClock(now: { self.now }, sleep: { self.advance($0) }) }
}

/// A pasteboard holding the user's clipboard; the target app's ⌘C lands `copyAfter` seconds
/// after it is posted (nil = the app copies nothing), clearing first and writing `copyText`
/// `writeDelay` later.
@MainActor
final class FakePasteboard: CopyPasteboard {
    let clock: FakeClock
    var copyAfter: TimeInterval?
    var copyText: String? = "selecionado"
    var writeDelay: TimeInterval = 0
    /// Set by `post()`.
    var postedAt: TimeInterval?
    /// The user's clipboard and changes made outside the ⌘C (e.g. the user copying).
    var userContents = "clipboard do usuário"
    var extraChanges = 0
    private(set) var restoredContents: String?
    private(set) var restoreCount = 0
    /// Whether the app's text write had already happened when the restore ran.
    private(set) var restoredAfterWrite: Bool?

    init(clock: FakeClock) { self.clock = clock }

    private var elapsed: TimeInterval? { postedAt.map { clock.now - $0 } }
    private var cleared: Bool { if let e = elapsed, let c = copyAfter { return e >= c } else { return false } }
    private var written: Bool { if let e = elapsed, let c = copyAfter { return e >= c + writeDelay } else { return false } }

    var changeCount: Int { (cleared ? 1 : 0) + (written && writeDelay > 0 ? 1 : 0) + extraChanges + restoreCount }
    func snapshot() -> String { userContents }
    func copiedText() -> String? { written ? copyText : nil }
    func restore(_ snapshot: String, ifChangeCount changeCount: Int) {
        guard changeCount == self.changeCount else { return }
        restoredContents = snapshot
        restoredAfterWrite = written
        restoreCount += 1
    }
    func post() { postedAt = clock.now }
}

@MainActor
final class CommandCopyTests: XCTestCase {
    func run(_ pb: FakePasteboard, userInput: Bool = false) async -> CommandCopy.Result {
        await CommandCopy.run(on: pb, clock: pb.clock.clock, userInputSince: { _ in userInput }, post: pb.post)
    }

    func testCopyWithinTheWindowIsTheSelectionAndTheClipboardIsRestored() async {
        let pb = FakePasteboard(clock: FakeClock())
        pb.copyAfter = 0.18 // Slack under load (I1): past the old 150 ms limit
        let result = await run(pb)
        XCTAssertEqual(result, .copied("selecionado"))
        XCTAssertEqual(pb.restoredContents, "clipboard do usuário")
        XCTAssertEqual(CommandCopy.selection(result, kind: .editable), .selected("selecionado", .editable))
    }

    func testClearThenWriteWaitsForTheTextBeforeRestoring() async {
        let pb = FakePasteboard(clock: FakeClock())
        pb.copyAfter = 0.1
        pb.writeDelay = 0.05
        let result = await run(pb)
        XCTAssertEqual(result, .copied("selecionado"))
        XCTAssertEqual(pb.restoreCount, 1)
        XCTAssertEqual(pb.restoredAfterWrite, true, "restored after the write, not between clear and write")
    }

    func testNothingCopiedIsNoSelectionAfterTheWholeWatch() async {
        let clock = FakeClock()
        let pb = FakePasteboard(clock: clock)
        let start = clock.now
        let result = await run(pb)
        XCTAssertEqual(result, .nothingCopied)
        XCTAssertGreaterThanOrEqual(clock.now - start, CommandCopy.watchWindow)
        XCTAssertEqual(pb.restoreCount, 0)
        XCTAssertEqual(CommandCopy.selection(result, kind: .readOnly), .none)
    }

    func testLateCopyIsRestoredAndTheSelectionIsUnknown() async {
        let pb = FakePasteboard(clock: FakeClock())
        pb.copyAfter = 0.7
        let result = await run(pb)
        XCTAssertEqual(result, .lateCopy)
        XCTAssertEqual(pb.restoredContents, "clipboard do usuário", "the user's clipboard is never lost")
        // Never "no selection": nothing is pasted over a selection that turned out to exist.
        XCTAssertEqual(CommandCopy.selection(result, kind: .editable), .unknown)
    }

    func testLateCopyAfterUserInputIsLeftAlone() async {
        let pb = FakePasteboard(clock: FakeClock())
        pb.copyAfter = 0.7
        let result = await run(pb, userInput: true)
        XCTAssertEqual(result, .lateCopy)
        XCTAssertEqual(pb.restoreCount, 0, "the user may have copied something: theirs wins")
    }

    func testNonTextCopyIsNoSelectionButStillRestored() async {
        let pb = FakePasteboard(clock: FakeClock())
        pb.copyAfter = 0.05
        pb.copyText = nil // files (Finder) or an image
        let result = await run(pb)
        XCTAssertEqual(result, .copied(nil))
        XCTAssertEqual(pb.restoreCount, 1)
        XCTAssertEqual(CommandCopy.selection(result, kind: .readOnly), .none)
    }

    func testDecisionRule() {
        XCTAssertEqual(CommandCopy.result(movedAfter: nil, text: nil), .nothingCopied)
        XCTAssertEqual(CommandCopy.result(movedAfter: 0.12, text: "a"), .copied("a"))
        XCTAssertEqual(CommandCopy.result(movedAfter: CommandCopy.answerWindow, text: "a"), .copied("a"))
        XCTAssertEqual(CommandCopy.result(movedAfter: CommandCopy.answerWindow + 0.01, text: "a"), .lateCopy)
        XCTAssertTrue(CommandCopy.shouldRestore(.copied("a"), userInputSinceCopy: true))
        XCTAssertTrue(CommandCopy.shouldRestore(.lateCopy, userInputSinceCopy: false))
        XCTAssertFalse(CommandCopy.shouldRestore(.lateCopy, userInputSinceCopy: true))
        XCTAssertFalse(CommandCopy.shouldRestore(.nothingCopied, userInputSinceCopy: false))
    }

    func testTheWatchEndsWellWithinThePipelineWait() {
        // ⌘C goes out ~0.2 s after ⌥-down; the pipeline waits up to captureWait after transcription.
        XCTAssertLessThan(CommandCopy.watchWindow + CommandCopy.textSettle, SelectionEdit.captureWait)
        XCTAssertGreaterThan(CommandCopy.answerWindow, 0.4)
    }
}
