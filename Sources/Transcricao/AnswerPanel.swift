// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TranscricaoCore

/// Floating glass panel near the mouse with the answer about a read-only selection, or to a
/// question asked with the question key (with a note that it comes from the local model). Never pasted
/// on its own: "Colar" pastes it where the text cursor is now (the user may click into a text
/// box first), "Copiar" (and ⌘C) copies. A click outside does not close it: Esc, the close
/// button, Copiar, a successful Colar or a new dictation do. It does not take keyboard focus when
/// it appears (the user's app stays key); clicking its text does, and only then does Return
/// trigger Colar. It can be dragged by its background.
/// The panel sizes itself to the text (up to `Metrics.maxWidth` and a share of the screen height,
/// then the text scrolls) and grows from a fixed anchor while the answer streams in.
@MainActor
final class AnswerPanelController: NSObject, NSWindowDelegate {
    /// The user closed the panel (Esc, close button): stop a generation in flight.
    var onClose: (() -> Void)?
    /// The panel appeared: the HUD pill is redundant from then on.
    var onShow: (() -> Void)?
    /// "Colar": nil = the paste went ahead (the panel was closed); otherwise a message to show
    /// inline, the panel staying open (nothing pasted, clipboard untouched).
    var onPaste: (@MainActor (_ text: String) async -> String?)?
    /// Debug screenshots: Copiar only logs (never touches the clipboard).
    var inert = false

    enum Metrics {
        static let minWidth: CGFloat = 340
        static let maxWidth: CGFloat = 560
        static let maxHeightFraction: CGFloat = 0.6
        static let cornerRadius: CGFloat = 26
        static let insets = NSEdgeInsets(top: 14, left: 20, bottom: 16, right: 16)
        static let fontSize: CGFloat = 15
        static let lineSpacing: CGFloat = 4
        /// Distance between the mouse and the panel edge it grows from.
        static let mouseGap: CGFloat = 16
        static let screenMargin: CGFloat = 8
    }

    private var panel: AnswerNSPanel?
    private let textView = AnswerTextView()
    private let scroll = NSScrollView()
    private let headerIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = CapsuleButton(title: String(localized: "Copy"), symbol: "doc.on.doc", kind: .secondary)
    private let pasteButton = CapsuleButton(title: String(localized: "Paste"), symbol: "doc.on.clipboard", kind: .primary)
    private let closeButton = CapsuleButton(title: "", symbol: "xmark", kind: .secondary, height: 24)
    private let stack = NSStackView()
    private var widthConstraint: NSLayoutConstraint!
    private var textHeightConstraint: NSLayoutConstraint!

    private var answer = ""
    private var generating = false
    /// Bumped per answer: late callbacks (paste check, note flash) for an older one are dropped.
    private var answerID = 0
    private var pasteChecking = false
    private var anchor: Anchor?
    /// The frame we last set ourselves (a move to anything else is the user dragging the panel).
    private var lastSetFrame: NSRect?
    /// While streaming into a capped (scrolling) panel: keep the end in view, unless the user
    /// scrolled up to read.
    private var followsEnd = true
    /// The note that belongs to the answer (e.g. "Resposta incompleta"), back after a flashed one.
    private var persistentNote: (text: String, isError: Bool)?
    private var lastResize: TimeInterval = 0
    private var resizeScheduled = false
    /// The panel reached its maximum height: the text scrolls (kept at the end while streaming).
    private var textCapped = false
    /// Last state applied to the header (nil = never set).
    private var headerBusy: Bool?
    private var copiedFeedback = 0
    /// What the current answer is about (its header title and note).
    private var kind: AnswerKind = .selection

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shown under every answer to a question: it comes from a small local model.
    static let questionNote = String(localized: "Answer from the local model — may contain mistakes")

    /// Header title once the answer is complete.
    private var doneTitle: String {
        kind == .question ? String(localized: "Answer") : String(localized: "About the selected text")
    }

    /// `point` = where to anchor the panel (screen coordinates); the mouse by default.
    func begin(at point: NSPoint? = nil, kind: AnswerKind = .selection) {
        self.kind = kind
        answer = ""
        generating = true
        answerID += 1
        pasteChecking = false
        followsEnd = true
        persistentNote = kind == .question ? (Self.questionNote, false) : nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        setText("")
        setHeader(busy: true, title: String(localized: "Thinking…"))
        setNote(persistentNote?.text)
        setButtonsEnabled(false)
        anchor = Anchor(mouse: point ?? NSEvent.mouseLocation)
        resizeNow()
        // Ordered front once per answer; streaming never orders it out/in nor rebuilds it.
        panel.orderFrontRegardless() // non-activating: the user's app keeps focus
        A11y.announce(kind == .question ? String(localized: "\(AppIdentity.name) is answering your question")
                                        : String(localized: "\(AppIdentity.name) is answering about the selected text"))
        onShow?()
    }

    /// A short message under the answer (e.g. why a key press did nothing); the answer's own note
    /// comes back after it.
    func showNotice(_ text: String) {
        guard isVisible else { return }
        flashNote(text)
    }

    func update(_ partial: String) {
        guard generating, isVisible else { return }
        answer = partial
        setText(partial)
        setHeader(busy: true, title: String(localized: "Answering…"))
        scheduleResize()
        if textCapped, followsEnd { textView.scrollToEndOfDocument(nil) }
    }

    func finish(_ text: String) {
        guard generating, isVisible else { return }
        generating = false
        answer = text
        setText(text)
        setHeader(busy: false, title: doneTitle)
        setButtonsEnabled(!text.isEmpty)
        resizeNow()
        if followsEnd { textView.scrollToBeginningOfDocument(nil) }
        A11y.announce(String(localized: "Answer ready"))
    }

    /// Keeps what was already streamed (e.g. a long translation that timed out) and says it failed.
    func fail(_ message: String) {
        guard generating, isVisible else { return }
        generating = false
        setHeader(busy: false, title: doneTitle)
        var note = answer.isEmpty ? message : String(localized: "Incomplete answer — \(message)")
        // A partial answer to a question can still be pasted: it keeps the local-model note.
        if kind == .question, !answer.isEmpty { note += "\n" + Self.questionNote }
        persistentNote = (note, true)
        setNote(note, isError: true)
        setButtonsEnabled(!answer.isEmpty)
        resizeNow()
        A11y.announce(note)
    }

    /// A new dictation starts: its paste must land in the user's app, never in this panel.
    /// An idle panel closes; one still generating stays visible but gives the keyboard back.
    func yieldForNewDictation() {
        guard let panel, panel.isVisible else { return }
        if !generating { close(); return }
        if panel.isKeyWindow {
            panel.orderOut(nil)          // drops key status: keys go back to the active app's window
            panel.orderFrontRegardless() // still visible, not key
        }
    }

    /// A dictation is about to paste: if the panel is key (clicked), give the keyboard back without
    /// closing it (an answer that opened during this recording must stay readable).
    func releaseKeyForPaste() {
        guard let panel, panel.isVisible, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        let wasGenerating = generating
        generating = false
        answerID += 1 // drops a pending note flash or paste check
        pasteChecking = false
        panel.orderOut(nil)
        if wasGenerating { onClose?() }
    }

    // MARK: - Content

    private static var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Metrics.lineSpacing
        return [.font: NSFont.systemFont(ofSize: Metrics.fontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph]
    }

    /// Streaming only appends: the new characters are added to the text storage (no full reset,
    /// so nothing already shown is laid out or drawn again).
    private func setText(_ text: String) {
        guard let storage = textView.textStorage else { return }
        let shown = storage.string
        if !shown.isEmpty, text.count > shown.count, text.hasPrefix(shown) {
            storage.append(NSAttributedString(string: String(text.dropFirst(shown.count)), attributes: Self.textAttributes))
        } else if text != shown {
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.textAttributes))
        }
        if scroll.isHidden != text.isEmpty { scroll.isHidden = text.isEmpty }
    }

    /// Touches the views only when something changes (called on every streamed token).
    private func setHeader(busy: Bool, title: String) {
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        guard headerBusy != busy else { return }
        headerBusy = busy
        headerIcon.isHidden = busy
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// Inline message under the text: an error (red) or a note (secondary); nil hides it.
    private func setNote(_ text: String?, isError: Bool = false) {
        noteLabel.isHidden = text == nil
        guard let text else { return }
        let color: NSColor = isError ? .systemRed : .secondaryLabelColor
        let font = NSFont.systemFont(ofSize: 13)
        let note = NSMutableAttributedString()
        let symbol = NSImage(systemSymbolName: isError ? "exclamationmark.triangle.fill" : "info.circle",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [color])))
        if let symbol {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            note.append(NSAttributedString(attachment: attachment))
            note.append(NSAttributedString(string: " "))
        }
        note.append(NSAttributedString(string: text))
        note.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: note.length))
        noteLabel.attributedStringValue = note
    }

    /// A short-lived note (e.g. why Colar did nothing); the answer's own note comes back after it.
    private func flashNote(_ text: String) {
        let current = answerID
        setNote(text)
        resizeNow()
        A11y.announce(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteFlashDuration) { [weak self] in
            guard let self, self.answerID == current, self.isVisible,
                  self.noteLabel.attributedStringValue.string.hasSuffix(text) else { return }
            self.setNote(self.persistentNote?.text, isError: self.persistentNote?.isError ?? false)
            self.resizeNow()
        }
    }

    private static let noteFlashDuration: TimeInterval = 6

    private func setButtonsEnabled(_ enabled: Bool) {
        copyButton.isEnabled = enabled
        pasteButton.isEnabled = enabled
    }

    // MARK: - Size and position

    /// Where the panel grows from, fixed for one answer: its left edge, and its top edge (below
    /// the mouse) or bottom edge (above it, when there is not enough room below).
    private struct Anchor {
        let left: CGFloat
        let edgeY: CGFloat
        let growsDown: Bool
        let visible: NSRect

        init(mouse: NSPoint) {
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
            visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let maxHeight = visible.height * Metrics.maxHeightFraction
            let below = mouse.y - Metrics.mouseGap - visible.minY - Metrics.screenMargin
            let above = visible.maxY - Metrics.screenMargin - (mouse.y + Metrics.mouseGap)
            growsDown = below >= maxHeight || below >= above
            edgeY = growsDown ? mouse.y - Metrics.mouseGap : mouse.y + Metrics.mouseGap
            left = mouse.x - Metrics.minWidth / 2
        }

        /// After the user dragged the panel: it keeps its top edge and grows down from there.
        init(dragged frame: NSRect, visible: NSRect) {
            self.visible = visible
            left = frame.minX
            edgeY = frame.maxY
            growsDown = true
        }

        /// The tallest the panel may get: a share of the screen, and no more than the room on the
        /// side it grows into (so the fixed edge never has to move; the text scrolls instead).
        var maxHeight: CGFloat {
            let m = Metrics.screenMargin
            let room = growsDown ? edgeY - visible.minY - m : visible.maxY - m - edgeY
            return floor(max(120, min(visible.height * Metrics.maxHeightFraction, room)))
        }

        func frame(for size: NSSize) -> NSRect {
            let m = Metrics.screenMargin
            var x = min(left, visible.maxX - m - size.width)
            x = max(x, visible.minX + m)
            var y = growsDown ? edgeY - size.height : edgeY
            y = min(max(y, visible.minY + m), visible.maxY - m - size.height)
            return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        }
    }

    /// The panel size for the current content: as wide as the longest line (between the min and
    /// max width), as tall as the text, capped at a share of the screen height (then it scrolls).
    private func fittingSize(maxHeight: CGFloat) -> NSSize {
        let horizontal = Metrics.insets.left + Metrics.insets.right
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        var width = Metrics.minWidth
        var textHeight: CGFloat = 0
        if let storage = textView.textStorage, storage.length > 0 {
            let natural = storage.boundingRect(with: NSSize(width: Metrics.maxWidth - horizontal, height: .greatestFiniteMagnitude),
                                               options: options)
            width = min(Metrics.maxWidth, max(Metrics.minWidth, ceil(natural.width) + horizontal + 2))
            let wrapped = storage.boundingRect(with: NSSize(width: width - horizontal, height: .greatestFiniteMagnitude),
                                               options: options)
            textHeight = ceil(wrapped.height) + 2
        }
        noteLabel.preferredMaxLayoutWidth = width - horizontal
        widthConstraint.constant = width
        textHeightConstraint.constant = textHeight
        stack.layoutSubtreeIfNeeded()
        var size = NSSize(width: width, height: ceil(stack.fittingSize.height))
        textCapped = size.height > maxHeight && textHeight > 0
        if textCapped {
            textHeightConstraint.constant = max(60, textHeight - (size.height - maxHeight))
            size.height = maxHeight
        }
        return size
    }

    /// Streaming: at most one resize per `resizeInterval`, and only when the size changes. The
    /// newest word may wrap out of sight for a moment until the panel widens.
    private static let resizeInterval: TimeInterval = 0.1

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        let wait = Self.resizeInterval - (ProcessInfo.processInfo.systemUptime - lastResize)
        if wait <= 0 { resizeNow(); return }
        resizeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            if self.isVisible { self.resizeNow() }
        }
    }

    /// Sets the frame for the current content, without animation: an animated window frame
    /// (or implicit layer animations) makes the glass flash while the answer streams.
    private func resizeNow() {
        guard let panel, let anchor else { return }
        lastResize = ProcessInfo.processInfo.systemUptime
        let target = anchor.frame(for: fittingSize(maxHeight: anchor.maxHeight))
        guard target != panel.frame else { return }
        lastSetFrame = target
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(target, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
        panel.invalidateShadow()
        if generating, textCapped, followsEnd { textView.scrollToEndOfDocument(nil) }
    }

    /// The user dragged the panel: later resizes grow from where they put it.
    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible, panel.frame != lastSetFrame else { return }
        let visible = panel.screen?.visibleFrame ?? anchor?.visible ?? panel.frame
        anchor = Anchor(dragged: panel.frame, visible: visible)
        lastSetFrame = panel.frame
    }

    /// A live scroll by the user: keep following the streaming end only if they stayed at it.
    @objc private func userScrolled() {
        guard let document = scroll.documentView else { return }
        followsEnd = scroll.contentView.bounds.maxY >= document.frame.height - 4
    }

    // MARK: - Panel

    private func makePanel() -> AnswerNSPanel {
        let p = AnswerNSPanel(contentRect: NSRect(x: 0, y: 0, width: Metrics.minWidth, height: 120),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // No order-out fade: its snapshot would linger under the glass when the panel is shown
        // again right away (yield/release key do orderOut + orderFront).
        p.animationBehavior = .none
        p.isMovableByWindowBackground = true // drag it off the text it covers
        p.title = String(localized: "\(AppIdentity.name) — answer") // VoiceOver's window list (never shown: borderless)
        p.delegate = self
        p.onCopy = { [weak self] in self?.copySelectionOrAll() }
        p.onEscape = { [weak self] in self?.close() }

        // Header: state on the left, close on the right.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel(String(localized: "Generating answer"))
        headerIcon.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        headerIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        headerIcon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.setAccessibilityLabel(String(localized: "Close"))
        closeButton.toolTip = String(localized: "Close (Esc)")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        // Plain constraints (not a stack view, which may detach views it thinks do not fit): the
        // spinner and the icon share the leading slot, the close button sits at the trailing edge.
        let header = NSView()
        for view in [spinner, headerIcon, titleLabel, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 24),
            spinner.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            spinner.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            headerIcon.centerXAnchor.constraint(equalTo: spinner.centerXAnchor),
            headerIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        // Answer text.
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.setAccessibilityLabel(String(localized: "Answer"))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        // The scroll view absorbs the panel's height while it animates; it never pushes back.
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(userScrolled), name: name, object: scroll)
        }

        // Inline error / note (one wrapping label, the symbol inline).
        noteLabel.font = .systemFont(ofSize: 13)
        noteLabel.isSelectable = false
        noteLabel.setContentHuggingPriority(.init(1), for: .horizontal) // spans the row, text at the margin

        // Buttons.
        copyButton.target = self
        copyButton.action = #selector(copyAll)
        copyButton.toolTip = String(localized: "Copy the answer and close")
        pasteButton.target = self
        pasteButton.action = #selector(pasteClicked)
        // Return works only while the panel is key (after a click in it): never a global shortcut.
        pasteButton.keyEquivalent = "\r"
        pasteButton.toolTip = String(localized: "Paste the answer where the text cursor is")
        // "Copiado" must not move the buttons.
        copyButton.label = String(localized: "Copied")
        let copiedWidth = copyButton.fittingSize.width
        copyButton.label = String(localized: "Copy")
        copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(copiedWidth)).isActive = true
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.addView(copyButton, in: .trailing)
        footer.addView(pasteButton, in: .trailing)

        stack.orientation = .vertical
        stack.alignment = .width // every row spans the panel (inside the insets)
        stack.spacing = 12
        stack.detachesHiddenViews = true
        stack.edgeInsets = Metrics.insets
        stack.setViews([header, scroll, noteLabel, footer], in: .top)
        stack.setCustomSpacing(10, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Measuring constraints (low priority): the panel frame wins while it animates.
        widthConstraint = stack.widthAnchor.constraint(equalToConstant: Metrics.minWidth)
        widthConstraint.priority = .init(260)
        textHeightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        textHeightConstraint.priority = .init(260)
        NSLayoutConstraint.activate([widthConstraint, textHeightConstraint])

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        p.contentView = Glass.container(content, cornerRadius: Metrics.cornerRadius)
        return p
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    }

    /// Copiar: copies the whole answer, shows "Copiado" for a moment, then closes.
    @objc private func copyAll() {
        guard !answer.isEmpty else { return }
        copy(answer)
        let current = answerID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.answerID == current, !self.inert else { return }
            self.close()
        }
    }
    @objc private func closeClicked() { close() }

    /// Colar: the environment checks where the paste would land; if it can't paste there, the
    /// panel stays open with its reason.
    @objc func pasteClicked() {
        guard !generating, !answer.isEmpty, !pasteChecking, let onPaste else { return }
        pasteChecking = true
        let text = answer, current = answerID
        Task { @MainActor [weak self] in
            let message = await onPaste(text)
            guard let self, self.answerID == current else { return }
            self.pasteChecking = false
            if let message, self.isVisible { self.flashNote(message) }
        }
    }

    private func copySelectionOrAll() {
        let range = textView.selectedRange()
        if range.length > 0, let selected = (textView.string as NSString?)?.substring(with: range) {
            copy(selected)
        } else {
            copy(answer)
        }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        if inert {
            appLog("answer panel Copiar (debug: clipboard untouched)")
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string) // kept on purpose (not transient): the user asked for it
        }
        copiedFeedback += 1
        let current = copiedFeedback
        copyButton.label = String(localized: "Copied")
        copyButton.image = Self.symbol("checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.copiedFeedback == current else { return }
            self.copyButton.label = String(localized: "Copy")
            self.copyButton.image = Self.symbol("doc.on.doc")
        }
    }

}

/// Selecting text starts on the first click, even while another app is active.
private final class AnswerTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Becomes key only when clicked (non-activating), so its text can be selected and copied.
private final class AnswerNSPanel: NSPanel {
    var onCopy: (() -> Void)?
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// No Edit menu in this menu-bar app: handle ⌘C here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "c" {
            onCopy?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Bridges the pipeline (any thread) to the panel (main thread), in order.
struct PanelAnswerPresenter: AnswerPresenter {
    let panel: AnswerPanelController

    func begin() { onMain { $0.begin() } }
    func begin(kind: AnswerKind) { onMain { $0.begin(kind: kind) } }
    func update(_ partial: String) { onMain { $0.update(partial) } }
    func finish(_ text: String) { onMain { $0.finish(text) } }
    func fail(_ message: String) { onMain { $0.fail(message) } }

    private func onMain(_ work: @escaping @MainActor (AnswerPanelController) -> Void) {
        let panel = self.panel
        DispatchQueue.main.async { MainActor.assumeIsolated { work(panel) } } // FIFO keeps the order
    }
}
