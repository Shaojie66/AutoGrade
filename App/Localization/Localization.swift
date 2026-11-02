import Foundation
import Observation

/// The two languages the interface has copy for.
enum Language: String, Sendable {
    case english, simplifiedChinese
}

/// What Settings offers: follow the system, or pin a language.
enum LanguageSetting: String, CaseIterable, Sendable {
    case system, english, simplifiedChinese
}

/// The interface language, observable so that changing it in Settings repaints
/// every view at once — no relaunch (CLAUDE.md, App/Localization). Views never
/// read this directly; they call `L(_:)`, which reads `language` and so
/// registers the dependency inside whatever body is being evaluated.
@MainActor @Observable
final class Localization {
    static let shared = Localization(defaults: .standard)
    static let key = "language"

    var setting: LanguageSetting {
        didSet {
            guard setting != oldValue else { return }
            defaults.set(setting.rawValue, forKey: Self.key)
            language = Self.resolve(setting, preferred: preferred())
        }
    }
    private(set) var language: Language
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferred: () -> [String]

    /// `defaults` and `preferred` are injectable so tests own their inputs and
    /// never touch the app's real settings.
    init(defaults: UserDefaults, preferred: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.preferred = preferred
        let stored = defaults.string(forKey: Self.key).flatMap(LanguageSetting.init(rawValue:)) ?? .system
        setting = stored
        language = Self.resolve(stored, preferred: preferred())
    }

    func text(_ copy: Copy) -> String {
        language == .simplifiedChinese ? copy.zh : copy.en
    }

    /// Simplified Chinese for zh-Hans / zh-CN / zh-SG / bare zh; everything
    /// else, including zh-Hant, gets English rather than the wrong script.
    static func resolve(_ setting: LanguageSetting, preferred: [String]) -> Language {
        switch setting {
        case .english: return .english
        case .simplifiedChinese: return .simplifiedChinese
        case .system:
            for id in preferred {
                let lower = id.lowercased()
                if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") { return .english }
                if lower.hasPrefix("zh") { return .simplifiedChinese }
                if lower.hasPrefix("en") { return .english }
            }
            return .english
        }
    }
}

/// One piece of interface copy in both languages.
struct Copy: Sendable {
    let en: String
    let zh: String
}

@MainActor func L(_ copy: Copy) -> String {
    Localization.shared.text(copy)
}
