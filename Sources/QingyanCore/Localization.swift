import Foundation

/// The words out shows are written in US English in the source. `tr` gives them in the
/// language chosen in Settings, the eleven of the website (user 2026-11-25): each other language
/// comes from `<code>.json` in the app's resources (`de.json`, `zh-Hans.json`…), a table from the
/// English text to its translation. A string the table lacks is shown in English, and so is
/// everything where the table is not bundled (the checks).
public enum Localization {
    /// In the website's order. Brazilian Portuguese, as the website's; Traditional Chinese in
    /// Taiwan's usage.
    public enum Language: String, CaseIterable, Sendable {
        case german = "de"
        case english = "en"
        case spanish = "es"
        case french = "fr"
        case hindi = "hi"
        case japanese = "ja"
        case korean = "ko"
        case portuguese = "pt-BR"
        case russian = "ru"
        case simplifiedChinese = "zh-Hans"
        case traditionalChinese = "zh-Hant"

        /// Its own name, the same in every language (escaped: outside the packs the sources hold no
        /// other script than Latin, which tools/mirror.sh checks).
        public var nativeName: String {
            switch self {
            case .german: return "Deutsch"
            case .english: return "English"
            case .spanish: return "Espa\u{F1}ol"
            case .french: return "Fran\u{E7}ais"
            case .hindi: return "\u{939}\u{93F}\u{928}\u{94D}\u{926}\u{940}"
            case .japanese: return "\u{65E5}\u{672C}\u{8A9E}"
            case .korean: return "\u{D55C}\u{AD6D}\u{C5B4}"
            case .portuguese: return "Portugu\u{EA}s"
            case .russian: return "\u{420}\u{443}\u{441}\u{441}\u{43A}\u{438}\u{439}"
            case .simplifiedChinese: return "\u{7B80}\u{4F53}\u{4E2D}\u{6587}"
            case .traditionalChinese: return "\u{7E41}\u{9AD4}\u{4E2D}\u{6587}"
            }
        }

        /// What joins the items of a list: an ideographic comma in Chinese and Japanese.
        public var listSeparator: String {
            switch self {
            case .simplifiedChinese, .traditionalChinese, .japanese: return "\u{3001}"
            default: return ", "
            }
        }

        /// The language a macOS language identifier stands for, if out has it: "de-DE" is German,
        /// "pt-PT" Portuguese (Brazil's), "zh-Hant-HK" or "zh-TW" Traditional Chinese, "zh" or
        /// "zh-Hans-CN" Simplified.
        public static func matching(_ identifier: String) -> Language? {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            guard let base = parts.first else { return nil }
            // The script (four letters) and the region (two letters, or three digits); what follows
            // "x" is private use and says neither.
            let fields = parts.dropFirst().prefix { $0 != "x" }
            let script = fields.first { $0.count == 4 }
            let region = fields.first { $0.count == 2 || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }
            switch base {
            case "zh":
                // The script says it; without one, Taiwan, Hong Kong and Macau write Traditional.
                if script == "hant" { return .traditionalChinese }
                if script == "hans" { return .simplifiedChinese }
                return ["tw", "hk", "mo"].contains(region ?? "") ? .traditionalChinese : .simplifiedChinese
            case "pt": return .portuguese
            default: return allCases.first { $0.rawValue == base }
            }
        }
    }

    /// The setting's values: "system" follows macOS, the others name a language.
    public static let followSystem = "system"

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var active = Language.english
        var tables: [Language: [String: String]] = [:]
    }
    private static let state = State()

    public static var current: Language {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.active
    }

    /// Posted after `use` changes the language, for words that were kept as text and must be
    /// made again.
    public static let didChange = Notification.Name("local.hopo.qingyan.language")

    public static func use(_ language: Language) {
        state.lock.lock()
        let changed = state.active != language
        state.active = language
        state.lock.unlock()
        if changed { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// The language a setting stands for. "system" is the first of the languages macOS prefers
    /// that out has (user 2026-11-25: down the list, not only its first), and English when it has
    /// none of them.
    public static func resolve(_ setting: String, preferred: [String] = Locale.preferredLanguages) -> Language {
        if let chosen = Language(rawValue: setting) { return chosen }
        return preferred.lazy.compactMap(Language.matching).first ?? .english
    }

    /// Installs a table directly; the app reads its own from the bundle when first needed.
    public static func install(_ table: [String: String], for language: Language) {
        state.lock.lock(); state.tables[language] = table; state.lock.unlock()
    }

    public static func text(_ english: String) -> String {
        state.lock.lock()
        let language = state.active
        if language == .english { state.lock.unlock(); return english }
        if state.tables[language] == nil { state.tables[language] = load(language) }
        let found = state.tables[language]?[english]
        state.lock.unlock()
        return found ?? english
    }

    private static func load(_ language: Language) -> [String: String] {
        guard let url = Bundle.main.url(forResource: language.rawValue, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }
}

/// A string the user reads, written in English and shown in the chosen language.
public func tr(_ english: String) -> String { Localization.text(english) }

/// The same, for a format: `%@` for text, `%ld` for an Int. A translation may reorder the
/// arguments with `%1$@`, `%2$@`. A literal percent sign in a format is written `%%`.
public func tr(_ english: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.text(english), arguments: arguments)
}
