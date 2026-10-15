# Simplified Chinese (zh-Hans)

> **Post-merge results:** see `docs/model-eval.md` ("Idiomas do ditado depois do merge"). This page is the language
> agent's pre-merge record (Task 3). Its scores, and the "re-run after the merge" notes, are superseded: the merge
> re-ran everything, and the cross-language mislabel cases (`*-mislabel-en`, `en-mislabel-es`, `zh-rotulado-en`) now
> live in `fixtures/cases-mislabel.json`. Of the shared requests, 2 (Chinese-script routing), 3 (full-width scorer) and 4 ("No AI" conversion) were applied; 1 (verb-repeating correction) was measured and skipped (it made a French mislabel case translate).

Dictation language `zh-Hans` (Whisper code `zh`), examples in
`Sources/TranscricaoCore/Text/Examples/Examples_zh.swift`, UI in `Sources/Transcricao/Resources/zh-Hans.lproj`.

**Verdict: not beta.** Cases 20/21 (95%), holdout 2/2, 0 answered dictated questions, 0 unrequested translations.
One systematic failure remains (a verb-repeating self-correction, below); it needs a shared rule change.

## How to run

    scripts/with-eval-slot.sh swift run --disable-keychain -c release tcli eval fixtures/cases-zh-Hans.json --lang zh-Hans
    scripts/with-eval-slot.sh swift run --disable-keychain -c release tcli eval fixtures/holdout-zh-Hans.json --lang zh-Hans
    swift run --disable-keychain -c release tcli wer fixtures/audio/zh-Hans/refs.json --lang zh-Hans   # and --lang auto

- `eval --lang`: `zh-Hans` and `zh` are equivalent (`MultilingualPrompt.baseCode` maps both to `zh`, the same
  rules and examples). The app passes the Whisper code `zh`. Every case also carries `"lang": "zh"` (required by
  `testLanguageFixturesDecode`), except the two mislabel cases, which carry their wrong label.
- `wer --lang zh-Hans` goes through `AppLanguage.match` to `zh`.

## Cases (`fixtures/cases-zh-Hans.json`, 21)

Fillers (嗯/呃/那个), self-corrections (不对, 哦不是), a numbered list, three dictated questions (two
general-knowledge ones, one request), layout commands (换行 / 新段落), two in-sentence "new line"s that must stay
as text (微信里按回车……不会换行, 加新的一行), a composition command (帮我写一条消息……), two proper-noun
cases (GitHub/review/李伟, 杭州/阿里巴巴/陈总), three selection edits (formal, translate on request, dictation
with a selection), two read-only answers (summary, translation), two mislabelled-language cases (`lang` `en`
p 0.45 and `ja` p 0.5), and Whisper's own Traditional-script output with half-width punctuation
(這個週末我們……,你覺得怎麼樣).

Most cases also list Traditional characters in `naoDeveConter`, so Traditional output fails.

The Traditional-script case (`zh-tradicional-do-whisper`) was added after iteration 1. The WER run showed Whisper
writing Traditional characters for Simplified speech. Its expectations were not adjusted afterwards.
Two expectations were loosened before the first eval: `zh-correcao-no-meio` checks `楼会议室见面` (digits vs Han
numerals are both correct), and `zh-comando-mensagem` no longer requires `推迟` (a composed message may say 延期).

## Holdout (`fixtures/holdout-zh-Hans.json`, 2)

A 不对 correction of a weekday, and a question asked with a selection whose answer is in the selection (it must
come back as the question). Written and committed (548afdd) before any example existed, and first run after
tuning ended. Its only later commit (a4635b4) adds the `"lang": "zh"` schema field; the content is unchanged
(`git diff 548afdd a4635b4 -- fixtures/holdout-zh-Hans.json`).

## Iterations

| # | Examples change | Cases | Holdout |
|---|---|---|---|
| 1 | 10 dictation, 3 edit, 3 answer | 17/20 | not run |
| 2 | + 哦不是 correction with a trailing clause, + 新段落 alone, + "语气正式一些" edit | 19/21 (Traditional case added) | not run |
| 3 | + second 哦不是 example (李老师/周老师), + second 新段落 example | 20/21 | 2/2 |
| 3b | the 哦不是 example moved last (subset run) | no change, reverted | — |
| final | same as 3, cases with `"lang": "zh"` | **20/21** | **2/2** |

Iteration 1 failures were `zh-correcao-nome`, `zh-comando-layout` (新段落 became a comma, not a blank line) and
`zh-ed-formal` (哥们儿 kept). Iterations 2 and 3 fixed the last two.

The examples ended at 14 dictation / 4 edit / 3 answer, versus pt's 9 / 2 / 3. Three layout examples were needed
before 新段落 produced a blank line (one or two were not enough). The second 哦不是 example did not fix its case
and is kept only as a correct example. Latency stayed low.

Latency: median 0.9–1.6 s per case, max 4 s (a translation edit). No `<think>` leaks.

Every run was also checked with a throwaway script (not in the repo) for half-width `, . ? ! : ;` next to Han
characters and for Traditional characters. No occurrence in any zh-routed output. The scorer cannot see this
(see shared change 3).

## Failures and why

- **`zh-correcao-nome`** (fails 4/4 runs): `把报告发给王经理哦不是发给张经理今天下班前` → `把报告发给王经理，今天下班前。`
  The model drops the corrected clause and keeps the wrong recipient, the worst possible outcome. When the
  correction repeats the verb (`哦不是发给张经理`), the model reads it as a negation ("not to Zhang"). Two examples
  of exactly this shape (去南京哦不是去苏州, 通知一下李老师哦不是通知周老师……) and moving one to the end did
  not help. Corrections with `不对` (case and holdout), `应该说是` and a bare repeated term work. See shared change 1.
- **Mislabelled cases pass, but with degraded output.** `zh-rotulado-en` → `我们周末去爬山\n记得带上水和零食`
  (那/吧 dropped, a line break instead of `，`, no final `。`). `zh-rotulado-ja` has no final `。`. These routes get
  neither the zh examples nor the "Simplified characters" sentence. `DictationLanguage.promptLanguage` only
  neutralizes a low-confidence `pt`, so an `en` or `ja` label uses that language's prompt. Nothing in this worktree
  can change that. In this worktree `Examples_en` is empty, so **re-run `zh-rotulado-en` after the merge**:
  the English examples may pull it towards English. See shared change 2.
- Soft issues that pass: the formal edit keeps `那个` and `你` (`你好，那个报价单你办理完毕了吗？`). The read-only
  summary is close to a paraphrase (2 long sentences). `zh-comando-mensagem` writes a notice (`通知客户：……`)
  rather than a message addressed to the client.

## Whisper (`fixtures/audio/zh-Hans/`, 3 phrases, `say -v Tingting`)

`tcli wer` already scores Chinese per character (`WordErrorRate.words` puts every Han character in its own token
via `CJK.spacedOut`), so its "WER" for zh **is a CER**. No separate CER script and no CER mode are needed.

| Mode | CER | Detected | Notes |
|---|---|---|---|
| fixed `zh` | 9.4% (5/53) | — | all 5 errors are Traditional characters |
| auto | 9.4% (5/53) | `zh` on all 3, p = ? | `WhisperKitTranscriber` measures p only when `DictationLanguage.needsConfidence` (a `pt` label) |

Hypothesis of `tingting-03`: `你能不能把明天會議的資料發到我的郵箱?`, with Traditional 會議資發郵 and a half-width
`?`. With Traditional mapped to Simplified, the CER is **0% (0/53)**. `tingting-02` came out with digits
(`3500块`, `10号`, matched by `alts`) and a half-width `,`. Latency is about 0.7 s per phrase.

So Whisper turbo is accurate on clean zh speech, but its script and punctuation are inconsistent. With the AI on,
Qwen converts both (`zh-tradicional-do-whisper` passes). With "No AI", Traditional characters and half-width
punctuation are pasted as-is. See shared change 4.

## UI (`zh-Hans.lproj`)

All 172 keys of `Localizable.strings` and the `InfoPlist.strings` key are translated, and
`LocalizationCompletenessTests` passes. The wording follows Apple zh-Hans: 设置, 退出 %@, 关于 %@, 隐藏 %@, 拷贝,
粘贴, 撤销, 辅助功能, 麦克风, 登录时打开, 历史记录, 自动, 跟随系统, 最小化, 窗口, and 点按 for click. It uses
full-width punctuation and parentheses, `——` in sentences and spaces between Han and Latin text or digits. `%@ (beta)` →
`%@（测试版）`. The app name is always the `%@`.

**Screenshot: skipped (not safe).** At launch `AppEnvironment.bootstrap()` requests microphone access and prompts
for Accessibility. An ad-hoc-signed dev build at a new path would raise system TCC dialogs on the user's screen,
and those can outlive the process. **Truncation by width estimate instead** (Han glyph ≈ 1 em, Latin ≈ 0.55 em):
the median zh/en width ratio is 0.67, and 11 of 172 strings are wider than en. The widest are `No AI` → `不使用 AI`
(1.7×, a picker item next to the wider `Qwen3 4B（推荐）`), `System` → `跟随系统`, `%@ (beta)` → `%@（测试版）` and
`Downloading %@ (%lld of %lld)… %@` → `正在下载 %@（第 %lld 个，共 %lld 个）… %@` (1.2×, a status line). The risk is low.
A real screenshot should be taken with a signed build (`scripts/local.env`).

## Shared changes requested

1. **Correction rule, verb-repeating form.** In `MultilingualPrompt.dictationRules`, extend the "X, no Y" bullet,
   for example: *"The correction may repeat the verb ("send it to A, no, send it to B" → "send it to B"): a "no"
   followed by the same verb and a new term is a correction, not a negation."* Evidence: `zh-correcao-nome` fails
   in all 4 runs and keeps the wrong recipient. Examples alone do not fix it. Re-run all languages, since this rule
   is shared.
2. **Chinese under a wrong label.** The "Write Chinese in Simplified characters" sentence (and so the zh behaviour)
   depends on the label being `zh`. Proposed: add the sentence when the *transcript* contains Han characters
   (`CJK.containsCJK`), whatever the label, or neutralize any low-confidence label the way `pt` is. That would
   require measuring confidence for every label (≈ 0.3 s). Evidence: `zh-rotulado-en` and `zh-rotulado-ja` keep the
   language but lose punctuation and words. `testRulesNeverNameTheLanguage` / `testDictationRulesStateKeyRules` would
   need updating.
3. **Scorer cannot check full-width punctuation.** `EvalScorer.fold` is `.widthInsensitive`, so a `？` needle
   matches `?`. Proposed: when the case's language is `zh`, count half-width `, ? ! : ;` (and `.` at the end) next to
   a Han character as a failure, or add a strict needle field. Evidence: Whisper emits `,` and `?` (WER run). The
   model always converted them here, but nothing guards it.
4. **Whisper's Traditional output and "No AI".** In the transcription-only path, convert zh transcripts to
   Simplified (`String.applyingTransform(StringTransform("Hant-Hans"), reverse: false)`, which is Foundation and
   allowed in Core) and map half-width punctuation between Han characters to full-width. Optionally, bias Whisper
   with a Simplified prompt (e.g. `以下是普通话的句子。` as prompt tokens). Evidence: `tingting-03` has 5 Traditional
   characters out of 18 (CER 28% → 0% after mapping).
