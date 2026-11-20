import Foundation

/// How a dictated text is written before it is entered: Raw is the transcript itself, Polish
/// tidies it within the words that were said, and Structured, Formal and custom styles rewrite
/// them — their output is used as returned, without a wording comparison or editing by voice.
public enum DictationStyle: Codable, Equatable, Sendable {
    case raw, polish, structured, formal
    /// A style the user wrote in Settings: its name in the menu, its instructions in the request.
    case custom(name: String, prompt: String)
}

/// One style the user wrote: a name for the menu and the instructions sent with each dictation.
public struct CustomStyle: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var prompt: String

    public init(id: UUID = UUID(), name: String = "", prompt: String = "") {
        self.id = id; self.name = name; self.prompt = prompt
    }

    /// Offered under Style only when both are filled in (after trimming).
    public var usable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let maxCount = 12, maxName = 40, maxPrompt = 4000
}

/// Between the stored preference id and the style itself.
public enum StyleChoice {
    /// Preference ids: "raw", "polish", "structured", "formal", or a custom style's id.uuidString.
    /// The switch this replaces was a Bool: on was Polish, off was Raw.
    public static func legacyID(polish: Bool) -> String { polish ? "polish" : "raw" }

    /// What a stored id names: the built-ins map directly; a usable custom style is found by its
    /// id; anything else — an unknown, deleted or unfinished id — is Polish, the old default.
    public static func resolve(_ id: String, customs: [CustomStyle]) -> DictationStyle {
        switch id {
        case "raw": return .raw
        case "structured": return .structured
        case "formal": return .formal
        default:
            if let custom = customs.first(where: { $0.id.uuidString == id && $0.usable }) {
                return .custom(name: custom.name.trimmingCharacters(in: .whitespacesAndNewlines),
                               prompt: custom.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .polish
        }
    }
}
