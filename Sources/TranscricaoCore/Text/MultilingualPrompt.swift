// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Few-shot examples of one dictation language (one `Examples_<code>.swift` per language).
/// They must be native-quality and must not copy the eval inputs (`fixtures/cases-<code>.json`).
public struct LanguageExamples: Sendable {
    /// Plain dictation: raw speech → text to paste.
    public var dictation: [(input: String, output: String)]
    /// Edit by voice: selected text + spoken instruction (or dictation) → text that replaces it.
    public var edit: [(selected: String, speech: String, output: String)]
    /// Read-only selection: selected text + spoken request → answer shown in the panel.
    public var answer: [(selected: String, speech: String, output: String)]

    public init(dictation: [(input: String, output: String)] = [],
                edit: [(selected: String, speech: String, output: String)] = [],
                answer: [(selected: String, speech: String, output: String)] = []) {
        self.dictation = dictation
        self.edit = edit
        self.answer = answer
    }

    /// No examples: a detected language we have no examples for gets only the rules.
    public static let empty = LanguageExamples()
}

/// The prompt for every dictation language except Portuguese (which keeps `PromptBuilder`'s own
/// prompt, byte for byte): English rules carrying the same behaviour as the Portuguese prompt,
/// plus short examples in the spoken language. The rules are shared by all languages; a language
/// only tunes its examples.
public enum MultilingualPrompt {
    /// Languages with an `Examples_<code>.swift` (Whisper codes).
    public static let exampleCodes: Set<String> = ["en", "es", "fr", "zh"]

    /// "pt-BR" → "pt", "zh-Hans" → "zh", "EN" → "en"; "" stays "".
    public static func baseCode(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").lowercased()
            .split(separator: "-").first.map(String.init) ?? ""
    }

    /// Registry: the examples of a language; any unknown code gets the English ones.
    public static func examples(for code: String) -> LanguageExamples {
        switch baseCode(code) {
        case "en": return .en
        case "es": return .es
        case "fr": return .fr
        case "zh": return .zh
        default: return .en
        }
    }

    /// The examples the prompt uses: a language without examples gets none (English examples
    /// would pull a German or Japanese dictation towards English).
    static func promptExamples(for code: String) -> LanguageExamples {
        exampleCodes.contains(baseCode(code)) ? examples(for: code) : .empty
    }

    // MARK: Rules (frozen: a change here affects every non-Portuguese language; re-run all evals)
    //
    // The rules never name the language: in Automatic, Whisper may label a short clip with the wrong
    // language, and a named language makes the model translate the transcript into it. The output
    // language always follows the transcript; the examples show what the language looks like.

    public static func dictationRules(language code: String) -> String {
        // Whisper writes Chinese in either script; v1 ships Simplified Chinese.
        let script = baseCode(code) == "zh" ? " Write Chinese in Simplified characters." : ""
        return """
        You are a dictation editor. Between <speech> and </speech> you receive the raw automatic transcript of what a person said, in any language. Return the text they want typed.
        Always write in the same language as the transcript. Never translate, unless the speech explicitly asks for a translation.\(script)

        DICTATION mode (default):
        - Rewrite the speech as the final text the person meant to write.
        - Apply the corrections they make while speaking ("no, I meant…", "actually…", "rather…", "scratch that", "correction…", and the same phrases in the speaker's language): keep only the corrected version.
        - Remove hesitations, repetitions and filler words ("uh", "um", "like", "you know", "I mean", and the fillers of the speaker's language).
        - When the person corrects the term right before with "X, no Y" (a "no" followed by a new term in the same place), the right version is Y: replace X with Y and drop that "no" ("in the blue room no in the green room" → "in the green room"). A "no" or "not" that negates a verb ("I went, but I didn't like it") is part of the meaning and must be kept.
        - Fix punctuation, accents and capitalization, following the conventions of the speaker's language. Write numbers as digits (two thousand three hundred → 2,300, with that language's separators), amounts of money with the currency symbol, and times and dates in the natural way.
        - Do not change the meaning, do not add information, do not summarize and do not answer questions: if the speech is a question, return the question written down. Dictated general-knowledge questions must be transcribed as questions, NEVER answered.
        - Greetings and thanks ("thanks", "good morning", "see you") are dictation too: transcribe what was said; never reply to the person.
        - Spoken layout commands: "new line" (or the same command in the speaker's language) becomes a line break and "new paragraph" becomes a blank line between paragraphs. Do not write the command words themselves.
        - Lists: when the speech starts by announcing a list (for example "list of…", "tasks for…", "items for…", "things to…", "ingredients…") and then enumerates loose items, write the title with a colon on the first line and a numbered list with one item per line ("1. Item"), even if the person does not say the numbers. Always use numbers (1., 2., 3.), never hyphens or other bullets. Items mentioned inside an ordinary sentence ("I bought bread and milk") stay as running text.

        COMMAND mode (only when the speech explicitly asks you to compose, write, generate, draft, rewrite, list or translate a text — for example "create a message…", "write an email…", "translate…"):
        - Produce the requested text, in the tone, length and language requested (the speaker's language unless another language is requested). Do not invent names or signatures.

        When in doubt, it is DICTATION.
        Reply ONLY with the final text, ready to paste: no quotes, no markdown (simple numbered lists are allowed), no comments and no explanation of what you did.
        """
    }

    public static func selectionRules(language code: String) -> String {
        """
        Selected text: sometimes the message contains, between <selected> and </selected>, a text the person selected on the screen, followed by the <speech>. What you return will REPLACE the selected text. First decide whether the speech is an INSTRUCTION to change the selected text or a DICTATION.
        - INSTRUCTION (the speech tells you to change the text: "improve this text", "make it more formal", "translate it into English", "fix the mistakes", "summarize", "turn it into bullet points"): apply the instruction to the whole selected text and return ONLY the edited text, complete. Keep the language of the selected text, unless the instruction asks for a translation. Do not add information that is not in the text.
          - Fix: correct every wrong word (spelling, accents, agreement, words wrongly joined or split), without removing or changing anything else.
          - More formal: leave no slang, abbreviation or informal greeting; use formal greetings and thanks.
          - Summarize: 1 to 3 short sentences, with only the main points.
        - DICTATION (any other speech: a message, a sentence, a question): discard the selected text and return only the speech written down, with the rules of DICTATION mode, in the language of the speech.
        - Questions ("what time…", "which…", "who…", "when…", "where…", "how much…", and the same in the speaker's language) are always DICTATION: return the question itself written down, with its question mark, and NEVER the answer, even if the answer is in the selected text.
        - When in doubt, it is DICTATION. Never comment on or explain the edit and never write the <selected> or <speech> tags.
        """
    }

    public static func answerRules(language code: String) -> String {
        let fallbackTarget = baseCode(code) == "en" ? "Spanish" : "English"
        return """
        You are an assistant. The person selected a text on the screen (between <selected> and </selected>) and spoke a request about this text (between <speech> and </speech>; it is an automatic transcript and may contain small errors). Fulfil the request: translate, summarize, explain or answer a question about the text. The answer appears in a small panel for the person to read; it does not replace the text.
        - A request to TRANSFORM the text (make it more formal or informal, fix, rewrite, improve, shorten, translate, summarize): return ONLY the transformed text, ready to use in place of the original. Do not describe the text, do not say what it is ("The text is a message…") and do not explain what changed. Describe or explain the text only when the speech asks for an explanation ("explain this", "what does it mean") or asks a question about it.
          - More formal: leave no slang nor informal greeting; use formal greetings and thanks.
        - Answer in the language of the spoken request, unless the request asks for another language. In a transformed text (formal, informal, fixed, rewritten), keep the language of the text. "Translate" with no language: translate into the language of the request (if the text is already in that language, translate it into \(fallbackTarget)).
        - Questions about the content of the text (who, when, where, how much, what happened): answer only with what is in the text. If the answer is not in the text, say that the text does not say so, in one sentence, and do not make anything up.
        - Explaining a word, acronym, expression or the meaning of a sentence of the text: you may use general knowledge, briefly and clearly.
        - Summary: 1 or 2 sentences, only the main idea; leave out details, secondary numbers and lists.
        - Be direct: only the answer, without repeating the request, without introductions ("Sure!", "Here it is") and without markdown (simple lists are allowed).
        """
    }

    // MARK: Messages

    /// The material is neutralised first (`PromptTags`): a selection can't close its tag and pose
    /// as the speech. Text without tags is unchanged.
    public static func wrap(_ speech: String, selection: String? = nil) -> String {
        let speech = PromptTags.neutralize(speech)
        guard let selection else { return "<speech>\(speech)</speech>" }
        return "<selected>\(PromptTags.neutralize(selection))</selected>\n<speech>\(speech)</speech>"
    }

    /// Dictation, or edit by voice when `selection` is set (same shape as the Portuguese prompt:
    /// rules, dictation examples, edit examples with a selection, then the speech).
    public static func messages(for transcript: String, selection: String?, language code: String) -> [ChatTurn] {
        messages(for: transcript, selection: selection, language: code, examples: promptExamples(for: code))
    }

    static func messages(for transcript: String, selection: String?, language code: String,
                         examples ex: LanguageExamples) -> [ChatTurn] {
        var system = dictationRules(language: code)
        if selection != nil { system += "\n\n" + selectionRules(language: code) }
        var turns = [ChatTurn(role: .system, content: system)]
        for e in ex.dictation {
            turns.append(ChatTurn(role: .user, content: wrap(e.input)))
            turns.append(ChatTurn(role: .assistant, content: e.output))
        }
        if selection != nil {
            for e in ex.edit {
                turns.append(ChatTurn(role: .user, content: wrap(e.speech, selection: e.selected)))
                turns.append(ChatTurn(role: .assistant, content: e.output))
            }
        }
        turns.append(ChatTurn(role: .user, content: wrap(transcript, selection: selection)))
        return turns
    }

    /// Read-only selection: the answer prompt.
    public static func answerMessages(for transcript: String, selection: String, language code: String) -> [ChatTurn] {
        answerMessages(for: transcript, selection: selection, language: code, examples: promptExamples(for: code))
    }

    static func answerMessages(for transcript: String, selection: String, language code: String,
                               examples: LanguageExamples) -> [ChatTurn] {
        var turns = [ChatTurn(role: .system, content: answerRules(language: code))]
        for e in examples.answer {
            turns.append(ChatTurn(role: .user, content: wrap(e.speech, selection: e.selected)))
            turns.append(ChatTurn(role: .assistant, content: e.output))
        }
        turns.append(ChatTurn(role: .user, content: wrap(transcript, selection: selection)))
        return turns
    }
}
