import Foundation

/// One key of the keyboard layout, with the modifiers that make it type a character.
public struct KeyStroke: Equatable, Hashable, Sendable {
    public let code: UInt16
    public let shift: Bool
    public let option: Bool

    public init(code: UInt16, shift: Bool = false, option: Bool = false) {
        self.code = code
        self.shift = shift
        self.option = option
    }

    public static let returnKey = KeyStroke(code: 36)
    public static let tabKey = KeyStroke(code: 48)
}

/// What "Type the Clipboard" sends for one character of the text.
public enum TypingStep: Equatable, Sendable {
    /// A key of the current layout: what a remote desktop or a console passes on, as a person's typing.
    case key(KeyStroke)
    /// A character the layout has no key for (Chinese, an emoji), sent as Unicode text: the app in
    /// front receives it, though a remote desktop may not.
    case text(String)
    /// A line break, sent as Return (user 2026-11-19: line breaks are typed as Return).
    case newline
}

/// Turns the clipboard's text into the keys that type it (the feature merged from PasteForce, user
/// 2026-11-19). Pure: the layout's map from character to key comes from the caller.
public enum KeystrokePlan {
    /// No clipboard is typed whole beyond this: about four minutes of keys.
    public static let longest = 20_000

    /// Apps that show another computer's screen and pass keys on: Screen Sharing and Jump Desktop (as
    /// RemoteWire knows them) and the other common remote-desktop and remote-control clients.
    public static func isRemoteClient(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        if RemoteWire.showsAnotherScreen(bundleID: id) { return true }
        return remoteClients.contains(id)
    }

    static let remoteClients: Set<String> = [
        "com.microsoft.rdc.macos", "com.microsoft.rdc.mac", "com.microsoft.rdc.osx.beta",   // Windows App / Microsoft Remote Desktop
        "com.realvnc.vncviewer", "com.teamviewer.teamviewer", "com.philandro.anydesk", "com.anydesk.anydeskmacos",
        "tv.parsec.www", "com.vmware.horizon", "com.citrix.receiver.icaviewer.mac", "com.nomachine.nxplayer",
        "com.lemonmojo.royaltsx.app", "com.edovia.screens.mac", "com.edovia.screens5.mac", "com.splashtop.business.mac.client",
        "com.splashtop.personal.mac.client", "net.tigervnc.vncviewer",
    ]

    /// The US (ANSI) keys for every printable ASCII character. A remote desktop or console passes
    /// keys on and the Mac or server at the other end reads them, nearly always with a US layout: so
    /// there the keys are these, whatever this Mac's own layout is (a Pinyin keyboard has no key for
    /// "!": its Shift-1 types a full-width exclamation mark).
    public static let usKeys: [Character: KeyStroke] = {
        var map: [Character: KeyStroke] = [:]
        let rows: [(UInt16, Character, Character)] = [
            (0, "a", "A"), (1, "s", "S"), (2, "d", "D"), (3, "f", "F"), (4, "h", "H"), (5, "g", "G"), (6, "z", "Z"),
            (7, "x", "X"), (8, "c", "C"), (9, "v", "V"), (11, "b", "B"), (12, "q", "Q"), (13, "w", "W"), (14, "e", "E"),
            (15, "r", "R"), (16, "y", "Y"), (17, "t", "T"), (18, "1", "!"), (19, "2", "@"), (20, "3", "#"), (21, "4", "$"),
            (22, "6", "^"), (23, "5", "%"), (24, "=", "+"), (25, "9", "("), (26, "7", "&"), (27, "-", "_"), (28, "8", "*"),
            (29, "0", ")"), (30, "]", "}"), (31, "o", "O"), (32, "u", "U"), (33, "[", "{"), (34, "i", "I"), (35, "p", "P"),
            (37, "l", "L"), (38, "j", "J"), (39, "'", "\""), (40, "k", "K"), (41, ";", ":"), (42, "\\", "|"), (43, ",", "<"),
            (44, "/", "?"), (45, "n", "N"), (46, "m", "M"), (47, ".", ">"), (50, "`", "~"),
        ]
        for (code, plain, shifted) in rows {
            map[plain] = KeyStroke(code: code)
            map[shifted] = KeyStroke(code: code, shift: true)
        }
        map[" "] = KeyStroke(code: 49)
        return map
    }()

    public static func steps(for text: String, layout: [Character: KeyStroke]) -> [TypingStep] {
        var steps: [TypingStep] = []
        steps.reserveCapacity(text.count)
        // "\r\n" is one Character in Swift, so a Windows line break is one Return.
        for character in text {
            switch character {
            case "\n", "\r", "\r\n", "\u{2028}", "\u{2029}":
                steps.append(.newline)
            case "\t":
                steps.append(.key(.tabKey))
            default:
                if let stroke = layout[character] { steps.append(.key(stroke)) }
                // Only control characters (a bell, a stray escape) are dropped; format characters such as
                // the joiner inside an emoji sequence belong to the character.
                else if !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                    steps.append(.text(String(character)))
                }
                // Other control characters are not typed.
            }
        }
        return steps
    }

    /// How long to wait after a step before the next one, in milliseconds: a remote desktop or a
    /// console drops keys that come faster, and a line takes a moment to be taken in.
    public static func pause(after step: TypingStep) -> UInt64 {
        switch step {
        case .newline: return 60
        case .key, .text: return 12
        }
    }
}
