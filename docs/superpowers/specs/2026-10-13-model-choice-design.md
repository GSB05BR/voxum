# Voxum — escolha de modelos na primeira abertura

Data: 2026-10-13 · Complementa `2026-10-13-transcricao-design.md` (que continua valendo).

## Objetivo
Quem recebe o Voxum escolhe, na primeira abertura, quais modelos baixar, com uma opção leve que
funcione bem num MacBook de 8 GB. **Todo modelo oferecido precisa ser bom em português do Brasil.**

## Critério de entrada de um modelo (PT-BR primeiro)
- **Transcrição (Whisper, WhisperKit CoreML, multilíngue):** WER em PT-BR medido em
  `fixtures/audio/*.wav` + um conjunto de frases PT-BR geradas com `say -v Luciana` (e outra voz pt_BR
  se houver), cobrindo números, nomes próprios, acentos e frases longas. Entra se o WER ficar até
  ~1,5× o do Turbo atual e a frase continuar compreensível; senão fica fora (registrar números).
  Modelos `distil-*` e `*.en` são só inglês → fora.
- **Texto (MLX):** `tcli eval fixtures/cases.json` e `fixtures/holdout.json`. Entra se não responder
  perguntas ditadas (classe de falha mais grave), passar ≥ 80% dos casos e manter PT-BR correto
  (acentos, concordância). Modelos com modo "thinking" (Qwen3 híbrido) rodam com thinking desligado.

## Catálogo (final depende da avaliação)
Transcrição: Turbo `openai_whisper-large-v3-v20240930_turbo_632MB` (atual, recomendado);
Turbo compacto `openai_whisper-large-v3-v20240930_547MB`; Small `openai_whisper-small_216MB` (só se
passar no critério). Texto: Qwen3 4B Instruct 2507 4-bit (atual); um Qwen leve (avaliar
`mlx-community/Qwen3-1.7B-4bit` e `mlx-community/Qwen3.5-2B-OptiQ-4bit`/`-MLX-4bit` — fica o melhor
em PT-BR que o mlx-swift-lm suportar); Gemma 4 E4B (opcional); "Sem IA" (só transcrição).

## Primeira abertura
- Janela "Escolha seus modelos" antes de qualquer download: dois seletores com tamanho de download e
  memória aproximada; pré-seleção pela RAM (`ProcessInfo.physicalMemory`): ≥ 16 GB → Turbo + Qwen3 4B;
  < 16 GB → combinação leve. Mostra o total a baixar e o espaço livre; botão "Baixar e começar".
- Progresso de download dos dois modelos (barra + MB), cancelável; erro com "Tentar de novo".
- Usuário existente (modelos já no disco e configuração salva) não vê a tela.

## Depois
- Ajustes (janela e menu): trocar transcrição e texto; se o modelo não estiver no disco, baixa com
  progresso; troca segue as regras atuais (não troca durante gravação/processamento).
- "Apagar modelos não usados" com o espaço que libera.
- Indicador de memória e status continuam como estão.

## Fora do escopo
Modelos remotos/na nuvem; reconhecimento de fala da Apple; iPhone.

## Decisão após a avaliação (2026-10-13, aprovada pelo usuário)
Resultados em `docs/model-eval.md` ("Modelos leves (8 GB)"). Nenhum modelo de texto leve passou no
critério PT-BR (todos responderam perguntas ditadas); o Whisper Turbo é o único com qualidade boa.
Catálogo final:
- Transcrição: só o Turbo (`openai_whisper-large-v3-v20240930_turbo_632MB`) — sem seletor; a tela
  mostra o tamanho (~620 MB).
- Texto: Qwen3 4B Instruct 2507 4-bit (recomendado, inclusive em 8 GB) · "Sem IA" (só transcreve;
  ditado cru, sem edição de seleção). **O Gemma sai do app** (decisão do usuário): remover de
  `TextModelChoice`, do menu e da janela; configuração salva com Gemma migra para Qwen.
- Em Macs com < 16 GB, a tela pré-seleciona "Liberar memória após 5 min" (editável ali mesmo).
- Total a baixar mostrado: ~2,7 GB (Turbo + Qwen) / ~0,6 GB (Sem IA).
- Exceção a "usuário existente não vê a tela": configuração salva com Gemma e sem o Qwen no disco
  migra para Qwen e mostra a janela de escolha (há ~2,1 GB a baixar, e "Sem IA" pode ser a melhor
  escolha); com o Qwen já no disco, migra e confirma sem tela.
- O tokenizador do Whisper (`openai/whisper-large-v3`, ~3 MB) é baixado junto com o modelo, para que
  a primeira carga funcione sem rede.
