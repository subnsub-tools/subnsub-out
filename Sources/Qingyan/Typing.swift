import AppKit
import Carbon.HIToolbox
import QingyanCore

// "Type the Clipboard": the clipboard's text typed key by key into the field in front, where
// pasting is refused (password fields, forms that block paste, remote desktops and consoles that
// share no clipboard). Merged from PasteForce (user 2026-11-19), which typed US-layout ASCII only,
// with no pause between keys and the shortcut's modifiers possibly still held.

/// The keyboard layout as a map from character to the key (with Shift / Option) that types it.
enum KeyboardLayoutMap {
    /// The keypad types digits too, but its keys mean other things with Num Lock off and in remote tools.
    private static let keypad: Set<UInt16> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    static func map(for source: TISInputSource) -> [Character: KeyStroke] {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        var map: [Character: KeyStroke] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            // Fewest modifiers first, so a character is its plain key when it has one.
            for (shift, option) in [(false, false), (true, false), (false, true), (true, true)] {
                let modifiers = UInt32(((shift ? shiftKey : 0) | (option ? optionKey : 0)) >> 8) & 0xFF
                for code in UInt16(0)..<128 where !keypad.contains(code) {
                    var deadKeyState: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, keyboardType, 0,
                                                &deadKeyState, chars.count, &length, &chars)
                    // A dead key types nothing until the next key: it is no key for a character.
                    guard status == noErr, deadKeyState == 0, length > 0 else { continue }
                    let string = String(utf16CodeUnits: chars, count: length)
                    guard string.count == 1, let character = string.first, map[character] == nil,
                          !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { continue }
                    map[character] = KeyStroke(code: code, shift: shift, option: option)
                }
            }
        }
        return map
    }
}

/// An input method (Pinyin, Kana) would take typed keys in as a composition: while typing, an
/// ASCII-capable keyboard layout is selected, and the input source that was in use comes back after
/// (unless the user has picked another one meanwhile).
@MainActor
final class InputSourceSwitch {
    private var original: TISInputSource?
    private var temporary: TISInputSource?
    var switched: Bool { original != nil }

    struct CannotSwitch: Error {}

    /// The layout the keys are typed with: the current input source when it is a keyboard layout,
    /// otherwise the ASCII-capable one, selected now. Throws when there is none or it will not select.
    func layoutForTyping() throws -> TISInputSource {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { throw CannotSwitch() }
        if Self.isLayout(current) { return current }
        guard let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              TISSelectInputSource(ascii) == noErr else { throw CannotSwitch() }
        original = current; temporary = ascii
        return ascii
    }

    func restore() {
        defer { original = nil; temporary = nil }
        guard let original, let temporary, Self.currentID() == Self.id(of: temporary) else { return }
        TISSelectInputSource(original)
    }

    static func currentID() -> String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return id(of: current)
    }

    static func id(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func isLayout(_ source: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        return CFEqual(Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue(), kTISTypeKeyboardLayout)
    }
}

@MainActor
enum ClipboardTyper {
    enum Origin { case shortcut, menu, panel }

    /// The input-source switch of the typing under way, so that a cancel, sleep or quit can put the
    /// input source back at once.
    private static var active: InputSourceSwitch?

    /// Stops what would be left half-done: the input source comes back now.
    static func stopNow() {
        active?.restore()
        active = nil
    }

    /// Types `text` into `target` (the app in front when it was asked for; from the panel or the menu,
    /// the app that was in front before this one) and returns how many characters went out. It stops
    /// when another window comes to the front, a click or a key press comes in between, the input
    /// source changes, or the task is cancelled.
    static func type(_ text: String, into target: NSRunningApplication, from origin: Origin,
                     userInputs: @escaping () -> Int, progress: @escaping (Int, Int) -> Void) async throws -> Int {
        let isTarget = { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier }
        if origin != .shortcut {
            // Let the menu close, or the panel give the keyboard back to the app it came from.
            try await Task.sleep(nanoseconds: 150_000_000)
            if !isTarget() && NSApp.isActive {
                target.activate()
                do { try await waitUntil(seconds: 1.5, isTarget) }
                catch is TimedOut { throw VoiceError(tr("Click the field you want to type into first.")) }
            }
        }
        guard isTarget(), !target.isTerminated else { throw VoiceError(tr("Typing did not start: another window came to the front.")) }
        // The shortcut's keys must be up first: held modifiers would turn letters into shortcuts, and a
        // V still held would repeat into the field.
        do { try await waitUntil(seconds: 3) { !modifiersHeld() && !(origin == .shortcut && CGEventSource.keyState(.combinedSessionState, key: 9)) } }
        catch is TimedOut { throw VoiceError(tr("Release the keys to start typing.")) }

        let inputSource = InputSourceSwitch()
        active = inputSource
        do {
            let source: TISInputSource
            do { source = try inputSource.layoutForTyping() }
            catch is InputSourceSwitch.CannotSwitch { throw VoiceError(tr("Could not select a keyboard layout to type with. Select ABC or another keyboard layout, then try again.")) }
            let sourceID = InputSourceSwitch.id(of: source)
            if inputSource.switched {
                do { try await waitUntil(seconds: 0.5) { InputSourceSwitch.currentID() == sourceID } }
                catch is TimedOut { throw VoiceError(tr("Could not select a keyboard layout to type with. Select ABC or another keyboard layout, then try again.")) }
            }
            // Into a remote desktop, the US keys (the other end reads them); into an app here, this
            // Mac's layout, and Unicode for what it has no key for.
            let remote = KeystrokePlan.isRemoteClient(target.bundleIdentifier)
            let layout = remote ? KeystrokePlan.usKeys : KeyboardLayoutMap.map(for: source)
            let steps = KeystrokePlan.steps(for: text, layout: layout)
            // A remote desktop passes on keys, not Unicode text: the whole text is checked before the
            // first key, since a password with characters missing is worse than none.
            if remote, steps.contains(where: { if case .text = $0 { return true } else { return false } }) {
                throw VoiceError(tr("A remote desktop receives only keys, and this text has characters that no key can type, such as Chinese or emoji. Nothing was typed."))
            }
            let inputsAtStart = userInputs()
            progress(0, steps.count)
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation()
                guard isTarget() else {
                    throw VoiceError(tr("Typing stopped after %ld of %ld characters: another window came to the front.", index, steps.count))
                }
                // A click or a key of the user's may have moved the focus to another field of the same app.
                guard userInputs() == inputsAtStart else {
                    throw VoiceError(tr("Typing stopped after %ld of %ld characters: a click or key press occurred.", index, steps.count))
                }
                guard InputSourceSwitch.currentID() == sourceID else {
                    throw VoiceError(tr("Typing stopped after %ld of %ld characters: the input source changed.", index, steps.count))
                }
                KeyPoster.post(step)
                if index % 4 == 3 || index == steps.count - 1 { progress(index + 1, steps.count) }
                try await Task.sleep(nanoseconds: KeystrokePlan.pause(after: step) * 1_000_000)
            }
            // The last keys are still being taken in: the input method comes back a moment later.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if active === inputSource { stopNow() }
            return steps.count
        } catch {
            if !(error is CancellationError) { try? await Task.sleep(nanoseconds: 150_000_000) }
            if active === inputSource { stopNow() }
            throw error
        }
    }

    private struct TimedOut: Error {}

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw TimedOut() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func modifiersHeld() -> Bool {
        !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }
}

/// Posts one step as key events, with exactly the modifiers the step needs.
@MainActor
enum KeyPoster {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func post(_ step: TypingStep) {
        switch step {
        case .newline: key(.returnKey)
        case .key(let stroke): key(stroke)
        case .text(let text): unicode(text)
        }
    }

    private static func key(_ stroke: KeyStroke) {
        var flags: CGEventFlags = []
        if stroke.shift { flags.insert(.maskShift) }
        if stroke.option { flags.insert(.maskAlternate) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private static func unicode(_ text: String) {
        var units = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.post(tap: .cghidEventTap)
        }
    }
}
