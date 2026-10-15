// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class AppLanguageTests: XCTestCase {
    func testTheFiveLanguagesPlusSystem() {
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), ["system", "en", "pt-BR", "es", "fr", "zh-Hans"])
        XCTAssertEqual(AppLanguage.languages, [.en, .ptBR, .es, .fr, .zhHans])
    }

    func testNativeNames() {
        XCTAssertEqual(AppLanguage.en.nativeName, "English")
        XCTAssertEqual(AppLanguage.ptBR.nativeName, "Português (Brasil)")
        XCTAssertEqual(AppLanguage.es.nativeName, "Español")
        XCTAssertEqual(AppLanguage.fr.nativeName, "Français")
        XCTAssertEqual(AppLanguage.zhHans.nativeName, "简体中文")
        XCTAssertFalse(AppLanguage.system.nativeName.isEmpty)
    }

    func testWhisperCodes() {
        XCTAssertEqual(AppLanguage.languages.map(\.whisperCode), ["en", "pt", "es", "fr", "zh"])
        XCTAssertNil(AppLanguage.system.whisperCode)
        XCTAssertEqual(AppLanguage(whisperCode: "pt"), .ptBR)
        XCTAssertEqual(AppLanguage(whisperCode: "zh"), .zhHans)
        XCTAssertNil(AppLanguage(whisperCode: "de"))
    }

    func testAppleLanguagesValue() {
        XCTAssertNil(AppLanguage.system.appleLanguagesValue)
        XCTAssertEqual(AppLanguage.ptBR.appleLanguagesValue, ["pt-BR"])
        XCTAssertEqual(AppLanguage.zhHans.appleLanguagesValue, ["zh-Hans"])
    }

    func testResolvedFromPreferredLanguages() {
        XCTAssertEqual(AppLanguage.resolved(preferred: "pt-PT"), .ptBR)
        XCTAssertEqual(AppLanguage.resolved(preferred: "pt-BR"), .ptBR)
        XCTAssertEqual(AppLanguage.resolved(preferred: "zh-Hans-CN"), .zhHans)
        XCTAssertEqual(AppLanguage.resolved(preferred: "es-MX"), .es)
        XCTAssertEqual(AppLanguage.resolved(preferred: "fr-CA"), .fr)
        XCTAssertEqual(AppLanguage.resolved(preferred: "fr_CA"), .fr)
        XCTAssertEqual(AppLanguage.resolved(preferred: "en-GB"), .en)
        XCTAssertEqual(AppLanguage.resolved(preferred: "de-DE"), .en)
        XCTAssertEqual(AppLanguage.resolved(preferred: "zh-Hant-TW"), .en)
        XCTAssertEqual(AppLanguage.match("zh-Hans-HK"), .zhHans, "Simplified script, Hong Kong region")
        XCTAssertEqual(AppLanguage.match("zh_Hans_MO"), .zhHans)
        XCTAssertNil(AppLanguage.match("zh-HK"))
        XCTAssertNil(AppLanguage.match("zh-Hant"))
        XCTAssertEqual(AppLanguage.match("zh"), .zhHans)
        XCTAssertEqual(AppLanguage.resolved(preferred: ["de-DE", "es-ES"]), .es)
        XCTAssertEqual(AppLanguage.resolved(preferred: []), .en)
    }

    /// From the post-merge evals (docs/model-eval.md): Spanish is below 80% of its cases; the others
    /// pass every criterion.
    func testOnlySpanishIsBeta() {
        XCTAssertEqual(AppLanguage.allCases.filter(\.isDictationBeta), [.es])
        XCTAssertNotEqual(DictationLanguage.fixed(.es).title, AppLanguage.es.nativeName, "the picker marks it")
        XCTAssertEqual(DictationLanguage.fixed(.fr).title, AppLanguage.fr.nativeName)
    }

    // MARK: Dictation language

    func testDictationChoices() {
        XCTAssertEqual(DictationLanguage.allChoices.count, 6)
        XCTAssertEqual(DictationLanguage.allChoices.first, .automatic)
        for choice in DictationLanguage.allChoices {
            XCTAssertEqual(DictationLanguage(rawValue: choice.rawValue), choice)
        }
        XCTAssertNil(DictationLanguage(rawValue: "system"))
        XCTAssertNil(DictationLanguage(rawValue: "de"))
        XCTAssertNil(DictationLanguage.automatic.whisperCode)
        XCTAssertEqual(DictationLanguage.fixed(.zhHans).whisperCode, "zh")
    }

    func testDefaultDictationLanguageIsTheAppLanguage() {
        XCTAssertEqual(DictationLanguage.defaultChoice(appLanguage: .fr, systemPreferred: ["pt-BR"]), .fixed(.fr))
        XCTAssertEqual(DictationLanguage.defaultChoice(appLanguage: .system, systemPreferred: ["pt-BR", "en"]), .fixed(.ptBR))
        XCTAssertEqual(DictationLanguage.defaultChoice(appLanguage: .system, systemPreferred: ["es-419"]), .fixed(.es))
        // A system language that is not one of ours: Automatic.
        XCTAssertEqual(DictationLanguage.defaultChoice(appLanguage: .system, systemPreferred: ["de-DE", "en"]), .automatic)
        XCTAssertEqual(DictationLanguage.defaultChoice(appLanguage: .system, systemPreferred: []), .automatic)
    }

    func testPromptLanguageFollowsTheSpokenLanguage() {
        XCTAssertEqual(DictationLanguage.fixed(.ptBR).promptLanguage(detected: "en", confidence: nil), "pt")
        XCTAssertEqual(DictationLanguage.fixed(.ptBR).promptLanguage(detected: "pt", confidence: 0.1), "pt",
                       "a chosen pt-BR keeps the Portuguese prompt, whatever Whisper thinks")
        XCTAssertEqual(DictationLanguage.automatic.promptLanguage(detected: "de", confidence: nil), "de")
        XCTAssertEqual(DictationLanguage.automatic.promptLanguage(detected: nil, confidence: nil), "")
        XCTAssertEqual(DictationLanguage.automatic.promptLanguage(detected: "", confidence: 1), "")
    }

    /// Chinese text under another label (a short clip) still gets the Chinese prompt: under "en" the
    /// English examples translated it. A Japanese or Korean label is never overridden, and a chosen
    /// language still wins.
    func testAutomaticChineseTextIsChineseWhateverTheLabel() {
        let auto = DictationLanguage.automatic
        for label in ["en", "es", "pt", "zh", "", nil] as [String?] {
            XCTAssertEqual(auto.promptLanguage(detected: label, confidence: 0.45, transcript: "那我们周末去爬山吧"), "zh",
                           label ?? "nil")
        }
        // Chinese with English terms (Han characters outnumber the Latin words).
        XCTAssertEqual(auto.promptLanguage(detected: "en", confidence: 0.9, transcript: "我用Mac"), "zh")
        XCTAssertEqual(auto.promptLanguage(detected: "en", confidence: 0.9, transcript: "我觉得iPhone 15 Pro Max挺好"), "zh")
        // English with a Chinese name stays English.
        XCTAssertEqual(auto.promptLanguage(detected: "en", confidence: 0.9, transcript: "Please send it to 王伟 tomorrow"), "en")
        XCTAssertEqual(auto.promptLanguage(detected: "en", confidence: 0.9, transcript: "see you tomorrow"), "en")
        XCTAssertEqual(DictationLanguage.fixed(.en).promptLanguage(detected: "zh", confidence: nil, transcript: "你好吗"), "en")
        XCTAssertEqual(DictationLanguage.fixed(.ptBR).promptLanguage(detected: nil, confidence: nil, transcript: "你好吗"), "pt")
    }

    /// Japanese written in kanji only looks Chinese: a Japanese label keeps it (no zh prompt, no
    /// Simplified conversion).
    func testJapaneseOrKoreanLabelIsNeverForcedToChinese() {
        let auto = DictationLanguage.automatic
        for text in ["新宿駅", "会議室予約", "東京駅に着きました"] {
            XCTAssertEqual(auto.promptLanguage(detected: "ja", confidence: 0.99, transcript: text), "ja", text)
            XCTAssertEqual(auto.promptLanguage(detected: "ja", confidence: nil, transcript: text), "ja", text)
        }
        XCTAssertEqual(auto.promptLanguage(detected: "ko", confidence: nil, transcript: "會議室"), "ko")
        XCTAssertFalse(DictationLanguage.needsConfidence(detected: "ja", transcript: "新宿駅"))
    }

    func testChineseScriptNeedsTwoHanCharactersAndMoreThanTheLatinWords() {
        XCTAssertTrue(CJK.looksChinese("我用Mac"))
        XCTAssertTrue(CJK.looksChinese("我觉得iPhone 15 Pro Max挺好"))
        XCTAssertTrue(CJK.looksChinese("帮我review一下这个PR"))
        XCTAssertFalse(CJK.looksChinese("Please send it to 王伟 tomorrow"))
        XCTAssertFalse(CJK.looksChinese("好"))
        XCTAssertFalse(CJK.looksChinese("東京駅に着きました"), "kana")
        XCTAssertFalse(CJK.looksChinese("회의실 예약"), "Hangul")
        XCTAssertFalse(CJK.looksChinese("hello"))
    }

    /// Automatic: a label with a prompt of its own (pt, en, es, fr, zh) needs Whisper's confidence,
    /// else the neutral rules (its examples would pull a mislabeled transcript into its language).
    func testAutomaticLabelsWithExamplesNeedAConfidentLabel() {
        let auto = DictationLanguage.automatic
        XCTAssertEqual(auto.promptLanguage(detected: "pt", confidence: 0.97), "pt")
        XCTAssertEqual(auto.promptLanguage(detected: "pt", confidence: DictationLanguage.portugueseConfidence), "pt")
        XCTAssertEqual(auto.promptLanguage(detected: "pt", confidence: 0.79), "")
        XCTAssertEqual(auto.promptLanguage(detected: "pt", confidence: nil), "", "not measured = not trusted")
        for label in ["en", "es", "fr", "zh"] {
            XCTAssertEqual(auto.promptLanguage(detected: label, confidence: 0.97), label)
            XCTAssertEqual(auto.promptLanguage(detected: label, confidence: DictationLanguage.examplesConfidence), label)
            XCTAssertEqual(auto.promptLanguage(detected: label, confidence: 0.45), "", label)
            XCTAssertEqual(auto.promptLanguage(detected: label, confidence: nil), "", label)
            XCTAssertTrue(DictationLanguage.needsConfidence(detected: label), label)
        }
        // No examples: the neutral rules anyway, nothing to measure.
        XCTAssertEqual(auto.promptLanguage(detected: "de", confidence: nil), "de")
        XCTAssertFalse(DictationLanguage.needsConfidence(detected: "de"))
        XCTAssertFalse(DictationLanguage.needsConfidence(detected: nil))
        XCTAssertTrue(DictationLanguage.needsConfidence(detected: "pt"))
        // Chinese text: the script decides, the pass is skipped.
        XCTAssertFalse(DictationLanguage.needsConfidence(detected: "zh", transcript: "那我们周末去爬山吧"))
        XCTAssertFalse(DictationLanguage.needsConfidence(detected: "en", transcript: "那我们周末去爬山吧"))
    }
}

final class DictationLanguageUpgradeTests: XCTestCase {
    func up(_ keys: Set<String>) -> DictationLanguage? {
        DictationLanguage.upgradeDefault(persistedKeys: keys, settingsKeys: ["aiEnabled", "modelsConfirmed", "textModel"],
                                         dictationKey: "dictationLanguage", markerKey: "languagesIntroduced")
    }

    func testExistingInstallKeepsPortuguese() {
        XCTAssertEqual(up(["aiEnabled", "modelsConfirmed"]), .fixed(.ptBR))
    }

    func testNewInstallOrAlreadyUpgradedChangesNothing() {
        XCTAssertNil(up([]))
        // Keys AppKit may write before the settings are read (window frames, status item) are not ours.
        XCTAssertNil(up(["NSWindow Frame main", "NSStatusItem Preferred Position Item-0"]))
        XCTAssertNil(up(["aiEnabled", "languagesIntroduced"]))
        XCTAssertNil(up(["aiEnabled", "dictationLanguage"]))
    }

    func testTitles() {
        XCTAssertEqual(DictationLanguage.fixed(.fr).title, "Français")
        XCTAssertEqual(DictationLanguage.automatic.title, "Automatic")
    }
}
