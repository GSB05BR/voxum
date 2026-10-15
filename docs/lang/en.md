# English (en): dictation eval and notes

> **Post-merge results:** see `docs/model-eval.md` ("Idiomas do ditado depois do merge"). This page is the language
> agent's pre-merge record (Task 3). Its scores, and the "re-run after the merge" notes, are superseded: the merge
> re-ran everything, and the cross-language mislabel cases (`*-mislabel-en`, `en-mislabel-es`, `zh-rotulado-en`) now
> live in `fixtures/cases-mislabel.json`.

Prompt: `MultilingualPrompt` (shared English rules) + `Examples_en.swift`
(11 dictation, 2 edit, 4 answer examples; topics and phrasings unlike the eval inputs).
Model: Qwen3-4B-Instruct-2507 4-bit. Whisper: large-v3 turbo.

## Verdict

**Not beta.** Cases 14/16 (87.5%), holdout 2/2, zero answered dictated questions, zero translations.

## Eval scores

`scripts/with-eval-slot.sh swift run --disable-keychain -c release tcli eval fixtures/cases-en.json --lang en`

| Iteration | Examples | cases-en | Notes |
|---|---|---|---|
| 0 | none (Task 2 stub) | 10/16 as first written, **8/16** after tightening | list, question without "?", composition, money, summary failed |
| 1 | 9 dictation, 2 edit, 3 answer | 11/16 | fillers dropped "I think", new paragraph came out as one "\n", "2,300 dollars", summary too long, mislabel-pt |
| 2 | + "I guess" with fillers, "$1,450", a second "new paragraph", a summary answer | **14/16** | summary too long, mislabel-pt |
| 3 | summary example speech reworded | 14/16 | identical outputs (greedy decoding); tuning stopped |

Holdout (`fixtures/holdout-en.json`, written and committed before any tuning, run once after iteration 3): **2/2**.

Latency: median 1.0–1.9 s per case, max 5.3 s (read-only summary), with other agents' evals sharing the GPU.

### Case expectations changed (declared)

After iteration 0, two cases were tightened because they passed with a changed meaning:
- `en-fillers` passed with "Push the launch to next week." (lost "I think we should"); it now requires
  "i think we should push the launch to next week".
- `en-mislabel-pt` passed with "Send me the slides before the meeting on Thursday." (a question turned into an
  order); it now requires "can you send me the slides" and "?".

The iteration-0 score is given under both scorings.

### Remaining failures

1. `en-ro-summarize` (read-only "summarize this" on a six-sentence paragraph): the answer is three sentences
   (409–427 chars, limit 320) and keeps secondary numbers ($12 million, 18 months), against the answer rule
   "Summary: 1 or 2 sentences, only the main idea". A one-sentence summary example ("sum this up") did not change
   the output at all. The Portuguese prompt has the same known failure (`ro-resumir`). No content error and no
   translation; only the length.
2. `en-mislabel-pt` (English transcript labelled "pt" with p = 0.5): `DictationLanguage.promptLanguage` routes
   it to the neutral prompt (`""`), which has **no examples**, so `Examples_en` cannot affect it. Output:
   "Send me the slides before the meeting on Thursday." It stays English (no translation), but "Can you…?"
   becomes an order. See shared change 1.

### Mislabel cases

- `en-mislabel-pt` (pt, 0.5 → neutral prompt): English kept, no Portuguese, but the question is lost (above).
- `en-mislabel-es` (es, 0.42 → Spanish prompt, since only a "pt" label checks the confidence): passes,
  "Thanks so much for dinner last night. See you on Saturday." **In this worktree `Examples_es` is still the
  empty stub**, so this case ran with rules only. The merge agent must re-run it after `lang/es` lands: the
  Spanish examples could pull an English transcript towards Spanish.

## Whisper WER

3 clips, `say -v Samantha`, 16 kHz mono LEI16 (`fixtures/audio/en/`, refs in `refs.json`; "forty"/"40" and the
Oxford comma are accepted as alternatives).

| Mode | WER | Detected |
|---|---|---|
| `--lang en` (fixed) | **0.0%** (0/43) | n/a |
| `--lang auto` | **0.0%** (0/43) | en on 3/3, p = "?" |

p prints "?" because Whisper's confidence is only measured when the detected label is "pt"
(`DictationLanguage.needsConfidence`); English labels skip that extra encoder pass by design.

## UI strings

en.lproj is the base. Two values were polished (keys unchanged):
- "Pastes the text as spoken and uses no memory beyond the voice model. You can change this later in Settings."
- "No AI: the text is pasted exactly as spoken (no tidying, no editing of the selection) and the text model isn't
  loaded at all. Choose a model above to use the AI."

Screenshot: `build/Voxum.app` launched with `-AppleLanguages '(en)'` and an empty temporary `VOXUM_DATA_DIR`
shows the first-run "Choose your models" window (not the main window, since no model is confirmed in that data
dir). No truncation. One inconsistency, see shared change 3.

## Shared changes requested

1. **Questions on the neutral prompt** (rules or neutral-prompt routing; priority medium). With no examples,
   the rules alone drop a request's opening words and its "?": `en-mislabel-pt` "can you send me the slides
   before the meeting on thursday" → "Send me the slides before the meeting on Thursday." Iteration 0 (en, no
   examples) showed the same weakness: "hey can you tell me how long it takes…" → "how long does it take…"
   (no "?"), "which room is the quarterly review in" → no "?". Examples fix it for en (iterations 1–3), but the
   neutral prompt never gets examples. Proposed: one rule line in `dictationRules`, e.g. "A question or request
   phrased as a question ("can you…", "could you…") stays a question: keep its opening words and end it with a
   question mark." Re-run all non-pt evals plus `cases-mislabel.json`. Caution: commit f33d763 reverted a rule change because one extra quoted
   sentence in the rules cost the no-examples en eval 2 of 3 cases, so measure this line on the neutral prompt too.
2. **Summary length in the answer prompt** (priority low). "1 or 2 sentences" is not followed on a long
   paragraph (`en-ro-summarize`, 3 sentences, 427 chars), as with pt `ro-resumir`. Proposed: a hard length in
   `answerRules`, e.g. "Summary: at most 2 sentences and about 40 words".
3. **Decimal separator in the first-run window** (app code, priority low). With the UI in English and a
   Portuguese region, sizes from the byte formatter use the region's comma ("~2,1 GB", "Free on disk: 281,9 GB")
   while the localized strings hard-code a dot ("~2.4 GB of memory", "~0.3–0.6 GB"). The same window mixes both.
   Proposed: format the memory figures with the same formatter/locale (or pass them as `%@`), so the two agree.
