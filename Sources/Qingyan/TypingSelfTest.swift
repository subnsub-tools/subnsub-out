#if DEBUG
import AppKit
import Carbon.HIToolbox
import QingyanCore

/// Type the Clipboard against a real app on this Mac's screen: a second copy of this binary shows a
/// window with two fields (`--typing-target <state.json>`) and writes what they hold, which has the
/// keyboard and whether an input method is composing; this copy plays out and types into it, from the
/// shortcut (the target in front throughout) and from the panel (this copy's own window in front
/// first, as a click on the panel's button makes it). Needs Accessibility, so the bundle must carry
/// out's signature, and is started by LaunchServices:
/// `open -n <bundle> --args --typing-selftest <report.json>`.
/// It takes the keyboard for about twenty seconds and changes the input source while it runs.
enum TypingSelfTest {
    static let sample = "Hello World abc 123, xyz! \u{4F60}\u{597D} Q.E.D."

    struct TargetState: Decodable {
        var seq: Int
        var active: Bool
        var key: Bool
        var focus: String
        var a: String
        var b: String
        var marked: Bool
        var source: String
        var done: Int
    }

    @MainActor private final class Run {
        var lines: [[String: Any]] = []
        var cases: [[String: Any]] = []
        let state: String
        var command = 0
        init(state: String) { self.state = state }

        func read() -> TargetState? {
            guard let data = FileManager.default.contents(atPath: state) else { return nil }
            return try? JSONDecoder().decode(TargetState.self, from: data)
        }

        func send(_ what: String) async -> Bool {
            command += 1
            let body = "\(command) \(what)"
            try? body.write(toFile: state + ".cmd", atomically: true, encoding: .utf8)
            for _ in 0..<100 {
                if let now = read(), now.done >= command { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }

        func until(_ seconds: Double, _ condition: (TargetState) -> Bool) async -> TargetState? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let now = read(), condition(now) { return now }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }
    }

    @MainActor static func run(report: String) async -> Bool {
        var out: [String: Any] = ["sample": sample]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                FileManager.default.createFile(atPath: report, contents: data)
            }
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            out["error"] = "This copy is not trusted for Accessibility or may not post events: sign it as out and start it with open."
            return false
        }
        let original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        out["sourceAtStart"] = InputSourceSwitch.currentID() ?? ""

        // This copy's window: the panel, as far as the keyboard goes (no text field in it).
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "out typing self-test (panel)"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView()
        let button = NSButton(title: "Type the Clipboard", target: nil, action: nil)
        button.frame = NSRect(x: 100, y: 60, width: 160, height: 32)
        panel.contentView?.addSubview(button)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 400, y: screen.maxY - 220))
        }

        let state = NSTemporaryDirectory() + "out-typing-\(getpid()).json"
        unlink(state); unlink(state + ".cmd")
        let run = Run(state: state)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--typing-target", state]
        configuration.activates = true
        let target: NSRunningApplication
        do { target = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) }
        catch { out["error"] = "The target did not start: \(error)"; return false }
        defer {
            target.terminate()
            if let original, InputSourceSwitch.currentID() != InputSourceSwitch.id(of: original) { TISSelectInputSource(original) }
            unlink(state); unlink(state + ".cmd")
        }
        guard await run.until(10, { $0.active && $0.key && $0.focus == "a" }) != nil else {
            out["error"] = "The target did not come in front with its first field focused."
            return false
        }

        // Is an input method composing in the target? One letter key, then the field is cleared.
        func probe() async -> [String: Any] {
            KeyPoster.postForTest(code: 0)
            let seen = await run.until(0.6) { $0.marked || !$0.a.isEmpty } ?? run.read()
            _ = await run.send("clear")
            return ["marked": seen?.marked ?? false, "a": seen?.a ?? "", "source": seen?.source ?? ""]
        }
        var first = await probe()
        if first["marked"] as? Bool != true {
            _ = await run.send("pinyin")
            try? await Task.sleep(nanoseconds: 300_000_000)
            first = await probe()
            first["selectedPinyin"] = true
        }
        out["probe"] = first

        func timeline(during body: () async -> [String: Any]) async -> [String: Any] {
            var samples: [String] = []
            let sampler = Task { @MainActor in
                let start = Date()
                while !Task.isCancelled {
                    let now = run.read()
                    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let who = front == target.processIdentifier ? "target" : front == getpid() ? "self" : "other"
                    let flags = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                    samples.append(String(format: "%4.0fms front=%@ mine=%@ theirs=%@ marked=%@ focus=%@ mods=%llx", Date().timeIntervalSince(start) * 1000,
                                          who, InputSourceSwitch.currentID() ?? "-", now?.source ?? "-", (now?.marked ?? false) ? "y" : "n", now?.focus ?? "-",
                                          flags.rawValue))
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
            }
            var result = await body()
            sampler.cancel()
            // Keep the first second and the last half second of the samples.
            result["timeline"] = samples.count > 70 ? Array(samples.prefix(50)) + ["…"] + Array(samples.suffix(20)) : samples
            return result
        }

        func record(_ result: [String: Any], expect: String) async {
            var final = result
            let seen = run.read()
            final["a"] = seen?.a ?? ""
            final["b"] = seen?.b ?? ""
            final["markedAfter"] = seen?.marked ?? false
            final["sourceAfter"] = seen?.source ?? ""
            final["pass"] = seen?.a == expect && seen?.b == "" && seen?.marked == false
            run.cases.append(final)
            _ = await run.send("clear")
        }

        func front() async {
            target.activate()
            _ = await run.until(3) { $0.active && $0.key }
            _ = await run.send("focusA")
        }

        // This copy's window takes the keyboard, as a click on the panel does.
        func panelInFront() async {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            for _ in 0..<100 where NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        func typeCase(_ name: String, from origin: ClipboardTyper.Origin, expect: String,
                      prepare: () async -> FocusReturn?) async {
            await front()
            let returning = await prepare()
            let result = await timeline {
                var result: [String: Any] = ["case": name, "returning": returning != nil]
                do {
                    let count = try await ClipboardTyper.type(sample, into: target, from: origin, returning: returning,
                                                              userInputs: { 0 }, progress: { _, _ in })
                    result["typed"] = count
                } catch {
                    result["error"] = error.localizedDescription
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                return result
            }
            await record(result, expect: expect)
        }

        await typeCase("shortcut", from: .shortcut, expect: sample) { nil }
        await typeCase("panel", from: .panel, expect: sample) {
            let left = FocusReturn.capture()
            await panelInFront()
            out["focusReadableWhileInactive"] = left?.isBack() ?? false
            return left
        }
        // The keyboard moved to the other field meanwhile: nothing may be typed.
        await typeCase("panel-moved", from: .panel, expect: "") {
            let left = FocusReturn.capture()
            await panelInFront()
            _ = await run.send("focusB")
            return left
        }
        // Where the keyboard was is not known (out came in front by the keyboard): nothing typed.
        await typeCase("panel-unknown", from: .panel, expect: "") {
            await panelInFront()
            return nil
        }

        // The Mac behind a remote desktop: its keys come in as US keys from outside (posted here from
        // the background, as a remote desktop's agent posts them), first with nothing done about the
        // input method there, then with LayoutHold as out does when the typing Mac asks.
        let remoteSample = "Hello World abc 123, xyz! Q.E.D."
        let keys = KeystrokePlan.steps(for: remoteSample, layout: KeystrokePlan.usKeys)
        func farCase(_ name: String, hold: Bool) async {
            await front()
            let result = await timeline {
                var result: [String: Any] = ["case": name]
                if hold { result["held"] = await LayoutHold.begin() }
                for step in keys {
                    KeyPoster.post(step)
                    try? await Task.sleep(nanoseconds: KeystrokePlan.pause(after: step) * 1_000_000)
                }
                if hold { LayoutHold.end() }
                try? await Task.sleep(nanoseconds: 700_000_000)
                return result
            }
            await record(result, expect: remoteSample)
        }
        await farCase("far-without-hold", hold: false)
        await farCase("far-with-hold", hold: true)
        out["sourceAfterFarHold"] = InputSourceSwitch.currentID() ?? ""
        panel.orderOut(nil)
        out["cases"] = run.cases
        out["sourceAtEnd"] = InputSourceSwitch.currentID() ?? ""
        // The case without the hold shows what a remote desktop's keys did before: it is expected to fail.
        return run.cases.allSatisfy { $0["pass"] as? Bool == true || $0["case"] as? String == "far-without-hold" }
    }
}

/// The app typed into by the self-test: a window with a text view (a) over a text field (b).
@MainActor
enum TypingTestTarget {
    private static var window: NSWindow?
    private static var fieldA: NSTextView?
    private static var fieldB: NSTextField?
    private static var seq = 0
    private static var done = 0

    static func run(state: String) {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "out typing self-test (target)"
        window.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 20, y: 70, width: 480, height: 150)
        let fieldA = scroll.documentView as? NSTextView
        fieldA?.isRichText = false
        fieldA?.isAutomaticQuoteSubstitutionEnabled = false
        fieldA?.isAutomaticDashSubstitutionEnabled = false
        fieldA?.isAutomaticTextReplacementEnabled = false
        fieldA?.isAutomaticSpellingCorrectionEnabled = false
        let fieldB = NSTextField(frame: NSRect(x: 20, y: 20, width: 480, height: 28))
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(fieldB)
        window.center()
        self.window = window; self.fieldA = fieldA; self.fieldB = fieldB
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(fieldA)
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { tick(state) }
        }
    }

    private static func tick(_ state: String) {
        guard let window, let fieldA, let fieldB else { return }
        if let body = try? String(contentsOfFile: state + ".cmd", encoding: .utf8) {
            let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, let id = Int(parts[0]), id > done {
                switch parts[1] {
                case "clear":
                    fieldA.inputContext?.discardMarkedText()
                    fieldA.unmarkText()
                    fieldA.string = ""
                    if let editor = fieldB.currentEditor() as? NSTextView { editor.inputContext?.discardMarkedText(); editor.unmarkText() }
                    fieldB.stringValue = ""
                case "focusA": window.makeFirstResponder(fieldA)
                case "focusB": window.makeFirstResponder(fieldB)
                case "pinyin":
                    let filter = [kTISPropertyInputSourceID as String: "com.apple.inputmethod.SCIM.ITABC"] as CFDictionary
                    if let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource], let pinyin = list.first {
                        TISSelectInputSource(pinyin)
                    }
                case "quit": NSApp.terminate(nil)
                default: break
                }
                done = id
            }
        }
        let editor = fieldB.currentEditor() as? NSTextView
        let responder = window.firstResponder
        let focus = responder === fieldA ? "a" : (editor != nil && responder === editor) ? "b" : "other"
        seq += 1
        let marked = fieldA.hasMarkedText() || (editor?.hasMarkedText() ?? false)
        let record: [String: Any] = [
            "seq": seq, "active": NSApp.isActive, "key": window.isKeyWindow, "focus": focus,
            "a": fieldA.string, "b": editor?.string ?? fieldB.stringValue, "marked": marked,
            "source": InputSourceSwitch.currentID() ?? "", "done": done,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: URL(fileURLWithPath: state), options: .atomic)
        }
    }
}

extension KeyPoster {
    /// One key, down and up, with no modifier: the self-test's probe for a composing input method.
    @MainActor static func postForTest(code: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }
}
#endif
