// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class PasteSafetyTests: XCTestCase {
    typealias Facts = SelectionClassifier.Facts

    func testColarNeedsAnEditableTarget() {
        XCTAssertTrue(PasteSafety.acceptsPaste(Facts(role: "AXTextArea", selectedTextSettable: true)))
        XCTAssertTrue(PasteSafety.acceptsPaste(Facts(role: "AXTextField", valueSettable: true)))
        var web = Facts(role: "AXGroup")
        web.insideEditableWebContent = true
        XCTAssertTrue(PasteSafety.acceptsPaste(web), "contenteditable box (reply field on a web page)")
        XCTAssertFalse(PasteSafety.acceptsPaste(Facts(role: "AXWebArea")), "a page: nothing to paste into")
        XCTAssertFalse(PasteSafety.acceptsPaste(Facts(role: "AXTextArea")), "read-only text area (Terminal output)")
        XCTAssertFalse(PasteSafety.acceptsPaste(Facts(role: nil)), "no focused element")
        XCTAssertFalse(PasteSafety.acceptsPaste(nil), "unreadable in time")
    }

    func testUndoNeedsNoInputSinceThePaste() {
        XCTAssertTrue(PasteSafety.undoAllowedByInput(lastOtherInputAt: 10, pastedAt: 12))
        XCTAssertTrue(PasteSafety.undoAllowedByInput(lastOtherInputAt: 12, pastedAt: 12))
        XCTAssertFalse(PasteSafety.undoAllowedByInput(lastOtherInputAt: 12.3, pastedAt: 12),
                       "a ⌘Z or a keystroke right after the edit")
    }

    func testUndoCheckConfirmsOnlyThePastedTextAtTheCursor() {
        let pasted = "Olá, como está? Tudo bem?"
        XCTAssertEqual(PasteSafety.undoCheck(pasted: pasted, textBeforeCursor: pasted, selectionLength: 0), .confirmed)
        XCTAssertEqual(PasteSafety.undoCheck(pasted: "a\nb", textBeforeCursor: "a\r\nb", selectionLength: 0), .confirmed)
        XCTAssertEqual(PasteSafety.undoCheck(pasted: "e\u{301}", textBeforeCursor: "é", selectionLength: 0), .confirmed)
        // The user typed after the paste (the cursor moved on), or undid it already (the original
        // selection is back and selected), or moved the cursor.
        XCTAssertEqual(PasteSafety.undoCheck(pasted: pasted, textBeforeCursor: "mo está? Tudo bem? ok", selectionLength: 0), .changed)
        XCTAssertEqual(PasteSafety.undoCheck(pasted: pasted, textBeforeCursor: pasted, selectionLength: 5), .changed)
        XCTAssertEqual(PasteSafety.undoCheck(pasted: pasted, textBeforeCursor: "", selectionLength: 0), .changed)
        XCTAssertEqual(PasteSafety.undoCheck(pasted: "", textBeforeCursor: "", selectionLength: 0), .changed)
        XCTAssertEqual(PasteSafety.undoCheck(pasted: pasted, textBeforeCursor: nil, selectionLength: 0), .unreadable)
        XCTAssertEqual(PasteSafety.undoCheck(pasted: pasted, textBeforeCursor: pasted, selectionLength: nil), .unreadable)
    }
}
