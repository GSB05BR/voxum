# Voxum

Voxum is a menu-bar dictation app for macOS that runs entirely on your Mac. Hold a key, speak, and
release: Whisper transcribes what you said, a local Qwen3 4B language model tidies it up (punctuation,
self-corrections, lists), and the result is pasted where you were typing.

Voxum uses Whisper (through [WhisperKit](https://github.com/argmaxinc/WhisperKit)) and Qwen (through
[MLX](https://github.com/ml-explore/mlx-swift)). It is an independent project, not affiliated with or
endorsed by OpenAI, Alibaba Cloud or any other author it credits.

## Features

- **Hold to dictate.** Hold the right ⌥ key (or right ⌘, right ⇧ or Fn/🌐), speak, release. Double-tap
  for hands-free mode and tap again to finish. Esc cancels. Correct yourself as you go ("no, I meant…")
  and the text comes out already fixed, or ask for a text ("write a short email asking…").
- **Edit a selection by voice.** Select text in an editable field and say what to do ("make it more
  formal", "translate it into English"): the result replaces the selection, with an Undo pill (⌘Z).
- **Answer panel.** With read-only text selected (a web page, a PDF), the answer appears in a small
  floating panel with Paste and Copy, instead of being pasted.
- **Question mode.** An optional second key asks the local model a question; the answer appears in the
  same panel and is never pasted on its own.
- **File transcription.** Transcribe audio and video files (m4a, mp3, wav, mp4, mov…) from the menu, by
  dropping them on the window, or with "Open With" in the Finder; then organize or summarize the text.
- **5 languages.** The interface and the tidying prompts are in English, Português (Brasil), Español,
  Français and 简体中文. Dictation can be set to one of them or to Automatic. Spanish dictation is
  marked beta: its text tidying is less reliable than in the other languages.
- **Automatic updates** through [Sparkle](https://sparkle-project.org), checked once a day (can be
  turned off). Updates are EdDSA-signed.
- **No AI mode.** Choose "No AI" to paste exactly what Whisper heard; the text model is then never
  downloaded or loaded.

## Privacy

Everything runs locally. Your audio, your dictated text and any selected text never leave your Mac. The
app uses the network for two things only:

- downloading the models from Hugging Face, once, the first time they are needed;
- the Sparkle update check, which reads the appcast published in this repository's GitHub releases.

The history of dictations stays in `~/Library/Application Support/Voxum`.

## Requirements

- A Mac with Apple Silicon (M1 or later) and macOS 14 Sonoma or later.
- About 3 GB of free disk for the models: Whisper large-v3-turbo (about 650 MB) and Qwen3 4B 4-bit
  (about 2.3 GB). With "No AI", only Whisper is downloaded.
- Memory: Qwen3 4B uses about 2.4 GB while loaded and Whisper about 0.3–0.6 GB. 16 GB of RAM is
  comfortable. On 8 GB Macs it works, and the first-run screen suggests freeing the models' memory after
  5 minutes of inactivity (they reload in about 3 s).

## Installation

1. Download `Voxum-<version>.zip` from the [Releases](https://github.com/GSB05BR/voxum/releases) page.
2. Unzip it by **double-clicking** it in the Finder. Command-line `unzip` can drop the code signature,
   and macOS then reports the app as damaged.
3. Move `Voxum.app` to `/Applications`.
4. Voxum is **not notarized** by Apple, so the first launch needs one extra step: **right-click (or
   Control-click) Voxum.app → Open**, then **Open**. If macOS only offers "Done", open
   **System Settings › Privacy & Security** and click **Open Anyway** next to the message about Voxum.
   Later updates open normally.
5. Allow **Microphone** (to hear you) and **Accessibility** (to read the selection and paste) when asked.
6. Choose your models in the first-run window. They are downloaded once.

## Usage

| Action | How |
| --- | --- |
| Dictate | Hold the dictation key, speak, release |
| Hands-free | Double-tap the dictation key; tap again to finish |
| Cancel | Esc |
| Edit selected text | Select it, hold the key and say what to change |
| Ask a question | Hold the question key (off by default; set it in the main window) |
| Transcribe a file | Menu › Transcribe file…, or drop it on the main window |

The menu-bar icon and the main window ("Open Voxum…") hold the settings: dictation key, question key,
app language, dictation language, text model (Qwen3 4B or No AI), "Organize with AI", freeing memory
after inactivity, sounds, open at login, automatic updates, the history of recent dictations, and the
credits.

## Building from source

Requirements: a recent Xcode (the project is built with Xcode 27) and its Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

    bash scripts/build-app.sh              # builds and signs build/Voxum.app
    swift test --disable-keychain          # unit tests (no models needed)

- Always pass `--disable-keychain` to `swift` commands. Every dependency is public; without the flag,
  SwiftPM looks up github.com credentials in the Keychain and can stop on a Keychain dialog.
- Signing: copy `scripts/local.env.example` to `scripts/local.env` (git-ignored) and set
  `CODESIGN_IDENTITY` to a code-signing certificate of yours, so macOS keeps the Microphone and
  Accessibility permissions across rebuilds. Without it the app is signed ad-hoc (`-`), which works but
  asks for the permissions again after every build.
- More details, including how to test the first run without deleting your models: [docs/BUILD.md](docs/BUILD.md).

## Releasing

Releases are built, EdDSA-signed and published with `scripts/release.sh`. The steps, the signing keys
and the update feed are described in [docs/RELEASING.md](docs/RELEASING.md).

## License and credits

Voxum is free software, released under the GNU General Public License, version 3 or any later version
(GPL-3.0-or-later). See [LICENSE](LICENSE).

The models and libraries it uses keep their own licenses (MIT, Apache-2.0 and other permissive
licenses); they are listed, with their full license texts and NOTICE files, in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The app carries that file and the GPL text, and shows
them from its Credits window. The model weights are not part of this repository: they are downloaded from Hugging
Face on first run.

---

## Português

O Voxum é um app de ditado para a barra de menus do macOS que roda inteiro no seu Mac. Segure uma tecla,
fale e solte: o Whisper transcreve o que você disse, um modelo de linguagem local (Qwen3 4B) organiza o
texto (pontuação, autocorreções, listas) e o resultado é colado onde você estava digitando. O Voxum usa
o Whisper e o Qwen; é um projeto independente, sem vínculo com a OpenAI, a Alibaba Cloud ou os outros
autores creditados, que não o endossam.

**Recursos:** segurar para ditar (⌥ direito por padrão, ou ⌘ direito, ⇧ direito ou Fn/🌐; toque duplo
para o modo contínuo; Esc cancela); editar um texto selecionado por voz, com "Desfazer"; janelinha de
resposta para texto só de leitura; modo pergunta com uma segunda tecla opcional; transcrição de
arquivos de áudio e vídeo, com organizar e resumir; interface e prompts em 5 idiomas (inglês,
português do Brasil, espanhol, francês e chinês simplificado; o ditado em espanhol está em beta); atualizações automáticas pelo Sparkle;
modo "Sem IA", que cola exatamente o que o Whisper ouviu.

**Privacidade:** tudo roda no Mac; áudio, texto ditado e seleção nunca saem dele. A rede só é usada para
baixar os modelos do Hugging Face (uma vez) e para a verificação de atualizações do Sparkle nos releases
deste repositório no GitHub.

**Requisitos:** Mac com Apple Silicon e macOS 14 ou posterior; cerca de 3 GB livres para os modelos
(Whisper ≈ 650 MB, Qwen3 4B ≈ 2,3 GB); 16 GB de RAM é confortável, e em Macs de 8 GB a tela inicial sugere
liberar a memória dos modelos após 5 minutos sem uso.

**Instalação:** baixe o zip em [Releases](https://github.com/GSB05BR/voxum/releases), abra-o com dois
cliques no Finder e mova o `Voxum.app` para `/Applications`. O app não é notarizado pela Apple: na
primeira vez, clique com o botão direito → Abrir, ou vá em Ajustes do Sistema › Privacidade e Segurança
› Abrir Mesmo Assim. Permita Microfone e Acessibilidade quando o app pedir.

**Build:** `bash scripts/build-app.sh` (assinatura em `scripts/local.env`, a partir de
`scripts/local.env.example`; sem ela, assinatura ad-hoc) e `swift test --disable-keychain`. Passe sempre
`--disable-keychain` aos comandos `swift`. Releases: [docs/RELEASING.md](docs/RELEASING.md).

**Licença:** GPL-3.0-or-later ([LICENSE](LICENSE)). Os créditos de terceiros estão em
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) e na janela "Créditos" do app.
