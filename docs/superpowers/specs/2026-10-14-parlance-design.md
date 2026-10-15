# Voxum: novo nome, 5 idiomas, tecla configurável, modo pergunta, arquivos, atualizações e repositório público

Data: 2026-10-14. Complementa as specs de 2026-10-13, que continuam valendo, exceto onde este documento diz o contrário. Decisões do usuário em chat: nome **Voxum** (antes "Parlance", trocado porque não era reconhecível para quem não fala inglês; Dicta, VoxType e TalkType já são nomes de apps de ditado); repositório **público com o código**, sem nenhuma chave privada nem dado pessoal; **10 idiomas ou mais**, com seletor no app (depois reduzido pelo usuário para 5 na v1, ver §2); tecla do modo pergunta **escolhida no app**.

## 1. Novo nome: Prosa → Voxum
- O app, o executável, os textos da interface, o README e os logs passam a se chamar "Voxum". O subsystem dos logs vira `io.github.gsb05br.voxum`.
- Bundle id: `io.github.gsb05br.voxum`. Ele não usa o nome pessoal do usuário e segue o padrão do domínio do GitHub.
- Migração na primeira abertura do Voxum:
  - **Preferências:** são copiadas do domínio antigo (o bundle id do Prosa) para o novo, uma vez só.
  - **Modelos:** a pasta `~/Library/Application Support/Transcricao` é **movida**, não copiada, para `~/Library/Application Support/Voxum`. Nada é baixado de novo. Se a pasta nova já existir, nada é movido.
  - **Histórico:** fica junto, na mesma pasta.
  - **Permissões:** Microfone e Acessibilidade precisam ser concedidas de novo uma vez, porque o bundle id mudou. A janela principal já abre quando falta permissão.
- Os nomes internos dos targets (`TranscricaoCore`, `TranscricaoEngines`, `tcli`) podem continuar como estão, se renomear custar caro. O que o usuário vê tem de ser só "Voxum".
- Ícone: o atual continua. Trocar o ícone fica fora do escopo.

## 2. Idiomas (5 na v1)
- **Interface:** todos os textos ficam num String Catalog (`.xcstrings`). Isso inclui menu, janela, HUD, janelinha de resposta, tela de escolha de modelos, alertas e mensagens de erro.
- **Idiomas da v1** (decisão do usuário em 2026-10-14): inglês (base), português (Brasil), espanhol, francês e chinês simplificado. Alemão, italiano, japonês, coreano, hindi, russo e árabe ficam para depois. A estrutura continua genérica: adicionar um idioma é criar o `.lproj`, os exemplos, os casos de teste e um caso no `AppLanguage`.
- **Seletor "Idioma do app":** na janela e no menu. As opções são "Sistema" mais os 5 idiomas, cada um com o nome escrito no próprio idioma. A escolha grava `AppleLanguages` no domínio do app e pede para reabrir, com um botão "Reabrir agora".
- **Seletor "Idioma do ditado":**
  - **Opções:** "Automático" (o Whisper detecta) ou um dos 5 idiomas.
  - **Padrão:** o idioma do app. Se o idioma do sistema não estiver na lista, o padrão é "Automático".
  - **Whisper:** o idioma escolhido vai para o Whisper (`DecodingOptions.language`). Em "Automático", o Whisper usa o idioma que detectar.
- **IA (Qwen):**
  - **Saída:** o texto sai sempre no idioma falado e nunca é traduzido, a menos que a fala peça tradução.
  - **Regras:** as mesmas de hoje, em todos os idiomas: correção no meio da fala, remoção de vícios de fala, pontuação, comandos de composição, listas numeradas, nunca responder a uma pergunta ditada, edição de seleção, modo resposta.
  - **Prompt do português:** o prompt atual de português não muda. O teste com SHA-256 continua valendo para o caminho sem seleção em pt-BR.
  - **Prompt dos outros idiomas:** um prompt com as regras em inglês, mais exemplos curtos no idioma do ditado. Em "Automático", o prompt é escolhido pelo idioma que o Whisper detectar.
  - **"Automático" na prática** (emenda de 2026-10-14, Task 3M, depois das medições em `docs/model-eval.md`):
    - **Escrita chinesa:** uma transcrição escrita em chinês (pelo menos 2 caracteres Han, sem kana nem Hangul e com mais caracteres Han que palavras latinas) usa o prompt zh, seja qual for o rótulo do Whisper. A exceção é um rótulo japonês ou coreano, que nunca é trocado, porque o japonês pode vir só em kanji.
    - **Confiança:** um rótulo com exemplos (pt, en, es, fr, zh) só usa o próprio prompt se o Whisper tiver confiança de pelo menos 0,8 nele; abaixo disso, ou sem medida, vale o prompt neutro, sem exemplos. Medir custa uma passada a mais do encoder (≈ 0,4 s por ditado no Automático); um idioma escolhido nunca paga esse custo, e o texto em chinês também não.
    - **Chinês sem IA:** em "Sem IA" (e quando a IA falha), o texto do Whisper em chinês vira caracteres simplificados com pontuação de largura total. A v1 só tem chinês simplificado, então isso vale também para quem fala com caracteres tradicionais.
- **Avaliação:**
  - **Casos de texto:** `fixtures/cases-<idioma>.json` com pelo menos 8 casos por idioma novo: vícios de fala, autocorreção, lista, pergunta ditada (não pode ser respondida), comando de composição, edição de seleção, resposta em somente-leitura e um caso de nome próprio.
  - **Holdout:** `fixtures/holdout-<idioma>.json` com 2 casos por idioma, escritos antes de ajustar o prompt.
  - **Áudio:** 3 frases por idioma, geradas com `say` (as vozes do macOS), para medir o WER do Whisper.
  - **Critério:** pelo menos 80% de acerto nos casos de cada idioma e **zero perguntas respondidas**. Os resultados vão para `docs/model-eval.md`. Se algum dos 5 não chegar lá mesmo depois de ajustar os exemplos, ele fica marcado como "beta" no seletor, isso é registrado e o usuário é avisado.

## 3. Tecla de ditado configurável (item 7)
- **Opções:** ⌥ direito (padrão), ⌘ direito, ⇧ direito e Fn/🌐.
- **Modos:** segurar para ditar, toque duplo para modo contínuo e Esc para cancelar continuam funcionando com qualquer tecla.
- **Uso como modificador:** usar a tecla como modificador (⌘C com o ⌘ direito, ⇧ para maiúscula) não pode disparar o ditado. Vale a mesma lógica do ⌥ hoje: atraso antes do som e cancelamento se outra tecla ou clique acontecer.
  - **Atraso por tecla** (emenda de 2026-10-14, revisão da Task 4): ⌥ direito e Fn esperam 0,2 s antes do som, do HUD e do ⌘C da seleção; ⌘ direito e ⇧ direito esperam 0,35 s, porque são modificadores do dia a dia, muitas vezes segurados um instante antes da letra. Uma gravação solta antes desse atraso é cancelada sem aviso (é mais curta que qualquer clipe que o filtro de fala aceita).
- **Fn:** se o macOS usar Fn para ditado ou emoji, a janela avisa onde desligar isso em Ajustes do Sistema: "Pressionar a tecla 🌐 para" → "Não Fazer Nada" e, em Ditado, um atalho que não seja "Pressione 🌐 2 Vezes" (ele colide com o toque duplo). Em teclados com a tecla fn, os ajustes mostram "fn" no lugar de 🌐, e o aviso diz isso. O app só mostra o texto; nunca muda ajustes do sistema.
- **Tecla sintética antes do ⌘C** (emenda de 2026-10-14, revisão da Task 4; substitui o "⌥ solto sintético passa a soltar a tecla escolhida"): o ⌘C que lê a seleção não pode virar ⌥⌘C ou ⇧⌘C, e a próxima tecla do usuário não pode perder o modificador que ele ainda segura.
  - **⌥ direito e ⇧ direito:** a tecla é solta (evento marcado), o ⌘C é enviado e a tecla é apertada de novo (marcada, mesmo código e flags), só se o usuário ainda a segura fisicamente. Quem diz isso é o monitor da tecla, que só vê eventos reais; a tabela de teclas do sistema não é consultada, porque pode já refletir a soltura sintética. Se ele soltou antes, nada é reapertado; se soltou logo antes ou logo depois do reaperto, uma nova checagem (depois que os eventos pendentes chegam ao monitor) solta a tecla, e nada fica preso.
  - **⌘ direito:** nada é solto; o ⌘ já é o modificador do atalho, e o ⌘C sintético tem exatamente ⌘.
  - **Fn:** nada é solto; Fn não muda o ⌘C, e um Fn sintético contaria como um toque no 🌐 para o macOS.
  - O monitor da tecla ignora todos os eventos marcados: nenhum deles inicia, termina ou cancela um ditado.

## 4. Modo pergunta (item 9)
- **Tecla:** uma segunda tecla, configurada no app, com as mesmas opções da seção 3 mais "Desligado", que é o padrão. Ela não pode ser igual à tecla de ditado.
- **Uso:** segurar, perguntar e soltar. A resposta aparece na janelinha de vidro, transmitida aos poucos, com "Colar" e "Copiar". Nada é colado automaticamente.
- **Contexto:** se houver texto selecionado, editável ou não, ele vai como contexto ("o que significa isso?").
- **Prompt:** um prompt próprio de assistente, que responde de forma curta e direta no idioma da pergunta. A janelinha mostra a nota "Resposta do modelo local — pode conter erros".
- **Sem IA:** a tecla de pergunta fica desativada e o seletor explica o motivo.
  - A chave "Organizar com IA" desligada não desativa a pergunta: ela só vale para o ditado, e o modelo continua carregado (emenda de 2026-10-14, Task 5).
- **Tecla de ditado igual à de pergunta** (emenda de 2026-10-14, Task 5): o seletor de pergunta não oferece a tecla de ditado. Se a tecla de ditado passar a ser a de pergunta, a de pergunta vira "Desligado" e a janela e o HUD avisam.
- **Uma tomada por vez** (emenda de 2026-10-14, Task 5): enquanto uma pergunta grava, é transcrita ou recebe a resposta, a tecla de ditado não faz nada; enquanto um ditado grava ou é processado, a tecla de pergunta não faz nada. Segurada além do atraso da tecla durante o processamento, ela mostra o motivo (na janelinha, se a resposta estiver aparecendo); durante uma gravação, a pílula de gravação já está visível e nada é mostrado. Ditados continuam podendo se sobrepor entre si, como antes.
- **Gestos:** toque duplo (modo contínuo) e Esc funcionam com a tecla de pergunta como com a de ditado. Esc depois de soltar descarta a pergunta ainda em transcrição; com a resposta aparecendo, Esc ou o botão de fechar a interrompem.

## 5. Transcrever arquivo (item 8)
- **Como abrir um arquivo:** o botão "Transcrever arquivo…" na janela e no menu, arrastar e soltar sobre a janela, ou "Abrir com" pelo Finder (tipos de documento no Info.plist).
- **Formatos:** os que o AVFoundation abre, como m4a, mp3, wav, aiff, caf, mp4 e mov. Áudio do WhatsApp (.opus/.ogg): o app tenta abrir; se o macOS não decodificar, mostra uma mensagem clara. Um decodificador extra fica fora do escopo.
- **Processamento:** o Whisper roda em trechos, com barra de progresso e Cancelar.
- **Idioma (emenda da Task 6):** cada janela de arquivo tem o seu seletor de idioma, independente do idioma do ditado. Ele começa em "Automático" e oferece os mesmos idiomas do ditado.
  - O idioma escolhido vale para a transcrição e para "Organizar com IA" e "Resumir". Em "Automático", vale o idioma detectado no primeiro trecho com fala.
  - Trocar o idioma durante a transcrição recomeça a transcrição no idioma novo; antes de ela começar, a troca vale para a transcrição que vai rodar.
  - Trocar o idioma depois da transcrição pronta mostra uma oferta "Transcrever de novo em …?". "Organizar" e "Resumir" passam a usar o idioma novo mesmo sem transcrever de novo. Cancelar a nova transcrição volta para o resultado anterior; o Histórico guarda as duas.
- **Resultado:** uma janela com o texto e os botões:
  - "Copiar";
  - "Salvar .txt";
  - "Organizar com IA": o Qwen organiza em pedaços que cabem no contexto, com as regras do ditado;
  - "Resumir": um resumo em tópicos no idioma do áudio.
- **Histórico:** recebe uma entrada por arquivo.
- **Concorrência:** usa os modelos com a mesma lógica de memória do ditado, com lease enquanto processa. Um ditado durante a transcrição espera ou é recusado com uma mensagem no HUD, nunca trava.
- **Vários arquivos (emenda da Task 6):** cada arquivo abre a sua própria janela. Os arquivos rodam um de cada vez, na ordem em que chegaram (fila FIFO), e a janela que espera diz "Aguardando o outro arquivo…". "Organizar" e "Resumir" entram na mesma fila. Fechar uma janela cancela o trabalho dela. Sair do app com trabalho na fila pede confirmação.

## 6. Atualizações automáticas (item 11)
- **Biblioteca:** Sparkle 2, via SwiftPM. O `Sparkle.framework` vai embutido no app pelo `build-app.sh`.
- **Feed:** `https://github.com/GSB05BR/voxum/releases/latest/download/appcast.xml`.
- **Assinatura das atualizações:**
  - Cada release é assinado com EdDSA.
  - A chave privada fica **só no Keychain do Mac do usuário** (`generate_keys` do Sparkle) e nunca vai para o repositório.
  - A chave pública fica no Info.plist (`SUPublicEDKey`).
- **Interface:** na janela e no menu, um toggle "Verificar atualizações automaticamente" (padrão ligado, verificação diária) e um botão "Verificar agora".
- **`scripts/release.sh <versão>`:**
  1. Atualiza a versão no Info.plist.
  2. Faz o build e assina.
  3. Gera o zip.
  4. Assina o zip com EdDSA.
  5. Gera ou atualiza o `appcast.xml`.
  6. Cria o release no GitHub com `gh release create` e anexa o zip e o appcast.
- **Limitação conhecida:** sem uma conta paga da Apple não há Developer ID nem notarização. A primeira instalação continua pedindo "botão direito → Abrir". O README explica isso.

## 7. Repositório público
- **Repositório:** `github.com/GSB05BR/voxum`, público.
- **Histórico novo:**
  - O repositório público começa com um único commit inicial. Assim, nenhum e-mail, nome de máquina ou caminho pessoal do histórico antigo é publicado.
  - O autor é `GSB05BR <ID+GSB05BR@users.noreply.github.com>`.
  - O histórico antigo fica só no Mac: um branch local `archive/pre-public`, que nunca é enviado, mais um `git bundle` de backup.
- **Limpeza antes de publicar** (verificada com grep no conteúdo publicado):
  - **Identidade de assinatura:** sai do `build-app.sh` e vira `CODESIGN_IDENTITY` lida de `scripts/local.env`. Esse arquivo está no `.gitignore`; quem não tem o arquivo assina ad-hoc (`-`).
  - **Dados pessoais:** e-mail, nome, o caminho da pasta pessoal, o Team ID da assinatura e o bundle id antigo saem de todos os arquivos, inclusive dos docs e dos planos em `docs/superpowers`.
  - **Áudios de teste:** são vozes sintéticas do `say`, sem voz real, e podem ser publicados.
  - **`.gitignore`:** ganha `.superpowers/`, `.remember/`, `scripts/local.env` e `build/`.
  - **Varredura de segredos:** procura por tokens do GitHub, do Hugging Face e da OpenAI, chaves privadas PEM e semelhantes antes do push.
- **README:** em inglês, com a seção "Português" no fim. Tem a descrição, os requisitos (Apple Silicon, macOS 14+), a instalação, o aviso de app não notarizado, a privacidade (tudo local) e o build.
- **Licença:** **GPL v3** (decisão do usuário). Arquivo `LICENSE` com o texto da GPL-3.0 e o cabeçalho
  `SPDX-License-Identifier: GPL-3.0-or-later` nos arquivos-fonte. É compatível com as dependências (MIT e Apache 2.0).
- **Créditos de terceiros:** `THIRD_PARTY_NOTICES.md` com a licença de cada dependência e modelo, e uma tela
  "Créditos" no app com o mesmo conteúdo:
  - Whisper large-v3-turbo: MIT;
  - WhisperKit CoreML: MIT;
  - tokenizador whisper-large-v3: Apache 2.0;
  - Qwen3-4B-Instruct-2507 e a conversão MLX: Apache 2.0;
  - WhisperKit, mlx-swift, mlx-swift-lm e Sparkle: MIT;
  - swift-transformers e as demais: Apache 2.0 ou MIT.

  Os pesos dos modelos não ficam no repositório: são baixados do Hugging Face na hora. Nunca sugerir que OpenAI ou
  Alibaba endossam o app; "usa Whisper e Qwen" pode.
- **Primeiro release:** v1.0.0, com o zip e o appcast.

## Fora do escopo
Pré-visualização ao vivo (item 4), dicionário pessoal, atalhos falados, tom por app, notarização, novo ícone, versão para iPhone.

## Ordem de execução
1. Renomear e migrar, mais a assinatura por `local.env`.
2. Infraestrutura de idiomas e os textos da interface nos 5 idiomas.
3. Ditado multilíngue, com prompts e avaliação.
4. Tecla configurável.
5. Modo pergunta.
6. Transcrever arquivo.
7. Sparkle e `release.sh`.
8. Limpeza, repositório público e release v1.0.0.

Revisão por etapa. Revisão final do conjunto antes da publicação.
