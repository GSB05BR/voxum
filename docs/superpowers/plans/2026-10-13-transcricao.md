# Transcrição — Plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App de barra de menus para macOS que grava a fala com o ⌥ direito, transcreve localmente com Whisper, organiza o texto com um LLM local pequeno e cola no campo em foco.

**Architecture:** Pacote SwiftPM com três camadas: `TranscricaoCore` (lógica pura, testada com XCTest, sem AppKit/ML), `TranscricaoEngines` (WhisperKit + mlx-swift-lm atrás dos protocolos do Core) e o executável `Transcricao` (AppKit/SwiftUI). Uma ferramenta `tcli` roda o eval do prompt e transcreve WAVs sem precisar do app.

**Tech Stack:** Swift 6.4 toolchain (modo de linguagem Swift 5), macOS 14+, WhisperKit 1.1.x, mlx-swift-lm 3.32.x (+ swift-huggingface, swift-transformers), XCTest, AppKit + SwiftUI.

**Spec:** `docs/superpowers/specs/2026-10-13-transcricao-design.md`

## Global Constraints

- Plataforma: `.macOS(.v14)`; `// swift-tools-version: 5.10` no `Package.swift` (modo Swift 5, evita a concorrência estrita do Swift 6 com MLX/WhisperKit).
- Pré-requisito: Metal Toolchain instalado (`xcodebuild -showComponent MetalToolchain` → `Status: installed`).
- Caminho do projeto: a raiz do repositório (`<repo>`). Use sempre caminhos absolutos ou `cd` explícito — o cwd do shell desta sessão pode voltar para a pasta antiga `Transcrição `.
- `TranscricaoCore` NÃO importa AppKit, AVFoundation, WhisperKit nem MLX.
- UI em português; comentários de código em inglês.
- Whisper: `openai_whisper-large-v3-v20240930_turbo_632MB`, `language: "pt"`, temperatura 0, sem timestamps.
- LLM padrão: `mlx-community/Qwen3-4B-Instruct-2507-4bit`; candidato: `mlx-community/gemma-4-e4b-it-4bit`. Temperatura 0. Timeout 6 s → texto bruto.
- `maxTokens = min(1024, max(256, 3/4 × caracteres da entrada))` (≈ 3× os tokens da entrada).
- Hotkey: ⌥ direito (keyCode 61). Segurar ≥ 250 ms = push-to-talk. Dois toques em ≤ 400 ms = contínuo.
- SpeechGate: < 0,4 s ou janela de 100 ms mais alta com RMS < 0,01 → descarta.
- Inserção: pasteboard com `org.nspasteboard.TransientType`, ⌘V via CGEvent, restaurar após 250 ms.
- Gravação máx. 5 min. Histórico: 50 itens em `~/Library/Application Support/Transcricao/history.json`; menu mostra 10.
- Modelos em `~/Library/Application Support/Transcricao/Models/`.
- Liberar memória após inatividade: Nunca (padrão) / 5 / 15 / 30 min.
- Assinatura: o certificado de desenvolvimento local (`CODESIGN_IDENTITY`); bundle id `<bundle id de então>`; nome exibido "Transcrição".
- Commits terminam com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

> Desvio consciente da spec §4.9: durante a recarga após inatividade não há ícone próprio de "carregando" — a gravação já está em andamento e, ao soltar, a pílula mostra "Processando…" enquanto a recarga termina. Evita um estado extra que competiria com "gravando".

1. **Pergunta ditada não pode ser respondida** — "qual é a capital da Austrália" deve virar `Qual é a capital da Austrália?`, nunca "Canberra". Coberto pelo caso `pergunta-ditado` do eval (Task 8) e pela regra explícita no prompt (Task 4).
2. **⌥ usado como modificador** (⌥+E, ⌥+setas, segurar ⌥ e clicar) não pode disparar nem colar nada — `otherKey` cancela em `pressed`/`awaitingSecondTap` (Task 2, testes `testOptionAsModifierCancels*`).
3. **"Obrigado." ditado de verdade não pode sumir** — o filtro de alucinação só remove marcadores que nunca são ditado (Amara.org, "inscreva-se no canal"…); silêncio é tratado pelo SpeechGate. Teste `testKeepsGenuineThanks` (Task 3). *Refinamento consciente da spec §4.3, que listava "Obrigado."*
4. **Gravação longa com pouca fala não pode ser descartada** — o gate usa a janela de 100 ms mais alta, não o RMS médio. Teste `testLongClipWithShortSpeechPasses` (Task 3). Gravações > 30 s usam `chunkingStrategy: .vad` no Whisper (Task 9).
5. **Duas gravações seguidas não podem colar fora de ordem nem se misturar** — o pipeline serializa execuções. Teste `testRunsAreSerializedInOrder` (Task 5).

---

### Task 1: Esqueleto do pacote + Core testável

**Files:**
- Create: `Package.swift`
- Create: `Sources/TranscricaoCore/TranscricaoCore.swift`
- Create: `Tests/TranscricaoCoreTests/SmokeTests.swift`

**Interfaces:**
- Produces: alvo `TranscricaoCore` (library) e `TranscricaoCoreTests`. Tasks 2–7 só adicionam arquivos a eles.

- [ ] **Step 1: Confirmar o Metal Toolchain** (necessário a partir da Task 8; verifique já)

Run: `xcodebuild -showComponent MetalToolchain | grep Status`
Expected: `Status: installed`. Se `uninstalled`, rode `xcodebuild -downloadComponent MetalToolchain` e continue com as Tasks 1–7 enquanto baixa.

- [ ] **Step 2: Criar `Package.swift` (só o Core por enquanto)**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Transcricao",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TranscricaoCore"),
        .testTarget(name: "TranscricaoCoreTests", dependencies: ["TranscricaoCore"]),
    ]
)
```

- [ ] **Step 3: Arquivo-âncora do Core e teste de fumaça**

`Sources/TranscricaoCore/TranscricaoCore.swift`:
```swift
/// Pure, UI-free logic for the dictation app. No AppKit / ML imports allowed here.
public enum TranscricaoCore {
    public static let version = "0.1.0"
}
```

`Tests/TranscricaoCoreTests/SmokeTests.swift`:
```swift
import XCTest
@testable import TranscricaoCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(TranscricaoCore.version, "0.1.0")
    }
}
```

- [ ] **Step 4: Rodar**

Run: `cd <repo> && swift test 2>&1 | tail -5`
Expected: `Executed 1 test, with 0 failures`

- [ ] **Step 5: Commit**

```bash
cd <repo> && git add Package.swift Sources Tests && git commit -m "chore: scaffold SwiftPM package with core library and tests

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: HotkeyStateMachine

**Files:**
- Create: `Sources/TranscricaoCore/Hotkey/HotkeyStateMachine.swift`
- Test: `Tests/TranscricaoCoreTests/HotkeyStateMachineTests.swift`

**Interfaces:**
- Produces:
  - `public enum HotkeyEvent: Equatable { case keyDown(TimeInterval), keyUp(TimeInterval), otherKey, escape, tick(TimeInterval) }`
  - `public enum HotkeyAction: Equatable { case startCapture, stopAndProcess, cancel }`
  - `public struct HotkeyStateMachine { enum State { idle, pressed(at:), awaitingSecondTap(releasedAt:), continuous }; static holdThreshold = 0.25; static doubleTapWindow = 0.40; private(set) var state; var isContinuous: Bool; mutating func handle(_:) -> [HotkeyAction] }`

- [ ] **Step 1: Escrever os testes**

```swift
import XCTest
@testable import TranscricaoCore

final class HotkeyStateMachineTests: XCTestCase {
    private var m = HotkeyStateMachine()

    override func setUp() { m = HotkeyStateMachine() }

    func testHoldIsPushToTalk() {
        XCTAssertEqual(m.handle(.keyDown(10.0)), [.startCapture])
        XCTAssertEqual(m.handle(.keyUp(10.8)), [.stopAndProcess])
        XCTAssertEqual(m.state, .idle)
    }

    func testHoldExactlyAtThresholdIsPushToTalk() {
        _ = m.handle(.keyDown(0))
        XCTAssertEqual(m.handle(.keyUp(0.25)), [.stopAndProcess])
    }

    func testSingleShortTapIsCancelledAfterWindow() {
        XCTAssertEqual(m.handle(.keyDown(0)), [.startCapture])
        XCTAssertEqual(m.handle(.keyUp(0.1)), [])
        XCTAssertEqual(m.state, .awaitingSecondTap(releasedAt: 0.1))
        XCTAssertEqual(m.handle(.tick(0.3)), [])          // window still open
        XCTAssertEqual(m.handle(.tick(0.6)), [.cancel])   // window (0.4 s) closed
        XCTAssertEqual(m.state, .idle)
    }

    func testDoubleTapEntersContinuousAndNextTapStops() {
        _ = m.handle(.keyDown(0))
        _ = m.handle(.keyUp(0.1))
        XCTAssertEqual(m.handle(.keyDown(0.3)), [])
        XCTAssertTrue(m.isContinuous)
        XCTAssertEqual(m.handle(.keyUp(0.35)), [])        // release of 2nd tap ignored
        XCTAssertEqual(m.handle(.tick(5)), [])
        XCTAssertEqual(m.handle(.keyDown(12)), [.stopAndProcess])
        XCTAssertEqual(m.handle(.keyUp(12.1)), [])
        XCTAssertEqual(m.state, .idle)
    }

    func testLateSecondPressRestartsCapture() {
        _ = m.handle(.keyDown(0))
        _ = m.handle(.keyUp(0.1))
        // tick was lost; press arrives after the window
        XCTAssertEqual(m.handle(.keyDown(1.0)), [.cancel, .startCapture])
        XCTAssertEqual(m.state, .pressed(at: 1.0))
    }

    func testOptionAsModifierCancelsWhilePressed() {
        _ = m.handle(.keyDown(0))
        XCTAssertEqual(m.handle(.otherKey), [.cancel])
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.handle(.keyUp(0.6)), [])         // stray release does nothing
    }

    func testOptionAsModifierCancelsWhileAwaitingSecondTap() {
        _ = m.handle(.keyDown(0))
        _ = m.handle(.keyUp(0.1))
        XCTAssertEqual(m.handle(.otherKey), [.cancel])
        XCTAssertEqual(m.state, .idle)
    }

    func testTypingDuringContinuousIsIgnored() {
        _ = m.handle(.keyDown(0)); _ = m.handle(.keyUp(0.1)); _ = m.handle(.keyDown(0.2))
        XCTAssertEqual(m.handle(.otherKey), [])
        XCTAssertTrue(m.isContinuous)
    }

    func testEscapeCancelsAnyCapture() {
        _ = m.handle(.keyDown(0))
        XCTAssertEqual(m.handle(.escape), [.cancel])
        _ = m.handle(.keyDown(1)); _ = m.handle(.keyUp(1.1)); _ = m.handle(.keyDown(1.2))
        XCTAssertEqual(m.handle(.escape), [.cancel])
        XCTAssertEqual(m.state, .idle)
    }

    func testEscapeWhenIdleDoesNothing() {
        XCTAssertEqual(m.handle(.escape), [])
        XCTAssertEqual(m.handle(.otherKey), [])
        XCTAssertEqual(m.handle(.keyUp(3)), [])
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd <repo> && swift test --filter HotkeyStateMachineTests 2>&1 | tail -5`
Expected: erro de compilação `cannot find 'HotkeyStateMachine' in scope`.

- [ ] **Step 3: Implementar**

```swift
import Foundation

/// Raw input for the hotkey state machine. Timestamps are monotonic seconds
/// (NSEvent.timestamp / ProcessInfo.systemUptime).
public enum HotkeyEvent: Equatable {
    case keyDown(TimeInterval)
    case keyUp(TimeInterval)
    /// Any non-hotkey key was pressed (e.g. Option used as a modifier: ⌥+E).
    case otherKey
    case escape
    /// Periodic/explicit timer tick used to close the double-tap window.
    case tick(TimeInterval)
}

public enum HotkeyAction: Equatable {
    case startCapture
    case stopAndProcess
    case cancel
}

/// Hold = push-to-talk; double tap = continuous until the next tap.
/// Capture starts on the first key down so no words are lost; an isolated
/// short tap is cancelled once the double-tap window closes.
public struct HotkeyStateMachine {
    public enum State: Equatable {
        case idle
        case pressed(at: TimeInterval)
        case awaitingSecondTap(releasedAt: TimeInterval)
        case continuous
    }

    public static let holdThreshold: TimeInterval = 0.25
    public static let doubleTapWindow: TimeInterval = 0.40

    public private(set) var state: State = .idle

    public init() {}

    public var isContinuous: Bool { state == .continuous }

    public mutating func handle(_ event: HotkeyEvent) -> [HotkeyAction] {
        switch (state, event) {
        case (.idle, .keyDown(let t)):
            state = .pressed(at: t)
            return [.startCapture]
        case (.idle, _):
            return []

        case (.pressed(let start), .keyUp(let t)):
            if t - start >= Self.holdThreshold {
                state = .idle
                return [.stopAndProcess]
            }
            state = .awaitingSecondTap(releasedAt: t)
            return []

        case (.awaitingSecondTap(let released), .keyDown(let t)):
            if t - released <= Self.doubleTapWindow {
                state = .continuous
                return []
            }
            state = .pressed(at: t)
            return [.cancel, .startCapture]
        case (.awaitingSecondTap(let released), .tick(let t)):
            if t - released >= Self.doubleTapWindow {
                state = .idle
                return [.cancel]
            }
            return []

        case (.continuous, .keyDown):
            state = .idle
            return [.stopAndProcess]

        case (.pressed, .otherKey), (.awaitingSecondTap, .otherKey):
            state = .idle
            return [.cancel]

        case (_, .escape):
            state = .idle
            return [.cancel]

        default:
            return []
        }
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd <repo> && swift test --filter HotkeyStateMachineTests 2>&1 | tail -3`
Expected: `Executed 10 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
cd <repo> && git add -A Sources Tests && git commit -m "feat(core): hotkey state machine for hold and double-tap

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: SpeechGate + HallucinationFilter

**Files:**
- Create: `Sources/TranscricaoCore/Audio/SpeechGate.swift`
- Create: `Sources/TranscricaoCore/Text/HallucinationFilter.swift`
- Test: `Tests/TranscricaoCoreTests/SpeechGateTests.swift`
- Test: `Tests/TranscricaoCoreTests/HallucinationFilterTests.swift`

**Interfaces:**
- Produces:
  - `public struct SpeechGate: Sendable { init(sampleRate: Double = 16_000, minDuration: Double = 0.4, minPeakRMS: Float = 0.01, windowSeconds: Double = 0.1); func shouldTranscribe(_ samples: [Float]) -> Bool; static func peakWindowRMS(_:windowSize:) -> Float }`
  - `public enum HallucinationFilter { static func clean(_ text: String) -> String? }` — `nil` = descartar.

- [ ] **Step 1: Testes do SpeechGate**

```swift
import XCTest
@testable import TranscricaoCore

final class SpeechGateTests: XCTestCase {
    let gate = SpeechGate()

    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        let n = Int(seconds * 16_000)
        return (0..<n).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    func testRejectsTooShort() {
        XCTAssertFalse(gate.shouldTranscribe(tone(seconds: 0.3, amplitude: 0.3)))
    }

    func testRejectsSilence() {
        XCTAssertFalse(gate.shouldTranscribe([Float](repeating: 0.001, count: 32_000)))
    }

    func testAcceptsSpeechLikeSignal() {
        XCTAssertTrue(gate.shouldTranscribe(tone(seconds: 1.0, amplitude: 0.1)))
    }

    func testLongClipWithShortSpeechPasses() {
        // 20 s of near-silence with 0.5 s of speech in the middle.
        var s = [Float](repeating: 0.0005, count: 20 * 16_000)
        let speech = tone(seconds: 0.5, amplitude: 0.08)
        s.replaceSubrange(160_000..<(160_000 + speech.count), with: speech)
        XCTAssertTrue(gate.shouldTranscribe(s))
    }

    func testEmptyInput() {
        XCTAssertFalse(gate.shouldTranscribe([]))
        XCTAssertEqual(SpeechGate.peakWindowRMS([], windowSize: 1600), 0)
    }
}
```

- [ ] **Step 2: Testes do HallucinationFilter**

```swift
import XCTest
@testable import TranscricaoCore

final class HallucinationFilterTests: XCTestCase {
    func testDropsKnownPhantomWholeText() {
        XCTAssertNil(HallucinationFilter.clean("Legendas pela comunidade Amara.org"))
        XCTAssertNil(HallucinationFilter.clean("  Inscreva-se no canal!  "))
        XCTAssertNil(HallucinationFilter.clean(""))
        XCTAssertNil(HallucinationFilter.clean("   "))
    }

    func testRemovesPhantomSentenceButKeepsSpeech() {
        XCTAssertEqual(
            HallucinationFilter.clean("Vou chegar às oito. Legendas pela comunidade Amara.org"),
            "Vou chegar às oito.")
    }

    func testKeepsGenuineThanks() {
        XCTAssertEqual(HallucinationFilter.clean("Obrigado."), "Obrigado.")
        XCTAssertEqual(HallucinationFilter.clean("Obrigada pela ajuda!"), "Obrigada pela ajuda!")
    }

    func testIsAccentAndCaseInsensitive() {
        XCTAssertNil(HallucinationFilter.clean("LEGENDAS PELA COMUNIDADE AMARA.ORG."))
        XCTAssertNil(HallucinationFilter.clean("Obrigado por assistir."))
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(HallucinationFilter.clean("  oi tudo bem  "), "oi tudo bem")
    }
}
```

- [ ] **Step 3: Rodar e ver falhar**

Run: `cd <repo> && swift test --filter "SpeechGateTests|HallucinationFilterTests" 2>&1 | tail -5`
Expected: erro de compilação (tipos inexistentes).

- [ ] **Step 4: Implementar o SpeechGate**

```swift
import Foundation

/// Decides whether a captured clip is worth sending to Whisper.
/// Uses the loudest short window rather than the clip-wide RMS so a long
/// recording with a little speech is not mistaken for silence.
public struct SpeechGate: Sendable {
    public var sampleRate: Double
    public var minDuration: Double
    public var minPeakRMS: Float
    public var windowSeconds: Double

    public init(sampleRate: Double = 16_000, minDuration: Double = 0.4,
                minPeakRMS: Float = 0.01, windowSeconds: Double = 0.1) {
        self.sampleRate = sampleRate
        self.minDuration = minDuration
        self.minPeakRMS = minPeakRMS
        self.windowSeconds = windowSeconds
    }

    public func shouldTranscribe(_ samples: [Float]) -> Bool {
        guard Double(samples.count) / sampleRate >= minDuration else { return false }
        let window = max(1, Int(windowSeconds * sampleRate))
        return Self.peakWindowRMS(samples, windowSize: window) >= minPeakRMS
    }

    public static func peakWindowRMS(_ samples: [Float], windowSize: Int) -> Float {
        guard !samples.isEmpty, windowSize > 0 else { return 0 }
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(start + windowSize, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            peak = max(peak, (sum / Float(end - start)).squareRoot())
            start = end
        }
        return peak
    }
}
```

- [ ] **Step 5: Implementar o HallucinationFilter**

```swift
import Foundation

/// Removes phrases Whisper invents on silence/noise in PT-BR (subtitle credits
/// learned from training data). Only markers that are never genuine dictation
/// are listed — a dictated "Obrigado." must survive; silence is the gate's job.
public enum HallucinationFilter {
    static let markers: [String] = [
        "amara.org",
        "legendas pela comunidade",
        "legendado por",
        "legenda adriana zanotto",
        "inscreva-se no canal",
        "obrigado por assistir",
        "obrigada por assistir",
    ]

    /// Returns the text without phantom sentences, or nil when nothing real is left.
    public static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Split only on sentence punctuation followed by whitespace, so "Amara.org" stays whole.
        let sentences = trimmed
            .replacingOccurrences(of: #"([.!?…])\s+"#, with: "$1\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kept = sentences.filter { sentence in
            let folded = fold(sentence)
            return !markers.contains { folded.contains($0) }
        }
        let result = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
    }
}
```

- [ ] **Step 6: Rodar e ver passar**

Run: `cd <repo> && swift test --filter "SpeechGateTests|HallucinationFilterTests" 2>&1 | tail -3`
Expected: `Executed 10 tests, with 0 failures`

- [ ] **Step 7: Commit**

```bash
cd <repo> && git add -A Sources Tests && git commit -m "feat(core): speech gate and Whisper hallucination filter

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: PromptBuilder + OutputSanitizer + EvalScorer

**Files:**
- Create: `Sources/TranscricaoCore/Text/PromptBuilder.swift`
- Create: `Sources/TranscricaoCore/Text/OutputSanitizer.swift`
- Create: `Sources/TranscricaoCore/Text/EvalScorer.swift`
- Test: `Tests/TranscricaoCoreTests/PromptBuilderTests.swift`
- Test: `Tests/TranscricaoCoreTests/OutputSanitizerTests.swift`
- Test: `Tests/TranscricaoCoreTests/EvalScorerTests.swift`

**Interfaces:**
- Produces:
  - `public struct ChatTurn: Equatable, Sendable { enum Role { system, user, assistant }; role; content }`
  - `public enum PromptBuilder { static let systemPrompt: String; static let examples: [(fala: String, texto: String)]; static func wrap(_ transcript: String) -> String; static func messages(for transcript: String) -> [ChatTurn]; static func maxTokens(forInputCharacters: Int) -> Int }`
  - `public enum OutputSanitizer { static func clean(_ raw: String) -> String }`
  - `public struct EvalCase: Codable { id, entrada, modo, esperado?, deveConter?, naoDeveConter?, maxCaracteres? }`
  - `public enum EvalScorer { static func failures(output: String, for: EvalCase) -> [String] }`

- [ ] **Step 1: Testes**

`PromptBuilderTests.swift`:
```swift
import XCTest
@testable import TranscricaoCore

final class PromptBuilderTests: XCTestCase {
    func testMessagesShape() {
        let msgs = PromptBuilder.messages(for: "oi tudo bem")
        XCTAssertEqual(msgs.first?.role, .system)
        XCTAssertEqual(msgs.last, ChatTurn(role: .user, content: "<fala>oi tudo bem</fala>"))
        // system + (user, assistant) per example + final user
        XCTAssertEqual(msgs.count, 1 + PromptBuilder.examples.count * 2 + 1)
        for (i, ex) in PromptBuilder.examples.enumerated() {
            XCTAssertEqual(msgs[1 + i * 2], ChatTurn(role: .user, content: "<fala>\(ex.fala)</fala>"))
            XCTAssertEqual(msgs[2 + i * 2], ChatTurn(role: .assistant, content: ex.texto))
        }
    }

    func testIncludesUserExamplesVerbatim() {
        let falas = PromptBuilder.examples.map(\.fala)
        XCTAssertTrue(falas.contains("oi tudo bem como você vai não quis dizer como você está"))
        XCTAssertTrue(falas.contains("crie uma mensagem de parabéns pra mim seja bem curto e casual"))
    }

    func testSystemPromptStatesKeyRules() {
        let p = PromptBuilder.systemPrompt
        XCTAssertTrue(p.contains("SOMENTE com o texto final"))
        XCTAssertTrue(p.contains("Na dúvida, é DITADO"))
        XCTAssertTrue(p.contains("não responda a perguntas"))
    }

    func testMaxTokensBounds() {
        XCTAssertEqual(PromptBuilder.maxTokens(forInputCharacters: 10), 256)
        XCTAssertEqual(PromptBuilder.maxTokens(forInputCharacters: 800), 600)
        XCTAssertEqual(PromptBuilder.maxTokens(forInputCharacters: 10_000), 1024)
    }
}
```

`OutputSanitizerTests.swift`:
```swift
import XCTest
@testable import TranscricaoCore

final class OutputSanitizerTests: XCTestCase {
    func testPlainTextUnchanged() {
        XCTAssertEqual(OutputSanitizer.clean("Oi, tudo bem? Como você está?"), "Oi, tudo bem? Como você está?")
    }
    func testRemovesThinkBlocks() {
        XCTAssertEqual(OutputSanitizer.clean("<think>hmm</think>\nOi!"), "Oi!")
        XCTAssertEqual(OutputSanitizer.clean("<think>never closed"), "")
    }
    func testRemovesLabels() {
        XCTAssertEqual(OutputSanitizer.clean("Texto final: Bom dia."), "Bom dia.")
        XCTAssertEqual(OutputSanitizer.clean("Resposta: Bom dia."), "Bom dia.")
    }
    func testRemovesMarkdown() {
        XCTAssertEqual(OutputSanitizer.clean("**Parabéns!** Tudo de bom."), "Parabéns! Tudo de bom.")
        XCTAssertEqual(OutputSanitizer.clean("## Assunto\nOlá"), "Assunto\nOlá")
    }
    func testStripsWrappingQuotes() {
        XCTAssertEqual(OutputSanitizer.clean("\"Bom dia.\""), "Bom dia.")
        XCTAssertEqual(OutputSanitizer.clean("“Bom dia.”"), "Bom dia.")
        // Inner quotes mean the quotes are content, keep them.
        XCTAssertEqual(OutputSanitizer.clean("\"Oi\", disse ele, \"tudo bem\""), "\"Oi\", disse ele, \"tudo bem\"")
    }
    func testRemovesEchoedTags() {
        XCTAssertEqual(OutputSanitizer.clean("<fala>Oi.</fala>"), "Oi.")
    }
}
```

`EvalScorerTests.swift`:
```swift
import XCTest
@testable import TranscricaoCore

final class EvalScorerTests: XCTestCase {
    let c = EvalCase(id: "x", entrada: "e", modo: "ditado", esperado: nil,
                     deveConter: ["Como você está"], naoDeveConter: ["vai"], maxCaracteres: 40)

    func testPasses() {
        XCTAssertEqual(EvalScorer.failures(output: "Oi, tudo bem? Como VOCÊ está?", for: c), [])
    }
    func testReportsEachFailure() {
        let f = EvalScorer.failures(output: "**Como você vai?** " + String(repeating: "a", count: 40), for: c)
        XCTAssertEqual(f.count, 4) // missing, forbidden, too long, markdown
    }
    func testIsAccentInsensitive() {
        XCTAssertEqual(EvalScorer.failures(output: "como voce esta", for: c), [])
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd <repo> && swift test --filter "PromptBuilderTests|OutputSanitizerTests|EvalScorerTests" 2>&1 | tail -5`
Expected: erro de compilação.

- [ ] **Step 3: Implementar o PromptBuilder**

```swift
import Foundation

public struct ChatTurn: Equatable, Sendable {
    public enum Role: Equatable, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Builds the chat for the text model. The transcript goes inside <fala> tags
/// so the model treats it as material to rewrite, not as a question to answer.
public enum PromptBuilder {
    public static let systemPrompt = """
    Você é um revisor de ditado. Você recebe, entre <fala> e </fala>, a transcrição automática e crua do que uma pessoa falou em português do Brasil. Devolva o texto que ela quer que seja digitado.

    Modo DITADO (padrão):
    - Reescreva a fala como o texto final que a pessoa quis escrever.
    - Aplique as correções que ela fizer falando ("não, quis dizer…", "na verdade…", "melhor…", "apaga isso", "corrigindo…"): mantenha só a versão corrigida.
    - Remova hesitações, repetições e muletas ("é…", "hã", "tipo", "né", "então assim").
    - Corrija pontuação, acentuação e maiúsculas. Escreva números, horários e datas de forma natural.
    - Não mude o sentido, não acrescente informações, não resuma e não responda a perguntas: se a fala é uma pergunta, devolva a pergunta escrita.

    Modo COMANDO (somente quando a fala pede explicitamente para você compor, escrever, gerar, redigir, reescrever, listar ou traduzir um texto — por exemplo "crie uma mensagem…", "escreva um e-mail…", "traduza…"):
    - Produza o texto pedido, no tom, tamanho e idioma pedidos. Não invente nomes nem assinaturas.

    Na dúvida, é DITADO.
    Responda SOMENTE com o texto final, pronto para colar: sem aspas, sem markdown, sem comentários e sem explicar o que fez.
    """

    public static let examples: [(fala: String, texto: String)] = [
        ("oi tudo bem como você vai não quis dizer como você está",
         "Oi, tudo bem? Como você está?"),
        ("crie uma mensagem de parabéns pra mim seja bem curto e casual",
         "Parabéns! Tudo de bom pra você! Que Deus continue te abençoando sempre!"),
        ("então é a reunião vai ser na terça não na quarta às três da tarde",
         "Então, a reunião vai ser na quarta, às 15h."),
        ("qual é o horário do voo de amanhã",
         "Qual é o horário do voo de amanhã?"),
        ("lembrar de criar a tarefa de revisão amanhã cedo",
         "Lembrar de criar a tarefa de revisão amanhã cedo."),
        ("escreva um email curto pedindo para remarcar a reunião de sexta",
         "Olá! Tudo bem? Será que conseguimos remarcar a reunião de sexta? Me avise qual dia fica melhor para você. Obrigado!"),
    ]

    public static func wrap(_ transcript: String) -> String {
        "<fala>\(transcript)</fala>"
    }

    public static func messages(for transcript: String) -> [ChatTurn] {
        var turns = [ChatTurn(role: .system, content: systemPrompt)]
        for ex in examples {
            turns.append(ChatTurn(role: .user, content: wrap(ex.fala)))
            turns.append(ChatTurn(role: .assistant, content: ex.texto))
        }
        turns.append(ChatTurn(role: .user, content: wrap(transcript)))
        return turns
    }

    /// ~3× the input tokens (≈ chars/4), clamped to [256, 1024].
    public static func maxTokens(forInputCharacters count: Int) -> Int {
        min(1024, max(256, count * 3 / 4))
    }
}
```

- [ ] **Step 4: Implementar o OutputSanitizer**

```swift
import Foundation

/// Strips the wrapping small models like to add around the answer.
public enum OutputSanitizer {
    public static func clean(_ raw: String) -> String {
        var s = raw
        s = replace(s, #"(?s)<think>.*?</think>"#, "")
        if let open = s.range(of: "<think>") {
            // Unterminated reasoning: nothing after it is usable.
            s = String(s[..<open.lowerBound])
        }
        s = replace(s, #"</?fala>"#, "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = replace(s, #"(?i)^(texto final|texto|resposta|sa[ií]da|output)\s*:\s*"#, "")
        s = replace(s, #"\*\*|__"#, "")
        s = replace(s, #"(?m)^#{1,6}\s+"#, "")
        s = replace(s, #"(?m)^>\s?"#, "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = stripWrappingQuotes(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripWrappingQuotes(_ s: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("«", "»")]
        guard s.count >= 2, let first = s.first, let last = s.last else { return s }
        for (open, close) in pairs where first == open && last == close {
            let inner = s.dropFirst().dropLast()
            if !inner.contains(open) && !inner.contains(close) { return String(inner) }
        }
        return s
    }

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
```

- [ ] **Step 5: Implementar o EvalScorer**

```swift
import Foundation

/// One prompt-eval case (fixtures/cases.json). Field names are Portuguese to
/// keep the fixture file readable.
public struct EvalCase: Codable, Sendable {
    public var id: String
    public var entrada: String
    public var modo: String
    public var esperado: String?
    public var deveConter: [String]?
    public var naoDeveConter: [String]?
    public var maxCaracteres: Int?

    public init(id: String, entrada: String, modo: String, esperado: String?,
                deveConter: [String]?, naoDeveConter: [String]?, maxCaracteres: Int?) {
        self.id = id; self.entrada = entrada; self.modo = modo; self.esperado = esperado
        self.deveConter = deveConter; self.naoDeveConter = naoDeveConter; self.maxCaracteres = maxCaracteres
    }
}

public enum EvalScorer {
    /// Empty array = pass. Comparisons ignore case and accents.
    public static func failures(output: String, for c: EvalCase) -> [String] {
        var out: [String] = []
        let folded = fold(output)
        for needle in c.deveConter ?? [] where !folded.contains(fold(needle)) {
            out.append("faltou \"\(needle)\"")
        }
        for needle in c.naoDeveConter ?? [] where folded.contains(fold(needle)) {
            out.append("não devia conter \"\(needle)\"")
        }
        if let max = c.maxCaracteres, output.count > max {
            out.append("longo demais (\(output.count) > \(max))")
        }
        if output.contains("**") || output.contains("<fala>") || output.hasPrefix("\"") {
            out.append("formatação indevida")
        }
        return out
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
    }
}
```

- [ ] **Step 6: Rodar e ver passar**

Run: `cd <repo> && swift test --filter "PromptBuilderTests|OutputSanitizerTests|EvalScorerTests" 2>&1 | tail -3`
Expected: `Executed 13 tests, with 0 failures`

- [ ] **Step 7: Commit**

```bash
cd <repo> && git add -A Sources Tests && git commit -m "feat(core): prompt builder, output sanitizer and eval scorer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Protocolos + DictationPipeline

**Files:**
- Create: `Sources/TranscricaoCore/Pipeline/Protocols.swift`
- Create: `Sources/TranscricaoCore/Pipeline/Timeout.swift`
- Create: `Sources/TranscricaoCore/Pipeline/DictationPipeline.swift`
- Test: `Tests/TranscricaoCoreTests/DictationPipelineTests.swift`

**Interfaces:**
- Consumes: `SpeechGate`, `HallucinationFilter.clean`, `OutputSanitizer.clean` (Tasks 3–4).
- Produces:
  - `public protocol Transcriber: AnyObject, Sendable { func transcribe(_ samples: [Float]) async throws -> String }`
  - `public protocol TextProcessor: AnyObject, Sendable { func process(_ transcript: String) async throws -> String }`
  - `public protocol TextInserter: Sendable { func insert(_ text: String) async }`
  - `public protocol ResidentModel: AnyObject, Sendable { func load() async throws; func unload() async }`
  - `public struct TimeoutError: Error`; `public func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T`
  - `public struct StageTimings: Codable, Equatable, Sendable { transcribe, process, total: Double }`
  - `public struct DictationResult: Codable, Equatable, Sendable { date: Date; raw: String; final: String; aiEnabled: Bool; usedFallback: Bool; timings: StageTimings }`
  - `public enum PipelineOutcome: Equatable, Sendable { inserted(DictationResult), discarded(DiscardReason), failed(String) }`, `public enum DiscardReason { tooShortOrSilent, noSpeech }`
  - `public actor DictationPipeline { init(transcriber:processor:inserter:gate:processingTimeout:aiEnabled:prepare:); func run(_ samples: [Float]) async -> PipelineOutcome }`

- [ ] **Step 1: Testes (com dublês)**

```swift
import XCTest
@testable import TranscricaoCore

final class FakeTranscriber: Transcriber, @unchecked Sendable {
    var text: String
    var error: Error?
    var delay: Double = 0
    init(_ text: String) { self.text = text }
    func transcribe(_ samples: [Float]) async throws -> String {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let error { throw error }
        return text
    }
}

final class FakeProcessor: TextProcessor, @unchecked Sendable {
    var transform: (String) -> String = { $0.uppercased() }
    var error: Error?
    var delay: Double = 0
    func process(_ transcript: String) async throws -> String {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let error { throw error }
        return transform(transcript)
    }
}

actor RecordingInserter: TextInserter {
    private(set) var inserted: [String] = []
    func insert(_ text: String) async { inserted.append(text) }
}

struct Boom: Error {}

final class DictationPipelineTests: XCTestCase {
    let speech: [Float] = (0..<16_000).map { 0.1 * sin(Float($0) * 0.0864) }

    func make(_ t: FakeTranscriber, _ p: FakeProcessor, ai: Bool = true, timeout: Double = 6,
              prepare: @escaping @Sendable () async throws -> Void = {}) -> (DictationPipeline, RecordingInserter) {
        let ins = RecordingInserter()
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: ins,
                                     processingTimeout: timeout, aiEnabled: { ai }, prepare: prepare)
        return (pipe, ins)
    }

    func testHappyPathInsertsProcessedText() async {
        let (pipe, ins) = make(FakeTranscriber("oi"), FakeProcessor())
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertEqual(r.raw, "oi")
        XCTAssertEqual(r.final, "OI")
        XCTAssertFalse(r.usedFallback)
        let got = await ins.inserted
        XCTAssertEqual(got, ["OI"])
    }

    func testSilenceIsDiscarded() async {
        let (pipe, ins) = make(FakeTranscriber("oi"), FakeProcessor())
        let outcome = await pipe.run([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(outcome, .discarded(.tooShortOrSilent))
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    func testHallucinationIsDiscarded() async {
        let (pipe, _) = make(FakeTranscriber("Legendas pela comunidade Amara.org"), FakeProcessor())
        let outcome = await pipe.run(speech)
        XCTAssertEqual(outcome, .discarded(.noSpeech))
    }

    func testProcessorErrorFallsBackToRaw() async {
        let p = FakeProcessor(); p.error = Boom()
        let (pipe, ins) = make(FakeTranscriber("oi tudo bem"), p)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertTrue(r.usedFallback)
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi tudo bem"])
    }

    func testProcessorTimeoutFallsBackToRaw() async {
        let p = FakeProcessor(); p.delay = 2
        let (pipe, ins) = make(FakeTranscriber("oi"), p, timeout: 0.2)
        let start = Date()
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertTrue(r.usedFallback)
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi"])
    }

    func testEmptyProcessorOutputFallsBackToRaw() async {
        let p = FakeProcessor(); p.transform = { _ in "  **  " }
        let (pipe, ins) = make(FakeTranscriber("oi"), p)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertTrue(r.usedFallback)
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi"])
    }

    func testAIDisabledSkipsProcessor() async {
        let p = FakeProcessor(); p.error = Boom()
        let (pipe, ins) = make(FakeTranscriber("oi"), p, ai: false)
        guard case .inserted(let r) = await pipe.run(speech) else { return XCTFail() }
        XCTAssertFalse(r.aiEnabled)
        XCTAssertFalse(r.usedFallback)
        let got = await ins.inserted
        XCTAssertEqual(got, ["oi"])
    }

    func testTranscriberErrorFails() async {
        let t = FakeTranscriber("x"); t.error = Boom()
        let (pipe, ins) = make(t, FakeProcessor())
        guard case .failed = await pipe.run(speech) else { return XCTFail() }
        let got = await ins.inserted
        XCTAssertEqual(got, [])
    }

    func testPrepareErrorFails() async {
        let (pipe, _) = make(FakeTranscriber("x"), FakeProcessor(), prepare: { throw Boom() })
        guard case .failed = await pipe.run(speech) else { return XCTFail() }
    }

    func testRunsAreSerializedInOrder() async {
        let t = FakeTranscriber("a")
        let p = FakeProcessor()
        let ins = RecordingInserter()
        let pipe = DictationPipeline(transcriber: t, processor: p, inserter: ins,
                                     processingTimeout: 6, aiEnabled: { true })
        p.delay = 0.3
        p.transform = { $0 }
        // First run is slow; second must wait for it and paste after it.
        let first = Task { await pipe.run(self.speech) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        t.text = "b"
        p.delay = 0
        let second = Task { await pipe.run(self.speech) }
        _ = await first.value
        _ = await second.value
        let got = await ins.inserted
        XCTAssertEqual(got, ["a", "b"])
    }
}
```

> Nota: `testRunsAreSerializedInOrder` muta os dublês entre execuções; o `FakeTranscriber` lê `text` no momento da chamada — a 2ª execução só chama o transcriber depois que a 1ª terminou, então lê "b".

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd <repo> && swift test --filter DictationPipelineTests 2>&1 | tail -5`
Expected: erro de compilação.

- [ ] **Step 3: Protocolos e timeout**

`Protocols.swift`:
```swift
import Foundation

public protocol Transcriber: AnyObject, Sendable {
    /// 16 kHz mono Float32 samples → raw transcript.
    func transcribe(_ samples: [Float]) async throws -> String
}

public protocol TextProcessor: AnyObject, Sendable {
    /// Raw transcript → final text (may contain reasoning/markdown; the pipeline sanitizes).
    func process(_ transcript: String) async throws -> String
}

public protocol TextInserter: Sendable {
    func insert(_ text: String) async
}

/// A model that can be loaded into / evicted from memory.
public protocol ResidentModel: AnyObject, Sendable {
    func load() async throws
    func unload() async
}
```

`Timeout.swift`:
```swift
import Foundation

public struct TimeoutError: Error, Equatable {
    public init() {}
}

/// Single-shot latch so whichever of (work, timer) finishes first wins.
private final class OnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Returns as soon as the timer fires even if `operation` ignores cancellation
/// (a task group would wait for the child; MLX generation may not stop instantly).
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let latch = OnceLatch()
        let work = Task {
            do {
                let value = try await operation()
                if latch.claim() { cont.resume(returning: value) }
            } catch {
                if latch.claim() { cont.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if latch.claim() {
                work.cancel()
                cont.resume(throwing: TimeoutError())
            }
        }
    }
}
```

- [ ] **Step 4: DictationPipeline**

```swift
import Foundation

public struct StageTimings: Codable, Equatable, Sendable {
    public var transcribe: Double
    public var process: Double
    public var total: Double
}

public struct DictationResult: Codable, Equatable, Sendable {
    public var date: Date
    public var raw: String
    public var final: String
    public var aiEnabled: Bool
    public var usedFallback: Bool
    public var timings: StageTimings
}

public enum DiscardReason: Equatable, Sendable {
    case tooShortOrSilent
    case noSpeech
}

public enum PipelineOutcome: Equatable, Sendable {
    case inserted(DictationResult)
    case discarded(DiscardReason)
    case failed(String)
}

/// audio → gate → Whisper → hallucination filter → (LLM with timeout → sanitize) → insert.
/// Runs are serialized: a clip finishing while another is processing is pasted after it.
public actor DictationPipeline {
    private let transcriber: Transcriber
    private let processor: TextProcessor
    private let inserter: TextInserter
    private let gate: SpeechGate
    private let processingTimeout: Double
    private let aiEnabled: @Sendable () -> Bool
    private let prepare: @Sendable () async throws -> Void
    private var tail: Task<Void, Never>?

    public init(transcriber: Transcriber, processor: TextProcessor, inserter: TextInserter,
                gate: SpeechGate = SpeechGate(), processingTimeout: Double = 6,
                aiEnabled: @escaping @Sendable () -> Bool,
                prepare: @escaping @Sendable () async throws -> Void = {}) {
        self.transcriber = transcriber
        self.processor = processor
        self.inserter = inserter
        self.gate = gate
        self.processingTimeout = processingTimeout
        self.aiEnabled = aiEnabled
        self.prepare = prepare
    }

    public func run(_ samples: [Float]) async -> PipelineOutcome {
        let previous = tail
        let job = Task { () -> PipelineOutcome in
            await previous?.value
            return await self.execute(samples)
        }
        tail = Task { _ = await job.value }
        return await job.value
    }

    private func execute(_ samples: [Float]) async -> PipelineOutcome {
        guard gate.shouldTranscribe(samples) else { return .discarded(.tooShortOrSilent) }
        let start = Date()

        do { try await prepare() } catch {
            return .failed("Não foi possível carregar os modelos.")
        }

        let raw: String
        let t0 = Date()
        do { raw = try await transcriber.transcribe(samples) } catch {
            return .failed("Falha na transcrição.")
        }
        let transcribeTime = Date().timeIntervalSince(t0)

        guard let cleaned = HallucinationFilter.clean(raw) else { return .discarded(.noSpeech) }

        let useAI = aiEnabled()
        var final = cleaned
        var usedFallback = false
        let t1 = Date()
        if useAI {
            let processor = self.processor
            let timeout = processingTimeout
            let processed = try? await withTimeout(seconds: timeout) {
                try await processor.process(cleaned)
            }
            let sanitized = processed.map(OutputSanitizer.clean) ?? ""
            if sanitized.isEmpty {
                usedFallback = true
            } else {
                final = sanitized
            }
        }
        let processTime = useAI ? Date().timeIntervalSince(t1) : 0

        await inserter.insert(final)
        return .inserted(DictationResult(
            date: start, raw: cleaned, final: final, aiEnabled: useAI, usedFallback: usedFallback,
            timings: StageTimings(transcribe: transcribeTime, process: processTime,
                                  total: Date().timeIntervalSince(start))))
    }
}
```

- [ ] **Step 5: Rodar e ver passar**

Run: `cd <repo> && swift test --filter DictationPipelineTests 2>&1 | tail -3`
Expected: `Executed 10 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
cd <repo> && git add -A Sources Tests && git commit -m "feat(core): serialized dictation pipeline with raw-text fallback

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: ModelResidency (liberar memória após inatividade)

**Files:**
- Create: `Sources/TranscricaoCore/Pipeline/ModelResidency.swift`
- Test: `Tests/TranscricaoCoreTests/ModelResidencyTests.swift`

**Interfaces:**
- Consumes: `ResidentModel` (Task 5).
- Produces:
  - `public enum IdleUnloadPolicy: Int, CaseIterable, Codable, Sendable { case never = 0, five = 5, fifteen = 15, thirty = 30; var interval: TimeInterval?; var title: String }`
  - `public actor ModelResidency { init(models: [ResidentModel], timeScale: Double = 1); var isLoaded: Bool; func ensureLoaded() async throws; func noteActivity(); func setPolicy(_:); func unloadNow() async; func setOnChange(_ handler: @escaping @Sendable (Bool) -> Void) }`

- [ ] **Step 1: Testes**

```swift
import XCTest
@testable import TranscricaoCore

final class CountingModel: ResidentModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0, _unloads = 0
    var loadDelay: Double = 0
    var loads: Int { lock.withLock { _loads } }
    var unloads: Int { lock.withLock { _unloads } }
    func load() async throws {
        if loadDelay > 0 { try await Task.sleep(nanoseconds: UInt64(loadDelay * 1e9)) }
        lock.withLock { _loads += 1 }
    }
    func unload() async { lock.withLock { _unloads += 1 } }
}

final class ModelResidencyTests: XCTestCase {
    // timeScale 0.0001 → 5 min becomes 30 ms.
    func makeResidency(_ models: [ResidentModel]) -> ModelResidency {
        ModelResidency(models: models, timeScale: 0.0001)
    }

    func testEnsureLoadedLoadsOnce() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        try await r.ensureLoaded()
        try await r.ensureLoaded()
        XCTAssertEqual(m.loads, 1)
        let loaded = await r.isLoaded
        XCTAssertTrue(loaded)
    }

    func testConcurrentEnsureLoadedSharesOneLoad() async throws {
        let m = CountingModel(); m.loadDelay = 0.1
        let r = makeResidency([m])
        async let a: Void = try r.ensureLoaded()
        async let b: Void = try r.ensureLoaded()
        _ = try await (a, b)
        XCTAssertEqual(m.loads, 1)
    }

    func testNeverPolicyNeverUnloads() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        try await r.ensureLoaded()
        await r.noteActivity()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(m.unloads, 0)
    }

    func testUnloadsAfterIdleInterval() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        await r.setPolicy(.five)
        try await r.ensureLoaded()
        await r.noteActivity()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(m.unloads, 1)
        let loaded = await r.isLoaded
        XCTAssertFalse(loaded)
        // Next use reloads.
        try await r.ensureLoaded()
        XCTAssertEqual(m.loads, 2)
    }

    func testActivityPostponesUnload() async throws {
        let m = CountingModel()
        let r = ModelResidency(models: [m], timeScale: 0.001) // 5 min → 300 ms
        await r.setPolicy(.five)
        try await r.ensureLoaded()
        for _ in 0..<4 {
            await r.noteActivity()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertEqual(m.unloads, 0)
    }

    func testOnChangeReportsTransitions() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        let box = ChangeBox()
        await r.setOnChange { box.append($0) }
        try await r.ensureLoaded()
        await r.unloadNow()
        XCTAssertEqual(box.values, [true, false])
    }
}

final class ChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    var values: [Bool] { lock.withLock { _values } }
    func append(_ v: Bool) { lock.withLock { _values.append(v) } }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd <repo> && swift test --filter ModelResidencyTests 2>&1 | tail -5`
Expected: erro de compilação.

- [ ] **Step 3: Implementar**

```swift
import Foundation

public enum IdleUnloadPolicy: Int, CaseIterable, Codable, Sendable {
    case never = 0, five = 5, fifteen = 15, thirty = 30

    public var interval: TimeInterval? {
        self == .never ? nil : TimeInterval(rawValue * 60)
    }

    public var title: String {
        self == .never ? "Nunca" : "\(rawValue) min"
    }
}

/// Keeps the models in memory, optionally evicting them after a period without
/// dictation. `timeScale` shrinks the idle interval for tests.
public actor ModelResidency {
    private let models: [ResidentModel]
    private let timeScale: Double
    private var policy: IdleUnloadPolicy = .never
    private var loadTask: Task<Void, Error>?
    private var idleTask: Task<Void, Never>?
    private var onChange: (@Sendable (Bool) -> Void)?
    public private(set) var isLoaded = false

    public init(models: [ResidentModel], timeScale: Double = 1) {
        self.models = models
        self.timeScale = timeScale
    }

    public func setOnChange(_ handler: @escaping @Sendable (Bool) -> Void) {
        onChange = handler
    }

    public func setPolicy(_ newPolicy: IdleUnloadPolicy) {
        policy = newPolicy
        noteActivity()
    }

    /// Loads every model once; concurrent callers share the same load.
    public func ensureLoaded() async throws {
        if isLoaded { return }
        if let running = loadTask { return try await running.value }
        let models = self.models
        let task = Task {
            for model in models { try await model.load() }
        }
        loadTask = task
        do {
            try await task.value
            loadTask = nil
            isLoaded = true
            onChange?(true)
            noteActivity()
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// Restarts the idle countdown (call on every dictation).
    public func noteActivity() {
        idleTask?.cancel()
        idleTask = nil
        guard isLoaded, let interval = policy.interval else { return }
        let nanos = UInt64(interval * timeScale * 1_000_000_000)
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.unloadNow()
        }
    }

    public func unloadNow() async {
        idleTask?.cancel()
        idleTask = nil
        guard isLoaded else { return }
        isLoaded = false
        for model in models { await model.unload() }
        onChange?(false)
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd <repo> && swift test --filter ModelResidencyTests 2>&1 | tail -3`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
cd <repo> && git add -A Sources Tests && git commit -m "feat(core): model residency with optional idle unloading

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: HistoryStore

**Files:**
- Create: `Sources/TranscricaoCore/History/HistoryStore.swift`
- Test: `Tests/TranscricaoCoreTests/HistoryStoreTests.swift`

**Interfaces:**
- Consumes: `DictationResult` (Task 5).
- Produces: `public final class HistoryStore { init(fileURL: URL, limit: Int = 50); private(set) var entries: [DictationResult] /* newest first */; func append(_:) }`

- [ ] **Step 1: Testes**

```swift
import XCTest
@testable import TranscricaoCore

final class HistoryStoreTests: XCTestCase {
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
    }

    func entry(_ s: String) -> DictationResult {
        DictationResult(date: Date(timeIntervalSince1970: 1_000), raw: s, final: s.uppercased(),
                        aiEnabled: true, usedFallback: false,
                        timings: StageTimings(transcribe: 0.1, process: 0.2, total: 0.3))
    }

    func testAppendNewestFirstAndPersists() {
        let h = HistoryStore(fileURL: url)
        h.append(entry("a")); h.append(entry("b"))
        XCTAssertEqual(h.entries.map(\.raw), ["b", "a"])
        let reloaded = HistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.map(\.raw), ["b", "a"])
    }

    func testLimit() {
        let h = HistoryStore(fileURL: url, limit: 3)
        for s in ["a", "b", "c", "d"] { h.append(entry(s)) }
        XCTAssertEqual(h.entries.map(\.raw), ["d", "c", "b"])
    }

    func testCorruptFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(HistoryStore(fileURL: url).entries.count, 0)
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd <repo> && swift test --filter HistoryStoreTests 2>&1 | tail -5`
Expected: erro de compilação.

- [ ] **Step 3: Implementar**

```swift
import Foundation

/// Last N dictation results, newest first, persisted as JSON. Used from the main actor.
public final class HistoryStore {
    private let fileURL: URL
    private let limit: Int
    public private(set) var entries: [DictationResult] = []

    public init(fileURL: URL, limit: Int = 50) {
        self.fileURL = fileURL
        self.limit = limit
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode([DictationResult].self, from: data) {
            entries = Array(decoded.prefix(limit))
        }
    }

    public func append(_ result: DictationResult) {
        entries.insert(result, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Transcricao: failed to save history: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
```

- [ ] **Step 4: Rodar a suíte inteira**

Run: `cd <repo> && swift test 2>&1 | tail -3`
Expected: `Executed 53 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
cd <repo> && git add -A Sources Tests && git commit -m "feat(core): persistent dictation history

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Motor de texto MLX + `tcli eval` + casos de teste

**Files:**
- Modify: `Package.swift` (dependências + alvos `TranscricaoEngines` e `tcli`)
- Create: `Sources/TranscricaoEngines/ModelLocations.swift`
- Create: `Sources/TranscricaoEngines/MLXTextProcessor.swift`
- Create: `Sources/tcli/main.swift`
- Create: `fixtures/cases.json`

**Interfaces:**
- Consumes: `TextProcessor`, `ResidentModel`, `PromptBuilder`, `OutputSanitizer`, `EvalCase`, `EvalScorer`.
- Produces:
  - `public enum ModelLocations { static var root: URL; static var whisper: URL; static var hub: URL; static var history: URL }`
  - `public enum TextModelChoice: String, CaseIterable, Sendable { case qwen3_4b = "mlx-community/Qwen3-4B-Instruct-2507-4bit"; case gemma4_e4b = "mlx-community/gemma-4-e4b-it-4bit"; var title: String }`
  - `public final class MLXTextProcessor: TextProcessor, ResidentModel { init(modelID: String); var modelID: String { get }; func setModelID(_:); var onProgress: (@Sendable (Double) -> Void)?; var isLoaded: Bool }`
  - Executável `tcli` com subcomandos `process`, `eval`, `transcribe` (este na Task 9).

- [ ] **Step 1: Confirmar o Metal Toolchain**

Run: `xcodebuild -showComponent MetalToolchain | grep Status`
Expected: `Status: installed`. Não prossiga sem isso.

- [ ] **Step 2: `Package.swift` completo**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Transcricao",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
    ],
    targets: [
        .target(name: "TranscricaoCore"),
        .target(
            name: "TranscricaoEngines",
            dependencies: [
                "TranscricaoCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]),
        .executableTarget(name: "tcli", dependencies: ["TranscricaoCore", "TranscricaoEngines"]),
        .testTarget(name: "TranscricaoCoreTests", dependencies: ["TranscricaoCore"]),
    ]
)
```

> Se o `swift package resolve` reclamar de incompatibilidade entre `swift-huggingface` 1.x e os macros do `MLXHuggingFace`, troque para `from: "0.9.0"` e ajuste `HubClient(cache:)` conforme a API dessa versão.

- [ ] **Step 3: `ModelLocations.swift`**

```swift
import Foundation

public enum ModelLocations {
    /// ~/Library/Application Support/Transcricao
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Transcricao", isDirectory: true)
    }
    public static var root: URL { ensure(appSupport.appendingPathComponent("Models", isDirectory: true)) }
    public static var whisper: URL { ensure(root.appendingPathComponent("whisperkit", isDirectory: true)) }
    public static var hub: URL { ensure(root.appendingPathComponent("hub", isDirectory: true)) }
    public static var history: URL { ensure(appSupport).appendingPathComponent("history.json") }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public enum TextModelChoice: String, CaseIterable, Sendable {
    case qwen3_4b = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    case gemma4_e4b = "mlx-community/gemma-4-e4b-it-4bit"

    public var title: String {
        switch self {
        case .qwen3_4b: return "Qwen3 4B (rápido)"
        case .gemma4_e4b: return "Gemma 4 E4B"
        }
    }
}
```

- [ ] **Step 4: `MLXTextProcessor.swift`**

```swift
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import TranscricaoCore

public enum TextEngineError: Error { case notLoaded }

/// In-process LLM via MLX. Each request uses a fresh ChatSession (no memory
/// between dictations): system prompt + few-shot history + the transcript.
public final class MLXTextProcessor: TextProcessor, ResidentModel, @unchecked Sendable {
    private let lock = NSLock()
    private var container: ModelContainer?
    private var _modelID: String
    public var onProgress: (@Sendable (Double) -> Void)?

    public init(modelID: String) {
        _modelID = modelID
    }

    public var modelID: String { lock.withLock { _modelID } }
    public var isLoaded: Bool { lock.withLock { container != nil } }

    /// Takes effect on the next load(); callers unload first.
    public func setModelID(_ id: String) { lock.withLock { _modelID = id } }

    public func load() async throws {
        if isLoaded { return }
        let hub = HubClient(cache: HubCache(cacheDirectory: ModelLocations.hub))
        let progress = onProgress
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hub),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: modelID),
            progressHandler: { p in progress?(p.fractionCompleted) })
        lock.withLock { container = loaded }
        _ = try await process("teste") // warm up kernels
    }

    public func unload() async {
        lock.withLock { container = nil }
        MLX.Memory.clearCache()
    }

    public func process(_ transcript: String) async throws -> String {
        guard let container = lock.withLock({ container }) else { throw TextEngineError.notLoaded }
        let turns = PromptBuilder.messages(for: transcript)
        let system = turns.first?.content
        let history: [Chat.Message] = turns.dropFirst().dropLast().map { turn in
            turn.role == .assistant ? .assistant(turn.content) : .user(turn.content)
        }
        let params = GenerateParameters(
            maxTokens: PromptBuilder.maxTokens(forInputCharacters: transcript.count),
            temperature: 0)
        let session = ChatSession(container, instructions: system, history: history,
                                  generateParameters: params)
        return try await session.respond(to: turns.last?.content ?? "")
    }
}
```

> Se `MLX.Memory.clearCache()` não existir na versão resolvida, use `MLX.GPU.clearCache()` (ambos existem no mlx-swift atual).

- [ ] **Step 5: `fixtures/cases.json`** (20 casos; os 2 primeiros são os exemplos do usuário)

```json
[
  {"id": "usuario-correcao", "entrada": "oi tudo bem como você vai não quis dizer como você está", "modo": "ditado", "esperado": "Oi, tudo bem? Como você está?", "deveConter": ["como você está"], "naoDeveConter": ["vai", "quis dizer"], "maxCaracteres": 40},
  {"id": "usuario-comando", "entrada": "crie uma mensagem de parabéns pra mim seja bem curto e casual", "modo": "comando", "esperado": "Parabéns! Tudo de bom pra você!", "deveConter": ["parabéns"], "naoDeveConter": ["crie", "mensagem"], "maxCaracteres": 160},
  {"id": "correcao-na-verdade", "entrada": "vou chegar às oito na verdade às nove da noite", "modo": "ditado", "esperado": "Vou chegar às nove da noite.", "naoDeveConter": ["oito", "na verdade"], "maxCaracteres": 50},
  {"id": "apaga-isso", "entrada": "manda o relatório para o pedro apaga isso manda o relatório para a ana", "modo": "ditado", "esperado": "Manda o relatório para a Ana.", "deveConter": ["ana"], "naoDeveConter": ["pedro", "apaga"], "maxCaracteres": 50},
  {"id": "hesitacoes", "entrada": "é tipo eu acho que né a gente pode é fazer a reunião amanhã", "modo": "ditado", "esperado": "Eu acho que a gente pode fazer a reunião amanhã.", "deveConter": ["reunião amanhã"], "naoDeveConter": ["tipo", " né"], "maxCaracteres": 70},
  {"id": "pergunta-ditado", "entrada": "qual é a capital da austrália", "modo": "ditado", "esperado": "Qual é a capital da Austrália?", "deveConter": ["capital da austrália", "?"], "naoDeveConter": ["canberra"], "maxCaracteres": 40},
  {"id": "pergunta-pedido", "entrada": "você pode me mandar o endereço da festa", "modo": "ditado", "esperado": "Você pode me mandar o endereço da festa?", "deveConter": ["endereço da festa"], "maxCaracteres": 60},
  {"id": "falso-comando-1", "entrada": "preciso criar uma mensagem para o cliente amanhã cedo", "modo": "ditado", "esperado": "Preciso criar uma mensagem para o cliente amanhã cedo.", "deveConter": ["preciso criar uma mensagem"], "maxCaracteres": 80},
  {"id": "falso-comando-2", "entrada": "lembrar de escrever o relatório até sexta", "modo": "ditado", "esperado": "Lembrar de escrever o relatório até sexta.", "deveConter": ["escrever o relatório"], "maxCaracteres": 70},
  {"id": "comando-email", "entrada": "escreva um e-mail curto e formal pedindo para remarcar a reunião de segunda para quarta", "modo": "comando", "deveConter": ["quarta"], "naoDeveConter": ["escreva"], "maxCaracteres": 600},
  {"id": "comando-traduzir", "entrada": "traduza para o inglês bom dia como posso ajudar", "modo": "comando", "esperado": "Good morning, how can I help?", "deveConter": ["good morning"], "naoDeveConter": ["traduza", "bom dia"], "maxCaracteres": 60},
  {"id": "comando-reescrever", "entrada": "reescreva de forma mais educada me manda logo esse arquivo", "modo": "comando", "deveConter": ["arquivo"], "naoDeveConter": ["reescreva", "logo"], "maxCaracteres": 200},
  {"id": "comando-lista", "entrada": "faça uma lista de compras com arroz feijão e café", "modo": "comando", "deveConter": ["arroz", "feijão", "café"], "naoDeveConter": ["faça"], "maxCaracteres": 200},
  {"id": "numeros", "entrada": "o valor é mil duzentos e cinquenta reais", "modo": "ditado", "esperado": "O valor é R$ 1.250.", "deveConter": ["1.250"], "maxCaracteres": 40},
  {"id": "data-hora", "entrada": "a consulta é dia quinze de março às duas e meia da tarde", "modo": "ditado", "esperado": "A consulta é dia 15 de março, às 14h30.", "deveConter": ["15", "março"], "maxCaracteres": 60},
  {"id": "curta-ok", "entrada": "ok", "modo": "ditado", "esperado": "Ok.", "deveConter": ["ok"], "maxCaracteres": 10},
  {"id": "curta-obrigado", "entrada": "obrigado", "modo": "ditado", "esperado": "Obrigado.", "deveConter": ["obrigad"], "maxCaracteres": 15},
  {"id": "correcao-no-meio", "entrada": "bom dia pessoal hoje a gente vai falar sobre o orçamento do segundo trimestre não do terceiro trimestre e depois sobre as contratações", "modo": "ditado", "esperado": "Bom dia, pessoal! Hoje a gente vai falar sobre o orçamento do terceiro trimestre e depois sobre as contratações.", "deveConter": ["terceiro trimestre", "contratações"], "naoDeveConter": ["segundo trimestre"], "maxCaracteres": 140},
  {"id": "termos-ingles", "entrada": "vou mandar o deploy pro staging depois do code review", "modo": "ditado", "esperado": "Vou mandar o deploy pro staging depois do code review.", "deveConter": ["deploy", "staging", "code review"], "maxCaracteres": 70},
  {"id": "repeticao", "entrada": "eu acho que a gente devia é é cancelar o pedido", "modo": "ditado", "esperado": "Eu acho que a gente devia cancelar o pedido.", "deveConter": ["cancelar o pedido"], "naoDeveConter": ["é é"], "maxCaracteres": 60}
]
```

- [ ] **Step 6: `Sources/tcli/main.swift`** (subcomandos `process` e `eval`; `transcribe` entra na Task 9)

```swift
import Foundation
import TranscricaoCore
import TranscricaoEngines

/// Developer CLI:
///   tcli process "<texto>" [--model <id>]
///   tcli eval <cases.json> [--model <id>]
///   tcli transcribe <arquivo.wav>
let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func makeProcessor() async throws -> MLXTextProcessor {
    let id = option("--model") ?? TextModelChoice.qwen3_4b.rawValue
    let p = MLXTextProcessor(modelID: id)
    let t0 = Date()
    try await p.load()
    print("modelo \(id) carregado em \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    return p
}

func timed<T>(_ op: () async throws -> T) async rethrows -> (T, Double) {
    let t0 = Date()
    let v = try await op()
    return (v, Date().timeIntervalSince(t0))
}

switch args.first {
case "process":
    guard args.count >= 2 else { fail("uso: tcli process \"<texto>\" [--model <id>]") }
    let p = try await makeProcessor()
    let (raw, secs) = try await timed { try await p.process(args[1]) }
    print(OutputSanitizer.clean(raw))
    print(String(format: "(%.2f s)", secs))

case "eval":
    guard args.count >= 2 else { fail("uso: tcli eval <cases.json> [--model <id>]") }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let cases = try JSONDecoder().decode([EvalCase].self, from: data)
    let p = try await makeProcessor()
    var passed = 0
    var latencies: [Double] = []
    for c in cases {
        let (raw, secs) = try await timed { try await p.process(c.entrada) }
        let out = OutputSanitizer.clean(raw)
        let failures = EvalScorer.failures(output: out, for: c)
        latencies.append(secs)
        if failures.isEmpty { passed += 1 }
        print("\(failures.isEmpty ? "✅" : "❌") [\(c.id)] \(String(format: "%.2f s", secs))")
        print("   fala:   \(c.entrada)")
        print("   saída:  \(out)")
        if let e = c.esperado { print("   ideal:  \(e)") }
        if !failures.isEmpty { print("   falhas: \(failures.joined(separator: "; "))") }
    }
    let sorted = latencies.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    print(String(format: "\nRESULTADO: %d/%d aprovados · mediana %.2f s · máx %.2f s",
                 passed, cases.count, median, sorted.last ?? 0))

default:
    fail("subcomandos: process | eval | transcribe")
}
```

- [ ] **Step 7: Buildar**

Run: `cd <repo> && swift build -c release --product tcli 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | tail -15`
Expected: `Build complete!` (a primeira compilação do MLX/WhisperKit leva vários minutos; a partir daqui `swift test` também compila o pacote inteiro e fica mais lento — é esperado). Erros de API do MLX/HuggingFace: ajuste conforme as assinaturas reais (`grep` nas checkouts em `.build/checkouts/`), sem mudar as interfaces públicas desta task.

- [ ] **Step 8: Localizar o metallib do MLX** (necessário para o empacotamento na Task 10)

Run: `cd <repo> && find "$(swift build -c release --show-bin-path)" -maxdepth 2 \( -name "*.metallib" -o -name "*.bundle" \) | head`
Expected: um `mlx-swift_Cmlx.bundle` (contendo `default.metallib`) e/ou um `.metallib`. Anote os caminhos em `docs/BUILD.md` (criado na Task 10).

- [ ] **Step 9: Teste rápido**

Run: `cd <repo> && swift run -c release tcli process "oi tudo bem como você vai não quis dizer como você está"`
Expected: primeira execução baixa ~2,3 GB; depois imprime algo como `Oi, tudo bem? Como você está?` e a latência. Se der erro `Failed to load the default metallib`, copie o metallib encontrado no Step 8 para `"$(swift build -c release --show-bin-path)/mlx.metallib"` e repita (registre o passo em `docs/BUILD.md`).

- [ ] **Step 10: Rodar o eval com o Qwen**

Run: `cd <repo> && swift run -c release tcli eval fixtures/cases.json | tee /tmp/eval-qwen.txt | tail -1`
Expected: linha `RESULTADO: N/20 …`. Meta: ≥ 17/20 e mediana < 1 s para casos de ditado. Se < 17, ajuste o `systemPrompt`/`examples` (Task 4) — nunca os casos — e repita; rode `swift test` depois de mexer no prompt.

**Portão de latência:** cada pedido refaz o prefill de system + 6 exemplos (~800–1000 tokens). Se a mediana dos casos de ditado passar de ~1 s, a correção é **cache de prompt**, não um modelo menor: em `load()`, faça o prefill de system + exemplos uma vez, guarde um `PromptCacheSnapshot` e, em `process()`, crie a sessão a partir dele (`ChatSession(container, instructions:, promptCache:, generateParameters:)`, conferindo a API em `.build/checkouts/mlx-swift-lm/Libraries/MLXLMCommon/ChatSession.swift`). Meça de novo e registre antes/depois em `docs/model-eval.md` (Task 10).

- [ ] **Step 11: Commit**

```bash
cd <repo> && git add -A Package.swift Package.resolved Sources fixtures && git commit -m "feat(engines): MLX text processor, tcli eval and PT-BR eval cases

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Motor Whisper + `tcli transcribe`

**Files:**
- Create: `Sources/TranscricaoEngines/WhisperKitTranscriber.swift`
- Create: `Sources/TranscricaoEngines/AudioFileLoader.swift`
- Modify: `Sources/tcli/main.swift` (caso `transcribe`)

**Interfaces:**
- Consumes: `Transcriber`, `ResidentModel`, `ModelLocations.whisper`.
- Produces:
  - `public final class WhisperKitTranscriber: Transcriber, ResidentModel { static let variant: String; init(); var isLoaded: Bool }`
  - `public enum AudioFileLoader { static func load16kMono(_ url: URL) throws -> [Float] }`

- [ ] **Step 1: `AudioFileLoader.swift`**

```swift
import AVFoundation
import Foundation

public enum AudioFileLoader {
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Reads any audio file and converts it to 16 kHz mono Float32.
    public static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        return try convert(input)
    }

    public static func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        guard let converter = AVAudioConverter(from: input.format, to: targetFormat) else { return [] }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let ptr = output.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(output.frameLength)))
    }
}
```

- [ ] **Step 2: `WhisperKitTranscriber.swift`**

```swift
import Foundation
import TranscricaoCore
import WhisperKit

public enum WhisperError: Error { case notLoaded }

public final class WhisperKitTranscriber: Transcriber, ResidentModel, @unchecked Sendable {
    public static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private let lock = NSLock()
    private var kit: WhisperKit?

    public init() {}

    public var isLoaded: Bool { lock.withLock { kit != nil } }

    static var options: DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: "pt",
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad)   // > 30 s clips (continuous mode)
    }

    public func load() async throws {
        if isLoaded { return }
        let config = WhisperKitConfig(
            model: Self.variant,
            downloadBase: ModelLocations.whisper,
            verbose: false,
            prewarm: true,
            load: true,
            download: true)
        let loaded = try await WhisperKit(config)
        _ = try await loaded.transcribe(audioArray: [Float](repeating: 0, count: 16_000),
                                        decodeOptions: Self.options) // warm up
        lock.withLock { kit = loaded }
    }

    public func unload() async {
        let current = lock.withLock { () -> WhisperKit? in
            defer { kit = nil }
            return kit
        }
        await current?.unloadModels()
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let kit = lock.withLock({ kit }) else { throw WhisperError.notLoaded }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: Self.options)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

> Os rótulos de `DecodingOptions` devem seguir a ordem da declaração; se o compilador reclamar, confira a ordem em `.build/checkouts/WhisperKit/Sources/WhisperKit/Core/Configurations.swift`.

- [ ] **Step 3: Caso `transcribe` no `tcli`** — inserir antes de `default:` em `Sources/tcli/main.swift`

```swift
case "transcribe":
    guard args.count >= 2 else { fail("uso: tcli transcribe <arquivo>") }
    let samples = try AudioFileLoader.load16kMono(URL(fileURLWithPath: args[1]))
    let w = WhisperKitTranscriber()
    let (_, loadSecs) = try await timed { try await w.load() }
    print(String(format: "whisper carregado em %.1f s", loadSecs))
    let (text, secs) = try await timed { try await w.transcribe(samples) }
    let audioSecs = Double(samples.count) / 16_000
    print(text)
    print(String(format: "(%.2f s para %.1f s de áudio)", secs, audioSecs))
```

- [ ] **Step 4: Áudio de teste e execução**

```bash
cd <repo> && mkdir -p fixtures/audio && say -v Luciana "Oi, tudo bem? Como você vai? Não, quis dizer, como você está?" -o /tmp/t.aiff && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/t.aiff fixtures/audio/correcao.wav && swift run -c release tcli transcribe fixtures/audio/correcao.wav
```
Expected: na primeira vez, baixa ~632 MB e compila o CoreML (pode levar minutos). Depois imprime algo próximo de `Oi, tudo bem? Como você vai? Não, quis dizer, como você está?` e `(<1 s para ~5 s de áudio)`. Rode o comando `transcribe` de novo para medir a latência aquecida (carga deve ser segundos).

- [ ] **Step 5: Commit**

```bash
cd <repo> && git add -A Sources fixtures/audio && git commit -m "feat(engines): WhisperKit transcriber and tcli transcribe

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Escolha do modelo de texto (Qwen × Gemma)

**Files:**
- Create: `docs/model-eval.md`
- Modify (só se o Gemma vencer): `Sources/TranscricaoEngines/ModelLocations.swift` — a ordem/padrão de `TextModelChoice` e o default em `Settings` (Task 11)

- [ ] **Step 1: Rodar o eval com o Gemma**

Run: `cd <repo> && swift run -c release tcli eval fixtures/cases.json --model mlx-community/gemma-4-e4b-it-4bit | tee /tmp/eval-gemma.txt | tail -1`
Expected: `RESULTADO: …`. Se o modelo não carregar (arquitetura/quantização não suportada), tente `mlx-community/gemma-4-e4b-it-qat-OptiQ-4bit`; se nenhum carregar, registre isso e mantenha o Qwen.

- [ ] **Step 2: Repetir o Qwen com o prompt final** (caso o prompt tenha mudado depois da Task 8)

Run: `cd <repo> && swift run -c release tcli eval fixtures/cases.json | tee /tmp/eval-qwen.txt | tail -1`

- [ ] **Step 3: Decidir e registrar**

Regra da spec: maior número de aprovados; diferença ≤ 1 caso → menor latência mediana. Escreva `docs/model-eval.md`:

```markdown
# Escolha do modelo de texto — 2026-10-13

| Modelo | Aprovados | Mediana | Máx |
|---|---|---|---|
| Qwen3-4B-Instruct-2507-4bit | <de /tmp/eval-qwen.txt> | … | … |
| gemma-4-e4b-it-4bit | <de /tmp/eval-gemma.txt> | … | … |

**Padrão escolhido:** <modelo>, porque <regra aplicada>.
Falhas notáveis: <ids e por quê>.
```

- [ ] **Step 4: Commit**

```bash
cd <repo> && git add -A docs Sources && git commit -m "docs: text model evaluation and default choice

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Casca do app — bundle, assinatura, barra de menus, permissões, ajustes

**Files:**
- Modify: `Package.swift` (alvo executável `Transcricao`)
- Create: `Resources/Info.plist`
- Create: `scripts/build-app.sh`
- Create: `docs/BUILD.md`
- Create: `Sources/Transcricao/TranscricaoApp.swift`
- Create: `Sources/Transcricao/AppDelegate.swift`
- Create: `Sources/Transcricao/AppState.swift`
- Create: `Sources/Transcricao/Settings.swift`
- Create: `Sources/Transcricao/Permissions.swift`
- Create: `Sources/Transcricao/StatusItemController.swift`

**Interfaces:**
- Consumes: `TextModelChoice`, `IdleUnloadPolicy`, `HistoryStore`, `DictationResult`.
- Produces:
  - `@MainActor final class AppState: ObservableObject { enum Status { preparing(String), ready, recording(continuous: Bool), processing, error(String) }; @Published status; @Published micGranted; @Published accessibilityGranted; @Published history: [DictationResult] }`
  - `final class Settings { static let shared; var aiEnabled: Bool; var soundsEnabled: Bool; var textModel: TextModelChoice; var idleUnload: IdleUnloadPolicy }`
  - `enum Permissions { static var accessibilityGranted: Bool; static func promptAccessibility(); static var microphoneGranted: Bool; static func requestMicrophone() async -> Bool; static func openAccessibilitySettings(); static func openMicrophoneSettings() }`
  - `@MainActor protocol StatusMenuActions: AnyObject { toggleAI(); setTextModel(_:); setIdleUnload(_:); toggleSounds(); toggleLaunchAtLogin(); copyHistory(_ entry: DictationResult, raw: Bool); retryPreparation(); requestPermissions() }`
  - `@MainActor final class StatusItemController { init(state: AppState, settings: Settings, actions: StatusMenuActions) }`

- [ ] **Step 1: Alvo do app no `Package.swift`** — adicionar em `targets`:

```swift
        .executableTarget(
            name: "Transcricao",
            dependencies: ["TranscricaoCore", "TranscricaoEngines"]),
```

- [ ] **Step 2: `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Transcricao</string>
    <key>CFBundleIdentifier</key><string><bundle id de então></string>
    <key>CFBundleName</key><string>Transcrição</string>
    <key>CFBundleDisplayName</key><string>Transcrição</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>O Transcrição usa o microfone para transformar sua fala em texto, localmente no seu Mac.</string>
</dict>
</plist>
```

- [ ] **Step 3: `scripts/build-app.sh`**

```bash
#!/usr/bin/env bash
# Build release, assemble build/Transcricao.app and sign it with a stable
# identity so macOS keeps the Microphone/Accessibility grants across builds.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Transcricao.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c release --product Transcricao
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Transcricao" "$APP/Contents/MacOS/Transcricao"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# SwiftPM resource bundles (MLX ships its Metal kernels in mlx-swift_Cmlx.bundle).
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# MLX also looks for mlx.metallib next to the executable.
METALLIB="$(find "$BIN" -maxdepth 3 -name '*.metallib' | head -1)"
if [ -n "$METALLIB" ]; then
    cp "$METALLIB" "$APP/Contents/MacOS/mlx.metallib"
else
    echo "warning: no .metallib found under $BIN (is the Metal Toolchain installed?)" >&2
fi

codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --verbose=1 "$APP"
echo "OK: $APP"
```

Run: `chmod +x <repo>/scripts/build-app.sh`

- [ ] **Step 4: `Settings.swift`**

```swift
import Foundation
import TranscricaoCore
import TranscricaoEngines

/// UserDefaults-backed preferences. Thread-safe reads (UserDefaults is).
final class Settings: @unchecked Sendable {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let aiEnabled = "aiEnabled"
        static let soundsEnabled = "soundsEnabled"
        static let textModel = "textModel"
        static let idleUnload = "idleUnloadMinutes"
    }

    private init() {
        defaults.register(defaults: [
            Key.aiEnabled: true,
            Key.soundsEnabled: true,
            Key.textModel: TextModelChoice.qwen3_4b.rawValue, // default decided in docs/model-eval.md
            Key.idleUnload: IdleUnloadPolicy.never.rawValue,
        ])
    }

    var aiEnabled: Bool {
        get { defaults.bool(forKey: Key.aiEnabled) }
        set { defaults.set(newValue, forKey: Key.aiEnabled) }
    }

    var soundsEnabled: Bool {
        get { defaults.bool(forKey: Key.soundsEnabled) }
        set { defaults.set(newValue, forKey: Key.soundsEnabled) }
    }

    var textModel: TextModelChoice {
        get { TextModelChoice(rawValue: defaults.string(forKey: Key.textModel) ?? "") ?? .qwen3_4b }
        set { defaults.set(newValue.rawValue, forKey: Key.textModel) }
    }

    var idleUnload: IdleUnloadPolicy {
        get { IdleUnloadPolicy(rawValue: defaults.integer(forKey: Key.idleUnload)) ?? .never }
        set { defaults.set(newValue.rawValue, forKey: Key.idleUnload) }
    }
}
```

> Se a Task 10 escolheu o Gemma, troque os dois `.qwen3_4b` acima por `.gemma4_e4b`.

- [ ] **Step 5: `AppState.swift` e `Permissions.swift`**

```swift
import Foundation
import TranscricaoCore

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case preparing(String)
        case ready
        case recording(continuous: Bool)
        case processing
        case error(String)
    }

    @Published var status: Status = .preparing("Preparando modelos…")
    @Published var micGranted = false
    @Published var accessibilityGranted = false
    @Published var history: [DictationResult] = []
}
```

```swift
import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        if microphoneGranted { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
```

- [ ] **Step 6: `StatusItemController.swift`**

```swift
import AppKit
import Combine
import ServiceManagement
import TranscricaoCore
import TranscricaoEngines

@MainActor
protocol StatusMenuActions: AnyObject {
    func toggleAI()
    func setTextModel(_ choice: TextModelChoice)
    func setIdleUnload(_ policy: IdleUnloadPolicy)
    func toggleSounds()
    func toggleLaunchAtLogin()
    func copyHistory(_ entry: DictationResult, raw: Bool)
    func retryPreparation()
    func requestPermissions()
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let state: AppState
    private let settings: Settings
    private weak var actions: StatusMenuActions?
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState, settings: Settings, actions: StatusMenuActions) {
        self.state = state
        self.settings = settings
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        state.$status.receive(on: RunLoop.main).sink { [weak self] in self?.updateIcon($0) }
            .store(in: &cancellables)
    }

    private func updateIcon(_ status: AppState.Status) {
        let (symbol, tint): (String, NSColor?) = {
            switch status {
            case .preparing: return ("hourglass", nil)
            case .ready: return ("waveform", nil)
            case .recording: return ("record.circle.fill", .systemRed)
            case .processing: return ("ellipsis.circle", nil)
            case .error: return ("exclamationmark.triangle", .systemOrange)
            }
        }()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Transcrição")
        image?.isTemplate = true            // contentTintColor only tints template images
        item.button?.image = image
        item.button?.contentTintColor = tint // nil restores the default menu bar color
    }

    // Rebuilt every time so it always reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusLine()))

        if !state.micGranted || !state.accessibilityGranted {
            menu.addItem(.separator())
            if !state.micGranted {
                menu.addItem(action("⚠︎ Permitir acesso ao Microfone…") { Permissions.openMicrophoneSettings() })
            }
            if !state.accessibilityGranted {
                menu.addItem(action("⚠︎ Permitir Acessibilidade…") { [weak self] in
                    self?.actions?.requestPermissions()
                    Permissions.openAccessibilitySettings()
                })
            }
        }
        if case .error = state.status {
            menu.addItem(action("Tentar de novo") { [weak self] in self?.actions?.retryPreparation() })
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Organizar com IA", settings.aiEnabled) { [weak self] in self?.actions?.toggleAI() })

        let models = NSMenu()
        for choice in TextModelChoice.allCases {
            models.addItem(toggle(choice.title, settings.textModel == choice) { [weak self] in
                self?.actions?.setTextModel(choice)
            })
        }
        menu.addItem(submenu("Modelo de texto", models))

        let idle = NSMenu()
        for policy in IdleUnloadPolicy.allCases {
            idle.addItem(toggle(policy.title, settings.idleUnload == policy) { [weak self] in
                self?.actions?.setIdleUnload(policy)
            })
        }
        menu.addItem(submenu("Liberar memória após inatividade", idle))

        menu.addItem(toggle("Sons", settings.soundsEnabled) { [weak self] in self?.actions?.toggleSounds() })
        menu.addItem(toggle("Abrir ao iniciar sessão", SMAppService.mainApp.status == .enabled) { [weak self] in
            self?.actions?.toggleLaunchAtLogin()
        })

        menu.addItem(.separator())
        let history = NSMenu()
        if state.history.isEmpty {
            history.addItem(disabled("Vazio"))
        }
        for entry in state.history.prefix(10) {
            let title = String(entry.final.replacingOccurrences(of: "\n", with: " ").prefix(60))
            history.addItem(action(title) { [weak self] in self?.actions?.copyHistory(entry, raw: false) })
            let raw = action("Bruto: " + String(entry.raw.prefix(55))) { [weak self] in
                self?.actions?.copyHistory(entry, raw: true)
            }
            raw.isAlternate = true
            raw.keyEquivalentModifierMask = .option
            history.addItem(raw)
        }
        menu.addItem(submenu("Histórico (clique copia, ⌥ = bruto)", history))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func statusLine() -> String {
        switch state.status {
        case .preparing(let msg): return msg
        case .ready: return "Pronto — segure ⌥ direito para ditar"
        case .recording(let continuous): return continuous ? "Gravando (contínuo) — toque ⌥ para terminar" : "Gravando…"
        case .processing: return "Processando…"
        case .error(let msg): return "Erro: \(msg)"
        }
    }

    // MARK: - Menu item helpers (closure-based targets)

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ handler: @escaping () -> Void) -> NSMenuItem {
        let i = action(title, handler)
        i.state = on ? .on : .off
        return i
    }

    private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: "")
        let target = ClosureTarget(handler)
        i.target = target
        i.representedObject = target // keep the target alive with the item
        return i
    }
}

final class ClosureTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
```

- [ ] **Step 7: `TranscricaoApp.swift` e `AppDelegate.swift`** (o `AppEnvironment` completo vem na Task 12; aqui um ambiente mínimo que só carrega os modelos)

`TranscricaoApp.swift`:
```swift
import AppKit

@main
enum TranscricaoMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
```

`AppDelegate.swift`:
```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment()
        environment = env
        env.start()
    }
}
```

`Sources/Transcricao/AppEnvironment.swift` (versão desta task — será substituída na Task 12):
```swift
import AppKit
import ServiceManagement
import TranscricaoCore
import TranscricaoEngines

@MainActor
final class AppEnvironment: StatusMenuActions {
    let state = AppState()
    let settings = Settings.shared
    let transcriber = WhisperKitTranscriber()
    let processor: MLXTextProcessor
    let residency: ModelResidency
    let history = HistoryStore(fileURL: ModelLocations.history)
    private var statusItem: StatusItemController?

    init() {
        processor = MLXTextProcessor(modelID: Settings.shared.textModel.rawValue)
        residency = ModelResidency(models: [transcriber, processor])
    }

    func start() {
        statusItem = StatusItemController(state: state, settings: settings, actions: self)
        state.history = history.entries
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        state.micGranted = await Permissions.requestMicrophone()
        state.accessibilityGranted = Permissions.accessibilityGranted
        if !state.accessibilityGranted { Permissions.promptAccessibility() }
        await residency.setPolicy(settings.idleUnload)
        await prepareModels()
    }

    func prepareModels() async {
        state.status = .preparing("Preparando modelos… (a primeira vez baixa ~3 GB)")
        processor.onProgress = { [weak self] fraction in
            Task { @MainActor in
                self?.state.status = .preparing("Baixando modelo de texto… \(Int(fraction * 100))%")
            }
        }
        do {
            try await residency.ensureLoaded()
            state.status = .ready
        } catch {
            state.status = .error("não foi possível preparar os modelos (\(error.localizedDescription))")
        }
    }

    // MARK: StatusMenuActions
    func toggleAI() { settings.aiEnabled.toggle() }
    func toggleSounds() { settings.soundsEnabled.toggle() }
    func setIdleUnload(_ policy: IdleUnloadPolicy) {
        settings.idleUnload = policy
        Task { await residency.setPolicy(policy) }
    }
    func setTextModel(_ choice: TextModelChoice) {
        guard choice != settings.textModel else { return }
        settings.textModel = choice
        Task {
            await residency.unloadNow()
            processor.setModelID(choice.rawValue)
            await prepareModels()
        }
    }
    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Transcricao: launch at login failed: \(error)")
        }
    }
    func copyHistory(_ entry: DictationResult, raw: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw ? entry.raw : entry.final, forType: .string)
    }
    func retryPreparation() { Task { await prepareModels() } }
    func requestPermissions() {
        Permissions.promptAccessibility()
        state.accessibilityGranted = Permissions.accessibilityGranted
    }
}
```

- [ ] **Step 8: Buildar, empacotar e abrir**

Run: `cd <repo> && bash scripts/build-app.sh 2>&1 | tail -3 && open build/Transcricao.app`
Expected: `OK: build/Transcricao.app`; ícone de ampulheta na barra de menus; pedido de Microfone; menu mostra "Preparando modelos…" e depois "Pronto — segure ⌥ direito para ditar". Os modelos baixados nas Tasks 8–9 são reaproveitados (mesmo `ModelLocations`), então não há novo download. Se o menu mostrar erro de metallib, ajuste a cópia no `build-app.sh` conforme o Step 8 da Task 8.

- [ ] **Step 9: `docs/BUILD.md`**

```markdown
# Build

Pré-requisitos: Xcode 27 + Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

    bash scripts/build-app.sh          # build release + bundle + assinatura
    ditto build/Transcricao.app /Applications/Transcricao.app
    open /Applications/Transcricao.app

- Testes: `swift test` (só o Core; não precisa de modelos).
- Eval do prompt: `swift run -c release tcli eval fixtures/cases.json [--model <id>]`.
- Whisper: `swift run -c release tcli transcribe fixtures/audio/correcao.wav`.
- Modelos ficam em `~/Library/Application Support/Transcricao/Models/`.
- MLX: o metallib fica em <caminho anotado na Task 8, Step 8>; o `build-app.sh` copia o bundle para
  `Contents/Resources` e o `.metallib` para `Contents/MacOS/mlx.metallib`.
- A assinatura usa o certificado Apple Development para que as permissões de Microfone e
  Acessibilidade sobrevivam a rebuilds. Outra identidade: `CODESIGN_IDENTITY="…" bash scripts/build-app.sh`.
```

- [ ] **Step 10: Commit**

```bash
cd <repo> && git add -A Package.swift Resources scripts docs Sources && git commit -m "feat(app): menu bar shell, settings, permissions and signed bundle

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Ditado de ponta a ponta — gravação, hotkey, colagem

**Files:**
- Create: `Sources/Transcricao/AudioRecorder.swift`
- Create: `Sources/Transcricao/HotkeyMonitor.swift`
- Create: `Sources/Transcricao/PasteboardInserter.swift`
- Modify: `Sources/Transcricao/AppEnvironment.swift` (substituir pela versão completa abaixo)

**Interfaces:**
- Consumes: `HotkeyStateMachine`, `HotkeyAction`, `DictationPipeline`, `PipelineOutcome`, `ModelResidency`, `AudioFileLoader.targetFormat`, `AppState`, `Settings`.
- Produces:
  - `final class StreamingResampler { init?(from: AVAudioFormat); func convert(_: AVAudioPCMBuffer) -> [Float] }`
  - `@MainActor final class AudioRecorder { var onLevel: ((Float) -> Void)?; var onLimitReached: (() -> Void)?; func start() throws; func stop() -> [Float]; func cancel() }`
  - `@MainActor final class HotkeyMonitor { var onAction: ((HotkeyAction) -> Void)?; var onContinuousChange: ((Bool) -> Void)?; func start() }`
  - `struct PasteboardInserter: TextInserter`
  - `AppEnvironment` ganha `handle(_ action: HotkeyAction)`; Task 13 adiciona HUD/sons por meio dos ganchos `onRecordingStarted/onLevel/onProcessing/onFinished`.

- [ ] **Step 1: `AudioRecorder.swift`**

```swift
import AVFoundation
import TranscricaoEngines

/// Thread-safe sample accumulator written from the audio render thread.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    func append(_ s: [Float]) { lock.withLock { samples.append(contentsOf: s) } }
    var count: Int { lock.withLock { samples.count } }
    func drain() -> [Float] { lock.withLock { defer { samples = [] }; return samples } }
}

/// One AVAudioConverter per recording so the resampler keeps its filter state
/// across tap buffers (a fresh converter per buffer causes boundary artifacts).
final class StreamingResampler: @unchecked Sendable {
    private let converter: AVAudioConverter

    init?(from format: AVAudioFormat) {
        guard let c = AVAudioConverter(from: format, to: AudioFileLoader.targetFormat) else { return nil }
        converter = c
    }

    func convert(_ input: AVAudioPCMBuffer) -> [Float] {
        let ratio = AudioFileLoader.targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioFileLoader.targetFormat,
                                            frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil } // keep stream open
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

/// Captures the default input at 16 kHz mono Float32. The engine only runs
/// while recording so the macOS mic indicator is off otherwise.
@MainActor
final class AudioRecorder {
    static let maxSeconds: Double = 300

    private var engine: AVAudioEngine?
    private let buffer = SampleBuffer()
    var onLevel: ((Float) -> Void)?
    var onLimitReached: (() -> Void)?

    func start() throws {
        _ = buffer.drain()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let resampler = StreamingResampler(from: format) else {
            throw NSError(domain: "Transcricao", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Formato de áudio não suportado"])
        }
        let buffer = self.buffer
        let maxSamples = Int(Self.maxSeconds * 16_000)
        var limitFired = false
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] pcm, _ in
            let samples = resampler.convert(pcm)
            guard !samples.isEmpty else { return }
            buffer.append(samples)
            var sum: Float = 0
            for s in samples { sum += s * s }
            let rms = (sum / Float(samples.count)).squareRoot()
            let reachedLimit = buffer.count >= maxSamples && !limitFired
            if reachedLimit { limitFired = true }
            Task { @MainActor in
                self?.onLevel?(rms)
                if reachedLimit { self?.onLimitReached?() }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() -> [Float] {
        teardown()
        return buffer.drain()
    }

    func cancel() {
        teardown()
        _ = buffer.drain()
    }

    private func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
```

- [ ] **Step 2: `HotkeyMonitor.swift`**

```swift
import AppKit
import TranscricaoCore

/// Feeds Right-Option (keyCode 61), other key presses and clicks into the state machine.
/// Listens only (events are never swallowed). Requires Accessibility.
@MainActor
final class HotkeyMonitor {
    private static let rightOptionKeyCode: UInt16 = 61
    private static let escapeKeyCode: UInt16 = 53
    private static let rightOptionDeviceMask: UInt = 0x40 // NX_DEVICERALTKEYMASK

    private var machine = HotkeyStateMachine()
    private var monitors: [Any] = []
    private var tickTimer: Timer?
    var onAction: ((HotkeyAction) -> Void)?
    var onContinuousChange: ((Bool) -> Void)?

    /// Safe to call again (e.g. after Accessibility is granted): replaces old monitors.
    func start() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(local) }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged where event.keyCode == Self.rightOptionKeyCode:
            let down = event.modifierFlags.rawValue & Self.rightOptionDeviceMask != 0
            feed(down ? .keyDown(event.timestamp) : .keyUp(event.timestamp))
        case .flagsChanged:
            break // other modifiers alone do not cancel
        case .keyDown:
            feed(event.keyCode == Self.escapeKeyCode ? .escape : .otherKey)
        case .leftMouseDown, .rightMouseDown:
            feed(.otherKey) // ⌥+click is a modifier use, not dictation
        default:
            break
        }
    }

    private func feed(_ event: HotkeyEvent) {
        let wasContinuous = machine.isContinuous
        for action in machine.handle(event) { onAction?(action) }
        if machine.isContinuous != wasContinuous { onContinuousChange?(machine.isContinuous) }

        tickTimer?.invalidate()
        tickTimer = nil
        if case .awaitingSecondTap = machine.state {
            tickTimer = Timer.scheduledTimer(withTimeInterval: HotkeyStateMachine.doubleTapWindow + 0.02,
                                             repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.feed(.tick(ProcessInfo.processInfo.systemUptime))
                }
            }
        }
    }
}
```

- [ ] **Step 3: `PasteboardInserter.swift`**

```swift
import AppKit
import TranscricaoCore

/// Pastes text into the focused field: stash clipboard → write text → ⌘V → restore.
struct PasteboardInserter: TextInserter {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let restoreDelay: UInt64 = 250_000_000

    func insert(_ text: String) async {
        let saved = await MainActor.run { Self.writeAndPaste(text) }
        try? await Task.sleep(nanoseconds: Self.restoreDelay)
        await MainActor.run { Self.restore(saved) }
    }

    @MainActor
    private static func writeAndPaste(_ text: String) -> [NSPasteboardItem] {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType) // clipboard managers skip it
        pb.writeObjects([item])
        postCommandV()
        return saved
    }

    @MainActor
    private static func restore(_ saved: [NSPasteboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 4: `AppEnvironment.swift` completo** (substitui o da Task 11; mantém todos os `StatusMenuActions`)

```swift
import AppKit
import ServiceManagement
import TranscricaoCore
import TranscricaoEngines

@MainActor
final class AppEnvironment: StatusMenuActions {
    let state = AppState()
    let settings = Settings.shared
    let transcriber = WhisperKitTranscriber()
    let processor: MLXTextProcessor
    let residency: ModelResidency
    let history = HistoryStore(fileURL: ModelLocations.history)
    let recorder = AudioRecorder()
    let hotkey = HotkeyMonitor()
    private(set) var pipeline: DictationPipeline!
    private var statusItem: StatusItemController?
    private var preparedOnce = false

    // Hooks for HUD/sounds (Task 13).
    var onRecordingStarted: ((_ continuous: Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onProcessing: (() -> Void)?
    var onFinished: ((_ errorMessage: String?) -> Void)?

    init() {
        processor = MLXTextProcessor(modelID: Settings.shared.textModel.rawValue)
        residency = ModelResidency(models: [transcriber, processor])
        let residency = self.residency
        let settings = self.settings
        pipeline = DictationPipeline(
            transcriber: transcriber,
            processor: processor,
            inserter: PasteboardInserter(),
            aiEnabled: { settings.aiEnabled },
            prepare: {
                try await residency.ensureLoaded()
                await residency.noteActivity()
            })
    }

    func start() {
        statusItem = StatusItemController(state: state, settings: settings, actions: self)
        state.history = history.entries
        recorder.onLevel = { [weak self] level in self?.onLevel?(level) }
        recorder.onLimitReached = { [weak self] in self?.handle(.stopAndProcess) }
        hotkey.onAction = { [weak self] action in self?.handle(action) }
        hotkey.onContinuousChange = { [weak self] continuous in
            guard let self, continuous else { return }
            self.state.status = .recording(continuous: true)
            self.onRecordingStarted?(true)
        }
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        state.micGranted = await Permissions.requestMicrophone()
        state.accessibilityGranted = Permissions.accessibilityGranted
        if !state.accessibilityGranted { Permissions.promptAccessibility() }
        hotkey.start()
        pollAccessibilityUntilGranted()
        await residency.setPolicy(settings.idleUnload)
        await prepareModels()
    }

    /// Accessibility is granted in System Settings while we run; poll so the menu updates.
    private func pollAccessibilityUntilGranted() {
        guard !state.accessibilityGranted else { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if Permissions.accessibilityGranted {
                    self.state.accessibilityGranted = true
                    timer.invalidate()
                    // Global monitors registered before the grant may be inert; re-register.
                    self.hotkey.start()
                }
            }
        }
    }

    func prepareModels() async {
        state.status = .preparing("Preparando modelos… (a primeira vez baixa ~3 GB)")
        processor.onProgress = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .preparing = self.state.status else { return }
                self.state.status = .preparing("Baixando modelo de texto… \(Int(fraction * 100))%")
            }
        }
        do {
            try await residency.ensureLoaded()
            preparedOnce = true
            state.status = .ready
        } catch {
            state.status = .error("não foi possível preparar os modelos (\(error.localizedDescription))")
        }
    }

    // MARK: - Dictation

    func handle(_ action: HotkeyAction) {
        switch action {
        case .startCapture:
            guard preparedOnce, state.micGranted, state.accessibilityGranted else { return }
            Task { try? await residency.ensureLoaded() } // reload in parallel with speech if evicted
            do {
                try recorder.start()
                state.status = .recording(continuous: false)
                onRecordingStarted?(false)
            } catch {
                state.status = .error("microfone indisponível")
                onFinished?("Microfone indisponível")
            }

        case .stopAndProcess:
            guard case .recording = state.status else { return }
            let samples = recorder.stop()
            state.status = .processing
            onProcessing?()
            Task {
                let outcome = await pipeline.run(samples)
                finish(outcome)
            }

        case .cancel:
            guard case .recording = state.status else { return }
            recorder.cancel()
            state.status = .ready
            onFinished?(nil)
        }
    }

    private func finish(_ outcome: PipelineOutcome) {
        var errorMessage: String?
        switch outcome {
        case .inserted(let result):
            history.append(result)
            state.history = history.entries
            NSLog("Transcricao: transcribe %.2fs, process %.2fs, total %.2fs%@",
                  result.timings.transcribe, result.timings.process, result.timings.total,
                  result.usedFallback ? " (fallback)" : "")
        case .discarded:
            break
        case .failed(let message):
            errorMessage = message
        }
        // A newer clip may already be recording; leave its HUD/status alone.
        guard case .processing = state.status else { return }
        state.status = .ready
        onFinished?(errorMessage)
    }

    // MARK: - StatusMenuActions

    func toggleAI() { settings.aiEnabled.toggle() }
    func toggleSounds() { settings.soundsEnabled.toggle() }

    func setIdleUnload(_ policy: IdleUnloadPolicy) {
        settings.idleUnload = policy
        Task { await residency.setPolicy(policy) }
    }

    func setTextModel(_ choice: TextModelChoice) {
        guard choice != settings.textModel else { return }
        settings.textModel = choice
        Task {
            await residency.unloadNow()
            processor.setModelID(choice.rawValue)
            await prepareModels()
        }
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Transcricao: launch at login failed: \(error)")
        }
    }

    func copyHistory(_ entry: DictationResult, raw: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw ? entry.raw : entry.final, forType: .string)
    }

    func retryPreparation() { Task { await prepareModels() } }

    func requestPermissions() {
        Permissions.promptAccessibility()
        state.accessibilityGranted = Permissions.accessibilityGranted
    }
}
```

- [ ] **Step 5: Buildar, instalar e testar à mão**

```bash
cd <repo> && bash scripts/build-app.sh 2>&1 | tail -1 && pkill -x Transcricao; ditto build/Transcricao.app /Applications/Transcricao.app && rm -rf build/Transcricao.app && open /Applications/Transcricao.app
```
Conceda Acessibilidade a "Transcrição" em Ajustes do Sistema se pedido. Depois, no app Notas:
1. Segure ⌥ direito, diga "oi tudo bem como você vai não quis dizer como você está", solte → aparece `Oi, tudo bem? Como você está?`.
2. Segure ⌥ e diga "crie uma mensagem de parabéns pra mim, seja bem curto e casual" → aparece uma mensagem curta de parabéns.
3. Copie algo antes (ex.: "XYZ"), dite, depois ⌘V manual → cola "XYZ" (pasteboard restaurado).
4. Digite ⌥+E (acento) → nada é gravado nem colado.
Verifique a latência: `log show --last 5m --predicate 'eventMessage CONTAINS "Transcricao: transcribe"' --style compact | tail -5` → `total` < 2 s para frases curtas.

- [ ] **Step 6: Commit**

```bash
cd <repo> && git add -A Sources && git commit -m "feat(app): end-to-end dictation with hotkey, recorder and paste

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Pílula flutuante (HUD) + sons

**Files:**
- Create: `Sources/Transcricao/RecordingHUD.swift`
- Create: `Sources/Transcricao/Sounds.swift`
- Modify: `Sources/Transcricao/AppDelegate.swift`

**Interfaces:**
- Consumes: ganchos `onRecordingStarted`, `onLevel`, `onProcessing`, `onFinished` do `AppEnvironment` (Task 12); `Settings.soundsEnabled`.
- Produces: `@MainActor final class RecordingHUD { func showRecording(continuous: Bool); func push(level: Float); func showProcessing(); func showError(_:); func hide() }`, `enum Sounds { static func start(); static func stop() }`.

- [ ] **Step 1: `RecordingHUD.swift`**

```swift
import AppKit
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum Mode: Equatable { case recording(continuous: Bool), processing, error(String) }
    @Published var mode: Mode = .recording(continuous: false)
    @Published var levels: [Float] = Array(repeating: 0, count: 24)
}

/// Non-activating floating pill at the bottom of the active screen. Never takes focus.
@MainActor
final class RecordingHUD {
    private let model = HUDModel()
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: HUDView(model: model))
        return p
    }()

    func showRecording(continuous: Bool) {
        model.levels = Array(repeating: 0, count: model.levels.count)
        model.mode = .recording(continuous: continuous)
        present()
    }

    func push(level: Float) {
        // Map RMS (~0…0.3) to 0…1 with a soft curve.
        let normalized = min(1, (level * 6).squareRoot())
        model.levels.removeFirst()
        model.levels.append(normalized)
    }

    func showProcessing() {
        model.mode = .processing
        present()
    }

    func showError(_ message: String) {
        model.mode = .error(message)
        present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, case .error = self.model.mode else { return }
            self.hide()
        }
    }

    func hide() { panel.orderOut(nil) }

    private func present() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 80))
        }
        panel.orderFrontRegardless()
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

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
                if continuous {
                    Text("contínuo").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            case .processing:
                ProgressView().controlSize(.small)
                Text("Processando…").font(.callout)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 200, height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.easeOut(duration: 0.08), value: model.levels)
    }
}
```

- [ ] **Step 2: `Sounds.swift`**

```swift
import AppKit

enum Sounds {
    static func start() { play("Tink") }
    static func stop() { play("Pop") }

    private static func play(_ name: String) {
        guard Settings.shared.soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
```

- [ ] **Step 3: Ligar os ganchos no `AppDelegate.swift`**

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private let hud = RecordingHUD()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment()
        env.onRecordingStarted = { [hud] continuous in
            if !continuous { Sounds.start() }
            hud.showRecording(continuous: continuous)
        }
        env.onLevel = { [hud] level in hud.push(level: level) }
        env.onProcessing = { [hud] in
            Sounds.stop()
            hud.showProcessing()
        }
        env.onFinished = { [hud] error in
            if let error { hud.showError(error) } else { hud.hide() }
        }
        environment = env
        env.start()
    }
}
```

- [ ] **Step 4: Buildar, instalar e verificar**

```bash
cd <repo> && bash scripts/build-app.sh 2>&1 | tail -1 && pkill -x Transcricao; ditto build/Transcricao.app /Applications/Transcricao.app && rm -rf build/Transcricao.app && open /Applications/Transcricao.app
```
Verifique em Notas: a pílula aparece embaixo ao segurar ⌥, as barras se mexem com a voz, vira "Processando…" ao soltar e some após colar; o foco continua no Notas (o cursor não sai do campo). Toque duplo mostra "contínuo". Esc cancela e a pílula some. Desligue "Sons" no menu e confira o silêncio.

- [ ] **Step 5: Commit**

```bash
cd <repo> && git add -A Sources && git commit -m "feat(app): floating recording HUD and sounds

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: QA manual + documentação do projeto

**Files:**
- Create: `CLAUDE.md`
- Create: `README.md`
- Create: `docs/QA.md`

- [ ] **Step 1: Rodar a suíte e o eval finais**

Run: `cd <repo> && swift test 2>&1 | tail -2 && swift run -c release tcli eval fixtures/cases.json | tail -1`
Expected: todos os testes passam; eval ≥ 17/20.

- [ ] **Step 2: Checklist manual (`docs/QA.md`) — executar e marcar cada item**

```markdown
# QA manual — Transcrição

- [ ] Primeira abertura: pede Microfone; orienta Acessibilidade; "Preparando…" → "Pronto".
- [ ] Push-to-talk em Notas: correção falada é aplicada (exemplo do "como você vai… como você está").
- [ ] Comando: "crie uma mensagem de parabéns, curta e casual" gera a mensagem.
- [ ] Pergunta ditada ("qual é a capital da Austrália") é colada como pergunta, sem resposta.
- [ ] Toque duplo → contínuo; fala longa (> 30 s); próximo toque cola tudo.
- [ ] Toque isolado curto não cola nada.
- [ ] ⌥+E / ⌥+setas não disparam gravação.
- [ ] Esc cancela no push-to-talk e no contínuo.
- [ ] Silêncio total → nada colado (sem "Legendas pela comunidade Amara.org").
- [ ] Colagem funciona em Notas, Safari (campo de busca), Mensagens, VS Code e Terminal.
- [ ] Clipboard anterior restaurado após a colagem; gerenciador do app Notch não registra o texto.
- [ ] "Organizar com IA" desligado → cola o texto bruto do Whisper.
- [ ] Trocar o modelo de texto no menu → "Preparando…" → funciona com o novo modelo.
- [ ] Histórico: clique copia o final; ⌥-clique copia o bruto.
- [ ] Liberar memória após 5 min: após 5 min parado, Monitor de Atividade mostra a memória cair;
      o próximo ditado funciona (um pouco mais lento).
- [ ] "Abrir ao iniciar sessão" liga/desliga (conferir em Ajustes → Geral → Itens de Início).
- [ ] Rebuild + reinstalar não pede as permissões de novo.
- [ ] Latência (log): ditado curto com total < 2 s.
```

- [ ] **Step 3: `CLAUDE.md`**

```markdown
# Transcrição — instruções do projeto

App de barra de menus do macOS: segure ⌥ direito, fale, solte — o texto é transcrito
localmente (WhisperKit, large-v3-turbo) e organizado por um LLM local (MLX) antes de
ser colado no campo em foco. Toque duplo no ⌥ = modo contínuo.

Docs: spec em `docs/superpowers/specs/2026-10-13-transcricao-design.md`, plano em
`docs/superpowers/plans/2026-10-13-transcricao.md`, build em `docs/BUILD.md`,
escolha do modelo em `docs/model-eval.md`, QA em `docs/QA.md`.

## Rodar / buildar

    bash scripts/build-app.sh
    ditto build/Transcricao.app /Applications/Transcricao.app && rm -rf build/Transcricao.app
    open /Applications/Transcricao.app

Requer Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

## Estrutura

    Sources/TranscricaoCore/     lógica pura testável (hotkey, gate, prompt, pipeline, residência, histórico)
    Sources/TranscricaoEngines/  WhisperKit + MLX atrás dos protocolos do Core
    Sources/Transcricao/         app AppKit/SwiftUI (AppEnvironment conecta tudo)
    Sources/tcli/                CLI: process | eval | transcribe
    fixtures/cases.json          casos do eval do prompt

## Convenções

- `TranscricaoCore` não importa AppKit/AVFoundation/WhisperKit/MLX.
- UI em português; comentários de código em inglês.
- Mudou o prompt? Rode `swift test` e `swift run -c release tcli eval fixtures/cases.json`.
  Ajuste o prompt, nunca os casos, para passar no eval.
```

- [ ] **Step 4: `README.md`** (curto, para o usuário)

```markdown
# Transcrição

Ditado por voz para macOS, 100% local.

- **Segure ⌥ direito**, fale e solte: o texto aparece onde o cursor estiver.
- **Toque duas vezes no ⌥ direito** para ditar sem segurar; toque de novo para terminar.
- **Esc** cancela.
- Corrija-se falando ("não, quis dizer…") — o texto sai já corrigido e pontuado.
- Peça textos: "escreva um e-mail curto pedindo…", "crie uma mensagem de parabéns…".

Menu na barra: ligar/desligar a organização por IA, trocar o modelo de texto, liberar
memória após inatividade, sons, abrir ao iniciar sessão e histórico.

Instalação e build: veja `docs/BUILD.md`.
```

- [ ] **Step 5: Commit**

```bash
cd <repo> && git add -A CLAUDE.md README.md docs && git commit -m "docs: project guide, README and manual QA checklist

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
