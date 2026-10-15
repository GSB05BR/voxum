// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TranscricaoCore
import TranscricaoEngines

/// UserDefaults-backed preferences. Thread-safe reads (UserDefaults is).
final class Settings: @unchecked Sendable {
    static let shared = Settings()
    /// Preferences store. With `VOXUM_DATA_DIR` set (development, see ModelLocations) it is a
    /// separate suite, so a test run never changes the real preferences.
    static let store: UserDefaults = ModelLocations.dataDirOverride == nil
        ? .standard : UserDefaults(suiteName: AppIdentity.devDefaultsDomain) ?? .standard
    private let defaults = Settings.store

    private enum Key {
        static let aiEnabled = "aiEnabled"
        static let soundsEnabled = "soundsEnabled"
        static let textModel = "textModel"
        static let idleUnload = "idleUnloadMinutes"
        static let modelsConfirmed = "modelsConfirmed"
        static let dictationLanguage = "dictationLanguage"
        static let dictationKey = "dictationKey"
        static let questionKey = "questionKey"
        /// Set once the app knows about languages (see `DictationLanguage.upgradeDefault`).
        static let languagesIntroduced = "languagesIntroduced"
        /// Foundation's own key; read only from the app's domain (see `appLanguage`).
        static let appleLanguages = "AppleLanguages"
    }

    /// Name of `store`'s persistent domain (the app's bundle id, or the dev suite).
    static let storeDomain: String = ModelLocations.dataDirOverride == nil
        ? (Bundle.main.bundleIdentifier ?? AppIdentity.bundleID) : AppIdentity.devDefaultsDomain

    private init() {
        // Before languages existed every dictation was Portuguese: an existing install keeps it
        // instead of switching to the system language.
        let persisted = Set((defaults.persistentDomain(forName: Settings.storeDomain) ?? [:]).keys)
        let ownKeys: Set<String> = [Key.aiEnabled, Key.soundsEnabled, Key.textModel, Key.idleUnload,
                                    Key.modelsConfirmed, MainWindowController.shownKey]
        if let keep = DictationLanguage.upgradeDefault(persistedKeys: persisted, settingsKeys: ownKeys,
                                                      dictationKey: Key.dictationLanguage,
                                                      markerKey: Key.languagesIntroduced) {
            defaults.set(keep.rawValue, forKey: Key.dictationLanguage)
        }
        if !persisted.contains(Key.languagesIntroduced) { defaults.set(true, forKey: Key.languagesIntroduced) }
        defaults.register(defaults: [
            Key.aiEnabled: true,
            Key.soundsEnabled: true,
            Key.textModel: TextModelChoice.recommended.rawValue, // default decided in docs/model-eval.md
            Key.idleUnload: IdleUnloadPolicy.never.rawValue,
            Key.modelsConfirmed: false,
        ])
        // A saved model that left the catalog (Gemma 4 E4B) migrates to the recommended one.
        if let stored = defaults.string(forKey: Key.textModel),
           TextModelChoice(rawValue: stored) == nil {
            defaults.set(TextModelChoice.migrated(from: stored).rawValue, forKey: Key.textModel)
        }
    }

    /// "Organizar com IA": the quick on/off switch. Only meaningful with a text model chosen;
    /// read `aiActive` to decide whether a dictation goes through the model.
    var aiEnabled: Bool {
        get { defaults.bool(forKey: Key.aiEnabled) }
        set { defaults.set(newValue, forKey: Key.aiEnabled) }
    }

    /// The text model runs on a dictation: a model is chosen (not "Sem IA") and the switch is on.
    var aiActive: Bool { aiEnabled && textModel.usesAI }

    /// The user confirmed the model choice (first-run screen), or an existing install was
    /// recognized; the first-run screen is never shown again.
    var modelsConfirmed: Bool {
        get { defaults.bool(forKey: Key.modelsConfirmed) }
        set { defaults.set(newValue, forKey: Key.modelsConfirmed) }
    }

    var soundsEnabled: Bool {
        get { defaults.bool(forKey: Key.soundsEnabled) }
        set { defaults.set(newValue, forKey: Key.soundsEnabled) }
    }

    var textModel: TextModelChoice {
        get { TextModelChoice.migrated(from: defaults.string(forKey: Key.textModel)) }
        set { defaults.set(newValue.rawValue, forKey: Key.textModel) }
    }

    /// "App language": `AppleLanguages` in the app's own domain (`.system` = not set there).
    /// `defaults.array(forKey:)` would also see the global (system) list, so only the persistent
    /// domain is read. With `VOXUM_DATA_DIR` this is the dev suite, which Foundation does not
    /// read: dev runs choose a language with the `-AppleLanguages` launch argument instead.
    /// The app's domain has its own `AppleLanguages` (possibly one `appLanguage` reads as System).
    var hasAppLanguage: Bool {
        defaults.persistentDomain(forName: Settings.storeDomain)?[Key.appleLanguages] != nil
    }

    var appLanguage: AppLanguage {
        get {
            let domain = defaults.persistentDomain(forName: Settings.storeDomain) ?? [:]
            guard let first = (domain[Key.appleLanguages] as? [String])?.first else { return .system }
            return AppLanguage(rawValue: first) ?? AppLanguage.match(first) ?? .system
        }
        set {
            if let value = newValue.appleLanguagesValue {
                defaults.set(value, forKey: Key.appleLanguages)
            } else {
                defaults.removeObject(forKey: Key.appleLanguages)
            }
        }
    }

    /// "Dictation language"; never chosen = the app's language (Automatic when the system
    /// language is not one of ours).
    var dictationLanguage: DictationLanguage {
        get {
            defaults.string(forKey: Key.dictationLanguage).flatMap(DictationLanguage.init(rawValue:))
                ?? DictationLanguage.defaultChoice(appLanguage: appLanguage, systemPreferred: Locale.preferredLanguages)
        }
        set { defaults.set(newValue.rawValue, forKey: Key.dictationLanguage) }
    }

    /// The key held to dictate; never chosen (every install before the setting) = right ⌥.
    var dictationKey: TriggerKey {
        get { TriggerKey.saved(defaults.string(forKey: Key.dictationKey)) }
        set { defaults.set(newValue.rawValue, forKey: Key.dictationKey) }
    }

    /// The key held to ask the local model a question (spec §4); nil = Off, the default. Never the
    /// dictation key: a saved value equal to it reads as Off.
    var questionKey: TriggerKey? {
        get {
            TriggerKeyValidation.effectiveQuestion(saved: TriggerKeyValidation.savedQuestion(defaults.string(forKey: Key.questionKey)),
                                                   dictation: dictationKey)
        }
        set { defaults.set(newValue?.rawValue ?? TriggerKeyValidation.offValue, forKey: Key.questionKey) }
    }

    /// A text model can answer questions: anything but "No AI". The "Organize with AI" switch only
    /// concerns dictation (the model stays loaded when it is off), so it does not gate questions.
    var questionAvailable: Bool { textModel.usesAI }

    /// The keys the hotkey monitor watches.
    var watchedKeys: [TriggerKey] {
        TriggerKeyValidation.watchedKeys(dictation: dictationKey, question: questionKey, questionAvailable: questionAvailable)
    }

    /// The idle policy only if the user (or the chooser) saved one; nil = never chosen.
    var savedIdleUnload: IdleUnloadPolicy? {
        defaults.object(forKey: Key.idleUnload) == nil ? nil : idleUnload
    }

    var idleUnload: IdleUnloadPolicy {
        get { IdleUnloadPolicy(rawValue: defaults.integer(forKey: Key.idleUnload)) ?? .never }
        set { defaults.set(newValue.rawValue, forKey: Key.idleUnload) }
    }
}
