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

    /// What a key types with no modifier in the current keyboard layout, to name a shortcut by.
    static func name(of code: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
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

/// Where the keyboard was in another app when a click went to one of out's windows, which takes the
/// keyboard away from it (user 2026-11-27: a click on the panel's button puts the focus on the panel,
/// wherever it was before). Type the Clipboard from the panel or the menu brings that app back and
/// types only once its focused element is this one again: or, for an app that shows none (an
/// Electron app not yet asked to show its fields), its focused window.
@MainActor
struct FocusReturn {
    let pid: pid_t
    let element: AXUIElement?
    let window: AXUIElement?

    /// The app in front now, when it is not out: read in the event tap, before the click arrives.
    /// Or `app`, the one out just took the keyboard from some other way (⌘Tab): an app that is no
    /// longer active still shows where its keyboard is (seen in a Cocoa app, 2026-11-27).
    static func capture(of app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> FocusReturn? {
        guard AXIsProcessTrusted(), let app, !app.isTerminated, app.processIdentifier != getpid() else { return nil }
        let (element, window) = read(app.processIdentifier)
        guard element != nil || window != nil else { return nil }
        return FocusReturn(pid: app.processIdentifier, element: element, window: window)
    }

    /// Whether the app has the keyboard where it had it.
    func isBack() -> Bool {
        let (element, window) = Self.read(pid)
        if let mine = self.element { return element.map { CFEqual(mine, $0) } ?? false }
        guard let mine = self.window, let window else { return false }
        return CFEqual(mine, window)
    }

    private static func read(_ pid: pid_t) -> (element: AXUIElement?, window: AXUIElement?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        func element(_ name: String) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, name as CFString, &value) == .success, let value,
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        return (element(kAXFocusedUIElementAttribute), element(kAXFocusedWindowAttribute))
    }
}

/// Typing into a remote desktop, the keys reach the app in front on the Mac it shows, and an input
/// method there (Pinyin, Kana) takes the letters in as a composition: digits and punctuation got
/// through, letters did not (user 2026-11-27, from m2 into a remote desktop). When that Mac is one
/// of the owner's with out, found by the knock, its out selects a keyboard layout while the keys come
/// and puts its input source back after.
@MainActor
final class FarLayout {
    private let session: RemoteSession
    private let index: Int
    var name: String { session.name(index) }

    init(session: RemoteSession, index: Int) {
        self.session = session; self.index = index
    }

    /// Whether that Mac still holds the layout: when its connection ends, its input source goes back.
    var holding: Bool { session.isArmed(index) }

    /// After the last key: one more knock, which that Mac sees only after every key before it (typed
    /// while `inFront`), then its input source goes back.
    func finish(inFront: () -> Bool) async {
        if inFront() {
            let caught = await session.caughtUp(index, within: 3) { nonce in await KnockKeys.post(nonce: nonce) }
            if !caught {
                // Not told: a moment more for keys still on their way.
                Trace.note("type: \(name) did not see the closing knock within 3 s; its input source goes back after another second")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        await session.releaseLayout(at: index)
        session.close()
    }

    /// Typing stopped: the connection ends, and that Mac's out puts its input source back on its own.
    func abandon() { session.close() }
}

/// What the Mac behind a remote desktop said before Type the Clipboard types into it.
enum FarSide {
    /// None of the owner's Macs with an out that can hold a layout is behind it: the keys go as they are.
    case none
    case held(FarLayout)
    /// That Mac's out can hold a layout but did not: no key is typed, since its input method would
    /// take the letters in.
    case refused(String)
}

/// The other side of FarLayout: this Mac's input source while another Mac's keys come through a
/// remote desktop.
@MainActor
enum LayoutHold {
    private static var held: InputSourceSwitch?
    private static var ending: DispatchWorkItem?

    /// A keyboard layout for the app in front, selected and seen to be in use (or one in use
    /// already). False when none could be selected.
    static func begin() async -> Bool {
        ending?.cancel(); ending = nil
        held?.restore(); held = nil
        let hold = InputSourceSwitch()
        guard let source = try? hold.layoutForTyping() else { return false }
        guard hold.switched else { return true }
        held = hold
        let id = InputSourceSwitch.id(of: source)
        let deadline = Date().addingTimeInterval(0.5)
        while InputSourceSwitch.currentID() != id {
            guard Date() < deadline else { hold.restore(); held = nil; return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// The input source comes back: after a moment, for the last keys still being taken in by the
    /// app in front, or `now` (this Mac sleeps, out quits).
    static func end(now: Bool = false) {
        ending?.cancel(); ending = nil
        guard let hold = held else { return }
        if now { hold.restore(); held = nil; return }
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard held === hold else { return }
                hold.restore(); held = nil; ending = nil
            }
        }
        ending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
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
    /// `returning`: where the keyboard was in `target` when a click took it to out's window; with out
    /// in front, typing starts only once `target` has the keyboard there again.
    /// `farSide`: for a remote desktop, the Mac it shows asked to type with a keyboard layout for the
    /// given number of seconds (nil: no Mac of the owner's is behind it, or it cannot).
    static func type(_ text: String, into target: NSRunningApplication, from origin: Origin, returning: FocusReturn? = nil,
                     farSide: ((Double) async -> FarSide)? = nil,
                     userInputs: @escaping () -> Int, progress: @escaping (Int, Int) -> Void) async throws -> Int {
        let isTarget = { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier }
        // The user's clicks and keys from the moment typing was asked for: one while out brings the app
        // back, or looks for the Mac behind a remote desktop, may move the keyboard elsewhere.
        let inputsAtStart = userInputs()
        if origin != .shortcut {
            // Let the menu close, or the panel give the keyboard back to the app it came from.
            try await Task.sleep(nanoseconds: 150_000_000)
            if !isTarget() && NSApp.isActive {
                // The app coming back is not enough: the keys go where its keyboard is then, which
                // must be where it was when out was clicked.
                guard let returning, returning.pid == target.processIdentifier else {
                    throw VoiceError(tr("Click the field you want to type into first."))
                }
                target.activate()
                do { try await waitUntil(seconds: 1.5) { isTarget() && returning.isBack() } }
                catch is TimedOut { throw VoiceError(tr("Click the field you want to type into first.")) }
            }
        }
        guard isTarget(), !target.isTerminated else { throw VoiceError(tr("Typing did not start: another window came to the front.")) }
        // The shortcut's keys must be up first: held modifiers would turn letters into shortcuts, and a
        // V still held would repeat into the field.
        do { try await waitUntil(seconds: 3) { !modifiersHeld() && !(origin == .shortcut && CGEventSource.keyState(.combinedSessionState, key: 9)) } }
        catch is TimedOut { throw VoiceError(tr("Release the keys to start typing.")) }
        // Where the keyboard is now, which must not have moved when the first key goes.
        let here = FocusReturn.capture(of: target)

        // Into a remote desktop, the US keys (the other end reads them); into an app here, this
        // Mac's layout, and Unicode for what it has no key for.
        let remote = KeystrokePlan.isRemoteClient(target.bundleIdentifier)
        if remote, KeystrokePlan.steps(for: text, layout: KeystrokePlan.usKeys).contains(where: { if case .text = $0 { return true } else { return false } }) {
            // A remote desktop passes on keys, not Unicode text: the whole text is checked before the
            // first key, since a password with characters missing is worse than none.
            throw VoiceError(tr("A remote desktop receives only keys, and this text has characters that no key can type, such as Chinese or emoji. Nothing was typed."))
        }
        var far: FarLayout?
        if remote, let farSide {
            let plan = KeystrokePlan.steps(for: text, layout: KeystrokePlan.usKeys)
            switch await farSide(Double(plan.reduce(0) { $0 + KeystrokePlan.pause(after: $1) }) / 1000) {
            case .none: break
            case .held(let layout): far = layout
            case .refused(let name):
                throw VoiceError(tr("%@: %@", name, tr("Could not select a keyboard layout to type with. Select ABC or another keyboard layout, then try again.")))
            }
            // Cancelled while looking: the other Mac's input source goes back, and this one is not touched.
            if Task.isCancelled { far?.abandon(); throw CancellationError() }
            guard isTarget(), !target.isTerminated else {
                far?.abandon()
                throw VoiceError(tr("Typing did not start: another window came to the front."))
            }
        }

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
            let layout = remote ? KeystrokePlan.usKeys : KeyboardLayoutMap.map(for: source)
            let steps = KeystrokePlan.steps(for: text, layout: layout)
            // The keyboard still where it was once the app was in front (another window of the same
            // remote desktop clicked meanwhile is another field).
            if let here, !here.isBack() { throw VoiceError(tr("Typing did not start: another window came to the front.")) }
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
                // Here, or on the Mac behind the remote desktop, which puts its own back when its connection ends.
                guard InputSourceSwitch.currentID() == sourceID, far?.holding ?? true else {
                    throw VoiceError(tr("Typing stopped after %ld of %ld characters: the input source changed.", index, steps.count))
                }
                KeyPoster.post(step)
                if index % 4 == 3 || index == steps.count - 1 { progress(index + 1, steps.count) }
                try await Task.sleep(nanoseconds: KeystrokePlan.pause(after: step) * 1_000_000)
            }
            // The other Mac's input source goes back once its keys are all in.
            await far?.finish(inFront: isTarget)
            // The last keys are still being taken in: the input method comes back a moment later.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if active === inputSource { stopNow() }
            return steps.count
        } catch {
            far?.abandon()
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
