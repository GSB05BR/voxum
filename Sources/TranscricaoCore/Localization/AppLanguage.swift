// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The languages of the app's interface (and of the dictation, see `DictationLanguage`).
/// Adding a language = one case here, its `<code>.lproj`, `Examples_<code>.swift` and its fixtures.
public enum AppLanguage: String, CaseIterable, Sendable {
    /// Follow the system's preferred languages (no `AppleLanguages` override in the app's domain).
    case system
    case en
    case ptBR = "pt-BR"
    case es
    case fr
    case zhHans = "zh-Hans"

    /// The real languages, without `.system`.
    public static let languages: [AppLanguage] = allCases.filter { $0 != .system }

    /// The name shown in the pickers, written in the language itself ("System" is localized).
    public var nativeName: String {
        switch self {
        case .system: return String(localized: "System", bundle: .main)
        case .en: return "English"
        case .ptBR: return "Português (Brasil)"
        case .es: return "Español"
        case .fr: return "Français"
        case .zhHans: return "简体中文"
        }
    }

    /// Whisper's language code (`DecodingOptions.language`); nil for `.system`.
    public var whisperCode: String? {
        switch self {
        case .system: return nil
        case .en: return "en"
        case .ptBR: return "pt"
        case .es: return "es"
        case .fr: return "fr"
        case .zhHans: return "zh"
        }
    }

    /// The value written to `AppleLanguages` (nil = remove the key, follow the system).
    public var appleLanguagesValue: [String]? {
        self == .system ? nil : [rawValue]
    }

    /// Dictation in this language is still marked "(beta)" in the pickers. Set from the post-merge
    /// evals (docs/model-eval.md): beta = under 80% of its cases, or any answered dictated question,
    /// or any translation. Spanish: 12/17 cases (71%).
    public var isDictationBeta: Bool { self == .es }

    /// The language a BCP-47 identifier ("pt-PT", "zh-Hans-CN", "es-MX", "fr_CA") belongs to, or
    /// nil when it is none of ours (e.g. "de", or Traditional Chinese).
    public static func match(_ identifier: String) -> AppLanguage? {
        let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
        guard let base = parts.first else { return nil }
        switch base {
        case "en": return .en
        case "pt": return .ptBR
        case "es": return .es
        case "fr": return .fr
        case "zh":
            let rest = Set(parts.dropFirst())
            if rest.contains("hans") { return .zhHans } // "zh-Hans-HK" is Simplified too
            if rest.contains("hant") || rest.contains("tw") || rest.contains("hk") || rest.contains("mo") { return nil }
            return .zhHans
        default: return nil
        }
    }

    /// The UI language the system picks for "System": the first of `preferred` that is one of
    /// ours, English (the development language) when none is, as Bundle does with the `.lproj`s.
    /// The default dictation language deliberately looks at the first preferred language only
    /// (`DictationLanguage.defaultChoice`): with ["de", "en"] the UI is English, but fixing
    /// dictation to English would transcribe German speech as English, so it stays Automatic.
    public static func resolved(preferred: [String]) -> AppLanguage {
        preferred.lazy.compactMap(match).first ?? .en
    }

    public static func resolved(preferred: String) -> AppLanguage {
        resolved(preferred: [preferred])
    }

    /// Whisper code → language ("pt" → `.ptBR`); nil for any other code.
    public init?(whisperCode: String) {
        guard let found = AppLanguage.languages.first(where: { $0.whisperCode == whisperCode.lowercased() }) else {
            return nil
        }
        self = found
    }
}

/// "Idioma do ditado": Whisper detects the language (`automatic`) or is told which one it is.
public enum DictationLanguage: Hashable, Sendable {
    case automatic
    case fixed(AppLanguage)

    /// The picker's options: Automatic, then the languages.
    public static let allChoices: [DictationLanguage] = [.automatic] + AppLanguage.languages.map { .fixed($0) }

    /// Persisted value: "auto" or the language's raw value ("pt-BR").
    public var rawValue: String {
        switch self {
        case .automatic: return "auto"
        case .fixed(let language): return language.rawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue == "auto" { self = .automatic; return }
        guard let language = AppLanguage(rawValue: rawValue), language != .system else { return nil }
        self = .fixed(language)
    }

    /// The picker's label: "Automatic" (localized) or the language's own name, "(beta)" when marked so.
    public var title: String {
        switch self {
        case .automatic: return String(localized: "Automatic", bundle: .main)
        case .fixed(let language):
            let name = language.nativeName
            return language.isDictationBeta ? String(localized: "\(name) (beta)", bundle: .main) : name
        }
    }

    /// Code for Whisper; nil = detect the language.
    public var whisperCode: String? {
        switch self {
        case .automatic: return nil
        case .fixed(let language): return language.whisperCode
        }
    }

    /// The default when the user never chose: the app's language. That is the language chosen in
    /// "App language"; with "System", the system's language (the first preferred one) when it is
    /// one of ours, else Automatic, even when a later preferred language sets the UI (see
    /// `AppLanguage.resolved`).
    public static func defaultChoice(appLanguage: AppLanguage, systemPreferred: [String]) -> DictationLanguage {
        if appLanguage != .system { return .fixed(appLanguage) }
        return systemPreferred.first.flatMap(AppLanguage.match).map { .fixed($0) } ?? .automatic
    }

    /// First launch of a version with languages: an existing install (its preferences domain has
    /// one of the app's own settings, `settingsKeys`, and none of the language ones) dictated in
    /// Portuguese, so it keeps Portuguese. A new install (only system-written keys, if any) or an
    /// explicit choice gets nil (no change).
    public static func upgradeDefault(persistedKeys: Set<String>, settingsKeys: Set<String>,
                                      dictationKey: String, markerKey: String) -> DictationLanguage? {
        guard !persistedKeys.isDisjoint(with: settingsKeys),
              !persistedKeys.contains(dictationKey), !persistedKeys.contains(markerKey) else { return nil }
        return .fixed(.ptBR)
    }

    /// Below this probability a "pt" label from Whisper's language ID does not get the Portuguese
    /// prompt in Automatic. That prompt says the speech is Brazilian Portuguese, and Qwen then
    /// translates a short Spanish or French clip mislabeled "pt" (fixtures/cases-mislabel.json).
    public static let portugueseConfidence = 0.8

    /// The same gate for the other labels with examples (en, es, fr, zh): their examples pull a
    /// mislabeled transcript into their language (Spanish labeled "en" came back in English,
    /// fixtures/cases-mislabel.json es-mislabel-en).
    public static let examplesConfidence = 0.8

    /// Japanese and Korean labels are never overridden by the Chinese-script rule: Japanese can be
    /// written in kanji only ("新宿駅").
    static let nonChineseCJKLabels: Set<String> = ["ja", "ko"]

    /// The confidence a label needs for its own prompt; nil = no gate (no examples: neutral rules).
    static func requiredConfidence(label: String) -> Double? {
        let base = MultilingualPrompt.baseCode(label)
        if base == "pt" { return portugueseConfidence }
        return MultilingualPrompt.exampleCodes.contains(base) ? examplesConfidence : nil
    }

    /// Chinese text whose label may be overridden to "zh" (any label but Japanese or Korean).
    static func isChineseOverride(detected: String?, transcript: String) -> Bool {
        !nonChineseCJKLabels.contains(MultilingualPrompt.baseCode(detected ?? "")) && CJK.looksChinese(transcript)
    }

    /// The language the text model writes in (the prompt's language code), the one routing rule:
    /// - a chosen language (`requested`) always wins, so a fixed pt-BR keeps the Portuguese prompt;
    /// - Automatic: a transcript written in Chinese (`CJK.looksChinese`) is "zh" whatever the label,
    ///   unless the label is Japanese or Korean: the script is certain where a short clip's label is
    ///   not, and under an "en" label the English examples translated it (zh-rotulado-en);
    /// - otherwise what Whisper detected; a label with a prompt of its own (pt, en, es, fr, zh) only
    ///   when Whisper is confident (`confidence` ≥ `requiredConfidence`, nil = not measured = not
    ///   confident), else "";
    /// - "" = the language-neutral rules with no examples (they keep the spoken language).
    public static func promptLanguage(requested: String?, detected: String?, confidence: Double?,
                                      transcript: String = "") -> String {
        if let requested { return requested }
        if isChineseOverride(detected: detected, transcript: transcript) { return "zh" }
        guard let detected, !detected.isEmpty else { return "" }
        if let required = requiredConfidence(label: detected), (confidence ?? 0) < required { return "" }
        return detected
    }

    /// Whether routing needs Whisper's confidence in this detected label: only a label with a prompt
    /// of its own, and not when the Chinese-script rule decides anyway. Measuring it costs one more
    /// encoder pass, paid only in Automatic (a chosen language never measures it).
    public static func needsConfidence(detected: String?, transcript: String = "") -> Bool {
        guard let detected, requiredConfidence(label: detected) != nil else { return false }
        return !isChineseOverride(detected: detected, transcript: transcript)
    }

    /// `promptLanguage(requested:detected:confidence:)` for this choice.
    public func promptLanguage(detected: String?, confidence: Double?, transcript: String = "") -> String {
        Self.promptLanguage(requested: whisperCode, detected: detected, confidence: confidence, transcript: transcript)
    }
}
