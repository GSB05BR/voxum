// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Liquid Glass on macOS 26+, a system material below it. Shared by the answer panel and the undo pill.
@MainActor
enum Glass {
    /// `content` on glass clipped to a continuous `cornerRadius`. The returned view is meant to be a
    /// window's contentView (it follows the window's size; `content` follows it).
    static func container(_ content: NSView, cornerRadius: CGFloat, interactive: Bool = false) -> NSView {
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content // only the contentView is guaranteed to sit inside the glass
            if interactive, #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            return glass
        }
        let fx = NSVisualEffectView()
        fx.material = .popover // follows light/dark
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        content.frame = fx.bounds
        fx.addSubview(content)
        return fx
    }
}

/// Floating panels show while another app is active: the first click must act at once, not
/// only bring the panel forward.
class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Capsule push button drawn by hand: the panels are never the active app's key window, where
/// system bezels (glass ones included) draw flat and untinted. Primary = accent fill.
final class CapsuleButton: FirstMouseButton {
    enum Kind { case primary, secondary }
    private let kind: Kind
    private let height: CGFloat
    private let padding: CGFloat

    init(title: String, symbol: String?, kind: Kind, height: CGFloat = 30, padding: CGFloat = 14) {
        self.kind = kind
        self.height = height
        self.padding = padding
        super.init(frame: .zero)
        self.label = title
        self.title = title.isEmpty ? "" : "\u{2009}" + title // didSet does not run in init
        isBordered = false
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 13, weight: kind == .primary ? .semibold : .medium)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? nil : title)?
                .withSymbolConfiguration(.init(pointSize: title.isEmpty ? 10 : 12, weight: .semibold))
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            imageHugsTitle = true
        }
        contentTintColor = kind == .primary ? .white : .labelColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The visible title (a thin space keeps it off the symbol).
    var label: String = "" {
        didSet { title = label.isEmpty ? "" : "\u{2009}" + label }
    }

    override var intrinsicContentSize: NSSize {
        guard !title.isEmpty else { return NSSize(width: height, height: height) }
        return NSSize(width: ceil(super.intrinsicContentSize.width) + padding * 2, height: height)
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        var fill: NSColor = kind == .primary ? .controlAccentColor : .labelColor.withAlphaComponent(0.09)
        if isHighlighted {
            fill = kind == .primary ? fill.blended(withFraction: 0.2, of: .black) ?? fill
                                    : .labelColor.withAlphaComponent(0.18)
        }
        if !isEnabled { fill = fill.withAlphaComponent(fill.alphaComponent * 0.45) }
        fill.setFill()
        path.fill()
        super.draw(dirtyRect)
    }
}

/// VoiceOver announcements for the floating panels (they appear without taking focus).
@MainActor
enum A11y {
    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
