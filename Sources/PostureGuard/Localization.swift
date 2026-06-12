import Foundation

enum AppLanguage: String {
    case system
    case chinese = "zh"
    case english = "en"
}

enum L10n {
    /// Set once at startup from Config, updated when the user switches.
    static var language: AppLanguage = .system

    static var isChinese: Bool {
        switch language {
        case .chinese: return true
        case .english: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

    static var speechLanguageCode: String { isChinese ? "zh-CN" : "en-US" }
}

/// Pick the localized variant of a user-facing string.
func tr(_ zh: String, _ en: String) -> String {
    L10n.isChinese ? zh : en
}
