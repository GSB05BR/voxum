// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NaturalLanguage
import TranscricaoCore
import TranscricaoEngines

/// Developer CLI:
///   tcli process "<texto>" [--model <id>]
///   tcli eval <cases.json> [--model <id>] [--lang <code>]   (cases with "selecionado" exercise edit by voice;
///       --lang = prompt language of cases without their own "lang", default pt = the Portuguese prompt;
///       a case with "langConfidence" simulates Automatic: "lang" detected with that probability)
///       cases with "modo": "pergunta" exercise question mode (QuestionPrompt; "selecionado" = context) and
///       also check the answer's language (NaturalLanguage) against the case's language
///   tcli ask "<pergunta>" [--context <texto>] [--lang <code>] [--model <id>]   (question mode, streamed)
///   tcli transcribe <arquivo.wav> [--whisper-model <variante>] [--lang <code|auto>]
///   tcli file <arquivo> [--lang <code|auto>] [--organize] [--summarize] [--cancel-after <s>]
///       [--cancel-ai-after <s>] [--whisper-model <variante>] [--model <id>]   (the app's file pipeline:
///       streamed reading, ~60 s blocks with progress, language decided once; Organize piece by piece,
///       Summarize map-reduce; --cancel-* cancel that stage after <s> seconds and time the stop;
///       prints the peak memory)
///   tcli wer <refs.json> [--whisper-model <variante>] [--lang <code|auto>]   (WER + latency per audio, refs
///       relative to the JSON; CJK is scored per character; --lang default pt, auto = Whisper detects)
///   tcli notices   (prints THIRD_PARTY_NOTICES.md from the repository root: `tcli notices > THIRD_PARTY_NOTICES.md`)
let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Whisper language for transcribe/wer: `--lang <code>` ("zh-Hans" → "zh"), `auto` = detect; default pt.
func whisperLanguage() -> String? {
    guard let lang = option("--lang") else { return "pt" }
    if lang == "auto" { return nil }
    return AppLanguage.match(lang)?.whisperCode ?? MultilingualPrompt.baseCode(lang)
}

func makeProcessor() async throws -> MLXTextProcessor {
    let id = option("--model") ?? TextModelChoice.qwen3_4b.rawValue
    let p = MLXTextProcessor(modelID: id)
    let t0 = Date()
    try await p.load()
    print("modelo \(id) carregado em \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    return p
}

/// Like the app: a generation cut at maxTokens is never used; the raw text is — except with a
/// selection, where the app pastes nothing (the selection stays intact), so the output is empty.
func processOrRaw(_ p: MLXTextProcessor, _ text: String, selection: String? = nil,
                  language: String = "pt") async throws -> String {
    do { return try await p.process(text, selection: selection, language: language) } catch is OutputTruncatedError {
        if selection != nil {
            print("   (saída cortada em maxTokens → edição falha, nada colado)")
            return ""
        }
        print("   (saída cortada em maxTokens → texto bruto)")
        return text
    }
}

/// Question mode like the app: a cut answer shows an error in the panel, so it scores as empty.
func askOrEmpty(_ p: MLXTextProcessor, _ question: String, context: String?, language: String,
                onPartial: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
    do { return try await p.ask(question, context: context, language: language, onPartial: onPartial) } catch is OutputTruncatedError {
        print("   (resposta cortada em maxTokens → erro na janelinha)")
        return ""
    }
}

/// The answer's language (NaturalLanguage), as a base code ("zh-Hans" → "zh"); nil if unsure.
func answerLanguage(_ text: String) -> String? {
    let r = NLLanguageRecognizer()
    r.processString(text)
    return r.dominantLanguage.map { MultilingualPrompt.baseCode($0.rawValue) }
}

/// Prints a stage's progress on one line, in steps of 5%.
final class ProgressPrinter: @unchecked Sendable {
    private var last: [String: Int] = [:]
    func show(_ stage: String, _ fraction: Double) {
        let step = Int(fraction * 20)
        guard last[stage] != step else { return }
        last[stage] = step
        print("   \(stage): \(Int(fraction * 100))%")
    }
}

/// The process's peak resident memory.
func peakMemory() -> String {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return String(format: "%.0f MB", Double(usage.ru_maxrss) / 1_048_576) // bytes on macOS
}

/// Awaits `task`; with `after` set, cancels it after that many seconds and reports how long it
/// took to stop. Rethrows its error (CancellationError when cancelled).
func cancelling<T: Sendable>(_ task: Task<T, Error>, after: Double?, stage: String) async throws -> T {
    guard let after else { return try await task.value }
    let canceller = Task {
        try await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
        let at = Date()
        print("   \(stage): cancelar (após \(after) s)")
        task.cancel()
        return at
    }
    do {
        let value = try await task.value
        canceller.cancel()
        print("   \(stage): terminou antes do cancelamento")
        return value
    } catch {
        if let at = try? await canceller.value {
            print(String(format: "   %@: parou %.2f s depois do cancelamento (%@)", stage, Date().timeIntervalSince(at),
                         String(describing: type(of: error))))
        }
        throw error
    }
}

func timed<T>(_ op: () async throws -> T) async rethrows -> (T, Double) {
    let t0 = Date()
    let v = try await op()
    return (v, Date().timeIntervalSince(t0))
}

switch args.first {
case "notices":
    // Run from the repository root: the license files come from .build/checkouts and .build/artifacts.
    let root = FileManager.default.currentDirectoryPath
    print(try ThirdPartyNotices.markdown(reading: { try String(contentsOfFile: root + "/" + $0, encoding: .utf8) }),
          terminator: "")

case "process":
    guard args.count >= 2 else { fail("uso: tcli process \"<texto>\" [--model <id>]") }
    let p = try await makeProcessor()
    let (raw, secs) = try await timed { try await processOrRaw(p, args[1]) }
    print(OutputSanitizer.clean(raw))
    print(String(format: "(%.2f s)", secs))

case "eval":
    guard args.count >= 2 else { fail("uso: tcli eval <cases.json> [--model <id>] [--lang <code>]") }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let cases = try JSONDecoder().decode([EvalCase].self, from: data)
    let fileLang = option("--lang") ?? "pt"
    print("idioma: \(fileLang)\(cases.contains { $0.lang != nil } ? " (casos com \"lang\" usam o seu)" : "")")
    let p = try await makeProcessor()
    var passed = 0
    var latencies: [Double] = []
    var thinkLeaks = 0
    var wrongLanguage = 0
    for c in cases {
        let lang = c.langConfidence.map {   // Automatic: the app's routing of the detected label
            DictationLanguage.promptLanguage(requested: nil, detected: c.lang ?? fileLang, confidence: $0,
                                             transcript: c.entrada)
        } ?? c.lang ?? fileLang
        let question = c.modo == "pergunta"
        let (raw, secs) = try await timed { () -> String in
            if question { return try await askOrEmpty(p, c.entrada, context: c.selecionado, language: lang) }
            if c.selecionadoSomenteLeitura == true, let sel = c.selecionado {
                // Answer panel: a cut or failed answer shows an error, so it scores as empty.
                do {
                    return try await p.answer(c.entrada, about: sel, language: lang, onPartial: { _ in })
                } catch is OutputTruncatedError {
                    print("   (resposta cortada em maxTokens → erro na janelinha)")
                    return ""
                }
            }
            return try await processOrRaw(p, c.entrada, selection: c.selecionado, language: lang)
        }
        let out = question ? OutputSanitizer.cleanAnswer(raw) : OutputSanitizer.clean(raw)
        if raw.contains("<think") || raw.contains("</think") { thinkLeaks += 1; print("   ⚠️ <think> no texto bruto") }
        var failures = EvalScorer.failures(output: out, for: c)
        // A question is answered in its own language (the case's), whatever the context's language.
        if question, let expected = c.lang.map(MultilingualPrompt.baseCode), !out.isEmpty {
            let got = answerLanguage(out)
            if got != expected {
                failures.append("idioma da resposta: \(got ?? "?") (esperado \(expected))")
                wrongLanguage += 1
            }
        }
        if question, out.isEmpty { failures.append("sem resposta") }
        // The app strips a <question> tag from the answer (cleanAnswer); the raw output shows whether
        // the model echoed the prompt's structure.
        if question, raw.range(of: #"(?i)</?question>"#, options: .regularExpression) != nil {
            failures.append("tag <question> na saída bruta")
        }
        latencies.append(secs)
        if failures.isEmpty { passed += 1 }
        print("\(failures.isEmpty ? "✅" : "❌") [\(c.id)] \(String(format: "%.2f s", secs))"
              + (c.langConfidence == nil ? "" : " · prompt: \(lang.isEmpty ? "neutro" : lang)"))
        if let sel = c.selecionado {
            print("   \(question ? "contexto" : "seleção")\(c.selecionadoSomenteLeitura == true ? " SOMENTE LEITURA" : "") (\(sel.count) car.): \(sel.count > 160 ? String(sel.prefix(160)) + "…" : sel)")
            let timeout = question ? QuestionPrompt.timeout : SelectionEdit.processingTimeout(base: 6, selectionCharacters: sel.count)
            if secs > timeout { print(String(format: "   ⚠️ passaria do timeout do app (%.1f s)", timeout)) }
        }
        if question, c.selecionado == nil, secs > QuestionPrompt.timeout {
            print(String(format: "   ⚠️ passaria do timeout do app (%.1f s)", QuestionPrompt.timeout))
        }
        print("   fala:   \(c.entrada)")
        print("   saída:  \(out)")
        if let e = c.esperado { print("   ideal:  \(e)") }
        if !failures.isEmpty { print("   falhas: \(failures.joined(separator: "; "))") }
    }
    let sorted = latencies.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    print(String(format: "\nRESULTADO: %d/%d aprovados · mediana %.2f s · máx %.2f s · vazamentos de <think>: %d",
                 passed, cases.count, median, sorted.last ?? 0, thinkLeaks)
          + (cases.contains { $0.modo == "pergunta" } ? " · idioma errado: \(wrongLanguage)" : ""))

case "ask":
    guard args.count >= 2 else { fail("uso: tcli ask \"<pergunta>\" [--context <texto>] [--lang <code>] [--model <id>]") }
    let lang = option("--lang") ?? "pt"
    let p = try await makeProcessor()
    let (raw, secs) = try await timed {
        try await askOrEmpty(p, args[1], context: option("--context"), language: lang)
    }
    let out = OutputSanitizer.cleanAnswer(raw)
    print(out)
    print(String(format: "(%.2f s, %d car., idioma %@)", secs, out.count, answerLanguage(out) ?? "?"))

case "transcribe":
    guard args.count >= 2 else { fail("uso: tcli transcribe <arquivo> [--whisper-model <variante>] [--lang <code|auto>]") }
    let samples = try AudioFileLoader.load16kMono(URL(fileURLWithPath: args[1]))
    let w = WhisperKitTranscriber(variant: option("--whisper-model") ?? WhisperKitTranscriber.variant)
    let (_, loadSecs) = try await timed { try await w.load() }
    print(String(format: "whisper carregado em %.1f s", loadSecs))
    let language = whisperLanguage()
    let (transcript, secs) = try await timed { try await w.transcribe(samples, language: language) }
    let audioSecs = Double(samples.count) / 16_000
    print(transcript.text)
    print("idioma: \(transcript.language ?? "?")"
          + (language == nil ? " (detectado, p = \(transcript.languageConfidence.map { String(format: "%.2f", $0) } ?? "?"))" : ""))
    print(String(format: "(%.2f s para %.1f s de áudio)", secs, audioSecs))

case "wer":
    guard args.count >= 2 else { fail("uso: tcli wer <refs.json> [--whisper-model <variante>] [--lang <code|auto>]") }
    let language = whisperLanguage()
    let refsURL = URL(fileURLWithPath: args[1])
    let cases = try JSONDecoder().decode([WERCase].self, from: Data(contentsOf: refsURL))
    let variant = option("--whisper-model") ?? WhisperKitTranscriber.variant
    let w = WhisperKitTranscriber(variant: variant)
    let (_, loadSecs) = try await timed { try await w.load() }
    print(String(format: "whisper %@ carregado em %.1f s", variant, loadSecs))
    let inputs = try cases.map { c in
        (c, try AudioFileLoader.load16kMono(refsURL.deletingLastPathComponent().appendingPathComponent(c.audio)))
    }
    if let first = inputs.first { _ = try await w.transcribe(first.1, language: language) } // untimed pass: later runs are warm
    var strict: [WordErrorRate.Result] = [], loose: [WordErrorRate.Result] = []
    var latencies: [Double] = []
    var byVoice: [String: [WordErrorRate.Result]] = [:]
    for (c, samples) in inputs {
        let (transcript, secs) = try await timed { try await w.transcribe(samples, language: language) }
        let text = transcript.text
        let s = WordErrorRate.compute(references: c.allReferences, hypothesis: text)
        let l = WordErrorRate.compute(references: c.allReferences, hypothesis: text, ignoreAccents: true)
        strict.append(s); loose.append(l); latencies.append(secs)
        byVoice[c.voice ?? "?", default: []].append(s)
        print(String(format: "[%@] WER %.0f%% (sem acento %.0f%%) %.2f s", c.id, s.rate * 100, l.rate * 100, secs)
              + (language == nil ? " · detectado: \(transcript.language ?? "?") p = "
                 + (transcript.languageConfidence.map { String(format: "%.2f", $0) } ?? "?") : ""))
        print("   ref: \(c.ref)")
        print("   hyp: \(text)")
    }
    let sorted = latencies.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    for (voice, rs) in byVoice.sorted(by: { $0.key < $1.key }) {
        let a = WordErrorRate.aggregate(rs)
        print(String(format: "voz %@: WER %.1f%% (%d/%d, n=%d)", voice, a.rate * 100, a.edits, a.referenceWords, rs.count))
    }
    let S = WordErrorRate.aggregate(strict), L = WordErrorRate.aggregate(loose)
    print(String(format: "\nRESULTADO %@: WER %.1f%% (%d/%d) · sem acento %.1f%% (%d/%d) · mediana %.2f s · total %.1f s · n=%d",
                 variant, S.rate * 100, S.edits, S.referenceWords, L.rate * 100, L.edits, L.referenceWords,
                 median, latencies.reduce(0, +), cases.count))

case "file":
    guard args.count >= 2 else {
        fail("uso: tcli file <arquivo> [--lang <code|auto>] [--organize] [--summarize] [--cancel-after <s>] [--cancel-ai-after <s>]")
    }
    let url = URL(fileURLWithPath: args[1])
    let w = WhisperKitTranscriber(variant: option("--whisper-model") ?? WhisperKitTranscriber.variant)
    let (_, loadSecs) = try await timed { try await w.load() }
    print(String(format: "whisper carregado em %.1f s · memória máx. %@", loadSecs, peakMemory()))
    let language = whisperLanguage()
    let printer = ProgressPrinter()
    let job = Task { () -> FileTranscript in
        try await w.transcribeFile(url, language: language, onProgress: { printer.show("transcrição", $0) })
    }
    let transcript: FileTranscript
    let t0 = Date()
    do {
        transcript = try await cancelling(job, after: option("--cancel-after").flatMap(Double.init), stage: "transcrição")
    } catch is CancellationError {
        print("memória máx. \(peakMemory())")
        exit(0)
    } catch {
        fail("erro: \(error.localizedDescription)")
    }
    let secs = Date().timeIntervalSince(t0)
    print("\n" + transcript.text)
    print("idioma: \(transcript.language ?? "?") · prompt: \(transcript.promptLanguage.isEmpty ? "neutro" : transcript.promptLanguage)")
    print(String(format: "(%.2f s para %.1f s de áudio, %.0fx · %d caracteres · memória máx. %@)", secs, transcript.seconds,
                 transcript.seconds / max(0.01, secs), transcript.text.count, peakMemory()))
    if args.contains("--organize") || args.contains("--summarize") {
        guard !transcript.raw.isEmpty else { fail("nada transcrito: nada a organizar ou resumir") }
        let p = try await makeProcessor()
        let aiCancel = option("--cancel-ai-after").flatMap(Double.init)
        if args.contains("--organize") {
            let pieces = TextChunker.chunks(transcript.raw, maxCharacters:
                TranscriptTasks.characters(forBudget: TranscriptTasks.organizeBudget, in: transcript.raw)).count
            print("\norganizar: \(pieces) pedaço(s), prompt \(transcript.promptLanguage.isEmpty ? "neutro" : transcript.promptLanguage)")
            let start = Date()
            let task = Task {
                try await TranscriptTasks.organize(transcript.raw, language: transcript.promptLanguage, using: p,
                                                   onProgress: { printer.show("organizar", $0) })
            }
            if let organized = try? await cancelling(task, after: aiCancel, stage: "organizar") {
                print("\n" + organized.text)
                print(String(format: "(%.1f s · %d pedaço(s), %d mantido(s) como transcrito(s))",
                             Date().timeIntervalSince(start), organized.pieces, organized.keptAsTranscribed))
            }
        }
        if args.contains("--summarize") {
            let start = Date()
            let task = Task {
                try await TranscriptTasks.summarize(transcript.raw, language: transcript.promptLanguage, using: p,
                                                    onProgress: { printer.show("resumir", $0) })
            }
            do {
                let summary = try await cancelling(task, after: aiCancel, stage: "resumir")
                print("\n" + summary)
                print(String(format: "(%.1f s · idioma do resumo: %@)", Date().timeIntervalSince(start), answerLanguage(summary) ?? "?"))
            } catch is CancellationError {
            } catch {
                print("resumo falhou: \(error)")
            }
        }
        print("memória máx. \(peakMemory())")
    }

default:
    fail("subcomandos: process | eval | ask | transcribe | file | wer | notices")
}
