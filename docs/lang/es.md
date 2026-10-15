# Spanish (es): dictation eval, WER and UI strings

> **Post-merge results:** see `docs/model-eval.md` ("Idiomas do ditado depois do merge"). This page is the language
> agent's pre-merge record (Task 3). Its scores, and the "re-run after the merge" notes, are superseded: the merge
> re-ran everything, and the cross-language mislabel cases (`*-mislabel-en`, `en-mislabel-es`, `zh-rotulado-en`) now
> live in `fixtures/cases-mislabel.json`. After the merge `es-mislabel-en` was translated into English by the English examples; the Automatic confidence gate (fix round 1) stopped that.

Neutral Spanish that reads well in Spain and Latin America. Prompt: `MultilingualPrompt` (frozen English rules) +
`Sources/TranscricaoCore/Text/Examples/Examples_es.swift`. Model: Qwen3-4B-Instruct-2507 4-bit. Whisper: large-v3 turbo.

## Verdict: beta

**Beta = yes.** After tuning, cases are 13/18 (72%), below the 80% bar. There are zero answered dictated questions and no
translations in the final run (cases and holdout). Without the `en`-labelled mislabel case (see below), cases are
13/17 (76%), still below 80%, so the verdict is the same either way.

## Scores

`scripts/with-eval-slot.sh swift run --disable-keychain -c release tcli eval fixtures/cases-es.json --lang es`

| Iteration | Examples | Cases | Answered questions | Translation | Failing |
|---|---|---|---|---|---|
| 0 | none (empty stub, rules only) | 9/18 | 1 (`es-pregunta-huesos` → "El cuerpo humano tiene 206 huesos.") | no | muletillas, autocorreccion, pregunta-huesos, pregunta-telefono (no "¿…?"), ed-corregir, ed-pregunta (no "¿…?"), ro-traducir, ro-resumir, mislabel-en |
| 1 | 10 dictation, 2 edit, 3 answer | 13/18 | 0 | no | autocorreccion, ed-corregir, ro-traducir, ro-resumir, mislabel-en |
| 2 | + "X no Y" mid-sentence correction, spelling-fix edit, translate and summary answers | 13/18 | 0 | no | same 5 |
| 3 | correction example swapped for "del X no del Y", longer summary selection | 12/18 | 0 | no | same 5 + ed-formal (lost "mañana") |
| 4 (final, committed) | it2 set + one formal edit example ("que suene más profesional") | **13/18** | **0** | **no** | autocorreccion, ed-corregir, ro-traducir, ro-resumir, mislabel-en |

Holdout (`fixtures/holdout-es.json`, written and committed before any tuning, run once on the final examples): **2/2**,
0 answered questions (`es-h-pregunta-libro` came back as "¿Sabes quién escribió Cien años de soledad?", without
the author).

After the eval runs, I added `"lang": "es"` to every es case and to both holdout cases, because
`EvalScorerLanguageTests.testLanguageFixturesDecode` requires every case to name its language. Inputs and expectations
are unchanged, and routing is unchanged: a `lang` without `langConfidence` is the same as `--lang es`.

The examples made the largest difference: 9 → 13, every question now comes back with "¿…?", and 0 are answered.
After iteration 1 the failures stayed the same in every run, so they look like fixed model behaviour rather than
noise. I stopped tuning at iteration 4.

## Failures and why

- **`es-autocorreccion`** ("presupuesto del primer trimestre no del segundo trimestre"): the model keeps "primer
  trimestre" and drops the correction. This is the same failure as pt's known `correcao-no-meio`. In Spanish, "A, no B"
  without pauses is also the normal contrast construction ("Q1's budget, not Q2's"), so the transcript is ambiguous to
  the model. Two different "X no Y" examples did not move it. The case keeps the product rule ("X no Y" → Y).
- **`es-ed-corregir`** (homophone errors "haber si" / "a echo" / "vamos haber"): it fixes "vamos a ver" but writes
  "Habría si" and "hizo" in every run. pt's `ed-corrigir` is also a known failure. A spelling-fix edit example with
  other homophones (valla/vaya, ay/hay, hechar/echar) did not help. This looks like a limit of the 4B model.
- **`es-ro-traducir`**: the translation is in Spanish except "office" ("Nuestro nuevo office…"). In Spain, "office" is
  itself a loanword (a small pantry), so the model keeps it. The case accidentally tests a lexical trap rather than
  translation behaviour. I kept the case as written; this is not a translation failure.
- **`es-ro-resumir`**: 349–356 characters (limit 320). The model writes 3–4 sentences where the rule asks for 1–2.
  pt's `ro-resumir` fails the same way. A one-sentence summary example did not shorten the output.
- **`es-mislabel-en`** (Spanish transcript labelled `en`, p = 0.45): the model returns "Llámame cuando llegues a casa"
  instead of "Necesito que me llames cuando llegues a casa". It paraphrases, which is wrong, but it does not translate.
  Detected `en` routes to the `en` prompt whatever the confidence (only `pt` checks it). In this worktree,
  `Examples_en.swift` is the empty stub, so the case ran with rules only. My examples are not in that prompt. **This
  case does not yet test the post-merge state, where the real English examples will be present.** It already failed
  at iteration 0.
- `es-mislabel-pt` (labelled `pt`, p = 0.5 → neutral prompt, no examples) passes in every run: the output is Spanish
  and untranslated.
- Minor issue with no case failure: in `es-ed-formal` the model reads the selected "oye" as "Hoy" ("Hoy, mañana no
  podré asistir…"), and in iteration 3 this lost "mañana". The formal edit example in iteration 4 brought "mañana" back.

## Whisper WER

`swift run --disable-keychain -c release tcli wer fixtures/audio/es/refs.json --lang es` and `--lang auto`. Three `say` phrases, 16 kHz
mono LEI16: Mónica (es_ES) × 2 and Paulina (es_MX) × 1. They include a proper noun, a number and fillers with a
self-correction.

| Mode | WER | Detected |
|---|---|---|
| Fixed (`es`) | 0.0% (0/43), 0.0% without accents | n/a |
| Automatic | 0.0% (0/43), 0.0% without accents | `es` on all 3 clips, `p = ?` (tcli only measures the probability when the label is `pt`, per `DictationLanguage.needsConfidence`) |

Whisper writes "4320" and "5" as digits; `alts` in `refs.json` accept them. The first Whisper load in this worktree took
504 s (first-time model preparation while other agents were busy); the next load took 2.2 s.

## UI strings

`es.lproj/Localizable.strings` (172 keys) and `InfoPlist.strings` are fully translated. They use Apple macOS es wording
(Ajustes, Eliminar, Salir de %@, Ocultar %@, Acerca de %@, Abrir al iniciar sesión, Accesibilidad), "tú" form, and
neutral vocabulary. Placeholders are byte-exact. The app name is always `%@`. `LocalizationCompletenessTests` and
`scripts/check-strings.sh` pass.
- "Downloading the text model… %lld%%" → "… %lld %%" (Spanish puts a space before %).
- "raw" (the unorganized transcript) → "original", which is short and natural ("Copiar original", "Original: %@").
- Key-press verbs use "pulsar" ("Pulsa dos veces…", "pulsa ⌥"), not "tocar".

Screenshot: **skipped**. Launching a second app copy would install a second global right-⌥ hotkey next to the user's
running app, could raise permission prompts, and shares the real preferences domain, so it is not clearly safe. I
judged truncation from length instead. The longest short labels against en are "Abrir al iniciar sesión" (23 vs
13 characters), "Deshacer edición" (16 vs 9) and "Copiar original" (15 vs 8). All are standard Apple lengths.

## Shared changes requested

1. **Move the `en`-labelled Spanish mislabel shape into `fixtures/cases-mislabel.json`**, e.g. `{"lang": "en",
   "langConfidence": 0.45, "entrada": "necesito que me llames cuando llegues a casa"}`, with `naoDeveConter`
   ["call me", "home"]. Evidence: `es-mislabel-en` routes to the `en` prompt, whose examples only exist after the
   merge. It cannot be measured honestly in the es worktree. Today it fails by paraphrasing ("Llámame cuando llegues
   a casa"), not by translating. After the merge, the real English examples could pull it towards English, so it
   should be measured there. (It can stay in `cases-es.json` too; the merge agent decides.)
2. (Optional, low priority) **A summary-length guard in the answer rules**, e.g. "at most 2 sentences and about 200
   characters". Evidence: `es-ro-resumir` writes 3–4 sentences (349–356 characters) in every run, as pt's
   `ro-resumir` does, and a Spanish example did not fix it. The rule would go in `MultilingualPrompt.answerRules`,
   which leaves pt untouched but affects en, es, fr and zh, so it needs all four evals re-run. It is listed for the
   merge agent to evaluate, not as a requirement.
