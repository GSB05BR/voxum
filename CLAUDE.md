# Voxum — instruções do projeto

App de barra de menus do macOS 14+ (nome de produto: **Voxum**; antes "Prosa" e "Transcrição", e "Parlance" só no plano):
segure ⌥ direito (ou a tecla escolhida: ⌘/⇧ direito ou Fn/🌐; `TriggerKey` no Core), fale, solte — o texto é transcrito localmente (WhisperKit,
large-v3-turbo) e organizado por um LLM local (MLX) antes de ser colado no campo em
foco. Toque duplo no ⌥ = modo contínuo. Esc cancela. Bundle id `io.github.gsb05br.voxum`.
Modo pergunta (spec §4): uma segunda tecla opcional (`Settings.questionKey`, Desligado por padrão, nunca a de ditado,
desativada no "Sem IA") pergunta ao modelo local; a resposta aparece na janelinha (`QuestionPrompt`), nunca é colada
sozinha. Uma tomada por vez entre as duas teclas (`TakeArbiter`). Eval: `tcli eval fixtures/questions.json`.
Transcrever arquivo (spec §5): "Transcrever arquivo…" (menu e janela), arrastar para a janela principal ou de arquivo, e
"Abrir com" no Finder (`CFBundleDocumentTypes` public.audio/public.movie, `application(_:open:)`). Uma janela por arquivo;
os arquivos rodam um de cada vez em ordem de chegada (fila FIFO em `FileTranscriptionController`), e Organizar/Resumir
entram na mesma fila. `AudioFileReader` (Engines) lê em streaming a 16 kHz (memória limitada num arquivo de 1 h);
`FileTranscription` (Core) manda blocos de ≤60 s cortados no trecho mais silencioso; `TranscriptTasks` organiza por
pedaços (`TextChunker`) e resume em map-reduce (`SummaryPrompt`). Idioma = o seletor da própria janela (Automático por padrão,
detecta no 1º bloco com fala); trocá-lo depois oferece transcrever de novo. Organizar usa o prompt do ditado + uma nota de
sistema só de arquivo (`RecordingPrompt`). Copiar só escreve na área de transferência no clique. CLI: `tcli file <arquivo> [--lang auto]
[--organize] [--summarize] [--cancel-after s] [--cancel-ai-after s]`. Ogg/Opus decodifica neste macOS; se não
decodificar, a janela explica e sugere converter.

Atualizações (spec §6): Sparkle 2 (`Updater`, `UpdateConfiguration` no Core). O updater só inicia num .app com
`SUPublicEDKey` real e sem `VOXUM_DATA_DIR`; toggle e "Verificar agora" na janela e no menu. Releases:
`scripts/release.sh <versão> [--dry-run|--publish]`, passo a passo em `docs/RELEASING.md` (a chave privada fica
só no Keychain; nunca rode `generate_keys` nem publique sem o usuário pedir).

Docs: spec atual em `docs/superpowers/specs/2026-10-14-parlance-design.md` (as de 2026-10-13 continuam
valendo onde ela não muda nada), plano em `docs/superpowers/plans/2026-10-14-parlance.md`, build em `docs/BUILD.md`,
escolha do modelo em `docs/model-eval.md`, QA em `docs/QA.md`.

## Rodar / buildar

    bash scripts/build-app.sh
    pkill -x Voxum; ditto build/Voxum.app /Applications/Voxum.app && open /Applications/Voxum.app

Passe `--disable-keychain` a todo comando `swift` (`build`, `test`, `run`, `package resolve`): sem ele o
SwiftPM pede credenciais do github.com ao Keychain e abre um diálogo na tela do usuário.

Mantenha `build/Voxum.app` (não apague). Requer Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

- O backend é Xcode 27 / Swift Build: os produtos de release ficam em
  `swift build --disable-keychain -c release --show-bin-path` (`.build/out/Products/Release`), não em `.build/release`.
- `scripts/build-app.sh` copia `mlx-swift_Cmlx.bundle` para `Contents/Resources` e
  `default.metallib` para `Contents/MacOS/mlx.metallib`; falha se faltar. Assina com a
  identidade `CODESIGN_IDENTITY` de `scripts/local.env` (fora do git; modelo em
  `scripts/local.env.example`) para que Microfone/Acessibilidade persistam entre rebuilds; sem ela, ad-hoc (`-`).
- Ícone: `Resources/AppIcon.icns`, gerado por `swift scripts/make-icon.swift .`.

## Estrutura

    Sources/TranscricaoCore/     lógica pura testável (hotkey, gate, prompt, pipeline, residência, histórico)
    Sources/TranscricaoEngines/  WhisperKit + MLX atrás dos protocolos do Core
    Sources/Transcricao/         app AppKit/SwiftUI (AppEnvironment conecta tudo; HUD, sons, janela principal)
    Sources/tcli/                CLI: process | eval | ask | transcribe | file | wer
    fixtures/cases.json          casos do eval do prompt
    fixtures/holdout.json        casos reservados (não ajuste o prompt em cima deles)

## Nomes internos (não "corrija")

O produto se chama Voxum, mas os targets SwiftPM continuam `TranscricaoCore`,
`TranscricaoEngines`, `Transcricao` e `tcli` (renomear quebraria imports/testes). O produto
executável `Voxum` (Package.swift) é o target `Transcricao`; o executável dentro do bundle é `Voxum`.
Dados (modelos + histórico) em `~/Library/Application Support/Voxum`.

O nome mora em um lugar só: `AppIdentity` (Core: nome lido do `CFBundleDisplayName`, bundle id/subsystem,
pasta, prefixo `VOXUM_` das variáveis de ambiente, domínio dev), `Resources/Info.plist` e o produto em
`Package.swift` (o `build-app.sh` lê o nome do Info.plist; um teste confere Info.plist × `AppIdentity`).
Textos da interface interpolam `AppIdentity.name`; `appLog`/`engineLog` já põem o prefixo "Voxum:".

## Modelos

Catálogo (spec `docs/superpowers/specs/2026-10-13-model-choice-design.md`, `ModelCatalog` no Core):
transcrição só Whisper Turbo; texto Qwen3-4B-Instruct-2507 4-bit (`mlx-community/Qwen3-4B-Instruct-2507-4bit`)
ou "Sem IA" (`TextModelChoice.transcriptionOnly`: o modelo de texto nem é baixado nem carregado).
O Gemma saiu do app (preferência salva com Gemma migra para Qwen). "Organizar com IA" continua como
chave rápida; a IA só roda com `Settings.aiActive` (chave ligada e modelo escolhido).
Primeira abertura: janela "Escolha seus modelos" se a escolha não foi confirmada (`modelsConfirmed`)
e os modelos não estão no disco; instalação existente é confirmada sem tela. Downloads com
progresso em `ModelDownloads`/`ModelDownloader`; "Apagar modelos não usados" usa `UnusedModels`.
Testar a primeira abertura sem apagar os modelos: `VOXUM_DATA_DIR` (ver `docs/BUILD.md`).
Detalhes e histórico em `docs/model-eval.md`.

## Janela principal

Status, Como usar, Transcrever um arquivo, Permissões, Ajustes e Histórico. Aparece quando o app é aberto pelo
Finder/Spotlight/Launchpad (inclusive com o app já rodando), na primeira execução, quando
faltam permissões e pelo menu "Abrir Voxum…". "Abrir ao iniciar sessão" é silencioso.

## Convenções

- Licença GPL-3.0-or-later (`LICENSE`). Todo `.swift` em Sources/Tests começa com
  `// SPDX-License-Identifier: GPL-3.0-or-later` (scripts: `#` logo após o shebang). Créditos de terceiros: uma
  fonte só, `ThirdPartyNotices` (Core), mostrada na janela "Créditos" (`CreditsWindow.swift`) e gerada em
  `THIRD_PARTY_NOTICES.md` com `swift run --disable-keychain tcli notices > THIRD_PARTY_NOTICES.md` (lista + textos
  integrais das licenças e NOTICEs lidos de `.build/checkouts`/`.build/artifacts`; `ThirdPartyNoticesTests` confere o
  arquivo e cada pacote do `Package.resolved`). O `build-app.sh` põe `LICENSE` e `THIRD_PARTY_NOTICES.md` em
  `Contents/Resources` (botões na janela "Créditos"). Dependência ou modelo novo, ou versão nova de um pacote = entrada
  lá e gerar o arquivo de novo.
  Código vendorizado dentro dos pacotes (PocketFFT, picojson, ThreadPool…) entra como componente com
  `licenseLines` (o comentário de licença do header); `testEveryVendoredLicenseHeaderIsInTheNotices` falha se um
  header com licença nomeia um detentor de copyright que não está no arquivo.
- Sair (⌘Q, ou "Instalar e reabrir" do Sparkle) com ditado/pergunta em andamento espera ele terminar (`WhenIdle`,
  no máximo 15 s; `RelaunchGuard` é o delegate do Sparkle). Logs: erros só com `appLog(_:error:)`/`engineLog(_:error:)`
  (domínio/código públicos, descrição privada: pode ter caminhos).
- `TranscricaoCore` não importa AppKit/AVFoundation/WhisperKit/MLX.
- Comentários de código em inglês. UI localizada (en base, pt-BR, es, fr, zh-Hans): todo texto visível passa por
  `String(localized:)`/`Text("…")`, com a chave = o texto em inglês; tabelas em
  `Sources/Transcricao/Resources/<idioma>.lproj` (o `build-app.sh` as copia para `Contents/Resources`). O nome do app
  entra como argumento (`%@`), nunca escrito na tabela. Texto novo: acrescente a chave em todos os `.lproj`;
  `bash scripts/check-strings.sh` confere código × `en.lproj` e `LocalizationCompletenessTests` confere os idiomas.
- Idiomas do ditado (`AppLanguage`/`DictationLanguage` no Core): "pt" usa o prompt português do `PromptBuilder` (intocado);
  os outros usam `MultilingualPrompt` (regras em inglês) + `Text/Examples/Examples_<código>.swift`. Evals por idioma:
  `swift run --disable-keychain -c release tcli eval fixtures/cases-<código>.json --lang <código>` (sem `--lang` = pt); com agentes em
  paralelo, rode via `scripts/with-eval-slot.sh` (no máximo 3 evals ao mesmo tempo). No Automático
  (`DictationLanguage.promptLanguage`): texto escrito em chinês usa o prompt zh qualquer que seja o rótulo (menos ja/ko);
  um rótulo com exemplos (pt, en, es, fr, zh) só usa o seu prompt com confiança ≥ 0,8 do Whisper (uma passada a mais,
  ≈ 0,4 s, só no Automático), senão o prompt neutro. Casos com rótulo errado: `fixtures/cases-mislabel.json`.
  Idioma novo: `.lproj`, `Examples_<código>.swift`, `cases-<código>.json` e, no código, `AppLanguage` (caso,
  `match`, `whisperCode`, `nativeName`), `MultilingualPrompt.examples(for:)` + `exampleCodes` e
  `LocalizationCompletenessTests` (`testTheV1LanguagesHaveFolders` e `testEveryLanguageMatchesEnglish`).
- Mudou o prompt? Rode `swift test --disable-keychain` e `swift run --disable-keychain -c release tcli eval fixtures/cases.json`
  e depois `fixtures/holdout.json`. Ajuste o prompt, nunca os casos; não ajuste o prompt
  em cima do holdout. Baseline honesto: cases 38/43 (`correcao-no-meio`, `ed-corrigir`, `ed-resumir`,
  `ro-resumir` e `ro-formal-saudacao` falham), holdout 15/15; 4 casos se parecem com
  exemplos do prompt (dois são exemplos canônicos do usuário, mantidos de propósito).
- Seleção (spec `docs/superpowers/specs/2026-10-13-edit-selection-design.md`): editável → edição por voz
  (casos com `selecionado`); somente leitura → resposta na janelinha (casos com `selecionadoSomenteLeitura`, prompt
  `answerSystemPrompt`). Sem seleção o prompt é exatamente o de antes. Editável vs leitura: `SelectionClassifier`
  (Core) a partir de fatos de Acessibilidade. Falha da IA com seleção nunca cola a fala crua: nada é colado e a fala
  fica no Histórico ("não colado"). O Histórico guarda a reescrita do modelo (o texto editado) e as respostas.
  Nunca logar a seleção nem a fala.

## Logs e latência

zsh tem um builtin `log`; use o caminho completo:

    /usr/bin/log show --last 5m --predicate 'subsystem == "io.github.gsb05br.voxum"' --style compact

Linhas começam com "Voxum:" (ex.: "Voxum: transcribe 1.07s, process 0.58s, total 1.91s",
"Voxum: models ready"; fallback mostra o motivo: "(fallback: timeout|error|truncated|empty)").
Depois do primeiro download os modelos carregam do disco, sem rede
("Voxum: whisper loaded from local folder", "Voxum: text model loaded from local snapshot";
ver `LocalModelFiles` no Core). Medido em uso real: frase curta ≈ 1,9 s no total. "Liberar memória
após inatividade" custa ~3 s para recarregar os modelos do disco (antes da carga local eram ~10–12 s); o padrão é Nunca.
