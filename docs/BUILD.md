# Build

Pré-requisitos: Xcode 27 + Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

    bash scripts/build-app.sh          # build release + bundle + assinatura
    pkill -x Voxum; ditto build/Voxum.app /Applications/Voxum.app
    open /Applications/Voxum.app

- Testes: `swift test --disable-keychain` (só o Core; não precisa de modelos).
- Eval do prompt: `swift run --disable-keychain -c release tcli eval fixtures/cases.json [--model <id>]`.
- Whisper: `swift run --disable-keychain -c release tcli transcribe fixtures/audio/correcao.wav`.
- Modelos ficam em `~/Library/Application Support/Voxum/Models/`.
- MLX: o metallib fica em `<bin>/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` (`<bin>` = `swift build --disable-keychain -c release --show-bin-path`); o `build-app.sh` copia o bundle para
  `Contents/Resources` e o `.metallib` para `Contents/MacOS/mlx.metallib`.
- Assinatura: copie `scripts/local.env.example` para `scripts/local.env` (fora do git) e defina
  `CODESIGN_IDENTITY` (ex.: um certificado autoassinado de assinatura de código, para que as permissões de
  Microfone e Acessibilidade sobrevivam a rebuilds; liste com `security find-identity -v -p codesigning`).
  Sem o arquivo, assina ad-hoc (`-`). Também dá para passar `CODESIGN_IDENTITY="…" bash scripts/build-app.sh`.
- Sparkle (atualizações): o `build-app.sh` copia `Sparkle.framework` para `Contents/Frameworks`
  (rpath `@executable_path/../Frameworks`), tira os XPC services (o app não é sandboxed) e assina de
  dentro para fora com a mesma identidade (dylibs, helpers do Sparkle, framework, `mlx.metallib`, app),
  sem `--deep`. `bash scripts/build-app.sh --release` recusa o build enquanto `SUPublicEDKey` for o
  placeholder ou não for uma chave válida (base64 de 32 bytes).
  Em execuções de desenvolvimento (`VOXUM_DATA_DIR`, `swift run`) ou sem a chave, o updater nem
  inicia. Com a chave real no Info.plist, abrir `build/Voxum.app` sem `VOXUM_DATA_DIR` inicia o Sparkle
  de verdade (ele consulta o feed e pode oferecer trocar essa cópia). Releases: `docs/RELEASING.md`.
- Bibliotecas de back-deploy do Swift (`libswiftCompatibilitySpan.dylib`): o executável as procura por
  `@rpath`; o `build-app.sh` copia cada uma do toolchain para `Contents/Frameworks` (usada no macOS 14/15;
  o 26+ tem a sua em `/usr/lib/swift`) e apaga os rpaths absolutos do toolchain, que só existem neste Mac.
- Passe sempre `--disable-keychain` aos comandos `swift` (as dependências são públicas): sem ele o SwiftPM
  procura credenciais do github.com no Keychain e pode travar num diálogo. Os scripts já passam.

## Testar a primeira abertura sem apagar os modelos

Variáveis de ambiente de desenvolvimento (sem efeito quando não definidas):

- `VOXUM_DATA_DIR=<pasta>`: modelos e histórico ficam nessa pasta em vez de
  `~/Library/Application Support/Voxum`, e as preferências vão para o domínio separado
  `io.github.gsb05br.voxum.dev` (as preferências reais não mudam). Vale também para o `tcli`.
- Só junto com `VOXUM_DATA_DIR`: `VOXUM_SIMULATED_RAM_GB=8` (a tela de escolha se comporta como num
  Mac com 8 GB) e `VOXUM_SETUP_AUTOSTART=qwen|sem-ia` (escolhe o modelo e aperta "Baixar e começar").

Rode o executável direto (o `open` não repassa variáveis) e feche o Voxum instalado antes, para
não ter dois atalhos ⌥ ativos:

    pkill -x Voxum
    D=$(mktemp -d); VOXUM_DATA_DIR=$D build/Voxum.app/Contents/MacOS/Voxum
    # depois: pkill -x Voxum; rm -rf "$D"; defaults delete io.github.gsb05br.voxum.dev; open /Applications/Voxum.app

