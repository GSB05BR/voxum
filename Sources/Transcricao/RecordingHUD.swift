// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum Mode: Equatable { case recording(continuous: Bool), processing, error(String) }
    @Published var mode: Mode = .recording(continuous: false)
    @Published var levels: [Float] = Array(repeating: 0, count: 24)
    /// Edit by voice: the result will replace the selected text.
    @Published var editing = false
    /// Question mode: the recording is a question for the local model.
    @Published var question = false
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Non-activating floating pill at the bottom of the screen under the mouse. Never takes focus.
@MainActor
final class RecordingHUD {
    /// Height of the recording/processing pill (the undo pill is centred on the same spot).
    static let pillHeight: CGFloat = 44
    private let model = HUDModel()
    private var generation = 0
    private lazy var host = NSHostingView(rootView: HUDView(model: model))
    private lazy var panel: NSPanel = {
        let p = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                         styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.contentView = host
        return p
    }()

    func showRecording(continuous: Bool) {
        generation += 1
        if case .recording = model.mode {} else {
            model.levels = Array(repeating: 0, count: model.levels.count)
        }
        model.mode = .recording(continuous: continuous)
        present()
    }

    /// Edit-by-voice hint; resizes a visible recording/processing pill in place.
    func setEditing(_ editing: Bool) {
        guard model.editing != editing else { return }
        model.editing = editing
        if case .error = model.mode { return }
        if panel.isVisible { present() }
    }

    /// Question-mode label; resizes a visible recording pill in place.
    func setQuestion(_ question: Bool) {
        guard model.question != question else { return }
        model.question = question
        if case .recording = model.mode, panel.isVisible { present() }
    }

    func push(level: Float) {
        // Map RMS (~0…0.3) to 0…1 with a soft curve.
        let normalized = min(1, (level * 6).squareRoot())
        model.levels.removeFirst()
        model.levels.append(normalized)
    }

    func showProcessing() {
        generation += 1
        model.mode = .processing
        present()
    }

    /// Shows the error for 2 s, then hides (or returns to the processing pill if a clip is still in flight).
    func showError(_ message: String, thenProcessing: Bool = false) {
        generation += 1
        let current = generation
        model.mode = .error(message)
        present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            // Only act if nothing newer replaced this error pill.
            guard let self, self.generation == current else { return }
            if thenProcessing { self.showProcessing() } else { self.hide() }
        }
    }

    func hide() {
        generation += 1
        panel.orderOut(nil)
    }

    private func present() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 80,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    private var isError: Bool { if case .error = model.mode { true } else { false } }
    private var isQuestionRecording: Bool { if case .recording = model.mode { model.question } else { false } }

    private func recordingLabel(continuous: Bool) -> String? {
        if model.question {
            return continuous ? String(localized: "continuous · question") : String(localized: "question")
        }
        return switch (continuous, model.editing) {
        case (true, true): String(localized: "continuous · editing selection")
        case (false, true): String(localized: "editing selection")
        case (true, false): String(localized: "continuous")
        case (false, false): nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .recording(let continuous):
                Circle().fill(.red).frame(width: 10, height: 10)
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                        Capsule().fill(.primary.opacity(0.85))
                            .frame(width: 3, height: max(3, CGFloat(level) * 24))
                    }
                }
                .frame(height: 24)
                if let label = recordingLabel(continuous: continuous) {
                    Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .fixedSize()
                }
            case .processing:
                ProgressView().controlSize(.small)
                Text(model.editing ? String(localized: "Editing selection…") : String(localized: "Processing…"))
                    .font(.callout)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: isError || model.editing || isQuestionRecording ? nil : 200, height: isError ? nil : 44)
        .frame(minWidth: 200, maxWidth: 360, minHeight: 44)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeOut(duration: 0.08), value: model.levels)
    }
}
