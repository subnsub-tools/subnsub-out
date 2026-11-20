import AppKit
import ApplicationServices
import Carbon
import QingyanCore

// WindowServer handles the system Globe action before session event taps.
// These optional HIToolbox entry points update its live cache as well as the preference.
// This local-build integration is not an App Store-compatible API.
@MainActor
final class FnSystemAction {
    private typealias Read = @convention(c) () -> Int32
    private typealias Update = @convention(c) (Int32) -> Void
    private static let api: (read: Read, update: Update)? = {
        guard let library = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY),
              let read = dlsym(library, "TISGetFnUsageType"),
              let update = dlsym(library, "TISUpdateFnUsageType") else { return nil }
        return (unsafeBitCast(read, to: Read.self), unsafeBitCast(update, to: Update.self))
    }()
    private let defaults: UserDefaults
    private let marker = "fnSystemActionOriginal"
    private let domain = "com.apple.HIToolbox" as CFString
    private let key = "AppleFnUsageType" as CFString

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isDisabled: Bool {
        if let api = Self.api { return api.read() == 0 }
        return (CFPreferencesCopyAppValue(key, domain) as? NSNumber)?.intValue == 0
    }

    @discardableResult func acquire() -> Bool {
        guard let api = Self.api else { return false }
        let current = api.read()
        // A surviving marker belongs to a previous run; do not back up our own override.
        if defaults.dictionary(forKey: marker) != nil {
            if current == 0 { return true }
            defaults.removeObject(forKey: marker)
        }
        guard current != 0 else { return true }
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let existed = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) != nil
        defaults.set(["value": Int(current), "existed": existed], forKey: marker)
        guard defaults.synchronize() else {
            defaults.removeObject(forKey: marker)
            return false
        }
        api.update(0)
        return isDisabled
    }

    func restore() {
        guard let saved = defaults.dictionary(forKey: marker),
              let value = saved["value"] as? Int, let existed = saved["existed"] as? Bool,
              let api = Self.api else { return }
        // Do not overwrite a new action the user chose in System Settings.
        if api.read() == 0 {
            api.update(Int32(value))
            guard api.read() == Int32(value) else { return }
            if !existed {
                CFPreferencesSetValue(key, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
        }
        defaults.removeObject(forKey: marker)
        defaults.synchronize()
    }
}

@MainActor
final class GlobalShortcut {
    var onToggle: (() -> Void)?
    var onCancel: (() -> Bool)?
    /// A complete knock arrived, typed by another Mac through a remote-desktop session.
    var onKnock: ((Int) -> Void)?
    /// Control + Option + V: type the clipboard key by key.
    var onTypeClipboard: (() -> Void)?
    /// How many keys and clicks of the user's have come in (not this app's own): Type the Clipboard
    /// stops when one comes in between, since it may have moved the focus.
    private(set) var userInputs = 0
    /// Keys whose key-down was taken (Control + Option + V, the shortcut, a key pressed while a new
    /// shortcut is recorded): their repeats and their key-up are taken too until they are released, so
    /// nothing of them reaches the app in front once the modifiers are up.
    private var swallowed: Set<Int64> = []
    /// Keys other than modifiers that are down now, from their key-down and key-up.
    private var held: Set<Int64> = []
    /// Whether the Fn key itself is down, from its own events: F keys and arrows carry the Fn flag on
    /// their own, so the flag on a key-down says nothing.
    private var fnDown = false
    private var knock = KnockDecoder()
    /// True once the user has typed or clicked. Cleared right after this app pastes, so while it is
    /// still false the cursor has to be sitting exactly behind the pasted text.
    var touched = true
    var choice = "fn" {
        didSet {
            guard choice != oldValue else { return }
            active = Shortcut(stored: choice) ?? .fn
            gesture.reset()
            updateFnOwnership()
        }
    }
    /// The shortcut `choice` names; Fn when it names none this version knows.
    private(set) var active: Shortcut = .fn
    /// While set, keys are not acted on: the next shortcut pressed is reported here (nil: Esc, the
    /// recording of a new shortcut is cancelled), and Fn and the shortcut do nothing meanwhile.
    var onRecorded: ((Shortcut.Verdict?) -> Void)? {
        didSet {
            recordingTap = nil
            // Fn is held for the recording too, or pressing it to record it would also run its macOS action.
            if (onRecorded == nil) != (oldValue == nil) { updateFnOwnership() }
        }
    }
    /// The modifier key that went down on its own while recording, if it is still the only one.
    private var recordingTap: Int64?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = FnGesture()
    private let fnSystemAction = FnSystemAction()
    var installed: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var fnExclusive: Bool { active == .fn && installed && fnSystemAction.isDisabled }

    func start() {
        guard AXIsProcessTrusted() else { stop(); return }
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                gesture.reset()
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: CGEventMask(mask), callback: callback,
                               userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        updateFnOwnership()
    }

    private func updateFnOwnership() {
        if (active == .fn || onRecorded != nil) && installed { fnSystemAction.acquire() }
        else { fnSystemAction.restore() }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil; gesture.reset()
        onRecorded = nil
        fnSystemAction.restore()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Key-ups may have been missed meanwhile.
            gesture.reset(); recordingTap = nil; swallowed = []; held = []
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        // Keys this app posts itself (the paste, the knock) are not the user's and must not disturb the gesture.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return pass }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            touched = true
            userInputs &+= 1
            // A click with the shortcut's modifier held is a chord, not a tap.
            gesture.otherKeyPressed()
            recordingTap = nil
            // A click anywhere ends the recording of a new shortcut, so that typing elsewhere is not taken.
            onRecorded?(nil)
            return pass
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        switch type {
        case .keyUp:
            held.remove(code)
            return swallowed.remove(code) != nil ? nil : pass
        case .keyDown:
            if swallowed.contains(code) {
                if repeating { return nil }
                swallowed.remove(code)       // its key-up was missed: this is a new press
            }
            held.insert(code)
            touched = true
            userInputs &+= 1
        case .flagsChanged:
            if code == 63 { fnDown = flags.contains(.maskSecondaryFn) }
        default: break
        }
        // The knock is read even while a new shortcut is being recorded.
        if type == .flagsChanged, let step = KnockKeys.step(code: code, flags: flags) {
            if let nonce = knock.feed(step, at: ProcessInfo.processInfo.systemUptime) { onKnock?(nonce) }
        } else { knock.reset() }
        if let onRecorded { return record(type, event, code: code, report: onRecorded) }
        if type == .keyDown {
            gesture.otherKeyPressed()
            if code == 53, onCancel?() == true { return nil }
            if code == 9, flags.contains([.maskControl, .maskAlternate]), !flags.contains(.maskCommand), !flags.contains(.maskShift) {
                if !repeating { onTypeClipboard?() }
                swallowed.insert(code)
                return nil
            }
            // With Fn held, only an F key matches: Fn with another key is a different key.
            if case let .combination(key, modifiers) = active, code == Int64(key), Self.modifiers(flags) == modifiers,
               !fnDown || Shortcut.functionKeys[key] != nil {
                if !repeating { onToggle?() }
                swallowed.insert(code)
                return nil
            }
        }
        if type == .flagsChanged {
            switch active {
            case .fn:
                let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
                let other = !flags.intersection(modifiers).isEmpty
                if code == 63 {
                    let down = flags.contains(.maskSecondaryFn)
                    if gesture.flagsChanged(isDown: down, hasOtherModifiers: other || (down && handsBusy())) { onToggle?() }
                    // The system Globe action is disabled separately; consuming this event alone is insufficient.
                    return nil
                } else if other { gesture.otherKeyPressed() }
            case .commandTap(let right):
                let mine: UInt64 = right ? 0x10 : 0x08, theirs: UInt64 = right ? 0x08 : 0x10
                if code == (right ? 54 : 55) {
                    let down = flags.rawValue & mine != 0
                    let other = !flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty
                        || flags.rawValue & theirs != 0
                    if gesture.flagsChanged(isDown: down, hasOtherModifiers: other || (down && handsBusy())) { onToggle?() }
                    // A Command key on its own does nothing in macOS: the event goes on, so no app sees it held.
                } else { gesture.otherKeyPressed() }
            case .combination: break
            }
        }
        return pass
    }

    /// A mouse button or another key already held when a modifier goes down makes it part of a drag or
    /// a chord, not a tap.
    private func handsBusy() -> Bool {
        if NSEvent.pressedMouseButtons != 0 { return true }
        held = held.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
        return !held.isEmpty
    }

    static func modifiers(_ flags: CGEventFlags) -> Shortcut.Modifiers {
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        return modifiers
    }

    /// Recording a new shortcut: the first key with its modifiers, or a modifier key pressed and let go
    /// on its own. Keys pressed meanwhile reach no app (nor their repeats and key-ups); modifier keys go
    /// on, except Fn (as above).
    private func record(_ type: CGEventType, _ event: CGEvent, code: Int64,
                        report: (Shortcut.Verdict?) -> Void) -> Unmanaged<CGEvent>? {
        switch type {
        case .keyDown:
            recordingTap = nil
            swallowed.insert(code)
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            let modifiers = Self.modifiers(event.flags)
            if code == 53 && modifiers.isEmpty { report(nil) }
            else if fnDown && Shortcut.functionKeys[Int(code)] == nil {
                report(.refuse(tr("Fn with another key cannot be the shortcut. Press the key without Fn.")))
            } else { report(Shortcut.recorded(code: Int(code), modifiers: modifiers)) }
            return nil
        case .flagsChanged:
            guard let bit = Shortcut.modifierBits[Int(code)] else { return Unmanaged.passUnretained(event) }
            let raw = event.flags.rawValue
            let count = Shortcut.modifierBits.values.filter { raw & $0 != 0 }.count
            if raw & bit != 0 {
                recordingTap = count == 1 && !handsBusy() ? code : nil
            } else {
                if recordingTap == code && count == 0 { report(Shortcut.recordedTap(code: Int(code))) }
                recordingTap = nil
            }
            return code == 63 ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// The knock as real key events. Right-hand modifiers are posted; either side is recognised,
/// because a remote-desktop tool may fold right into left.
@MainActor
enum KnockKeys {
    private static func key(_ key: Knock.Key) -> (code: CGKeyCode, mask: UInt64) {
        switch key {
        case .option: return (61, 0x80000 | 0x40)
        case .shift: return (60, 0x20000 | 0x04)
        case .control: return (62, 0x40000 | 0x2000)
        }
    }

    static func step(code: Int64, flags: CGEventFlags) -> Knock.Step? {
        switch code {
        case 58, 61: return Knock.Step(.option, down: flags.contains(.maskAlternate))
        case 56, 60: return Knock.Step(.shift, down: flags.contains(.maskShift))
        case 59, 62: return Knock.Step(.control, down: flags.contains(.maskControl))
        default: return nil
        }
    }

    /// Always runs to the end, so no modifier is left held even if the caller is cancelled.
    static func post(nonce: Int, spacing: UInt64 = 12_000_000) async {
        var flags: UInt64 = 0x100
        for step in Knock.steps(for: nonce) {
            let (code, mask) = key(step.key)
            if step.down { flags |= mask } else { flags &= ~mask }
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: step.down) {
                event.type = .flagsChanged
                event.flags = CGEventFlags(rawValue: flags)
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: spacing)
        }
    }
}

/// Captures the live screen geometry — focused caret or input field, active window, background
/// windows, pointer, and input's own panel — so `OverlayPlacement` can keep the status capsule
/// completely out of the user's line of sight.
@MainActor
enum SightSensor {
    static func capture(excludingPanel panel: NSWindow?, previousOrigin: CGPoint?) -> (screen: NSScreen, scene: OverlayPlacement.Scene)? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let primaryHeight = primary.frame.height
        let pointer = NSEvent.mouseLocation
        let myPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var activeWindow: CGRect?
        var otherWindows: [CGRect] = []
        if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in infos {
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                      let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != myPID,
                      let rawBounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let quartzRect = CGRect(dictionaryRepresentation: rawBounds),
                      quartzRect.width >= 100, quartzRect.height >= 60 else { continue }
                let appRect = OverlayPlacement.quartzToAppKit(quartzRect, primaryHeight: primaryHeight)
                if let frontPID, owner == frontPID, activeWindow == nil {
                    activeWindow = appRect
                } else if otherWindows.count < 12 {
                    otherWindows.append(appRect)
                }
            }
        }

        let focusedField = frontPID.flatMap { focusedElementRect(pid: $0, primaryHeight: primaryHeight) }

        let anchorPoint = focusedField.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? activeWindow.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? pointer
        let screen = screens.first(where: { $0.frame.contains(anchorPoint) })
            ?? screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
            ?? primary

        let visible = screen.visibleFrame
        let panelFrame: CGRect? = (panel?.isVisible == true && panel?.frame.intersects(screen.frame) == true) ? panel?.frame : nil
        let clippedActive = activeWindow?.intersects(screen.frame) == true ? activeWindow : nil
        let clippedOthers = otherWindows.filter { $0.intersects(screen.frame) }

        let scene = OverlayPlacement.Scene(
            visibleFrame: visible,
            activeWindow: clippedActive,
            otherWindows: clippedOthers,
            focusedField: focusedField,
            panelFrame: panelFrame,
            pointer: screen.frame.contains(pointer) ? pointer : nil,
            previousOrigin: previousOrigin
        )
        return (screen, scene)
    }

    private static func focusedElementRect(pid: pid_t, primaryHeight: CGFloat) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.06)
        var rawElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &rawElement) == .success,
              let rawElement, CFGetTypeID(rawElement) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(rawElement, to: AXUIElement.self)

        // Prefer exact caret / selection bounds when the focused control exposes them.
        var rawRange: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rawRange) == .success,
           let rawRange {
            var rawBounds: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rawRange, &rawBounds) == .success,
               let rawBounds, CFGetTypeID(rawBounds) == AXValueGetTypeID() {
                var caret = CGRect.zero
                if AXValueGetValue(unsafeBitCast(rawBounds, to: AXValue.self), .cgRect, &caret),
                   caret.width >= 0, caret.height > 0, caret.height < 400 {
                    let expanded = CGRect(x: caret.minX, y: caret.minY, width: max(caret.width, 24), height: max(caret.height, 20))
                    return OverlayPlacement.quartzToAppKit(expanded, primaryHeight: primaryHeight)
                }
            }
        }

        // Fall back to the focused control's frame when it is a compact input box rather than a whole document canvas.
        var rawPos: CFTypeRef?, rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPos, let rawSize,
              CFGetTypeID(rawPos) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(rawPos, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size),
              size.width > 0, size.height > 0, size.height <= 320 else { return nil }
        return OverlayPlacement.quartzToAppKit(CGRect(origin: origin, size: size), primaryHeight: primaryHeight)
    }
}

/// Which window had the keyboard when the knock was typed. If it is still the same one when the
/// text is ready, the knock's answer still holds and nothing has to be typed again.
@MainActor
struct FocusMark {
    let pid: pid_t
    let window: AXUIElement?

    static func current() -> FocusMark? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        let found = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success
        let window = found && value.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true ? unsafeBitCast(value, to: AXUIElement.self) : nil
        return FocusMark(pid: app.processIdentifier, window: window)
    }

    /// An unknown window never counts as the same one.
    func same(as other: FocusMark?) -> Bool {
        guard let other, pid == other.pid, let window, let theirs = other.window else { return false }
        return CFEqual(window, theirs)
    }
}

/// What writing text into the front app did, in words, and whether the text was also left on
/// the clipboard to be pasted with ⌘V.
struct WriteResult {
    let summary: String
    var onClipboard = false
    /// Why the text is not in a text field (it is then on the clipboard).
    var miss: MissReason?
    /// The other Mac the text went to, by name; nil when it was written on this Mac.
    var peer: String?
}

/// Why the text could not be written in front, with the words for it.
struct TargetProblem: LocalizedError {
    let miss: MissReason
    let message: String
    var errorDescription: String? { message }
}

@MainActor
struct TextTarget {
    let app: NSRunningApplication
    let selectedText: String
    /// Whether the keyboard is in something that reports itself as a text field that can be written to.
    var editable = false

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func capture() throws -> TextTarget {
        guard AXIsProcessTrusted() else { throw TargetProblem(miss: .accessibility, message: tr("Accessibility permission is not granted. Allow put in System Settings.")) }
        guard !IsSecureEventInputEnabled() else { throw TargetProblem(miss: .secureInput, message: tr("Secure input is on. No text is written while a password is being entered.")) }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw TargetProblem(miss: .noApp, message: tr("No app is in focus. The text is saved in History."))
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let raw = attribute(appElement, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return TextTarget(app: app, selectedText: "")
        }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        guard subrole != kAXSecureTextFieldSubrole else { throw TargetProblem(miss: .passwordField, message: tr("To protect privacy, dictated text is not entered into a password field.")) }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let range = attribute(element, kAXSelectedTextRangeAttribute)
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) || range != nil else {
            return TextTarget(app: app, selectedText: "")
        }
        return TextTarget(app: app, selectedText: attribute(element, kAXSelectedTextAttribute) as? String ?? "",
                          editable: writable(element, in: app))
    }

    private static func writable(_ element: AXUIElement, in app: NSRunningApplication) -> Bool {
        if attribute(element, kAXEnabledAttribute) as? Bool == false { return false }
        if terminals.contains(app.bundleIdentifier ?? "") { return true }
        return [kAXValueAttribute, kAXSelectedTextAttribute].contains { name in
            var settable: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
        }
    }

    /// Resolve the destination only when the final text is ready.
    static func insertAtFocus(_ text: String) throws -> WriteResult {
        let current = try capture()
        let name = current.app.localizedName ?? tr("the target app")
        try paste(text, keep: !current.editable)
        if current.editable { return WriteResult(summary: tr("Inserted into %@", name)) }
        return WriteResult(summary: tr("Sent to %@ · No text field found; the text stays on the clipboard (⌘V)", name), onClipboard: true, miss: .noField)
    }

    /// `keep`: the text stays on the clipboard afterwards.
    private static func paste(_ text: String, hold: TimeInterval = 0.9, keep: Bool = false) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            throw TargetProblem(miss: .pasteFailed, message: tr("Could not send the paste keystroke. Click the text to copy it."))
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        PasteboardLease.general.supply(text, hold: hold, keep: keep) {
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }

    private static func backspace(_ count: Int) {
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false) else { return }
            down.flags = []; up.flags = []
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }

    /// In a terminal a selection is only a highlight; pasting does not replace it.
    private static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper"]

    static func replace(_ previous: String, with text: String, untouched: Bool) throws -> WriteResult {
        let current = try capture()
        let name = current.app.localizedName ?? tr("the target app")
        let done = WriteResult(summary: text.isEmpty ? tr("Deleted the previous text in %@", name) : tr("Replaced the previous text in %@", name))
        if untouched, previous.count <= 4000 {
            backspace(previous.count)
            if !text.isEmpty { try paste(text, hold: 0.9 + Double(previous.count) * 0.004, keep: !current.editable) }
            return done
        }
        if !terminals.contains(current.app.bundleIdentifier ?? ""), select(previous, in: current.app) {
            if text.isEmpty { backspace(1) } else { try paste(text) }
            return done
        }
        guard !text.isEmpty else { throw TargetProblem(miss: .previousGone, message: tr("The cursor has moved and the previous text was not found. Nothing was deleted.")) }
        try paste(text, keep: !current.editable)
        if current.editable { return WriteResult(summary: tr("Previous text not found; new text added to %@", name)) }
        return WriteResult(summary: tr("Previous text not found; new text added to %@ · The text stays on the clipboard", name), onClipboard: true, miss: .previousGone)
    }

    private static func focusedText(in app: NSRunningApplication) -> (AXUIElement, String)? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        guard let raw = attribute(appElement, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        guard attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              let value = attribute(element, kAXValueAttribute) as? String else { return nil }
        return (element, value)
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let boxed = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(boxed) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(unsafeBitCast(boxed, to: AXValue.self), .cfRange, &range) ? range : nil
    }

    private static func select(_ location: Int, _ length: Int, in element: AXUIElement) -> Bool {
        var target = CFRange(location: location, length: length)
        guard let boxed = AXValueCreate(.cfRange, &target),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, boxed) == .success,
              let now = selectedRange(element) else { return false }
        return now.location == location && now.length == length
    }

    private static func select(_ previous: String, in app: NSRunningApplication) -> Bool {
        guard let (element, value) = focusedText(in: app) else { return false }
        let whole = value as NSString
        let cursor = selectedRange(element).map { max(0, min(whole.length, $0.location + $0.length)) } ?? whole.length
        var found = whole.range(of: previous, options: .backwards, range: NSRange(location: 0, length: cursor))
        if found.location == NSNotFound { found = whole.range(of: previous, options: .backwards) }
        guard found.location != NSNotFound, select(found.location, found.length, in: element) else { return false }
        return attribute(element, kAXSelectedTextAttribute) as? String == previous
    }

    private static let fieldLimit = 6000

    /// Like `field()` but also names the focused element, so a caller can tell whether it is still
    /// the same field at the next read. Same refusals: no Accessibility, secure input, terminals
    /// and fields over 6000 characters.
    static func fieldWithElement() -> (element: AXUIElement, before: String, after: String)? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), let app = NSWorkspace.shared.frontmostApplication,
              !terminals.contains(app.bundleIdentifier ?? ""), let (element, value) = focusedText(in: app) else { return nil }
        let whole = value as NSString
        guard whole.length <= fieldLimit else { return nil }
        let cursor = selectedRange(element).map { max(0, min(whole.length, $0.location)) } ?? whole.length
        return (element, whole.substring(to: cursor), whole.substring(from: cursor))
    }

    static func field() -> (before: String, after: String)? {
        fieldWithElement().map { ($0.before, $0.after) }
    }

    static func rewriteField(from old: String, to new: String) throws -> WriteResult {
        let current = try capture()
        let name = current.app.localizedName ?? tr("the target app")
        guard !terminals.contains(current.app.bundleIdentifier ?? ""), let (element, value) = focusedText(in: current.app),
              value == old else { throw VoiceError(tr("The text field has changed or could not be read. Nothing was changed.")) }
        let span = OpenAIWire.changedSpan(from: old, to: new)
        guard span.length > 0 || !span.insert.isEmpty else { return WriteResult(summary: tr("No change in %@", name)) }
        guard select(span.location, span.length, in: element) else { throw VoiceError(tr("Could not find the part to change in %@. Nothing was changed.", name)) }
        if span.insert.isEmpty { backspace(1) } else { try paste(span.insert) }
        let cleared = span.insert.isEmpty && span.length == (old as NSString).length
        return WriteResult(summary: cleared ? tr("Cleared the text field in %@", name) : tr("Updated the text in %@", name))
    }
}
