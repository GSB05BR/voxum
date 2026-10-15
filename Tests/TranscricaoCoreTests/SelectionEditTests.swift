// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class SelectionEditTests: XCTestCase {
    func testUsableSelection() {
        XCTAssertNil(SelectionEdit.usable(nil))
        XCTAssertNil(SelectionEdit.usable(""))
        XCTAssertNil(SelectionEdit.usable(" \n\t "))
        XCTAssertEqual(SelectionEdit.usable(" oi \n"), " oi \n") // passed on unchanged
        let max = String(repeating: "a", count: SelectionEdit.maxCharacters)
        XCTAssertEqual(SelectionEdit.usable(max), max)
        XCTAssertNil(SelectionEdit.usable(max + "a"))
    }

    func testTimeoutGrowsWithSelection() {
        XCTAssertEqual(SelectionEdit.processingTimeout(base: 6, selectionCharacters: 0), 6)
        XCTAssertEqual(SelectionEdit.processingTimeout(base: 6, selectionCharacters: 1000), 16, accuracy: 0.001)
        XCTAssertGreaterThan(SelectionEdit.processingTimeout(base: 6, selectionCharacters: 1200),
                             SelectionEdit.processingTimeout(base: 6, selectionCharacters: 100))
        XCTAssertEqual(SelectionEdit.processingTimeout(base: 6, selectionCharacters: 3000), 20) // capped
        XCTAssertGreaterThanOrEqual(SelectionEdit.captureWait, 1.5)
    }

    func testPreservingEdges() {
        XCTAssertEqual(SelectionEdit.preservingEdges(of: "abc", "X"), "X")
        XCTAssertEqual(SelectionEdit.preservingEdges(of: "abc\n", "X"), "X\n")
        XCTAssertEqual(SelectionEdit.preservingEdges(of: "  abc \n", "X"), "  X \n")
        XCTAssertEqual(SelectionEdit.preservingEdges(of: "   ", "X"), "X")
    }
}
