# Voxum — editar o texto selecionado por voz

Data: 2026-10-13 · Complementa `2026-10-13-transcricao-design.md`. Aprovado pelo usuário em chat.

## Comportamento
- Ao pressionar ⌥ direito, o Voxum captura o texto selecionado no app em foco (se houver).
- Com seleção:
  - Fala que é uma **instrução sobre o texto** ("melhora esse texto", "deixa mais formal", "traduz pro
    inglês", "corrige os erros", "resume", "coloca em tópicos") → a IA aplica a instrução à seleção e
    o resultado **substitui a seleção**.
  - Fala que é **ditado comum** ("obrigado pela ajuda") → o ditado organizado substitui a seleção
    (como digitar por cima). **Na dúvida, é ditado.**
- Sem seleção: comportamento atual, sem mudança.
- IA desligada: sem edição; o ditado cru substitui a seleção.
- Timeout/erro da IA no modo edição: **não** substitui a seleção pelo texto cru da fala (perderia o
  texto do usuário); mostra erro no HUD e deixa a seleção intacta. Falha nunca destrói a seleção.

## Captura da seleção
1. Acessibilidade: `AXFocusedUIElement` do app em foco → `kAXSelectedTextAttribute`. Atributo
   suportado + string vazia = sem seleção (não usar fallback).
2. Fallback (atributo não suportado/erro, ex.: Electron, alguns sites): ⌘C sintético (mesma origem
   `.privateState`, flags só ⌘, marcado para o monitor de hotkey ignorar), lê o pasteboard se o
   `changeCount` mudou, e restaura o conteúdo anterior do pasteboard.
3. Captura em paralelo com o início da gravação (fora do caminho soltar → colar). Limite ~3000
   caracteres (acima disso, recorta e avisa no HUD? — não: acima de 3000, ignora a seleção e segue
   como ditado normal, para não estourar latência/contexto).
4. Nunca logar o texto selecionado nem a fala.

## Modelo
- Prompt: quando há seleção, a mensagem do usuário leva `<selecionado>…</selecionado>` e
  `<fala>…</fala>`; regras novas no systemPrompt: se a fala é instrução sobre o selecionado, devolva
  só o texto editado; senão, devolva o ditado (regras normais). Nunca responder perguntas; nunca
  comentar a edição.
- `maxTokens` considera o tamanho da seleção.
- Eval: casos novos com campo `selecionado` em `fixtures/cases.json` (instruções variadas, ditado
  comum com seleção, pergunta ditada com seleção → pergunta transcrita) e 2–3 no holdout escritos
  antes de ajustar o prompt.

## Fora do escopo
Editar sem seleção ("melhora o último parágrafo"); várias seleções; formatação rica.

## Seleção fora de caixa de texto → resposta numa janelinha (pedido do usuário, 2026-10-13)
- Se o texto selecionado **não é editável** (texto de página web, tweet, PDF, e-mail no painel de
  leitura, saída do Terminal…), a fala é tratada como um pedido **sobre** o texto ("traduz pra
  português", "resume", "o que significa isso?", "explica") e a resposta aparece numa **janelinha
  flutuante** perto do mouse — nunca é colada.
- Nesse modo a IA **pode responder** perguntas sobre o texto selecionado (é o objetivo); continua
  proibido inventar fatos que não estão no texto quando o pedido é sobre o texto.
- Janelinha: texto selecionável, botões "Copiar" e "Colar" (e ⌘C depois de clicar nela). **Não
  fecha ao clicar fora** (decisão de 2026-10-14): fecha com Esc, o ✕, depois de Copiar ou de um
  Colar que colou, ou quando um novo ditado começa. Pode ser arrastada pelo fundo. Mostra
  "Pensando…" enquanto a IA trabalha. Erro → mensagem na própria janelinha.
- "Colar" cola no elemento em foco do app que está na frente agora (não no Voxum): o usuário pode
  clicar antes numa caixa de texto de qualquer app. Antes do ⌘V, o Voxum confere por
  Acessibilidade (com tempo limite) que esse elemento aceita texto (`isEditableText`: papel de texto
  com texto selecionado ou valor settable, ou dentro de conteúdo web editável). Se não aceitar (página,
  PDF, Terminal) ou não der para saber: nada é colado, o clipboard não é tocado e a janelinha fica
  aberta com "Clique numa caixa de texto e toque em Colar". O clipboard anterior volta depois do
  Colar, como num ditado.
- Return aciona "Colar" só com a janelinha em foco (depois de clicar nela); o Voxum nunca captura
  Return globalmente.
- Editável vs não editável: elemento em foco com papel de texto (AXTextField/AXTextArea/AXComboBox/
  AXSearchField) e `kAXSelectedTextAttribute` settable → editável (fluxo de edição atual). Seleção
  obtida de outro jeito (papel não-texto, AXSelectedTextRange + AXStringForRange, AXWebArea/
  AXStaticText) → não editável. Fallback ⌘C: editável só se o elemento em foco for de texto e
  editável; senão, não editável.
- IA desligada/"Sem IA": seleção não editável é ignorada (ditado normal).
