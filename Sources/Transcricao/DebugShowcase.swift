// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TranscricaoCore
import TranscricaoEngines

/// Screenshots of the answer panel and the undo pill without dictating:
///
///     VOXUM_DEBUG_SHOW_PANEL=tour|short|long|huge|thinking|error|question|question-thinking|undo|hud|hud-question|hud-processing|main|main-bottom|credits|notices|file|file-progress|file-organized|file-summary|file-organizing|file-noai|file-error|file-language \
///         [VOXUM_DEBUG_APPEARANCE=light|dark] [VOXUM_DEBUG_SNAPSHOT_DIR=<dir>] \
///         build/Voxum.app/Contents/MacOS/Voxum
///
/// "main" shows the main window over inert actions (run it with `VOXUM_DATA_DIR`: opening the
/// window marks it as shown in the preferences of that dev domain). "file…" shows a file
/// transcription window in one state, over a fake runner: no model, no file read, and Copy/Save
/// only log.
/// Nothing else starts (no hotkey monitor, recorder, models, status item or settings writes) and
/// the buttons only log or show their inline note: no paste, no ⌘Z, no clipboard change. Prints each visible window's frame
/// in screen-capture coordinates (`screencapture -R`) once the sample has settled.
@MainActor
enum DebugShowcase {
    static var requestedMode: String? { ProcessInfo.processInfo.environment[AppIdentity.env("DEBUG_SHOW_PANEL")] }

    private static var retained: [AnyObject] = []

    static let shortAnswer = "Olá, como está? Tudo bem?"
    /// A question-mode answer (in the interface language when it is one of ours: the layout of the
    /// note under it is what the screenshot checks).
    static var questionAnswer: String {
        switch Locale.preferredLanguages.first.flatMap(AppLanguage.match) {
        case .fr: "Camberra est la capitale de l’Australie. Sydney est la plus grande ville, mais Camberra a été choisie comme compromis entre Sydney et Melbourne."
        case .zhHans: "澳大利亚的首都是堪培拉。悉尼是最大的城市，但堪培拉是作为悉尼和墨尔本之间的折中而选定的。"
        case .es: "La capital de Australia es Canberra. Sídney es la ciudad más grande, pero Canberra se eligió como término medio entre Sídney y Melbourne."
        case .en: "The capital of Australia is Canberra. Sydney is the largest city, but Canberra was chosen as a compromise between Sydney and Melbourne."
        default: "A capital da Austrália é Camberra. Sydney é a maior cidade, mas Camberra foi escolhida como meio-termo entre Sydney e Melbourne."
        }
    }
    static let longAnswer = """
    A prefeitura vai reformar a Praça Central a partir de 3 de março, com obras previstas para durar oito meses. \
    Durante esse período, a feira de domingo passa para a Rua das Flores e duas linhas de ônibus mudam o ponto final.

    O projeto inclui bancos novos, iluminação de LED, um parquinho e a recuperação do chafariz, desativado há mais de dez anos. \
    O custo estimado é de R$ 4,2 milhões, pagos com recursos do estado, e um site vai permitir acompanhar o andamento das obras.

    Em resumo: a praça fica fechada por boa parte do ano, mas volta com mais estrutura para crianças, feirantes e moradores. \
    Quem usa as linhas de ônibus afetadas deve conferir os novos pontos antes da primeira semana de março.
    """

    /// The visible frame of the main screen (a fixed size if no screen is attached).
    private static var visibleFrame: NSRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// The debug panel: Copiar only logs, Colar always answers with the "click a text box" hint.
    private static func makePanel() -> AnswerPanelController {
        let panel = AnswerPanelController()
        panel.inert = true
        panel.onPaste = { _ in AppEnvironment.colarHint }
        return panel
    }

    static func run(_ mode: String) {
        if mode == "tour" { tour(); return }
        switch ProcessInfo.processInfo.environment[AppIdentity.env("DEBUG_APPEARANCE")] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        appLog("debug showcase '\(mode)' (nothing else started)")
        let visible = visibleFrame
        if mode == "main" || mode == "main-bottom" {
            // Opening the window marks it as shown in the preferences: only in a dev data dir.
            guard ModelLocations.dataDirOverride != nil else {
                appLog("debug showcase '\(mode)' needs \(AppIdentity.env("DATA_DIR")) (it writes preferences)")
                NSApp.terminate(nil)
                return
            }
            let state = AppState()
            state.status = .ready
            state.micGranted = true
            state.accessibilityGranted = true
            let actions = InertMenuActions()
            let window = MainWindowController(state: state, settings: Settings.shared, actions: actions)
            retained += [state, actions, window]
            window.show()
            if mode == "main-bottom" { // the Settings and History sections, below the fold
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    MainActor.assumeIsolated {
                        func scrollViews(_ view: NSView) -> [NSScrollView] {
                            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                        }
                        for window in NSApp.windows where window.isVisible {
                            for scroll in scrollViews(window.contentView ?? NSView()) {
                                guard let doc = scroll.documentView else { continue }
                                let bottom = doc.isFlipped ? max(0, doc.bounds.height - scroll.contentView.bounds.height) : 0
                                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                                scroll.reflectScrolledClipView(scroll.contentView)
                            }
                        }
                    }
                }
            }
            reportFrames(after: 1.5)
            return
        }
        if mode == "notices" {
            BundledTextWindowController.show(.notices)
            reportFrames(after: 1)
            return
        }
        if mode == "credits" {
            CreditsWindowController.show()
            reportFrames(after: 1)
            return
        }
        if mode.hasPrefix("file") {
            showFile(mode)
            reportFrames(after: mode == "file-progress" ? 1.5 : 1.2)
            return
        }
        if mode == "hud" || mode == "hud-processing" || mode == "hud-question" {
            // The widest recording pill (continuous + editing a selection), or its processing state.
            let hud = RecordingHUD()
            retained.append(hud)
            if mode == "hud-question" { hud.setQuestion(true) } else { hud.setEditing(true) }
            if mode != "hud-processing" {
                hud.showRecording(continuous: true)
                for i in 0..<24 { hud.push(level: Float(0.004 + 0.02 * abs(sin(Double(i) * 0.7)))) }
            } else {
                hud.showProcessing()
            }
            reportFrames(after: 1)
            return
        }
        if mode == "undo" {
            let pill = UndoPillController()
            pill.inert = true
            pill.lifetime = 600
            retained.append(pill)
            pill.show()
            reportFrames(after: 1)
            return
        }
        let panel = makePanel()
        retained.append(panel)
        let question = mode.hasPrefix("question")
        panel.begin(at: NSPoint(x: visible.midX - 120, y: visible.maxY - 120), kind: question ? .question : .selection)
        switch mode {
        case "question":
            let answer = questionAnswer
            stream(answer, into: panel) { panel.finish(answer) }
        case "short":
            stream(shortAnswer, into: panel) { panel.finish(shortAnswer) }
        case "long":
            stream(longAnswer, into: panel) { panel.finish(longAnswer) }
        case "huge": // past the height cap: the text scrolls
            let huge = [longAnswer, longAnswer, longAnswer].joined(separator: "\n\n")
            panel.update(huge)
            panel.finish(huge)
        case "error":
            stream("Olá, equipe, o cliente aprovou o orçamento. Começamos", into: panel) {
                panel.fail(SelectionEdit.answerFailureMessage)
            }
        default: // "thinking"
            break
        }
        reportFrames(after: mode == "long" ? 6 : 2.5)
    }

    /// A file window in the state `mode` names (the text is the transcript of fixtures/audio/longo.wav).
    private static func showFile(_ mode: String) {
        let runner = ShowcaseFileRunner(aiAvailable: mode != "file-noai")
        let controller = FileTranscriptionController(runner: runner)
        let job = FileJob(url: URL(fileURLWithPath: "/tmp/reuniao-de-equipe.m4a"))
        retained += [runner, controller, job]
        let transcript = FileTranscript(raw: fileTranscript, text: fileTranscript, language: "pt", promptLanguage: "pt",
                                        seconds: 68.2)
        switch mode {
        case "file-progress":
            job.phase = .transcribing
            job.progress = 0.42
            job.liveText = String(fileTranscript.prefix(420))
        case "file-error":
            job.phase = .failed(AudioFileError.unreadable(ogg: true).localizedDescription)
        default:
            job.transcript = transcript
            job.transcribedLanguage = .automatic
            if mode == "file-language" { job.language = .fixed(.en) } // the "transcribe again" offer
            job.phase = .done
            if mode != "file" && mode != "file-noai" && mode != "file-organizing" && mode != "file-language" {
                job.organized = TranscriptTasks.Organized(text: fileOrganized, pieces: 1, keptAsTranscribed: 0)
                job.summary = fileSummary
                job.tab = mode == "file-summary" ? .summary : .organized
            }
            if mode == "file-organizing" {
                job.aiWork = .organizing
                job.aiProgress = 0.6
            }
        }
        controller.present(job)
    }

    static let fileTranscript = """
    Hoje eu gostaria de falar um pouco sobre a rotina de trabalho da nossa equipe de desenvolvimento. Todas as manhãs, nós nos reunimos por 15 minutos para combinar as prioridades do dia. Depois disso, cada pessoa escolhe uma tarefa e começa a trabalhar nela com calma. Quando surge alguma dúvida, a gente conversa no canal da equipe, para que todo mundo acompanhe a decisão. À tarde, fazemos a revisão do código que foi escrito durante o dia, procurando erros e melhorias possíveis. Na sexta-feira, Reservamos uma hora para testar o aplicativo inteiro, do começo ao fim, como se fôssemos usuários de verdade. Os problemas encontrados são anotados e organizados por ordem de importância. Na segunda-feira seguinte, começamos corrigindo os mais urgentes. Esse ritmo simples nos ajuda a entregar novidades toda semana, sem correria e sem deixar a qualidade de lado. Por fim, sempre terminamos o mês com uma conversa sobre o que aprendemos e o que podemos fazer melhor no próximo ciclo.
    """
    static let fileOrganized = """
    Hoje eu gostaria de falar um pouco sobre a rotina de trabalho da nossa equipe de desenvolvimento.

    Todas as manhãs, nós nos reunimos por 15 minutos para combinar as prioridades do dia. Depois disso, cada pessoa escolhe uma tarefa e começa a trabalhar nela com calma. Quando surge alguma dúvida, a gente conversa no canal da equipe, para que todo mundo acompanhe a decisão.

    À tarde, fazemos a revisão do código que foi escrito durante o dia, procurando erros e melhorias possíveis. Na sexta-feira, reservamos uma hora para testar o aplicativo inteiro, do começo ao fim, como se fôssemos usuários de verdade.
    """
    static let fileSummary = """
    - Reunião diária de 15 minutos pela manhã para combinar as prioridades.
    - Dúvidas são discutidas no canal da equipe, para que todos acompanhem as decisões.
    - Revisão do código à tarde; teste completo do aplicativo às sextas-feiras.
    - Problemas anotados por ordem de importância e corrigidos a partir da segunda-feira.
    - Conversa mensal sobre o que foi aprendido e o que melhorar.
    """

    /// Every state in one launch (one window on the user's screen instead of one per state):
    /// first the long answer streamed at a realistic token rate (the caller records it on video to
    /// check that nothing flickers), then each state, printed as `VOXUM_DEBUG_STEP <name> <rect>`
    /// once settled and held for 1.5 s for a screenshot. Quits at the end.
    private static func tour() {
        let panel = makePanel()
        let pill = UndoPillController()
        pill.inert = true
        pill.lifetime = 600
        retained += [panel, pill]
        let visible = visibleFrame
        let point = NSPoint(x: visible.midX - 120, y: visible.maxY - 120)
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func appearance(_ name: NSAppearance.Name) { NSApp.appearance = NSAppearance(named: name) }
        func step(_ name: String) async {
            await pause(0.6)
            emit("\(AppIdentity.env("DEBUG_STEP")) \(name) \(rect(NSApp.windows.first { $0.isVisible }))")
            await pause(1.5)
        }
        Task { @MainActor in
            appearance(.darkAqua)
            emit("\(AppIdentity.env("DEBUG_STREAM_START")) \(rect(NSRect(x: point.x - 190, y: point.y - 16 - visible.height * 0.6 - 20, width: 600, height: visible.height * 0.6 + 40)))")
            await pause(1.0)
            panel.begin(at: point)
            await pause(1.2) // "Pensando…"
            await streamTokens(longAnswer, into: panel)
            panel.finish(longAnswer)
            emit(AppIdentity.env("DEBUG_STREAM_END"))
            await step("long-dark")
            panel.close()

            for (name, look) in [("short-dark", NSAppearance.Name.darkAqua), ("short-light", .aqua)] {
                appearance(look)
                panel.begin(at: point)
                panel.update(shortAnswer)
                panel.finish(shortAnswer)
                await step(name)
                panel.close()
            }
            appearance(.aqua)
            panel.begin(at: point)
            panel.update(longAnswer)
            panel.finish(longAnswer)
            await step("long-light")
            panel.close()

            appearance(.darkAqua)
            let huge = [longAnswer, longAnswer, longAnswer].joined(separator: "\n\n")
            panel.begin(at: point)
            panel.update(huge)
            panel.finish(huge)
            await step("scroll-dark")
            panel.close()

            appearance(.aqua)
            panel.begin(at: point)
            await step("thinking-light")
            panel.close()

            appearance(.darkAqua)
            panel.begin(at: point)
            panel.update("Olá, equipe, o cliente aprovou o orçamento. Começamos")
            panel.fail(SelectionEdit.answerFailureMessage)
            await step("error-dark")
            panel.close()

            appearance(.aqua) // Colar with no text box focused: the panel stays, with the hint
            panel.begin(at: point)
            panel.update(shortAnswer)
            panel.finish(shortAnswer)
            panel.pasteClicked()
            await step("colar-hint-light")
            panel.close()

            for (name, look) in [("undo-dark", NSAppearance.Name.darkAqua), ("undo-light", .aqua)] {
                appearance(look)
                pill.show()
                await step(name)
                pill.dismiss()
            }
            emit(AppIdentity.env("DEBUG_DONE"))
            NSApp.terminate(nil)
        }
    }

    /// Model-like stream: chunks of 2–6 characters every 30 ms (~33 tokens/s), each delivering
    /// the whole text so far, like `SelectionAnswering.answer`'s onPartial.
    private static func streamTokens(_ text: String, into panel: AnswerPanelController) async {
        let sizes = [3, 5, 4, 6, 2, 4]
        var index = text.startIndex
        var i = 0
        while index < text.endIndex {
            index = text.index(index, offsetBy: sizes[i % sizes.count], limitedBy: text.endIndex) ?? text.endIndex
            i += 1
            panel.update(String(text[..<index]))
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// Screen-capture coordinates (top-left origin): "x,y,w,h".
    private static func rect(_ window: NSWindow?) -> String {
        guard let window else { return "none" }
        return rect(window.frame)
    }

    private static func rect(_ f: NSRect) -> String {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return "\(Int(f.minX)),\(Int(top - f.maxY)),\(Int(f.width)),\(Int(f.height))"
    }

    /// Feeds the text word by word, like the model's stream.
    private static func stream(_ text: String, into panel: AnswerPanelController, then done: @escaping @MainActor () -> Void) {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        var partial = ""
        for (i, word) in words.enumerated() {
            partial += (i == 0 ? "" : " ") + word
            let snapshot = partial
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.035) {
                MainActor.assumeIsolated { panel.update(snapshot) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(words.count) * 0.035) {
            MainActor.assumeIsolated { done() }
        }
    }

    private static func reportFrames(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                for window in NSApp.windows where window.isVisible {
                    let f = window.frame
                    let line = "\(AppIdentity.env("DEBUG_FRAME")) \(Int(f.minX)),\(Int(top - f.maxY)),\(Int(f.width)),\(Int(f.height)) window=\(window.windowNumber)\n"
                    FileHandle.standardOutput.write(Data(line.utf8))
                    snapshot(window)
                }
            }
        }
    }
}

extension DebugShowcase {
    /// With `VOXUM_DEBUG_SNAPSHOT_DIR`, each reported window's content is also drawn into
    /// `<dir>/window-<number>.png` (works when the screen can't be captured, e.g. while it sleeps).
    fileprivate static func snapshot(_ window: NSWindow) {
        guard let dir = ProcessInfo.processInfo.environment[AppIdentity.env("DEBUG_SNAPSHOT_DIR")],
              let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return }
        // The layer tree, not `cacheDisplay`: SwiftUI draws its text in layers.
        let scale = window.backingScaleFactor
        let size = NSSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = context.cgContext
        cg.setFillColor(window.backgroundColor.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        cg.scaleBy(x: scale, y: scale)
        layer.render(in: cg)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("window-\(window.windowNumber).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The main window's actions in the showcase: none does anything.
@MainActor
private final class InertMenuActions: StatusMenuActions {
    let downloads = ModelDownloads()
    let updater = Updater.disabled()
    func toggleAI() {}
    func setTextModel(_ choice: TextModelChoice) {}
    func setIdleUnload(_ policy: IdleUnloadPolicy) {}
    func setAppLanguage(_ language: AppLanguage) {}
    func setDictationLanguage(_ language: DictationLanguage) {}
    func setDictationKey(_ key: TriggerKey) {}
    func setQuestionKey(_ key: TriggerKey?) {}
    func toggleSounds() {}
    func toggleLaunchAtLogin() {}
    func copyHistory(_ entry: DictationResult, raw: Bool) {}
    func retryPreparation() {}
    func requestPermissions() {}
    func refreshPermissions() {}
    func showMainWindow() {}
    func cancelDownload() {}
    func retryDownload() {}
    func deleteUnusedModels() {}
    func unusedModels() -> [UnusedModelFolder] { [] }
    func transcribeFile() {}
    func transcribeFiles(_ urls: [URL]) {}
}

/// The file windows' work in the showcase: nothing runs, nothing is read, Copy and Save only log.
@MainActor
private final class ShowcaseFileRunner: FileJobRunner {
    let aiAvailable: Bool
    init(aiAvailable: Bool) { self.aiAvailable = aiAvailable }
    func beginFileWork(waiting: @escaping @MainActor (String) -> Void) async throws {
        throw FileJobError(message: "showcase")
    }
    func endFileWork() async {}
    func transcribe(_ url: URL, language: String?, onProgress: @escaping @Sendable (Double) -> Void,
                    onText: @escaping @Sendable (String) -> Void) async throws -> FileTranscript {
        throw CancellationError()
    }
    func organize(_ text: String, language: String,
                  onProgress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptTasks.Organized {
        throw CancellationError()
    }
    func summarize(_ text: String, language: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        throw CancellationError()
    }
    func recordFile(_ entry: DictationResult, update: Bool) {}
    func copy(_ text: String) { appLog("showcase: Copy (clipboard untouched)") }
    func save(_ text: String, suggestedName: String) { appLog("showcase: Save (nothing written)") }
}
