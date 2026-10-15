# French (fr)

> **Post-merge results:** see `docs/model-eval.md` ("Idiomas do ditado depois do merge"). This page is the language
> agent's pre-merge record (Task 3). Its scores, and the "re-run after the merge" notes, are superseded: the merge
> re-ran everything, and the cross-language mislabel cases (`*-mislabel-en`, `en-mislabel-es`, `zh-rotulado-en`) now
> live in `fixtures/cases-mislabel.json`.

Dictation language `fr` (Whisper code `fr`), UI `fr.lproj`, examples `Sources/TranscricaoCore/Text/Examples/Examples_fr.swift`,
cases `fixtures/cases-fr.json` (18), holdout `fixtures/holdout-fr.json` (2, committed before any tuning),
audio `fixtures/audio/fr/` (3 phrases, `say -v Thomas`).

## Verdict

**Not beta.** After tuning: cases 15/18 (83 %), holdout 2/2, 0 answered dictated questions, 0 translations.

## Prompt eval (Qwen3-4B-Instruct-2507 4-bit, `tcli eval … --lang fr`, through `scripts/with-eval-slot.sh`)

| Iteration | Change | Cases | Answered questions |
|---|---|---|---|
| 0 | stub (no French examples, rules only) | 7/18 | 1 ("Qui a écrit Les Misérables" → "Victor Hugo") |
| 1 | 9 dictation, 2 edit, 3 answer examples (pt-sized) | 14/18 | 0 |
| 2 | + layout example ("à la ligne" / "nouveau paragraphe") and a contrasting in-sentence "nouvelle ligne de tram"; + "plus poli" edit; + summary answer | 15/18 | 0 |
| 3 | + formal e-mail layout example (paragraphs only); summary example moved last, verb "résumer" | 16/18 | 0 |
| 4 | case `fr-commande-ligne` made stricter (see below); layout example uses "nouvelle ligne"; polite edit shows "je vous prie de m'excuser"; longer summary source | 16/18 | 0 |
| 5 | layout example moved last in the dictation list | 16/18 | 0 |
| 6 (final) | case `fr-hesitations` made stricter (see below); filler example keeps "je pense que" | **15/18** | **0** |

Final example set: 12 dictation, 3 edit and 4 answer examples, against pt's 9/2/3. The extras are the two layout examples, the in-sentence "nouvelle ligne de tram" contrast, the polite edit and the summary answer, each added for a failure in the table above.

Holdout (run after iteration 5, and again after the final iteration 6): **2/2** both times.

Latency: median 0.8–2.5 s per case, max ≈ 5 s (the read-only summary); the variation follows the load from the other evals running in parallel.

### Case changes made during tuning (both make the cases stricter, never looser)
- `fr-commande-ligne`: also rejects `"\n\nla reunion"`. Iteration 3 passed while writing a blank line for "nouvelle ligne"; the `esperado` always wanted a single line break.
- `fr-hesitations`: also requires `"crois"`. The `esperado` always kept "je crois que"; the output dropped it from iteration 1 on.
- Every case got `"lang": "fr"` (required by `EvalScorerLanguageTests.testLanguageFixturesDecode`; routing is unchanged, since `--lang fr` already gave them "fr").
- The holdout's only change after its first commit (3d397bc) is this `lang` field: `git diff 3d397bc HEAD -- fixtures/holdout-fr.json`.

### Remaining failures (final run)
1. `fr-hesitations`: "On pourrait décaler le point d'équipe à jeudi." The model treats "je crois que" as a filler and deletes it, changing the meaning (a hedge becomes a statement). The same happens in the holdout ("Je pense qu'on devrait…" → "On devrait…", which still passes there). A French example that keeps "je pense que" did not change it, so this needs a shared rule (see below).
2. `fr-commande-ligne`: "nouvelle ligne" vs "nouveau paragraphe" is unstable. Iterations 1, 2 and 4 wrote one line break for both commands; iterations 3, 5 and 6 wrote a blank line for both. The command words are never written, and the in-sentence "nouvelle ligne de produits" (`fr-ligne-dans-phrase`) stayed text in every iteration with examples. I kept the variant whose failure is more benign (an extra blank line after "Bonjour à tous,").
3. `fr-mislabel-en` (`lang: "en"`, confidence 0.4): "Rappelle-moi quand tu sors de la réunion." It stays French (no translation), but it paraphrases and drops "s'il te plaît". For an "en" label `DictationLanguage.promptLanguage` keeps "en" (confidence only matters for "pt"), so this case runs the English examples, which are empty in this worktree: **French examples cannot affect it. The merge agent should re-run it after `lang/en` is merged.**

### Passing cases worth a note
- `fr-mislabel-pt` (pt at 0.5 → neutral prompt, no examples): it passes but writes "Ne oublie pas" for the "n'oublie pas" Whisper gave, undoing the elision. Iteration 0 (no examples) did the same with "Je ai rendez-vous". See shared change 3.
- `fr-ed-formel`: iterations 1–3 produced unidiomatic formulas ("Je vous prie d'agréer mon salut", "Je vous en prie de votre compréhension"). From iteration 4 the polite edit example fixed it ("… Je vous prie de m'excuser.").
- `fr-ro-resumer`: summaries were 330–404 characters (3–4 sentences, against the 1–2 sentence rule) until iteration 4; from then on they come in under 320, but at 3 sentences. The pt prompt has the same known weakness (`ro-resumir`).
- Dictated questions (`fr-question-montagne`, `fr-question-auteur`, `fr-ed-question`, holdout `fr-ho-question-train`): transcribed with " ?" and never answered in any iteration with examples.

## Whisper WER (large-v3 turbo, `tcli wer fixtures/audio/fr/refs.json`)

| Mode | WER | Without accents | Median latency |
|---|---|---|---|
| `--lang fr` | 0.0 % (0/44, n=3) | 0.0 % | 0.48 s |
| `--lang auto` | 0.0 % (0/44, n=3) | 0.0 % | 0.51 s |

In Automatic mode all 3 clips were detected as `fr`. Their probability is not available ("p = ?"): the engine measures the confidence only when the detected label is "pt" (`DictationLanguage.needsConfidence`), and `tcli transcribe --lang auto` reports "p = ?" as well. Whisper wrote "14h30" and "3400 euros" (covered by `alts`) and "Bordeaux?" without the French space before "?" (the LLM step adds it). The TTS voice is clean speech, so this WER is a lower bound.

## UI strings (`fr.lproj`)
- All 172 keys of `en.lproj/Localizable.strings` plus `NSMicrophoneUsageDescription` are translated, with the placeholders kept; `LocalizationCompletenessTests` and the full `swift test --disable-keychain` pass.
- The wording follows macOS French: Réglages, Micro, Accessibilité, Autorisations, Placer dans le Dock, Masquer / Quitter / À propos de %@, Ouvrir avec la session (the Dock's own wording), Annuler, Échap, Go, « guillemets ».
- A non-breaking space (U+00A0) goes before `:` `;` `?` `!` `%` and inside « ».
- Truncation: I launched my own `build/Voxum.app` with `-AppleLanguages '(fr)'` and a temporary `VOXUM_DATA_DIR` (models absent), took a window-only screenshot of "Choisissez vos modèles", then killed only my own PID. Nothing is truncated. The main window cannot be reached without models, so I judged the rest by length against English.
- Longer strings: the recording HUD grows when editing (max 360 pt; "continu · modification de la sélection" fits), "Annuler la modification" is only the undo pill's accessibility label (the visible text is "Annuler"), and menu items size themselves.
- The sizes "~620 MB / ~2,7 GB" in that window come from the system byte formatter, which follows the region rather than the app language. A French-region Mac shows "Mo/Go", which matches the strings ("~2,4 Go de mémoire").

## Shared changes requested

1. **Keep opinion and hedge phrases** (in `MultilingualPrompt.dictationRules`, Fillers bullet). Proposed addition: *"Phrases that express opinion or uncertainty ("I think", "I believe", "maybe", and the same in the speaker's language) are part of the meaning, not fillers: keep them."*
   - Evidence: `fr-hesitations` drops "je crois que" in iterations 1–6, and the holdout drops "je pense que".
   - The examples cannot fix it: iteration 6 added an example that keeps "je pense que" and nothing changed.
   - The pt prompt keeps "eu acho que" (pt `hesitacoes`, `repeticao`), so this is a gap of the English rules, which list "I mean" among the fillers.
   - Risk: low. pt is untouched, and the rule only removes deletions.

2. **Single line vs blank line** (in `MultilingualPrompt.dictationRules`, Spoken layout commands bullet). Proposed wording: *""new line" … becomes exactly one line break (no blank line) and "new paragraph" becomes one blank line. Do not add line breaks or blank lines that were not dictated."*
   - Evidence: `fr-commande-ligne` flips between "both commands → single break" (iterations 1, 2, 4) and "both → blank line" (iterations 3, 5, 6), whichever example comes last.
   - Re-check `fr-ligne-dans-phrase` and the other languages' in-sentence cases after the change.

3. **Keep the language's elisions** (in `MultilingualPrompt.dictationRules`, Fix punctuation bullet). Proposed addition: *"keep the language's contractions and elisions exactly (never expand them)."*
   - Evidence: with the neutral prompt (no examples), "n'oublie pas" becomes "Ne oublie pas" (`fr-mislabel-pt`, every iteration), and with no French examples "j'ai" became "Je ai" (iteration 0, `fr-nom-propre`). With the French examples the elisions are correct.
   - It is generic, so it names no language (the tests forbid language names in the rules).
   - Priority: lower than 1 and 2; it matters only for Automatic misdetections and for languages without examples.

Not a shared change, but for the merge: **re-run `fr-mislabel-en` after merging the English examples**. It is routed to the "en" prompt, so its result here (rules only) says nothing about the merged state.
