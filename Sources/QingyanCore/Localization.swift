import Foundation

/// The words input shows are written in US English in the source. `tr` gives them in the
/// language chosen in Settings: Simplified Chinese comes from `zh-Hans.json` in the app's
/// resources, a table from the English text to its translation. A string the table lacks is
/// shown in English, and so is everything where the table is not bundled (the checks).
public enum Localization {
    public enum Language: String, CaseIterable, Sendable {
        case english = "en"
        case simplifiedChinese = "zh-Hans"
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

    /// The language a setting stands for. "system" is Simplified Chinese when the first of the
    /// languages macOS prefers is any Chinese, and English otherwise.
    public static func resolve(_ setting: String, preferred: [String] = Locale.preferredLanguages) -> Language {
        if let chosen = Language(rawValue: setting) { return chosen }
        return preferred.first?.lowercased().hasPrefix("zh") == true ? .simplifiedChinese : .english
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
