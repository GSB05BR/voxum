// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// After an edit by voice was pasted over a selection: a small glass pill where the HUD appears,
/// offering "Desfazer". The pill is only the button: `onUndo` decides whether ⌘Z is safe to send
/// (AppEnvironment.undoLastEdit, fail closed). Non-activating and never key: clicking it leaves the
/// user's app focused. It goes away after `lifetime`, on any other key press or click, and when a
/// new dictation starts.
@MainActor
final class UndoPillController: NSObject {
    var lifetime: TimeInterval = 6
    /// "Desfazer" clicked (the pill is already gone).
    var onUndo: (() -> Void)?
    /// Debug screenshots: the button only logs.
    var inert = false

    private var panel: UndoPillPanel?
    private var generation = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    /// A click on the pill (its own click is not the user's input in their app).
    func contains(_ event: NSEvent) -> Bool {
        guard let panel, panel.isVisible else { return false }
        if event.window === panel { return true }
        return event.window == nil && panel.frame.contains(NSEvent.mouseLocation)
    }

    func show() {
        generation += 1
        let current = generation
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        A11y.announce(String(localized: "Edit applied. Undo with ⌘Z."))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
            guard let self, self.generation == current else { return }
            self.dismiss(animated: true)
        }
    }

    func dismiss(animated: Bool = false) {
        guard let panel, panel.isVisible else { return }
        generation += 1
        panel.ignoresMouseEvents = true // a click during the fade goes to whatever is below
        guard animated else { panel.orderOut(nil); return }
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    /// Any real key press or click (from the hotkey monitor): the pill goes, except for a click on
    /// the pill itself (its button acts on mouse-up, after this).
    func userInput(_ event: NSEvent) {
        guard isVisible, !contains(event) else { return }
        dismiss()
    }

    @objc private func undoClicked() {
        guard isVisible, !(panel?.ignoresMouseEvents ?? true) else { return }
        dismiss()
        guard !inert else { appLog("undo pill clicked (debug: nothing sent)"); return }
        onUndo?()
    }

    // MARK: - Panel

    private func makePanel() -> UndoPillPanel {
        let button = FirstMouseButton(title: "", target: self, action: #selector(undoClicked))
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.contentTintColor = .labelColor
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        let title = NSMutableAttributedString(string: " " + String(localized: "Undo"), attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        title.append(NSAttributedString(string: "   ⌘Z", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        button.attributedTitle = title
        button.setAccessibilityLabel(String(localized: "Undo edit"))
        button.toolTip = String(localized: "Undo the edit (⌘Z)")
        button.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            button.topAnchor.constraint(equalTo: content.topAnchor),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let height: CGFloat = 40
        let width = ceil(button.intrinsicContentSize.width) + 36
        let p = UndoPillPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .none // fades are done here (alphaValue)
        p.contentView = Glass.container(content, cornerRadius: height / 2, interactive: true)
        return p
    }

    /// Where the recording HUD appears: bottom centre of the screen under the mouse.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: (frame.midX - size.width / 2).rounded(),
                                     y: frame.minY + 80 + (RecordingHUD.pillHeight - size.height) / 2))
    }
}

/// Never key nor main: the user's app keeps the keyboard while the pill is clicked.
private final class UndoPillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension SyntheticEvent {
    static let zKey: CGKeyCode = 6 // kVK_ANSI_Z
}
