import Foundation

/// The key that starts and stops a recording: a tap of Fn (the default), a tap of one Command key on
/// its own, or a key with modifiers. Chosen by clicking the shortcut on the panel and pressing the
/// new one (asked for by the user on 2026-11-19), and kept in the preferences as a short string.
public enum Shortcut: Equatable, Sendable {
    case fn
    case commandTap(right: Bool)
    case combination(code: Int, modifiers: Modifiers)

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// What a key pressed while recording a new shortcut comes to.
    public enum Verdict: Equatable, Sendable {
        case accept(Shortcut)
        case refuse(String)
    }

    /// The F keys, which may be the shortcut on their own.
    public static let functionKeys: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// Keys whose name is a symbol, as in macOS menus.
    private static let symbols: [Int: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// For each modifier key, the device-dependent flag bit that says whether that very key is down.
    public static let modifierBits: [Int: UInt64] = [
        55: 0x08, 54: 0x10,          // left / right Command
        56: 0x02, 60: 0x04,          // left / right Shift
        58: 0x20, 61: 0x40,          // left / right Option
        59: 0x01, 62: 0x2000,        // left / right Control
        63: 0x800000,                // Fn
    ]

    public init?(stored: String) {
        switch stored {
        case "fn": self = .fn
        case "control-option-space": self = .combination(code: 49, modifiers: [.control, .option])
        case "right-command": self = .commandTap(right: true)
        case "left-command": self = .commandTap(right: false)
        default:
            let parts = stored.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "key", let code = Int(parts[1]), (0..<128).contains(code),
                  let raw = Int(parts[2]), (0..<16).contains(raw),
                  // A stored combination follows the same rules as one recorded: no bare letter, no Control + Option + V.
                  case .accept(let shortcut) = Self.recorded(code: code, modifiers: Modifiers(rawValue: raw)) else { return nil }
            self = shortcut
        }
    }

    public var stored: String {
        switch self {
        case .fn: return "fn"
        case .commandTap(let right): return right ? "right-command" : "left-command"
        case .combination(let code, let modifiers):
            // The combination of earlier versions keeps its old name.
            if code == 49 && modifiers == [.control, .option] { return "control-option-space" }
            return "key:\(code):\(modifiers.rawValue)"
        }
    }

    /// The shortcut as shown on the panel; `keyName` says what a character key types in the current
    /// keyboard layout.
    public func label(keyName: (Int) -> String?) -> String {
        switch self {
        case .fn: return "fn"
        case .commandTap(let right): return right ? tr("Right ⌘") : tr("Left ⌘")
        case .combination(let code, let modifiers):
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("⌃") }
            if modifiers.contains(.option) { parts.append("⌥") }
            if modifiers.contains(.shift) { parts.append("⇧") }
            if modifiers.contains(.command) { parts.append("⌘") }
            parts.append(Self.name(of: code, keyName: keyName))
            return parts.joined(separator: " ")
        }
    }

    static func name(of code: Int, keyName: (Int) -> String?) -> String {
        if let name = functionKeys[code] { return name }
        if code == 49 { return tr("Space") }
        if let symbol = symbols[code] { return symbol }
        if let name = keyName(code)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return name.uppercased()
        }
        return "#\(code)"
    }

    /// A key pressed, with these modifiers, while a new shortcut is being recorded.
    public static func recorded(code: Int, modifiers: Modifiers) -> Verdict {
        if code == 53 { return .refuse(tr("Esc cancels a recording, so it cannot start one. Choose another key.")) }
        if code == 9 && modifiers == [.control, .option] {
            return .refuse(tr("Control + Option + V types the clipboard. Choose another key."))
        }
        if functionKeys[code] != nil { return .accept(.combination(code: code, modifiers: modifiers)) }
        // On its own, or with Shift or Command only, a key types or is an app's shortcut.
        guard !modifiers.isDisjoint(with: [.control, .option]) else {
            return .refuse(tr("Add Control or Option to this key, or use an F key. On its own, or with only Shift or Command, the key belongs to typing and to apps."))
        }
        return .accept(.combination(code: code, modifiers: modifiers))
    }

    /// A modifier key pressed and let go on its own while a new shortcut is being recorded.
    public static func recordedTap(code: Int) -> Verdict {
        switch code {
        case 63: return .accept(.fn)
        case 54: return .accept(.commandTap(right: true))
        case 55: return .accept(.commandTap(right: false))
        // Shift alone switches input methods, and Control and Option make up the knock between Macs.
        default: return .refuse(tr("Shift, Control or Option alone cannot be the shortcut. Use Fn, a Command key, an F key, or a key with Control or Option."))
        }
    }
}
