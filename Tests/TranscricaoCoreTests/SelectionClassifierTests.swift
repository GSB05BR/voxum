// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class SelectionClassifierTests: XCTestCase {
    typealias F = SelectionClassifier.Facts
    func c(_ f: F) -> SelectionClassifier.Decision { SelectionClassifier.classify(f) }

    func testTextRoleSettableSelectionIsEditable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertEqual(c(F(role: role, selectedText: "oi", selectedTextSettable: true)), .selected("oi", .editable))
        }
    }

    func testTextRoleNotSettableIsReadOnly() {
        XCTAssertEqual(c(F(role: "AXTextArea", selectedText: "oi", selectedTextSettable: false)), .selected("oi", .readOnly))
    }

    func testTextRoleWithSettableValueIsEditable() {
        // WhatsApp (Catalyst): the message box's selected text is not settable, its value is.
        XCTAssertEqual(c(F(role: "AXTextArea", selectedText: "oi", valueSettable: true)), .selected("oi", .editable))
        // Terminal: neither is settable.
        XCTAssertEqual(c(F(role: "AXTextArea", selectedText: "oi")), .selected("oi", .readOnly))
    }

    func testWebKitTextMarkerSelectionIsReadOnly() {
        // Safari/X: a tweet (AXGroup) answers kAXErrorNoValue for its selected text; the page's
        // selection is only exposed through text markers.
        XCTAssertEqual(c(F(role: "AXGroup", selectedText: "", markerText: "tweet")), .selected("tweet", .readOnly))
        XCTAssertEqual(c(F(role: nil, markerText: "tweet")), .selected("tweet", .readOnly))
        XCTAssertEqual(c(F(role: "AXGroup", selectedText: "", markerText: "")), .none)
        // A text field's own selection wins over the page's.
        XCTAssertEqual(c(F(role: "AXTextArea", selectedText: "campo", selectedTextSettable: true, markerText: "página")),
                       .selected("campo", .editable))
    }

    func testTextRoleEmptySelectionIsNone() {
        XCTAssertEqual(c(F(role: "AXTextField", selectedText: "", selectedTextSettable: true)), .none)
    }

    func testTextRoleWithoutSelectedTextFallsToRange() {
        XCTAssertEqual(c(F(role: "AXTextArea", rangeLength: 5, rangeText: "texto")), .selected("texto", .readOnly))
        XCTAssertEqual(c(F(role: "AXTextArea", rangeLength: 0)), .none)
    }

    func testNonTextRoleSelectedTextIsReadOnly() {
        XCTAssertEqual(c(F(role: "AXWebArea", selectedText: "tweet")), .selected("tweet", .readOnly))
        XCTAssertEqual(c(F(role: "AXStaticText", selectedText: "x", selectedTextSettable: true)), .selected("x", .readOnly))
        XCTAssertEqual(c(F(role: "AXWebArea", selectedText: "")), .none)
    }

    func testNonTextRoleRange() {
        XCTAssertEqual(c(F(role: "AXGroup", rangeLength: 0)), .none)
        XCTAssertEqual(c(F(role: "AXGroup", rangeLength: 4, rangeText: "saída")), .selected("saída", .readOnly))
        XCTAssertEqual(c(F(role: "AXWebArea", selectedText: "", rangeLength: 3, rangeText: "abc")), .selected("abc", .readOnly))
    }

    func testCopyFallbackOnlyWhenEverythingFails() {
        XCTAssertEqual(c(F(role: nil)), .tryCopy(copyKind: .readOnly))
        XCTAssertEqual(c(F(role: "AXGroup")), .tryCopy(copyKind: .readOnly))
        XCTAssertEqual(c(F(role: "AXGroup", rangeLength: 3)), .tryCopy(copyKind: .readOnly)) // range but no string
        XCTAssertEqual(c(F(role: "AXTextArea")), .tryCopy(copyKind: .editable))
    }

    func testNeverCopiesFromItemLists() {
        for role in ["AXTable", "AXList", "AXOutline", "AXBrowser"] {
            XCTAssertEqual(c(F(role: role)), .none, role)
        }
    }
}

final class CopyFallbackPolicyTests: XCTestCase {
    func testCopyBlockedWithNoFocusedElementIsUnknown() {
        // Electron, tree off, another clip in flight: a selection may exist → never paste over it.
        XCTAssertEqual(CopyFallbackPolicy.selectionWhenCopyBlocked(lookup: .noFocusedElement), .unknown)
    }

    func testCopyBlockedOtherwiseIsNoSelection() {
        for lookup in [FocusLookup.found, .timedOut, .failed] {
            XCTAssertEqual(CopyFallbackPolicy.selectionWhenCopyBlocked(lookup: lookup), .none, "\(lookup)")
        }
    }

    func testCopyLineEditorsMatchedByPrefix() {
        for id in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.vscodium.codium",
                   "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.sublimetext.4",
                   "com.jetbrains.intellij", "com.jetbrains.pycharm.ce", "dev.zed.Zed", "dev.zed.Zed-Preview",
                   "com.visualstudio.code.oss", "com.google.android.studio"] {
            XCTAssertTrue(CopyFallbackPolicy.isCopyLineEditor(id), id)
            XCTAssertFalse(CopyFallbackPolicy.allowsCopy(id), id)
        }
    }

    func testOtherAppsAllowCopy() {
        for id in ["com.tinyspeck.slackmacgap", "com.google.Chrome", "com.apple.Terminal", "com.microsoft.Word",
                   "com.microsoft.teams2", "dev.zedcorp.other"] {
            XCTAssertFalse(CopyFallbackPolicy.isCopyLineEditor(id), id)
            XCTAssertTrue(CopyFallbackPolicy.allowsCopy(id), id)
        }
        XCTAssertTrue(CopyFallbackPolicy.allowsCopy(nil))
    }
}

final class AccessibilitySwitchPolicyTests: XCTestCase {
    func enable(_ lookup: FocusLookup, copied: Bool = true, attempted: Bool = false,
                id: String? = "com.tinyspeck.slackmacgap") -> Bool {
        AccessibilitySwitchPolicy.shouldEnable(lookup: lookup, copiedSelection: copied,
                                               alreadyAttempted: attempted, bundleID: id)
    }

    func testOnlyNoFocusedElementAfterAConfirmedCopyOncePerApp() {
        XCTAssertTrue(enable(.noFocusedElement))
        XCTAssertFalse(enable(.noFocusedElement, copied: false), "no selection confirmed: leave the app alone")
        XCTAssertFalse(enable(.noFocusedElement, attempted: true), "at most once per app run")
        XCTAssertFalse(enable(.timedOut), "a hung app is not touched")
        XCTAssertFalse(enable(.failed))
        XCTAssertFalse(enable(.found))
        XCTAssertFalse(enable(.noFocusedElement, id: "com.microsoft.VSCode"), "screen-reader mode in editors")
    }
}

final class SelectionUpgradeTests: XCTestCase {
    typealias F = SelectionClassifier.Facts
    let copied = CapturedSelection.selected("texto copiado", .readOnly)

    func r(_ captured: CapturedSelection, _ facts: F) -> CapturedSelection {
        SelectionUpgrade.reclassified(captured, with: facts)
    }

    func testUpgradesToEditableWhenTheTreeShowsAnEditableField() {
        let field = F(role: "AXTextArea", selectedText: "texto copiado", selectedTextSettable: true,
                      selectedTextReadSucceeded: true)
        XCTAssertEqual(SelectionUpgrade.outcome(for: copied, with: field), .upgradeToEditable)
        XCTAssertEqual(r(copied, field), .selected("texto copiado", .editable))
        // Selected text not readable yet, but the field is editable: still an upgrade (copied text kept).
        XCTAssertEqual(r(copied, F(role: "AXTextField", selectedTextSettable: true)),
                       .selected("texto copiado", .editable))
        // Same text apart from whitespace (line breaks, nbsp, trailing newline from ⌘C).
        XCTAssertEqual(r(.selected("linha um\nlinha dois\n", .readOnly),
                         F(role: "AXTextArea", selectedText: "linha um\u{00A0}linha  dois", selectedTextSettable: true,
                           selectedTextReadSucceeded: true)),
                       .selected("linha um\nlinha dois\n", .editable))
    }

    func testKeepsReadOnlyOtherwise() {
        for facts in [F(role: nil),
                      F(role: "AXWebArea", selectedText: "x", selectedTextSettable: true),
                      F(role: "AXTextArea", selectedText: "texto copiado", selectedTextSettable: false),
                      // A different selection than the one copied: never an upgrade (M3).
                      F(role: "AXTextArea", selectedText: "outra coisa", selectedTextSettable: true,
                        selectedTextReadSucceeded: true)] {
            XCTAssertEqual(SelectionUpgrade.outcome(for: copied, with: facts), .keep)
            XCTAssertEqual(r(copied, facts), copied)
        }
    }

    func testDowngradesToNoneOnlyOnTwoSuccessfulEmptyReadsInARow() {
        // Obsidian/CodeMirror: ⌘C copied the current line; the field says nothing is selected.
        let empty = F(role: "AXTextArea", selectedText: "", selectedTextSettable: true, selectedTextReadSucceeded: true)
        // One empty read is not enough: it may be a transient answer of a half-built tree.
        XCTAssertEqual(SelectionUpgrade.outcome(for: copied, with: empty), .keep)
        XCTAssertEqual(r(copied, empty), copied)
        XCTAssertEqual(SelectionUpgrade.outcome(for: copied, with: empty, previous: empty), .downgradeToNone)
        XCTAssertEqual(SelectionUpgrade.reclassified(copied, with: empty, previous: empty), .none)
        let emptyField = F(role: "AXTextField", selectedText: "", selectedTextSettable: true, selectedTextReadSucceeded: true)
        XCTAssertEqual(SelectionUpgrade.reclassified(copied, with: emptyField, previous: empty), .none)
    }

    func testDowngradeNeedsConsecutiveEmptyReads() {
        let empty = F(role: "AXTextArea", selectedText: "", selectedTextSettable: true, selectedTextReadSucceeded: true)
        let noValue = F(role: "AXTextArea", selectedText: "", selectedTextSettable: true)
        let other = F(role: "AXTextArea", selectedText: "outra coisa", selectedTextSettable: true,
                      selectedTextReadSucceeded: true)
        // Replays the re-read loop: the downgrade only fires on the second empty read of a run.
        func replay(_ reads: [F]) -> SelectionUpgrade.Outcome {
            var previous: F?
            for read in reads {
                let outcome = SelectionUpgrade.outcome(for: copied, with: read, previous: previous)
                if outcome != .keep { return outcome }
                previous = read
            }
            return .keep
        }
        XCTAssertEqual(replay([empty, empty]), .downgradeToNone)
        XCTAssertEqual(replay([empty, other, empty]), .keep, "interrupted by a non-empty read")
        XCTAssertEqual(replay([empty, noValue, empty]), .keep, "kAXErrorNoValue is not an empty read")
        XCTAssertEqual(replay([noValue, empty]), .keep)
        XCTAssertEqual(replay([other, empty, empty]), .downgradeToNone)
        // A previous empty read of a non-editable element does not count either.
        let emptyWeb = F(role: "AXWebArea", selectedText: "", selectedTextSettable: true, selectedTextReadSucceeded: true)
        XCTAssertEqual(SelectionUpgrade.outcome(for: copied, with: empty, previous: emptyWeb), .keep)
    }

    func testNoValueOrFailedReadNeverCountsAsEmpty() {
        // kAXErrorNoValue is reported as "" but without a successful read: a selection may exist.
        let noValue = F(role: "AXTextArea", selectedText: "", selectedTextSettable: true)
        XCTAssertEqual(SelectionUpgrade.outcome(for: copied, with: noValue), .keep)
        XCTAssertEqual(r(copied, noValue), copied)
        // Empty but not an editable text field: keep.
        for facts in [F(role: "AXWebArea", selectedText: "", selectedTextSettable: true, selectedTextReadSucceeded: true),
                      F(role: "AXTextArea", selectedText: "", selectedTextSettable: false, selectedTextReadSucceeded: true),
                      F(role: nil, selectedText: "", selectedTextReadSucceeded: true)] {
            XCTAssertEqual(SelectionUpgrade.outcome(for: copied, with: facts), .keep)
        }
    }

    func testUpgradesWhenOnlyTheValueIsSettable() {
        let captured = CapturedSelection.selected("oi", .readOnly)
        let facts = SelectionClassifier.Facts(role: "AXTextArea", selectedText: "oi", valueSettable: true,
                                              selectedTextReadSucceeded: true)
        XCTAssertEqual(SelectionUpgrade.reclassified(captured, with: facts), .selected("oi", .editable))
    }

    func testOnlyReadOnlySelectionsAreTouched() {
        let editable = F(role: "AXTextArea", selectedText: "a", selectedTextSettable: true, selectedTextReadSucceeded: true)
        let empty = F(role: "AXTextArea", selectedText: "", selectedTextSettable: true, selectedTextReadSucceeded: true)
        for facts in [editable, empty] {
            XCTAssertEqual(SelectionUpgrade.reclassified(.selected("a", .editable), with: facts, previous: empty),
                           .selected("a", .editable))
            XCTAssertEqual(r(.none, facts), .none)
            XCTAssertEqual(r(.unknown, facts), .unknown)
            XCTAssertEqual(r(.selected("a", .editable), facts), .selected("a", .editable))
            XCTAssertEqual(SelectionUpgrade.outcome(for: .unknown, with: facts), .keep)
        }
    }
}

final class SelectionReclassificationsTests: XCTestCase {
    func testTakeReturnsTheEntryOnce() {
        var store = SelectionReclassifications()
        XCTAssertNil(store.take(1))
        store.store(.none, for: 1)
        XCTAssertEqual(store.take(1), CapturedSelection.none)
        XCTAssertNil(store.take(1), "read once")
    }

    func testANewerRecordingDoesNotDropAnOlderClipsEntry() {
        var store = SelectionReclassifications()
        store.store(.selected("a", .editable), for: 3)
        // Later ⌥ presses (new recordings, or ⌥ used as a modifier) store nothing or other ids.
        store.store(.none, for: 7)
        XCTAssertEqual(store.take(3), .selected("a", .editable))
        XCTAssertEqual(store.take(7), CapturedSelection.none)
    }

    func testEntriesNeverTakenArePrunedOldestFirst() {
        var store = SelectionReclassifications()
        for id in 1...(SelectionReclassifications.limit + 3) { store.store(.none, for: id) }
        XCTAssertEqual(store.count, SelectionReclassifications.limit)
        XCTAssertNil(store.take(1))
        XCTAssertNotNil(store.take(SelectionReclassifications.limit + 3))
    }
}

final class EditTargetCheckTests: XCTestCase {
    typealias F = SelectionClassifier.Facts
    let captured = "Parágrafo um.\n"

    func allows(viaAX: Bool, sameApp: Bool = true, _ now: F?) -> Bool {
        EditTargetCheck.allowsPaste(of: captured, capturedViaAccessibility: viaAX, sameApp: sameApp, now: now)
    }

    func testSameSelectionIsPasted() {
        let same = F(role: "AXTextArea", selectedText: "Parágrafo um.", selectedTextSettable: true,
                     selectedTextReadSucceeded: true)
        XCTAssertTrue(allows(viaAX: true, same))
        XCTAssertTrue(allows(viaAX: false, same))
        // Read through the selected range instead of the selected text.
        XCTAssertTrue(allows(viaAX: true, F(role: "AXWebArea", rangeLength: 13, rangeText: "Parágrafo um.")))
    }

    func testAnotherAppIsNeverPasted() {
        let same = F(role: "AXTextArea", selectedText: captured, selectedTextReadSucceeded: true)
        XCTAssertFalse(allows(viaAX: true, sameApp: false, same))
        XCTAssertFalse(allows(viaAX: false, sameApp: false, nil))
    }

    func testOtherOrNoSelectionIsNotPasted() {
        // The next paragraph was selected for the next edit (I2), or the user clicked elsewhere.
        for now in [F(role: "AXTextArea", selectedText: "Parágrafo dois.", selectedTextReadSucceeded: true),
                    F(role: "AXTextArea", selectedText: "", selectedTextReadSucceeded: true),
                    F(role: "AXTextArea", rangeLength: 0)] {
            XCTAssertFalse(allows(viaAX: true, now))
            XCTAssertFalse(allows(viaAX: false, now), "a ⌘C capture that AX now contradicts")
        }
    }

    func testUnreadableSelection() {
        // kAXErrorNoValue (reported as "" without a successful read), unsupported, timed out.
        for now in [F(role: "AXTextArea", selectedText: ""), F(role: nil), nil] {
            XCTAssertFalse(allows(viaAX: true, now), "an AX capture that cannot be confirmed is not pasted")
            XCTAssertTrue(allows(viaAX: false, now), "⌘C capture: the same app is all that can be checked")
        }
    }
}
