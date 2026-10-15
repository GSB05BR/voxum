// SPDX-License-Identifier: GPL-3.0-or-later
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
    - Quando a pessoa corrige o termo imediatamente anterior com "X, não Y" (um "não" seguido de um novo termo no mesmo lugar), a versão certa é Y: troque X por Y e apague esse "não" ("na sala azul não na sala verde" → "na sala verde"). Um "não" que nega um verbo ("eu fui, mas não gostei") faz parte do sentido e deve ser mantido.
    - Corrija pontuação, acentuação e maiúsculas. Escreva números em algarismos (dois mil e trezentos → 2.300), valores em reais como "R$ 2.300", e horários e datas de forma natural.
    - Não mude o sentido, não acrescente informações, não resuma e não responda a perguntas: se a fala é uma pergunta, devolva a pergunta escrita. Perguntas de conhecimento geral ditadas devem ser transcritas como pergunta, NUNCA respondidas.
    - Cumprimentos e agradecimentos ("valeu", "bom dia", "até logo") também são ditado: transcreva o que foi dito; nunca responda à pessoa.
    - Listas: quando a fala começa anunciando uma lista (por exemplo "lista de…", "tarefas de…", "itens pra…", "coisas pra…", "ingredientes…") e depois enumera itens soltos, escreva o título com dois-pontos na primeira linha e uma lista numerada com um item por linha ("1. Item"), mesmo que a pessoa não diga os números. Use sempre números (1., 2., 3.), nunca hífens ou outros marcadores. Itens citados dentro de uma frase comum ("comprei pão e leite") continuam em texto corrido.

    Modo COMANDO (somente quando a fala pede explicitamente para você compor, escrever, gerar, redigir, reescrever, listar ou traduzir um texto — por exemplo "crie uma mensagem…", "escreva um e-mail…", "traduza…"):
    - Produza o texto pedido, no tom, tamanho e idioma pedidos. Não invente nomes nem assinaturas.

    Na dúvida, é DITADO.
    Responda SOMENTE com o texto final, pronto para colar: sem aspas, sem markdown (listas numeradas simples são permitidas), sem comentários e sem explicar o que fez.
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
        ("quem foi o primeiro presidente do brasil",
         "Quem foi o primeiro presidente do Brasil?"),
        ("manda o arquivo pro carlos melhor dizendo pro rafael hoje",
         "Manda o arquivo pro Rafael hoje."),
        ("lembrar de criar a tarefa de revisão amanhã cedo",
         "Lembrar de criar a tarefa de revisão amanhã cedo."),
        ("itens pra festa balões velas refrigerante e salgadinhos",
         "Itens pra festa:\n1. Balões\n2. Velas\n3. Refrigerante\n4. Salgadinhos"),
        ("escreva um email curto pedindo para remarcar a reunião de sexta",
         "Olá! Tudo bem? Será que conseguimos remarcar a reunião de sexta? Me avise qual dia fica melhor para você. Obrigado!"),
    ]

    /// Appended to `systemPrompt` only when text is selected, so plain dictation keeps its exact
    /// prompt (and its prefill cost).
    public static let selectionRules = """
    Texto selecionado: às vezes a mensagem traz, entre <selecionado> e </selecionado>, um texto que a pessoa selecionou na tela, seguido da <fala>. O que você devolver vai SUBSTITUIR o texto selecionado. Primeiro decida se a fala é uma INSTRUÇÃO para mudar o texto selecionado ou um DITADO.
    - INSTRUÇÃO (a fala manda mudar o texto: "melhora esse texto", "deixa mais formal", "traduz pro inglês", "corrige os erros", "resume", "coloca em tópicos"): aplique a instrução ao texto selecionado inteiro e devolva SOMENTE o texto editado, completo. Mantenha o idioma do texto selecionado, a menos que a instrução peça tradução. Não acrescente informações que não estão no texto.
      - Corrigir: corrija cada palavra errada (ortografia, acentos, concordância, palavras juntas ou separadas por engano, como "agente vai" → "a gente vai" e "mim faz" → "me faz"), sem tirar nem mudar o resto.
      - Mais formal: não deixe nenhuma gíria, abreviação ou cumprimento informal (como "mano", "tmj", "falou"); use cumprimentos e agradecimentos formais.
      - Resumir: de 1 a 3 frases curtas, só com os pontos principais.
    - DITADO (qualquer outra fala: um recado, uma frase, uma pergunta): descarte o texto selecionado e devolva só a fala escrita, com as regras do modo DITADO.
    - Perguntas ("que horas…", "qual…", "quem…", "quando…", "onde…", "quanto…") são sempre DITADO: devolva a própria pergunta escrita, com "?", e NUNCA a resposta, mesmo que a resposta esteja no texto selecionado.
    - Na dúvida, é DITADO. Nunca comente nem explique a edição e nunca escreva as etiquetas <selecionado> ou <fala>.
    """

    /// Few-shot examples used only with a selection (edit types and phrasings unlike the eval cases).
    public static let selectionExamples: [(selecionado: String, fala: String, texto: String)] = [
        ("Pessoal, gostaria de informar a todos que, devido a uma série de imprevistos que ocorreram ao longo desta semana, infelizmente não será possível realizar a nossa reunião de quinta-feira no horário que havíamos combinado anteriormente.",
         "deixa isso mais curto",
         "Pessoal, por causa de alguns imprevistos, não vamos conseguir fazer a reunião de quinta no horário combinado."),
        ("A apresentação do projeto será feita pela Carla amanhã às 14h, na sala de reuniões.",
         "quem vai apresentar o projeto amanhã",
         "Quem vai apresentar o projeto amanhã?"),
    ]

    /// The inserted material (never the prompt text above) is neutralised first (`PromptTags`): a
    /// selection can't close `<selecionado>` and pose as the `<fala>`. Text without tags is
    /// unchanged, so every prompt built from it is byte-identical (`testNoSelectionPromptIsUnchanged`).
    public static func wrap(_ transcript: String) -> String {
        "<fala>\(PromptTags.neutralize(transcript))</fala>"
    }

    public static func wrap(_ transcript: String, selection: String?) -> String {
        guard let selection else { return wrap(transcript) }
        return "<selecionado>\(PromptTags.neutralize(selection))</selecionado>\n<fala>\(PromptTags.neutralize(transcript))</fala>"
    }

    /// `selection` = text selected in the focused app (edit-by-voice); nil = plain dictation,
    /// whose prompt is exactly the one used before selections existed.
    public static func messages(for transcript: String, selection: String? = nil) -> [ChatTurn] {
        let system = selection == nil ? systemPrompt : systemPrompt + "\n\n" + selectionRules
        var turns = [ChatTurn(role: .system, content: system)]
        for ex in examples {
            turns.append(ChatTurn(role: .user, content: wrap(ex.fala)))
            turns.append(ChatTurn(role: .assistant, content: ex.texto))
        }
        if selection != nil {
            for ex in selectionExamples {
                turns.append(ChatTurn(role: .user, content: wrap(ex.fala, selection: ex.selecionado)))
                turns.append(ChatTurn(role: .assistant, content: ex.texto))
            }
        }
        turns.append(ChatTurn(role: .user, content: wrap(transcript, selection: selection)))
        return turns
    }

    // MARK: Read-only selection: answer about the text (shown in a panel, never pasted)

    public static let answerSystemPrompt = """
    Você é um assistente. A pessoa selecionou um texto na tela (entre <selecionado> e </selecionado>) e falou um pedido sobre esse texto (entre <fala> e </fala>; é uma transcrição automática e pode ter pequenos erros). Atenda o pedido: traduzir, resumir, explicar ou responder uma pergunta sobre o texto. A resposta aparece numa janelinha para a pessoa ler; ela não substitui o texto.
    - Pedido para TRANSFORMAR o texto (deixar mais formal ou informal, corrigir, reescrever, melhorar, encurtar, traduzir, resumir): devolva SOMENTE o texto transformado, pronto para usar no lugar do original. Não descreva o texto, não diga o que ele é ("O texto é uma mensagem…") e não explique o que mudou. Descreva ou explique o texto só quando a fala pedir uma explicação ("explica isso", "o que significa") ou fizer uma pergunta sobre ele.
      - Mais formal: não deixe nenhuma gíria nem cumprimento informal; use cumprimentos e agradecimentos formais.
    - Responda em português do Brasil, a menos que o pedido peça outro idioma. Num texto transformado (formal, informal, corrigido, reescrito), mantenha o idioma do texto. "Traduz" sem idioma: traduza para o português (se o texto já estiver em português, traduza para o inglês).
    - Perguntas sobre o conteúdo do texto (quem, quando, onde, quanto, o que aconteceu): responda só com o que está no texto. Se a resposta não está no texto, diga que o texto não informa isso, em uma frase, e não invente.
    - Explicar uma palavra, sigla, expressão ou o sentido de uma frase do texto: pode usar conhecimento geral, de forma breve e clara.
    - Resumo: 1 ou 2 frases, só com a ideia principal; deixe de fora detalhes, números secundários e listas.
    - Seja direto: só a resposta, sem repetir o pedido, sem introduções ("Claro!", "Aqui está") e sem markdown (listas simples são permitidas).
    """

    /// Few-shot examples for the answer mode (topics and phrasings unlike the eval cases).
    public static let answerExamples: [(selecionado: String, fala: String, texto: String)] = [
        ("The meeting has been moved to Friday at 3 PM due to a scheduling conflict.",
         "o que tá dizendo aqui",
         "A reunião foi remarcada para sexta-feira às 15h por causa de um conflito de agenda."),
        ("O pacote foi enviado ontem pelos Correios e deve chegar em até cinco dias úteis.",
         "qual é o código de rastreio",
         "O texto não informa o código de rastreio."),
        ("fala pessoal, amanhã não vai rolar o treino, foi mal aí",
         "deixa isso mais formal",
         "Olá a todos. Informo que o treino de amanhã foi cancelado. Peço desculpas pelo transtorno."),
    ]

    public static func answerMessages(for transcript: String, selection: String) -> [ChatTurn] {
        var turns = [ChatTurn(role: .system, content: answerSystemPrompt)]
        for ex in answerExamples {
            turns.append(ChatTurn(role: .user, content: wrap(ex.fala, selection: ex.selecionado)))
            turns.append(ChatTurn(role: .assistant, content: ex.texto))
        }
        turns.append(ChatTurn(role: .user, content: wrap(transcript, selection: selection)))
        return turns
    }

    // MARK: Language routing

    /// Portuguese ("pt", "pt-BR") keeps this file's prompt, byte for byte.
    static func isPortuguese(_ language: String) -> Bool {
        MultilingualPrompt.baseCode(language) == "pt"
    }

    /// `language` = the dictation's Whisper code (fixed, or detected in Automatic; "" = unknown).
    /// "pt" → the Portuguese prompt above (identical to `messages(for:selection:)`); any other
    /// language → `MultilingualPrompt` (English rules + that language's examples, none if it has none).
    public static func messages(for transcript: String, selection: String? = nil, language: String) -> [ChatTurn] {
        if isPortuguese(language) { return messages(for: transcript, selection: selection) }
        return MultilingualPrompt.messages(for: transcript, selection: selection, language: language)
    }

    public static func answerMessages(for transcript: String, selection: String, language: String) -> [ChatTurn] {
        if isPortuguese(language) { return answerMessages(for: transcript, selection: selection) }
        return MultilingualPrompt.answerMessages(for: transcript, selection: selection, language: language)
    }

    /// How much a CJK character (or full-width mark) weighs in the token budget, in Latin
    /// characters. Qwen3's tokenizer spends ~0.6–0.7 token on one, vs ~0.2–0.3 per Latin character
    /// (measured on zh, pt and en sentences), so it counts as 3 characters.
    public static let cjkCharacterWeight = 3

    /// The text's length for the token budget: its character count, with CJK characters weighed
    /// `cjkCharacterWeight` times. Text with no CJK (pt, en, es, fr…) counts exactly `count`.
    public static func budgetCharacters(_ text: String) -> Int {
        let cjk = text.unicodeScalars.reduce(0) { $0 + (CJK.isCJK($1) || CJK.isCJKPunctuation($1) ? 1 : 0) }
        return text.count + cjk * (cjkCharacterWeight - 1)
    }

    /// The budget for a dictation (selection nil) or an edit/answer: `budgetCharacters` of each.
    public static func maxTokens(transcript: String, selection: String?) -> Int {
        maxTokens(transcriptCharacters: budgetCharacters(transcript),
                  selectionCharacters: selection.map(budgetCharacters) ?? 0)
    }

    /// ~3× the input tokens (≈ chars/4), clamped to [256, 1024].
    public static func maxTokens(forInputCharacters count: Int) -> Int {
        min(1024, max(256, count * 3 / 4))
    }

    /// Edit-by-voice: the output can be as long as the selection (a translation, a rewrite), so the
    /// budget counts selection + speech and the ceiling is higher. Without a selection it is
    /// exactly `maxTokens(forInputCharacters:)`.
    public static func maxTokens(transcriptCharacters: Int, selectionCharacters: Int) -> Int {
        guard selectionCharacters > 0 else { return maxTokens(forInputCharacters: transcriptCharacters) }
        return min(2048, max(256, (transcriptCharacters + selectionCharacters) * 3 / 4))
    }
}
