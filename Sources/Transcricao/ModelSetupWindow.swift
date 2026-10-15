// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import TranscricaoCore
import TranscricaoEngines

/// First-run window "Escolha seus modelos": shown before any download when no model choice was
/// confirmed and the chosen models are not on disk (see `FirstRunDecision`).
@MainActor
final class ModelSetupWindowController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private let model: ModelSetupModel
    private var window: NSWindow?
    /// Called once the models are downloaded (loading then proceeds as on any launch).
    var onFinished: (() -> Void)?

    init(env: AppEnvironment) {
        self.env = env
        self.model = ModelSetupModel(physicalMemory: DevOverrides.physicalMemory ?? ProcessInfo.processInfo.physicalMemory,
                                     settings: env.settings)
        super.init()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        let window = self.window ?? makeWindow()
        self.window = window
        model.refreshDisk()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let choice = DevOverrides.autostartSetup {
            model.text = choice
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() } // time for a screenshot
        }
    }

    func close() { window?.close() }

    /// Window number for scripted screenshots (`screencapture -l`).
    var windowNumber: Int? { window?.windowNumber }

    private func makeWindow() -> NSWindow {
        let view = ModelSetupView(model: model, downloads: env.downloads, start: { [weak self] in self?.start() },
                                  cancel: { [weak self] in self?.env.cancelDownload() })
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = AppIdentity.name
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 480, height: 640))
        w.center()
        w.delegate = self
        return w
    }

    private func start() {
        guard !model.downloading else { return }
        model.downloading = true
        Task {
            let ok = await env.beginModelSetup(text: model.text, idleUnload: model.idle)
            model.downloading = false
            model.refreshDisk()
            if ok { onFinished?() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing does not cancel a running download; the menu shows its progress.
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class ModelSetupModel: ObservableObject {
    @Published var text: TextModelChoice
    @Published var idle: IdleUnloadPolicy
    @Published var downloading = false
    @Published private(set) var whisperOnDisk = false
    @Published private(set) var qwenOnDisk = false
    @Published private(set) var freeBytes: Int64?
    let lowMemory: Bool
    let memoryText: String

    /// A choice saved by an earlier "Baixar e começar" (then cancelled or quit) is shown again;
    /// otherwise Qwen and the RAM-based idle preset.
    init(physicalMemory: UInt64, settings: Settings) {
        lowMemory = ModelCatalog.isLowMemory(physicalMemory: physicalMemory)
        text = settings.textModel
        idle = settings.savedIdleUnload ?? ModelCatalog.recommendedIdleUnload(physicalMemory: physicalMemory)
        memoryText = "\(Int((Double(physicalMemory) / 1_073_741_824).rounded())) \(String(localized: "GB"))"
        refreshDisk()
    }

    func refreshDisk() {
        whisperOnDisk = ModelDownloader.whisperOnDisk
        qwenOnDisk = ModelDownloader.isOnDisk(text: .qwen3_4b)
        freeBytes = ModelDownloader.freeBytes
    }

    var plan: ModelDownloadPlan {
        ModelDownloadPlan(text: text, whisperOnDisk: whisperOnDisk, textOnDisk: text == .qwen3_4b ? qwenOnDisk : true)
    }

    func onDisk(_ choice: TextModelChoice) -> Bool { choice == .qwen3_4b ? qwenOnDisk : true }
}

private struct ModelSetupView: View {
    @ObservedObject var model: ModelSetupModel
    @ObservedObject var downloads: ModelDownloads
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("Transcription") {
                    LabeledContent {
                        Text(model.whisperOnDisk ? String(localized: "already downloaded") : "~\(ByteText.approx(ModelCatalog.whisperBytes))")
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(ModelCatalog.whisperTitle)
                        Text("Recognizes your speech. Required. \(ModelCatalog.whisperMemoryText).")
                    }
                }
                Section("Organize the text") {
                    choiceRow(.qwen3_4b,
                              detail: String(localized: "Punctuates, organizes lists, fixes what you rephrased and edits the selected text by voice. \(TextModelChoice.qwen3_4b.memoryText ?? "")."))
                    choiceRow(.transcriptionOnly,
                              detail: String(localized: "Pastes the text as spoken. No memory beyond the voice model; you can change it later in Settings."))
                }
                Section {
                    Picker("Free memory after inactivity", selection: $model.idle) {
                        ForEach(IdleUnloadPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Memory")
                } footer: {
                    Text(model.lowMemory
                         ? String(localized: "This Mac has \(model.memoryText) of memory: freeing the models after 5 min without dictating gives memory back to other apps. Reloading takes about 3 s.")
                         : String(localized: "Reloading the models after they are freed takes about 3 s."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .disabled(model.downloading)
            footer
        }
        .frame(width: 480)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            Text("Choose your models").font(.title2.weight(.semibold))
            Text("Everything runs on your Mac. The models are downloaded once and then work without internet.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 20).padding(.horizontal, 24)
    }

    private func choiceRow(_ choice: TextModelChoice, detail: String) -> some View {
        let selected = model.text == choice
        return Button {
            model.text = choice
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if choice.usesAI {
                    Text(model.onDisk(choice) ? String(localized: "already downloaded") : "~\(ByteText.approx(choice.downloadBytes))")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let progress = downloads.progress {
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.statusLine).font(.callout).monospacedDigit()
                    HStack {
                        ProgressView(value: progress.fraction)
                        Button("Cancel", action: cancel)
                    }
                }
            } else {
                let plan = model.plan
                let fits = plan.fits(freeBytes: model.freeBytes)
                HStack {
                    Text(plan.isEmpty ? String(localized: "Nothing to download")
                                      : String(localized: "Total to download: ~\(ByteText.approx(plan.totalBytes))"))
                    Spacer()
                    if let free = model.freeBytes {
                        Text("Free on disk: \(ByteText.approx(free))")
                            .foregroundStyle(fits ? Color.secondary : Color.red)
                    }
                }
                .font(.callout)
                if !fits {
                    Text("Not enough free space. Free up disk space and try again.")
                        .font(.caption).foregroundStyle(.red)
                }
                if let failure = downloads.failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: start) {
                    Text(downloads.failure != nil ? String(localized: "Try again")
                         : (plan.isEmpty ? String(localized: "Start") : String(localized: "Download and start")))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!fits || model.downloading)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 4)
    }
}

/// Development-only knobs, honored only together with `VOXUM_DATA_DIR` (a throwaway data folder,
/// see docs/BUILD.md), so a normal launch can never be affected:
///  - `VOXUM_SIMULATED_RAM_GB=8`: the first-run screen behaves as on a Mac with that much memory.
///  - `VOXUM_SETUP_AUTOSTART=qwen|sem-ia`: picks that text model and presses "Baixar e começar".
enum DevOverrides {
    private static var env: [String: String] {
        ModelLocations.dataDirOverride == nil ? [:] : ProcessInfo.processInfo.environment
    }

    static var physicalMemory: UInt64? {
        env[AppIdentity.env("SIMULATED_RAM_GB")].flatMap(UInt64.init).map { $0 * 1_073_741_824 }
    }

    static var autostartSetup: TextModelChoice? {
        switch env[AppIdentity.env("SETUP_AUTOSTART")] {
        case "qwen": return .qwen3_4b
        case "sem-ia": return .transcriptionOnly
        default: return nil
        }
    }
}
