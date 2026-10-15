// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Text selected in the focused app when a dictation starts.
public enum SelectionKind: Equatable, Sendable {
    /// In an editable text field: the result replaces it (edit by voice).
    case editable
    /// Web page, tweet, PDF, reading pane, terminal output…: the speech is a request about it and
    /// the answer goes to a floating panel, never pasted.
    case readOnly
}

/// What the concurrent selection capture produced, as seen by the pipeline.
public enum CapturedSelection: Equatable, Sendable {
    case none
    case selected(String, SelectionKind)
    /// The capture did not finish in time: the pipeline must not paste over a possible selection.
    case unknown
}

/// Turns accessibility facts about the focused element into a decision. Pure: the app collects the
/// facts (AX calls), this decides what they mean.
public enum SelectionClassifier {
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// ⌘C there copies items (files, rows), not a text selection.
    public static let noCopyRoles: Set<String> = ["AXTable", "AXList", "AXOutline", "AXBrowser"]

    public struct Facts: Equatable, Sendable {
        /// nil = no focused element (or its role could not be read).
        public var role: String?
        /// kAXSelectedTextAttribute; nil = unsupported / error. kAXErrorNoValue is reported as "".
        public var selectedText: String?
        /// True only when the kAXSelectedTextAttribute read itself succeeded with a string, so an
        /// empty `selectedText` really means "nothing selected" (not kAXErrorNoValue, which a
        /// half-built Electron tree may answer while a selection exists).
        public var selectedTextReadSucceeded: Bool
        public var selectedTextSettable: Bool
        /// kAXValueAttribute settable: Catalyst text areas (WhatsApp) accept text this way while
        /// their selected text is not settable.
        public var valueSettable: Bool
        /// kAXSelectedTextRangeAttribute length; nil = unsupported / error.
        public var rangeLength: Int?
        /// kAXStringForRangeParameterizedAttribute for that range; nil = unsupported / error.
        public var rangeText: String?
        /// WebKit/Chromium page selection (AXSelectedTextMarkerRange + AXStringForTextMarkerRange);
        /// nil = unsupported / error. Text on a page (a tweet) is only exposed this way.
        public var markerText: String?
        /// The focused element sits inside editable web content (AXEditableAncestor is set): a
        /// contenteditable box that takes pasted text. Read only for "Colar".
        public var insideEditableWebContent: Bool = false

        public init(role: String?, selectedText: String? = nil, selectedTextSettable: Bool = false,
                    valueSettable: Bool = false, rangeLength: Int? = nil, rangeText: String? = nil,
                    markerText: String? = nil, selectedTextReadSucceeded: Bool = false) {
            self.role = role
            self.selectedText = selectedText
            self.selectedTextReadSucceeded = selectedTextReadSucceeded
            self.selectedTextSettable = selectedTextSettable
            self.valueSettable = valueSettable
            self.rangeLength = rangeLength
            self.rangeText = rangeText
            self.markerText = markerText
        }

        /// A text role whose selection or value the app lets us set.
        public var isEditableText: Bool {
            (role.map(SelectionClassifier.textRoles.contains) ?? false) && (selectedTextSettable || valueSettable)
        }
    }

    public enum Decision: Equatable, Sendable {
        case selected(String, SelectionKind)
        case none
        /// Accessibility could not tell: try ⌘C; what it copies is `copyKind`.
        case tryCopy(copyKind: SelectionKind)
    }

    public static func classify(_ f: Facts) -> Decision {
        let isText = f.role.map(textRoles.contains) ?? false
        // 1–2) Text roles: the selected text, editable only if the app lets us set it.
        if isText, let text = f.selectedText {
            if text.isEmpty { return .none }
            return .selected(text, f.isEditableText ? .editable : .readOnly)
        }
        // The page's selection (WebKit/Chromium text markers): read-only.
        if !isText, let text = f.markerText, !text.isEmpty { return .selected(text, .readOnly) }
        // Non-text roles that still expose a selected text (AXWebArea, AXStaticText): read-only.
        if !isText, let text = f.selectedText {
            if !text.isEmpty { return .selected(text, .readOnly) }
            if f.rangeLength == nil { return .none } // supported and empty, nothing else to ask
        }
        // 3) Selected range + string for range: read-only.
        if let length = f.rangeLength {
            if length == 0 { return .none }
            if let text = f.rangeText, !text.isEmpty { return .selected(text, .readOnly) }
        }
        // 4) ⌘C fallback, never where ⌘C copies items.
        if let role = f.role, noCopyRoles.contains(role) { return .none }
        return .tryCopy(copyKind: copyKind(role: f.role))
    }

    /// A ⌘C copy is editable only when the focused element is a text role (reaching the fallback
    /// means its selected-text attribute was unreadable, so settability is unknown); else read-only.
    public static func copyKind(role: String?) -> SelectionKind {
        role.map(textRoles.contains) ?? false ? .editable : .readOnly
    }
}

/// Per-app exceptions to the ⌘C fallback and to switching on an Electron app's accessibility tree.
public enum CopyFallbackPolicy {
    /// Code editors copy the whole current line on ⌘C with nothing selected, so a ⌘C "selection"
    /// there means nothing (a dictation would be mistaken for a request about that line); and
    /// switching their accessibility tree on puts the Electron ones in screen-reader mode.
    /// Matched by bundle-id prefix so variants (Insiders, OSS builds, forks) are covered.
    public static let copyLineEditorPrefixes: [String] = [
        "com.microsoft.VSCode",     // VS Code, Insiders, Exploration
        "com.visualstudio.code",    // Code - OSS builds
        "com.vscodium",             // VSCodium
        "com.todesktop.",           // Cursor (ToDesktop-packaged apps)
        "com.exafunction.windsurf", // Windsurf
        "com.sublimetext.",         // Sublime Text
        "com.jetbrains.",           // IntelliJ IDEA, PyCharm, WebStorm, Fleet…
        "dev.zed.",                 // Zed
        "com.google.android.studio", // Android Studio (IntelliJ-based)
    ]

    public static func isCopyLineEditor(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return copyLineEditorPrefixes.contains { id.hasPrefix($0.lowercased()) }
    }

    /// The ⌘C fallback is treated as "no selection" in copy-line editors.
    public static func allowsCopy(_ bundleID: String?) -> Bool { !isCopyLineEditor(bundleID) }

    /// While another clip is in flight no ⌘C is sent. An app that exposes no focused element
    /// (Electron with its accessibility tree off) may still have a selection there: `.unknown`, so
    /// the spoken instruction is never pasted over it. Otherwise nothing selectable was seen.
    public static func selectionWhenCopyBlocked(lookup: FocusLookup) -> CapturedSelection {
        lookup == .noFocusedElement ? .unknown : .none
    }
}

/// How the first accessibility read found the focused element.
public enum FocusLookup: Equatable, Sendable {
    case found
    /// kAXErrorNoValue: the app answered but exposes no focused element (Electron with its
    /// accessibility tree off).
    case noFocusedElement
    /// kAXErrorCannotComplete (messaging timeout): the app is busy or hung.
    case timedOut
    case failed
}

/// Electron/Chromium apps build their accessibility tree only when an assistive app asks
/// (AXManualAccessibility). Without it there is no focused element, so an editable field can only
/// be reached through ⌘C and looks read-only. Switching it on is an optimisation for the NEXT
/// capture in that app, attempted at most once per app run and only when it is clearly that case.
public enum AccessibilitySwitchPolicy {
    public static func shouldEnable(lookup: FocusLookup, copiedSelection: Bool,
                                    alreadyAttempted: Bool, bundleID: String?) -> Bool {
        lookup == .noFocusedElement      // not after a timeout (hung app) nor other errors
            && copiedSelection           // the ⌘C fallback confirmed there really was a selection
            && !alreadyAttempted         // once per app run
            && !CopyFallbackPolicy.isCopyLineEditor(bundleID) // VS Code & co: screen-reader mode
    }
}

/// After the accessibility tree of an Electron app was switched on, a ⌘C capture classified
/// read-only (no focused element at the time) is looked at again (several re-reads) while the
/// user is still speaking.
public enum SelectionUpgrade {
    public enum Outcome: Equatable, Sendable {
        /// The focused element is an editable text field with that selection: edit by voice.
        case upgradeToEditable
        /// The focused element is an editable text field that positively reports an empty selection:
        /// the ⌘C copied something else (copy-line editors like Obsidian/CodeMirror copy the current
        /// line with nothing selected), so this is a plain dictation.
        case downgradeToNone
        case keep
    }

    /// Successful empty reads in a row needed before a downgrade: one transient empty answer of a
    /// half-built tree must not turn a real selection into a dictation pasted over it.
    public static let emptyReadsForNone = 2

    /// Only a read-only ⌘C capture is reconsidered, and only when the re-read focused element is a
    /// text role whose selected text is settable. Then:
    /// - selected text unreadable, or readable and the same as the copied text (whitespace aside)
    ///   → `upgradeToEditable`;
    /// - selected text read successfully as "" on this re-read AND the one before it (`previous`)
    ///   → `downgradeToNone` (never on kAXErrorNoValue or a failed read: that must not turn into a
    ///   paste over a selection that may exist);
    /// - anything else → `keep`.
    public static func outcome(for captured: CapturedSelection, with facts: SelectionClassifier.Facts,
                               previous: SelectionClassifier.Facts? = nil) -> Outcome {
        guard isEditableField(captured, facts) else { return .keep }
        guard case .selected(let copied, _) = captured, let selected = facts.selectedText else { return .upgradeToEditable }
        if selected.isEmpty {
            guard facts.selectedTextReadSucceeded, let previous, positivelyEmpty(captured, previous) else { return .keep }
            return .downgradeToNone
        }
        return sameText(selected, copied) ? .upgradeToEditable : .keep
    }

    /// The capture after applying `outcome(for:with:previous:)`.
    public static func reclassified(_ captured: CapturedSelection, with facts: SelectionClassifier.Facts,
                                    previous: SelectionClassifier.Facts? = nil) -> CapturedSelection {
        switch outcome(for: captured, with: facts, previous: previous) {
        case .upgradeToEditable:
            guard case .selected(let text, _) = captured else { return captured }
            return .selected(text, .editable) // the copied text is kept
        case .downgradeToNone: return .none
        case .keep: return captured
        }
    }

    private static func isEditableField(_ captured: CapturedSelection, _ facts: SelectionClassifier.Facts) -> Bool {
        guard case .selected(_, .readOnly) = captured else { return false }
        return facts.isEditableText
    }

    /// An editable text field that answered "" for its selected text with a successful read.
    private static func positivelyEmpty(_ captured: CapturedSelection, _ facts: SelectionClassifier.Facts) -> Bool {
        isEditableField(captured, facts) && facts.selectedTextReadSucceeded && facts.selectedText == ""
    }

    /// ⌘C and AXSelectedText may differ in line breaks, non-breaking spaces and surrounding space.
    public static func sameText(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }

    private static func normalized(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

/// Right before an edit is pasted (seconds after the capture): is the captured selection still
/// what a ⌘V would replace? The user may have switched apps, clicked elsewhere or selected other
/// text meanwhile (e.g. the next paragraph, for the next edit).
public enum EditTargetCheck {
    /// The selection AX reports now; nil = unreadable (unsupported, error, kAXErrorNoValue).
    public static func currentSelection(_ f: SelectionClassifier.Facts) -> String? {
        if f.selectedTextReadSucceeded, let text = f.selectedText { return text }
        if let length = f.rangeLength {
            if length == 0 { return "" }
            if let text = f.rangeText { return text }
        }
        return nil
    }

    /// - Another app is frontmost → no.
    /// - AX reads the selection → it must be the captured text (whitespace aside).
    /// - AX cannot read it → yes only if the capture itself came through ⌘C (that app never
    ///   exposed its selection: the same app is all that can be checked); an accessibility capture
    ///   that can no longer be confirmed is not pasted.
    public static func allowsPaste(of captured: String, capturedViaAccessibility: Bool, sameApp: Bool,
                                   now: SelectionClassifier.Facts?) -> Bool {
        guard sameApp else { return false }
        guard let current = now.flatMap(currentSelection) else { return !capturedViaAccessibility }
        return SelectionUpgrade.sameText(current, captured)
    }
}

/// Later reclassifications of recordings' captures (`SelectionUpgrade`), keyed by recording id so a
/// new press of the dictation key never drops the result of a clip still being processed. Entries are taken by that
/// clip's pipeline run; ones never taken (cancelled recordings, or arrived after the pipeline read
/// the capture) are pruned by count, keeping the newest. Entries are rare (at most one per app run
/// of each Electron app), so count pruning never evicts one that is still wanted.
public struct SelectionReclassifications: Sendable {
    public static let limit = 4
    private var byID: [Int: CapturedSelection] = [:]

    public init() {}

    public var count: Int { byID.count }

    public mutating func store(_ value: CapturedSelection, for id: Int) {
        byID[id] = value
        if byID.count > Self.limit {
            for old in byID.keys.sorted().dropLast(Self.limit) { byID[old] = nil }
        }
    }

    /// The reclassification of recording `id`, if one arrived (removed: read once).
    public mutating func take(_ id: Int) -> CapturedSelection? {
        byID.removeValue(forKey: id)
    }
}
