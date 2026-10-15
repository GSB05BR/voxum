# Transcrição — design

Data: 2026-10-13 · Status: aguardando revisão

## 1. Objetivo

Um ditado para macOS melhor que o nativo. O usuário segura uma tecla, fala, solta
— e o texto aparece no campo de texto que estiver em foco, em qualquer app.
Entre a transcrição e a colagem, um modelo de texto pequeno **organiza** a fala:

- **Ditado:** aplica autocorreções faladas, remove hesitações, pontua.
  "oi tudo bem como você vai não quis dizer como você está" → `Oi, tudo bem? Como você está?`
- **Comando:** quando a fala é um pedido para compor um texto, o modelo gera o texto.
  "crie uma mensagem de parabéns pra mim, seja bem curto e casual" →
  `Parabéns! Tudo de bom pra você! Que Deus continue te abençoando sempre!`

Restrições: **tudo local/offline**, foco em **velocidade**, PT-BR em primeiro lugar.
Uso pessoal (sem App Store), MacBook M5 Pro / 48 GB, macOS 27.

**Critérios de sucesso**

1. Soltar a tecla → texto colado em **< 2 s** para ~10 s de fala (máquina aquecida).
2. Os dois exemplos acima (e o conjunto de casos da §8) saem corretos.
3. Nunca perder o que foi falado: qualquer falha do modelo de texto cai para o texto
   bruto do Whisper, e todo resultado fica no histórico.
4. Funciona em qualquer app que aceite ⌘V.

## 2. Decisões já tomadas

| Tema | Decisão |
|---|---|
| Plataforma | App nativo Swift (SwiftPM), barra de menus (`LSUIElement`), macOS 14+ |
| Reconhecimento de fala | WhisperKit (CoreML/Neural Engine), modelo `openai_whisper-large-v3-v20240930_turbo_632MB`, idioma fixo `pt` |
| Modelo de texto | `mlx-swift-lm` (MLX, GPU) dentro do processo. Padrão: `mlx-community/Qwen3-4B-Instruct-2507-4bit`. Candidato: Gemma 4 E4B instruct 4-bit do `mlx-community` — a variante exata (`gemma-4-e4b-it-4bit` ou `-qat-OptiQ-4bit`) é a primeira que carregar no `mlx-swift-lm`, verificado na primeira tarefa do plano. Escolha final pelo eval da §8 |
| Ativação | ⌥ direito: segurar = push-to-talk; toque duplo = modo contínuo |
| Ditado × comando | Automático, decidido pelo prompt do modelo de texto |
| Inserção | Pasteboard + ⌘V sintético, com restauração do pasteboard |
| Assinatura | Certificado "Apple Development" do usuário (identidade estável → permissões persistem entre builds) |

Pré-requisito de ambiente: Metal Toolchain do Xcode instalado
(`xcodebuild -downloadComponent MetalToolchain`) — sem ele o MLX não compila.

## 3. Arquitetura

```
Package.swift
Sources/
  TranscricaoCore/      lógica pura e testável, sem UI
    Hotkey/HotkeyStateMachine.swift   eventos de tecla+timestamps → ações
    Audio/SpeechGate.swift            decide se um áudio vale transcrever
    Text/PromptBuilder.swift          monta mensagens (system + few-shot + fala)
    Text/OutputSanitizer.swift        limpa a saída do modelo
    Text/HallucinationFilter.swift    frases-fantasma do Whisper
    Pipeline/Protocols.swift          Transcriber, TextProcessor, TextInserter
    Pipeline/DictationPipeline.swift  orquestra áudio → texto → inserção, com fallback
    Pipeline/ModelResidency.swift     carrega/descarrega modelos (inatividade)
    History/HistoryStore.swift        últimos resultados (JSON)
  TranscricaoEngines/   implementações com dependências pesadas
    WhisperKitTranscriber.swift
    MLXTextProcessor.swift
    ModelLocations.swift              onde ficam os modelos no disco
  Transcricao/          o app (AppKit + SwiftUI)
    TranscricaoApp.swift / AppDelegate.swift
    AppEnvironment.swift              cria e conecta tudo (DI)
    HotkeyMonitor.swift               NSEvent global monitor → HotkeyStateMachine
    AudioRecorder.swift               AVAudioEngine → PCM 16 kHz mono Float
    PasteboardInserter.swift          implementa TextInserter
    StatusItemController.swift        ícone + menu
    RecordingHUD.swift                pílula flutuante (NSPanel não ativável)
    Permissions.swift                 microfone + acessibilidade
    Settings.swift                    UserDefaults
  tcli/                 ferramenta de linha de comando (eval e depuração)
Tests/TranscricaoCoreTests/
Resources/Info.plist
scripts/build-app.sh                  build release + bundle + codesign
fixtures/cases.json                   casos do eval
```

Regra de fronteira: `TranscricaoCore` não importa AppKit, WhisperKit nem MLX.
Tudo que depende de hardware/modelo fica atrás de protocolos, para que o pipeline
seja testado com dublês.

Convenções (iguais ao app Notch): UI em português, comentários de código em inglês;
managers `@MainActor final class … : ObservableObject`; trabalho pesado fora do main.

## 4. Componentes

### 4.1 HotkeyStateMachine (Core)

Entrada: `keyDown(t)`, `keyUp(t)` do ⌥ direito, `otherKeyPressed`, `escape`.
Saída: `startCapture`, `stopAndProcess`, `cancel`.

Constantes: `holdThreshold = 250 ms`, `doubleTapWindow = 400 ms`.

| Estado | Evento | Ação → próximo estado |
|---|---|---|
| idle | keyDown | `startCapture` → pressed |
| pressed | keyUp após ≥ 250 ms | `stopAndProcess` → idle (push-to-talk) |
| pressed | keyUp antes de 250 ms | → awaitingSecondTap (captura continua) |
| awaitingSecondTap | keyDown dentro de 400 ms | → continuous |
| awaitingSecondTap | 400 ms sem keyDown | `cancel` → idle (toque isolado) |
| continuous | keyDown (próximo toque) | `stopAndProcess` → idle |
| pressed / awaiting | otherKeyPressed | `cancel` → idle (⌥ usado como modificador, ex.: ⌥+E) |
| qualquer gravando | escape | `cancel` → idle |

A captura começa no primeiro keyDown para não perder as primeiras palavras;
se virar um toque isolado, o áudio é descartado.

O monitor do app usa `NSEvent.addGlobalMonitorForEvents([.flagsChanged, .keyDown])`
filtrando keyCode 61 (⌥ direito). O evento não é engolido. Requer Acessibilidade.

### 4.2 AudioRecorder (App)

`AVAudioEngine` com tap no input, convertido para 16 kHz mono Float32 em memória.
Publica o nível RMS (~20 Hz) para a pílula. Limite de 5 min por gravação
(no limite, para e processa). O engine só roda enquanto grava (indicador de
microfone do macOS some fora da gravação).

### 4.3 SpeechGate + HallucinationFilter (Core)

- Descarta áudio < 0,4 s ou com RMS abaixo de um limiar (silêncio).
- Após o Whisper, descarta resultados vazios ou que batem com frases-fantasma
  conhecidas em PT-BR ("Legendas pela comunidade Amara.org", "Obrigado.",
  "Inscreva-se no canal", etc.) quando são o texto inteiro.

### 4.4 WhisperKitTranscriber (Engines)

- Modelo `openai_whisper-large-v3-v20240930_turbo_632MB`, `language: "pt"`,
  `task: .transcribe`, sem timestamps, temperatura 0.
- Pré-carregado na abertura do app e aquecido com 1 s de silêncio.
  A primeira execução compila os modelos CoreML (pode levar minutos) —
  o menu mostra "Preparando…" e o atalho fica inativo até terminar.

### 4.5 MLXTextProcessor (Engines) + PromptBuilder + OutputSanitizer (Core)

- Modelo carregado e aquecido na abertura; fica residente (~2,5 GB) enquanto o
  `ModelResidency` (§4.9) não o descarregar.
- Geração: temperatura 0, `maxTokens = min(1024, max(256, 3 × tokens da entrada))`.
- **Timeout de 6 s** → o pipeline usa o texto bruto.
- O id do modelo vem das configurações (Qwen ou Gemma), trocável pelo menu.

**Prompt** (system, em português), em essência:

> Você recebe a transcrição crua de uma fala em português do Brasil.
> Decida o modo:
> - DITADO (padrão): reescreva a fala como o texto final que a pessoa quis escrever.
>   Aplique correções faladas ("não, quis dizer…", "na verdade…", "apaga isso"),
>   remova hesitações e repetições ("é…", "tipo", "né"), corrija pontuação e
>   maiúsculas. Não mude o sentido, não acrescente nada, não responda à fala.
> - COMANDO: só quando a fala pede explicitamente para compor, escrever, gerar,
>   reescrever ou traduzir um texto ("crie uma mensagem…", "escreva um e-mail…").
>   Produza o texto pedido, respeitando tom e tamanho pedidos.
> Responda SOMENTE com o texto final. Sem aspas, sem markdown, sem explicações.

Seguido de 4–6 exemplos few-shot (incluindo os dois do usuário) e da fala.
A regra "na dúvida é ditado" protege contra falsos comandos
("lembrar de criar a tarefa amanhã" é ditado).

**OutputSanitizer:** remove blocos `<think>…</think>`, aspas envolvendo o texto
todo, prefixos tipo "Texto:"/"Resposta:", marcação markdown (`**`, `#`) e espaços
nas pontas. Se o resultado ficar vazio → texto bruto.

### 4.6 DictationPipeline (Core)

```
audio → SpeechGate → Transcriber → HallucinationFilter
      → (IA ligada?) TextProcessor com timeout → OutputSanitizer
      → TextInserter → HistoryStore
```

- Serial: se uma nova gravação termina enquanto outra processa, entra na fila e é
  colada na ordem.
- Falha/timeout do TextProcessor → insere o texto bruto e marca no histórico.
- Estados publicados para a UI: `preparing`, `ready`, `recording`, `processing`,
  `error(String)`.
- Mede e registra a latência de cada etapa (para o critério de sucesso 1).

### 4.7 PasteboardInserter (App)

1. Salva todos os itens/tipos do `NSPasteboard.general`.
2. Escreve o texto com o tipo `org.nspasteboard.TransientType` (gerenciadores de
   clipboard, como o do app Notch, ignoram).
3. Envia ⌘V via `CGEvent` (requer Acessibilidade).
4. Após 250 ms, restaura o conteúdo original.

O texto vai para o app em foco no momento da colagem. Se não houver campo de texto,
o ⌘V não faz nada — o resultado continua no histórico.

### 4.8 UI

- **Ícone na barra de menus** (SF Symbols) por estado: preparando (progresso),
  pronto, gravando (vermelho), processando.
- **Menu:** status/permissões pendentes (com botão para abrir Ajustes do Sistema);
  "Organizar com IA" (liga/desliga); submenu "Modelo de texto" (Qwen / Gemma);
  "Sons" (liga/desliga); "Liberar memória após inatividade" (Nunca/5/15/30 min); "Abrir ao iniciar sessão" (`SMAppService`);
  "Histórico" (últimos 10 — clicar copia o texto processado; ⌥-clique copia o bruto);
  "Sair".
- **Pílula flutuante:** `NSPanel` não ativável (nunca rouba o foco), centralizada
  embaixo da tela ativa, com barras de nível do microfone enquanto grava e um
  spinner enquanto processa; indica "contínuo" no modo de toque duplo.
- **Sons** opcionais e discretos no início e no fim da gravação.

### 4.9 ModelResidency (Core)

Controla se os modelos estão na memória. Ambos os engines implementam
`load()` / `unload()` (protocolo `ResidentModel`).

- **Padrão: sempre carregados** (~3,5 GB residentes: Whisper ~1 GB + modelo de
  texto ~2,5 GB). Parados, não usam CPU/GPU — só memória.
- Opção no menu **"Liberar memória após inatividade"**: Nunca (padrão) /
  5 min / 15 min / 30 min. Após esse tempo sem gravações, descarrega os dois.
- **Recarga sob demanda:** se os modelos estiverem descarregados, o `keyDown`
  inicia a gravação normalmente **e** dispara a recarga em paralelo — a recarga
  (~2–3 s) se sobrepõe à fala. O pipeline aguarda a recarga antes de transcrever.
  O ícone mostra "carregando" durante a recarga.
- O relógio de inatividade é injetável (testável sem esperar minutos).
- Trocar de modelo de texto no menu descarrega o antigo e carrega o novo.

### 4.10 HistoryStore (Core)

Últimos 50 resultados `{data, bruto, final, modo, latências, usouFallback}` em
`~/Library/Application Support/Transcricao/history.json`.

### 4.11 Modelos no disco

Ambos os modelos baixados na primeira execução (~3 GB no total, progresso no menu)
para `~/Library/Application Support/Transcricao/Models/`. Sem rede depois disso.

### 4.12 Permissões e empacotamento

- `Info.plist`: `LSUIElement`, `NSMicrophoneUsageDescription`, bundle id
  `<bundle id de então>`, nome exibido "Transcrição".
- `scripts/build-app.sh`: build release, monta `build/Transcricao.app`, copia o
  metallib do MLX e os recursos, assina com
  o certificado de desenvolvimento local (`CODESIGN_IDENTITY`).
  Se o `swift build` não gerar o `default.metallib` do MLX corretamente, o script
  usa `xcodebuild` para o pacote (decidido na primeira tarefa do plano).
- Na abertura: verifica microfone e Acessibilidade e orienta o usuário no menu.

## 5. Tratamento de erros

| Situação | Comportamento |
|---|---|
| Modelos ainda carregando (primeira abertura) | Atalho inativo, menu mostra "Preparando…" |
| Modelos descarregados por inatividade | Grava normalmente; recarga em paralelo à fala; primeiro ditado ~2–3 s mais lento no pior caso |
| Download de modelo falha | Erro no menu com "Tentar de novo" |
| Sem permissão de microfone/Acessibilidade | Atalho inativo, item no menu leva aos Ajustes |
| Áudio curto/silencioso ou alucinação | Descarta silenciosamente (pílula some) |
| Modelo de texto falha/estoura 6 s/saída vazia | Cola o texto bruto, marca no histórico |
| Whisper falha | Erro breve na pílula; nada é colado |

## 6. Desempenho esperado (M5 Pro)

Whisper turbo no Neural Engine: ~0,3–0,6 s para 10 s de áudio.
Qwen3-4B 4-bit no MLX: ~100+ tokens/s → ~0,5–1 s para um ditado típico.
Comandos que geram textos longos podem passar de 2 s; o critério 1 vale para ditado.

## 7. Fora de escopo (v1)

Atalho configurável, inserção por streaming (palavra a palavra), contexto do app em
foco no prompt, vocabulário personalizado, outros idiomas, distribuição pública.

## 8. Testes

- **Unitários (`swift test`, Core):** `HotkeyStateMachine` (todas as transições da
  tabela, incluindo ⌥+tecla e Esc), `SpeechGate`, `HallucinationFilter`,
  `OutputSanitizer`, `PromptBuilder`, `ModelResidency` (descarrega após o tempo
  configurado com relógio falso; "Nunca" nunca descarrega; recarga no keyDown;
  pipeline espera a recarga), e `DictationPipeline` com dublês
  (fallback por erro, por timeout, por saída vazia; IA desligada; ordem da fila).
- **Eval do modelo de texto (`tcli eval fixtures/cases.json`):** ~20 casos PT-BR
  com `entrada`, `esperado` (referência) e checagens simples (`deveConter`,
  `naoDeveConter`, `modo`). Inclui literalmente os dois exemplos do usuário,
  correções ("não, quis dizer", "na verdade", "apaga isso"), hesitações,
  números/datas, falsos comandos que são ditado, e comandos com tom/tamanho.
  Mostra saída, aprovação e latência por caso. **Escolha do modelo:** maior taxa
  de aprovação; empate (diferença ≤ 1 caso) → menor latência mediana.
- **Whisper (`tcli transcribe arquivo.wav`):** transcreve e mostra a latência.
- **Manual (app real):** push-to-talk, toque duplo, ⌥+E não dispara, Esc cancela,
  colagem em Notas/Safari/Mensagens/VS Code, pasteboard restaurado, histórico.
