import Foundation

enum AppLocalization {
    static var isKoreanPreferred: Bool {
        Locale.preferredLanguages.first?
            .lowercased()
            .hasPrefix("ko") == true
    }

    static var locale: Locale {
        Locale(identifier: isKoreanPreferred ? "ko" : "en")
    }

    static var documentLanguageCode: String {
        isKoreanPreferred ? "ko" : "en"
    }

    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }

    static func pick(korean: String, english: String) -> String {
        isKoreanPreferred ? korean : english
    }
}
