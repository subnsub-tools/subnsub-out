import AppKit
import AVFoundation
import Combine
import CryptoKit
import CoreImage
import CoreMedia
import ImageIO
import Network
import QingyanCore
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

/// Another Mac's screen in a window of out's own (user 2026-11-21: a screen button after each Mac
/// in Multiple Macs opens it; the Macs there can be worked from each other's out without a switch).
/// What it shows is that Mac's own Screen Sharing in its High Performance mode, which the Monitor
/// helper there signs in to with the account given here (ScreenHost, helper/go/screenhp.go): the
/// picture, the sound, the pointer's shape, the clipboard both ways, and the pointer, the keys and
/// the wheel sent back. The account is asked for once and kept in this Mac's keychain. One window a Mac.
///
/// The window has what Screen Sharing's own has (user 2026-11-22: and the features of macOS's own
/// Screen Sharing go without saying): the shared clipboard always, and as buttons down its right
/// side full screen, Scaling, Dynamic Resolution (a display of the session's own that follows the
/// window), Full Quality without it, the sound, keys this Mac keeps for itself and Info; each kept
/// for each Mac. Under the picture, always, what is known of the way there (ScreenInfo): the road,
/// the path (direct, a peer relay or DERP) with a ping a second, the picture's size, codec, frame
/// rate and bit rate; a click there, or Info, shows everything. The window is glass, as out's panel
/// is (user 2026-11-22: the same glass design as out's own window): its title strip, the space around
/// the picture and the line under it.
@MainActor
final class ScreenViewer: NSObject, NSWindowDelegate {
    private static var open: [String: ScreenViewer] = [:]

    /// The Mac whose screen is in the window in front: out is the app in front, and the window is
    /// its key window. Dictation goes to that Mac, as it goes behind a remote desktop.
    static var frontKey: String? {
        guard NSApp.isActive else { return nil }
        // Only while the window works that Mac: observing, the text is not for it.
        return open.values.first { $0.window.isKeyWindow && $0.live && $0.view.canControl }?.device.key
    }

    static func show(_ device: TrustedDevice, controller: DictationController) {
        NSApp.activate(ignoringOtherApps: true)
        if let viewer = open[device.key] {
            viewer.window.makeKeyAndOrderFront(nil)
            if viewer.ended { viewer.connect() }
            return
        }
        let viewer = ScreenViewer(device: device, controller: controller)
        open[device.key] = viewer
        viewer.window.makeKeyAndOrderFront(nil)
        viewer.connect()
    }

    let device: TrustedDevice
    private weak var controller: DictationController?
    let window: NSWindow
    private let container: ScreenContainer
    private var view: ScreenView { container.screen }
    private let info: ScreenInfo
    private var link: ScreenLink?
    private var ended = true
    /// The screen is shown: a window still connecting, or one that says why it is not, takes no dictation.
    private(set) var live = false
    private var sized = false
    private var resizeWork: DispatchWorkItem?
    /// The size last asked of that Mac for the session's display, so the same one is not asked twice
    /// (each asking has that Mac make the display again, and the picture stops meanwhile).
    private var askedSize: (w: Int, h: Int, scale: Double)?
    /// That Mac is making its display again (Dynamic Resolution switched, or the window resized with
    /// it): the picture is blurred, as Screen Sharing blurs its own (user 2026-11-23), until a picture
    /// of the new display has come and, for a new size, the layout that says it; at most `reshapeLimit`.
    private var reshaping: (layout: Bool, picture: Bool)?
    private var reshapeWork: DispatchWorkItem?
    private static let reshapeLimit: TimeInterval = 8
    private var clipboardSeen = 0
    private var clipboardTimer: Timer?
    /// The codecs both sides take, from the other Mac's hello, for the open that follows the sign-in.
    private var codecs: [String] = ["avc"]
    /// The account the session is opening with, kept once the session is live when asked to; and one
    /// typed after a session ended, for the next.
    private var signingIn: (account: ScreenSignIn, remember: Bool)?
    private var typed: (account: ScreenSignIn, remember: Bool)?
    /// That Mac takes the pointer and the keys from this window (an out before 0.1.60 there may not).
    private var inputAllowed = true
    private var pathTask: Task<Void, Never>?
    private var pathConnection: NWConnection?
    private var tallyTimer: Timer?
    private var tallied: (frames: Int, bytes: Int, at: TimeInterval)?

    // MARK: What the window keeps for each Mac

    private func kept(_ name: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: "screen.\(name)." + device.key) as? Bool ?? fallback
    }
    private func keep(_ name: String, _ value: Bool) { UserDefaults.standard.set(value, forKey: "screen.\(name)." + device.key) }

    /// A display of the session's own, which takes the window's size: that Mac's own displays are
    /// dark while it lasts.
    private var ownDisplay: Bool {
        get { UserDefaults.standard.bool(forKey: "screenOwnDisplay." + device.key) }
        set { UserDefaults.standard.set(newValue, forKey: "screenOwnDisplay." + device.key) }
    }
    /// The picture scaled to fit the window; off, at its own size, the window scrolling over it.
    private var scaled: Bool { get { kept("scaled", true) } set { keep("scaled", newValue) } }
    /// Only watching by choice: never now, and with no button (user 2026-11-23: no Observe button; a
    /// window works that Mac once its picture is double-clicked, see `engaged`). A Mac whose Screen
    /// Sharing lets this account watch only is still only watched (inputAllowed).
    private var observing: Bool { get { false } set {} }
    private var fullQuality: Bool { get { kept("fullQuality", false) } set { keep("fullQuality", newValue) } }
    private var sound: Bool { get { kept("sound", true) } set { keep("sound", newValue) } }
    /// Always, with no button (user 2026-11-23: the shared clipboard must be on, and may have no button).
    private var sharedClipboard: Bool { get { true } set {} }
    /// The pointer and the keys go to that Mac. In a window, only after a double-click on the picture,
    /// until the window is no longer in front: before that a press on the picture moves the window
    /// (user 2026-11-23: in a window, a press drags the whole window, and only a double-click starts
    /// working that Mac, the pointer going through). In full screen, always.
    private var engaged = false
    /// Full Quality: the most the helper lets Screen Sharing send; Adaptive, its usual ceiling.
    private static let fullKbps = 60_000
    /// A display of the session's own is always sent at full quality (user 2026-11-23: with Dynamic
    /// Resolution on there is no Full Quality button).
    private var kbps: Int { fullQuality || ownDisplay ? Self.fullKbps : ScreenWire.kbpsDefault }

    private init(device: TrustedDevice, controller: DictationController) {
        self.device = device
        self.controller = controller
        info = ScreenInfo(device: device.label)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1024, visible.width * 0.8), height: min(640, visible.height * 0.8))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        container = ScreenContainer(frame: NSRect(origin: .zero, size: size), info: info)
        super.init()
        // The title for the Window menu and Mission Control; the window draws its own row.
        window.title = tr("%@ — Screen", device.label)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.contentMinSize = NSSize(width: 600, height: 300)
        window.center()
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        container.scaled = scaled
        container.onAct = { [weak self] action in self?.act(action) }
        container.overlay.onReconnect = { [weak self] in self?.connect() }
        container.overlay.onSignIn = { [weak self] account, password, remember in
            guard let self else { return }
            self.window.makeFirstResponder(self.view)
            self.signIn(ScreenSignIn(account: account, password: password), remember: remember)
        }
        container.onInfo = { [weak self] in self?.info.showingInfo.toggle() }
        view.send = { [weak self] frame in self?.link?.send(frame) }
        view.onEngage = { [weak self] in
            guard let self, self.live, !self.engaged else { return }
            self.engaged = true
            self.applyControl()
            // What was copied here meanwhile goes over now.
            self.sendClipboard()
        }
        info.sound = sound
        info.observing = observing
        info.fullQuality = fullQuality
        info.own = ownDisplay
        info.scaled = scaled
        info.clipboard = sharedClipboard
        watchPath()
    }

    // MARK: The session

    private func connect() {
        guard let controller, let identity = controller.identity else {
            container.say(tr("This Mac has no identity for working with other Macs yet. Open Multiple Macs on the panel first."), again: false)
            return
        }
        link?.close()
        ended = false
        live = false
        sized = false
        inputAllowed = true
        tallied = nil
        stopTally()
        view.reset()
        view.showsPicture = false
        container.banner = nil
        info.reset()
        container.say(tr("Connecting to %@…", device.label), again: false)
        let device = device, name = controller.deviceName, listening = controller.settings.preferences.remotePort
        let next = ScreenLink(name: device.label)
        next.muted = !sound
        link = next
        next.onStatus = { [weak self, weak next] status in
            guard let self, let next, self.link === next else { return }
            self.status(status)
        }
        next.onHello = { [weak self, weak next] hello, codecs in
            guard let self, let next, self.link === next else { return }
            self.hello(hello, codecs: codecs)
        }
        next.onLayout = { [weak self, weak next] layout in
            guard let self, let next, self.link === next else { return }
            self.view.remoteLayout = layout
            self.fitWindow(to: layout)
            self.reshapeCame(layout: true)
        }
        next.onPicture = { [weak self, weak next] in
            guard let self, let next, self.link === next else { return }
            self.reshapeCame(picture: true)
        }
        next.onCodec = { [weak self, weak next] codec in
            guard let self, let next, self.link === next else { return }
            self.info.codec = codec
        }
        next.onClipboard = { [weak self, weak next] text in
            guard let self, let next, self.link === next, self.sharedClipboard else { return }
            // Only the window in front: another one's text would be sent on to the Mac in front.
            guard NSApp.isActive, self.window.isKeyWindow else { return }
            // Through the lease, so that a dictation on its way to a paste keeps the clipboard until it lands.
            PasteboardLease.general.keep(text)
            self.clipboardSeen = NSPasteboard.general.changeCount
        }
        next.onCursor = { [weak self, weak next] cursor in
            guard let self, let next, self.link === next else { return }
            self.view.remoteCursor = cursor
        }
        next.onEnd = { [weak self, weak next] why in
            guard let self, let next, self.link === next else { return }
            self.end(why)
        }
        view.displayLayer = next.displayLayer
        publish()
        Task { @MainActor [weak self] in
            do {
                let connection = try await RemoteSender.openScreen(device, identity: identity, name: name, listening: listening)
                guard let self, self.link === next, !self.ended else { connection.cancel(); return }
                self.info.route = HelperLink.route(of: connection) ?? ""
                next.start(connection, scale: self.window.backingScaleFactor)
            } catch {
                guard let self, self.link === next else { return }
                self.ended = true
                self.publish()
                self.container.say(error.localizedDescription, again: true)
            }
        }
    }

    private func status(_ status: [String: Any]) {
        guard let state = status["s"] as? String else { return }
        switch state {
        case "connecting":
            container.say(tr("Signing in to %@’s Screen Sharing…", device.label), again: false)
        case "live":
            live = true
            container.say(nil, again: false)
            inputAllowed = status["input"] as? Bool != false
            applyControl()
            view.showsPicture = true
            // The keys go to that Mac, however the session was started (a title row button may hold
            // the focus after Connect pressed from the keyboard).
            window.makeFirstResponder(view)
            container.banner = inputAllowed ? nil
                : tr("View only: out on %@ has no Accessibility permission, so the pointer and keys do not reach it.", device.label)
            if inputAllowed, !view.canControl { flash(tr("Double-click the picture to work %@. Until then, a drag moves the window.", device.label)) }
            info.live = true
            info.viewOnly = !inputAllowed
            info.since = Date()
            info.own = status["own"] as? Bool ?? ownDisplay
            if info.codec.isEmpty, let codec = status["codec"] as? String { info.codec = codec }
            if observing { link?.send(ScreenWire.control(["t": "mode", "observe": true])) }
            if let signingIn {
                info.account = signingIn.account.account
                // Kept only once it has been taken.
                if signingIn.remember {
                    if let failure = signingIn.account.save(for: device.key) { flash(failure) }
                } else { ScreenSignIn.forget(device.key) }
                self.signingIn = nil
            }
            if sharedClipboard {
                clipboardSeen = 0
                sendClipboard()
                startClipboardWatch()
            }
            startTally()
            publish()
        case "stats":
            var numbers: [String: Double] = [:]
            for key in ["fps", "kbps", "audio", "lost", "keyframes", "bad", "dropped", "asks"] {
                if let value = status[key] as? NSNumber { numbers[key] = value.doubleValue }
            }
            info.helper = numbers
        case "cursor":
            if status["picture"] as? Bool == true { view.cursorInPicture = true }
        case "clip":
            if status["ok"] as? Bool == false {
                flash(tr("This text did not reach %@’s clipboard: it is too long, or the helper on that Mac is older than 2026.11.23.1 and takes Latin-1 text only.", device.label))
            }
        default:
            break
        }
    }

    /// The pointer and the keys go to that Mac only while the session is live, that Mac takes them,
    /// and the window is not observing.
    private func applyControl() {
        view.canControl = live && inputAllowed && !observing && (engaged || window.styleMask.contains(.fullScreen))
        publish()
    }

    /// What the title row shows of the session.
    private func publish() {
        info.ended = ended
        info.controlling = view.canControl
        container.live = live && !ended
    }

    private func end(_ why: String) {
        guard !ended else { return }
        ended = true
        live = false
        reshaped(animated: false)
        info.live = false
        applyControl()
        stopClipboardWatch()
        stopTally()
        view.releaseAll()
        view.showsPicture = false
        publish()
        let name = device.label
        let words: String
        switch why {
        case "auth":
            // The account was not taken: it is asked for again, and not kept.
            ScreenSignIn.forget(device.key)
            let tried = signingIn?.account.account ?? ""
            signingIn = nil
            container.askSignIn(device: name, account: tried, error: tr("%@ did not accept that account name and password.", name))
            return
        case "busy": words = tr("%@’s screen is being shown elsewhere. Try again once that has ended.", name)
        case "perm-screen": words = tr("out on %@ may not record its screen. On that Mac, turn out on in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen out there.", name)
        case "stopped", "off": words = tr("%@ stopped showing its screen.", name)
        case "no-vnc": words = tr("Screen Sharing is off on %@. Turn it on there in System Settings → General → Sharing.", name)
        case "no-hp", "no-media": words = tr("%@’s Screen Sharing did not start its High Performance mode.", name)
        case "helper-old": words = tr("The Monitor helper on %@ is too old to show its screen. It updates itself; or update it from the Monitor page.", name)
        case "helper": words = tr("The Monitor helper on %@ is not running.", name)
        case "no-display", "capture-stopped", "failed": words = tr("%@’s screen could not be shown.", name)
        default: words = tr("The connection to %@ was lost.", name)
        }
        signingIn = nil
        container.say(words, again: true)
    }

    /// Ends the session here; Connect starts the next.
    private func disconnect() {
        guard !ended else { return }
        ended = true
        live = false
        reshaped(animated: false)
        info.live = false
        stopClipboardWatch()
        stopTally()
        view.releaseAll()
        applyControl()
        view.showsPicture = false
        link?.close()
        link = nil
        signingIn = nil
        publish()
        container.say(tr("Disconnected from %@.", device.label), again: true)
    }

    private var flashWork: DispatchWorkItem?
    /// A line over the picture for a few seconds.
    private func flash(_ words: String) {
        flashWork?.cancel()
        container.banner = words
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.container.banner = self.inputAllowed ? nil
                : tr("View only: out on %@ has no Accessibility permission, so the pointer and keys do not reach it.", self.device.label)
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: Signing in to that Mac's Screen Sharing

    /// The other Mac's first word. A Mac whose out shows its screen through Screen Sharing asks for
    /// an account: the one kept for it, else the one typed into the window.
    private func hello(_ hello: [String: Any], codecs: [String]) {
        self.codecs = codecs
        if let typed {
            self.typed = nil
            open(typed.account, remember: typed.remember)
            return
        }
        if let kept = ScreenSignIn.load(device.key) {
            open(kept, remember: true)
            return
        }
        // The form on the window's glass, not over the picture kept from before.
        reshaped(animated: false)
        container.askSignIn(device: device.label, account: hello["user"] as? String ?? "", error: nil)
    }

    private func signIn(_ account: ScreenSignIn, remember: Bool) {
        // Typed after the last session ended (a password that was not taken): a new one, with it.
        guard !ended, link != nil else { typed = (account, remember); connect(); return }
        open(account, remember: remember)
    }

    private func open(_ account: ScreenSignIn, remember: Bool) {
        signingIn = (account, remember)
        var fields: [String: Any] = ["t": "open", "codecs": codecs, "audio": true, "kbps": kbps,
                                     "user": account.account, "password": account.password]
        askedSize = nil
        if ownDisplay {
            let size = container.pictureSize
            let asked = (w: max(Int(size.width), 640), h: max(Int(size.height), 400), scale: Double(window.backingScaleFactor))
            fields["own"] = true
            fields["w"] = asked.w
            fields["h"] = asked.h
            fields["scale"] = asked.scale
            askedSize = asked
        }
        container.say(tr("Signing in to %@’s Screen Sharing…", device.label), again: false)
        link?.send(ScreenWire.control(fields))
    }

    /// The window in the proportions of that Mac's display, as large as fits most of this screen
    /// the first time; later, while scaled, the window keeps them as it is resized.
    private func fitWindow(to layout: ScreenWire.Layout) {
        info.layout = layout
        guard !sized else { return }
        sized = true
        // A display of the session's own takes the window's size: the window stays as it is.
        guard !window.styleMask.contains(.fullScreen), !ownDisplay else { askSize(); return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        // The title row and the line under the picture.
        let chrome = NSSize(width: window.frame.width - container.pictureSize.width, height: window.frame.height - container.pictureSize.height)
        let room = CGRect(origin: .zero, size: CGSize(width: visible.width * 0.85 - chrome.width, height: max(visible.height * 0.85 - chrome.height, 200)))
        let fitted = ScreenWire.fit((layout.width, layout.height), in: room)
        let frame = NSSize(width: min(fitted.width, CGFloat(layout.width)).rounded() + chrome.width,
                           height: min(fitted.height, CGFloat(layout.height)).rounded() + chrome.height)
        window.setFrame(NSRect(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2, width: frame.width, height: frame.height), display: true)
        askSize()
    }

    /// The window's room for the picture, for a display of the session's own (the other Mac's own
    /// displays stay as they are).
    private func askSize() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ended else { return }
            let size = self.container.pictureSize
            guard size.width >= 160, size.height >= 120 else { return }
            let asking = (w: Int(size.width), h: Int(size.height), scale: Double(self.window.backingScaleFactor))
            if let asked = self.askedSize, asked == asking { return }
            self.askedSize = asking
            self.link?.send(ScreenWire.control(["t": "size", "w": asking.w, "h": asking.h, "scale": asking.scale]))
            // A display of the session's own is made again at a new size (the helper takes 320 × 200
            // to 7680 × 4320); the Mac's own display, or one already that size, is not.
            if self.live, self.info.own, self.view.showsPicture, let shown = self.view.remoteLayout,
               shown.width != asking.w || shown.height != asking.h,
               (320...7680).contains(asking.w), (200...4320).contains(asking.h) {
                self.reshape(awaitingLayout: true)
            }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Blurs the picture while that Mac makes its display again.
    private func reshape(awaitingLayout: Bool) {
        reshaping = (layout: !awaitingLayout, picture: false)
        view.blur()
        reshapeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reshaped(animated: true) }
        reshapeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reshapeLimit, execute: work)
    }

    private func reshapeCame(layout: Bool = false, picture: Bool = false) {
        guard var waiting = reshaping else { return }
        waiting.layout = waiting.layout || layout
        waiting.picture = waiting.picture || picture
        reshaping = waiting
        if waiting.layout && waiting.picture { reshaped(animated: true) }
    }

    /// The new display is shown: the blur clears as Screen Sharing's does; at once when the session
    /// ended, the window asks for an account, or Reduce Motion is on.
    private func reshaped(animated: Bool) {
        reshapeWork?.cancel()
        reshapeWork = nil
        reshaping = nil
        view.unblur(animated: animated)
    }

    // MARK: The way there and the stream's numbers

    /// The helper's report of both roads to that Mac, a line a second, for as long as the window is
    /// open; asked for again when it stops.
    private func watchPath() {
        guard pathTask == nil, let agent = HelperLink.agent(of: device.host) else { return }
        pathTask = Task { @MainActor [weak self] in
            var pause: UInt64 = 2
            while !Task.isCancelled {
                do {
                    let connection = try await HelperLink.path(agent: agent)
                    guard let self, !Task.isCancelled else { connection.cancel(); return }
                    self.pathConnection = connection
                    self.info.pathNote = nil
                    pause = 2
                    do {
                        while !Task.isCancelled { self.info.add(try await HelperLink.pathLine(connection)) }
                    } catch {}
                    connection.cancel()
                    self.pathConnection = nil
                    // What the report said last is no longer the path.
                    self.info.pathLost()
                } catch {
                    if Task.isCancelled { return }
                    let code = (error as? VoiceError)?.message ?? ""
                    if code == "unknown-op" {
                        // A helper before the report: the next one this Mac gets tells it.
                        self?.info.pathNote = tr("The Monitor helper on this Mac is too old to report the path. It updates itself.")
                        pause = 300
                    } else if code == "unknown-peer" {
                        self?.info.pathNote = tr("The Monitor helper on this Mac does not know that Mac yet.")
                    }
                }
                try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
                pause = min(pause * 2, 300)
            }
        }
    }

    private func startTally() {
        stopTally()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tally() } }
        RunLoop.main.add(timer, forMode: .common)
        tallyTimer = timer
    }

    private func stopTally() { tallyTimer?.invalidate(); tallyTimer = nil }

    /// What this Mac took in over the last second.
    private func tally() {
        guard let link else { return }
        link.tally { [weak self, weak link] frames, bytes in
            guard let self, let link, self.link === link else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let last = self.tallied, now > last.at, frames >= last.frames, bytes >= last.bytes {
                let seconds = now - last.at
                self.info.local = (Double(frames - last.frames) / seconds, Double(bytes - last.bytes) * 8 / 1000 / seconds)
            }
            self.tallied = (frames, bytes, now)
        }
    }

    // MARK: The buttons: what Screen Sharing's own window has

    private func act(_ action: ScreenAction) {
        switch action {
        case .observe(let on):
            setObserving(on)
        case .scaling(let on):
            scaled = on
            info.scaled = on
            container.scaled = on
            if on { keepProportions() }
        case .dynamic(let on):
            ownDisplay = on
            info.own = on
            // A session's display is chosen as it opens: it opens again. What was shown stays,
            // blurred, until the new display's first picture.
            if !ended || live {
                if live, view.hold() { reshape(awaitingLayout: false) }
                connect()
            }
        case .quality(let on):
            fullQuality = on
            info.fullQuality = on
            if live { link?.send(ScreenWire.control(["t": "kbps", "kbps": kbps])) }
        case .clipboard(let on):
            sharedClipboard = on
            info.clipboard = on
            if on, live {
                clipboardSeen = 0
                sendClipboard()
                startClipboardWatch()
            } else { stopClipboardWatch() }
        case .sound(let on):
            sound = on
            info.sound = on
            link?.muted = !on
        case .keys:
            guard live, view.canControl else { return }
            // Where the pointer is: on the Keys button, when it was pressed with the pointer.
            keysMenu().popUp(positioning: nil, at: container.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: container)
            return
        case .screenshot:
            screenshot()
        case .fullScreen:
            window.toggleFullScreen(nil)
        case .connection:
            if ended { connect() } else { disconnect() }
        }
        // The keys go on to that Mac after a press of a button.
        if live { window.makeFirstResponder(view) }
    }

    private func setObserving(_ value: Bool) {
        guard value != observing else { return }
        observing = value
        info.observing = value
        // What is held goes up there before the keys stay here.
        if value { view.releaseAll() }
        applyControl()
        if live {
            link?.send(ScreenWire.control(["t": "mode", "observe": value]))
            if !value, sharedClipboard { sendClipboard() }
        }
    }

    /// Keys this Mac's system takes before any window hears them, sent to that Mac from a menu.
    private func keysMenu() -> NSMenu {
        let menu = NSMenu()
        let combos: [(String, [UInt16])] = [
            (tr("Switch Apps (⌘Tab)"), [0x37, 0x30]),
            (tr("Spotlight (⌘Space)"), [0x37, 0x31]),
            (tr("Mission Control (⌃↑)"), [0x3B, 0x7E]),
            (tr("App Windows (⌃↓)"), [0x3B, 0x7D]),
            (tr("Force Quit (⌥⌘Esc)"), [0x3A, 0x37, 0x35]),
            (tr("Lock Screen (⌃⌘Q)"), [0x3B, 0x37, 0x0C]),
        ]
        for (title, codes) in combos {
            let entry = NSMenuItem(title: title, action: #selector(sendCombo(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = codes.map { NSNumber(value: $0) }
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func sendCombo(_ sender: NSMenuItem) {
        guard live, let codes = sender.representedObject as? [NSNumber] else { return }
        view.combo(codes.map(\.uint16Value))
    }

    private func screenshot() {
        guard live, let link else { return }
        let name = device.label
        link.capture { [weak self] image in
            guard let self else { return }
            guard let image else { self.flash(tr("No picture came from %@ in time for the screenshot.", name)); return }
            self.flash(self.save(image))
        }
    }

    /// The picture as a PNG on this Mac's Desktop; what to say of it.
    private func save(_ image: CGImage) -> String {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = device.label.map { "/:".contains($0) ? "-" : $0 }
        let base = String(safe) + " " + stamp.string(from: Date())
        // Never over another picture: a second one in the same second gets a number.
        var url = desktop.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return tr("The screenshot could not be saved to the Desktop.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return tr("The screenshot could not be saved to the Desktop.") }
        return tr("Saved to the Desktop as “%@”.", url.lastPathComponent)
    }

    // MARK: The clipboard: this Mac's text goes over while the window is in front

    private func startClipboardWatch() {
        stopClipboardWatch()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window.isKeyWindow == true { self?.sendClipboard() } }
        }
        timer.tolerance = 0.3
        clipboardTimer = timer
    }

    private func stopClipboardWatch() { clipboardTimer?.invalidate(); clipboardTimer = nil }

    private func sendClipboard() {
        guard !ended, live, sharedClipboard, view.canControl, NSApp.isActive, window.isKeyWindow else { return }
        let board = NSPasteboard.general
        guard board.changeCount != clipboardSeen else { return }
        clipboardSeen = board.changeCount
        guard let text = board.string(forType: .string), !text.isEmpty, text.utf8.count <= ScreenWire.clipboardLimit else { return }
        let frame = ScreenWire.control(["t": "clip", "text": text])
        // Its JSON, quotes and line breaks escaped, must still be a frame the other Mac takes, or the session ends.
        guard frame.count - 4 <= ScreenWire.controlLimit else { return }
        link?.send(frame)
    }

    // MARK: The window

    func windowDidBecomeKey(_ notification: Notification) { sendClipboard() }

    func windowDidResignKey(_ notification: Notification) {
        // Keys and buttons held here are let go there: this window no longer hears them go up.
        view.releaseAll()
        // And the window stops working that Mac until its picture is double-clicked again.
        if engaged { engaged = false; applyControl() }
    }

    /// While scaled, and the other Mac's display is its own size, the window keeps its proportions.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard scaled, !ownDisplay, let layout = view.remoteLayout, layout.width > 0, layout.height > 0,
              !sender.styleMask.contains(.fullScreen) else { return frameSize }
        // The title row and the line under the picture take the same height whatever the size.
        let picture = container.pictureSize
        let chrome = NSSize(width: sender.frame.width - picture.width, height: sender.frame.height - picture.height)
        let width = frameSize.width - chrome.width
        return NSSize(width: frameSize.width, height: (width * CGFloat(layout.height) / CGFloat(layout.width)).rounded() + chrome.height)
    }

    /// Scaling turned on: the window takes the display's proportions at its width.
    private func keepProportions() {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let size = windowWillResize(window, to: window.frame.size)
        guard size != window.frame.size else { return }
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true, animate: true)
    }

    func windowDidEndLiveResize(_ notification: Notification) { askSize() }
    /// A size the window took without being dragged to it (the zoom button, the system's window
    /// tiling, a move to a display of another scale): the session's display follows that too. While
    /// it is dragged, only where the drag ends is asked for (above).
    func windowDidResize(_ notification: Notification) {
        guard !window.inLiveResize else { return }
        askSize()
    }
    func windowDidChangeBackingProperties(_ notification: Notification) { askSize() }
    func windowDidExitFullScreen(_ notification: Notification) { info.fullScreen = false; applyControl(); askSize() }
    // Black around the picture from the moment the window leaves for full screen until it starts back.
    func windowWillEnterFullScreen(_ notification: Notification) { container.fullScreen = true }
    func windowWillExitFullScreen(_ notification: Notification) { container.fullScreen = false }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { container.fullScreen = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { container.fullScreen = true }
    func windowDidEnterFullScreen(_ notification: Notification) { info.fullScreen = true; applyControl(); askSize() }

    func windowWillClose(_ notification: Notification) {
        ended = true
        live = false
        reshaped(animated: false)
        stopClipboardWatch()
        stopTally()
        view.releaseAll()
        link?.close()
        link = nil
        pathTask?.cancel()
        pathTask = nil
        pathConnection?.cancel()
        pathConnection = nil
        info.showingInfo = false
        Self.open.removeValue(forKey: device.key)
    }

    #if DEBUG
    /// The window in a session of made-up numbers, light and dark, in English and Chinese, and its
    /// Info: PNGs in `directory` (`Qingyan --screen-window-preview <directory>`). Nothing is dialed.
    static func preview(to directory: String, controller: DictationController) async throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func write(_ view: NSView, _ name: String) throws {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw VoiceError("Could not capture \(name).") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
            print("Rendered \(name).png")
        }
        for language in Localization.Language.allCases {
            Localization.use(language)
            for dark in [false, true] {
                let device = TrustedDevice(key: HelperLink.id("previewStudy"), name: "Study", host: HelperLink.id("previewStudy"), port: RemoteWire.defaultPort)
                let viewer = ScreenViewer(device: device, controller: controller)
                viewer.pathTask?.cancel()
                viewer.pathTask = nil
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                viewer.window.appearance = appearance
                viewer.fillForPreview()
                viewer.window.setFrame(NSRect(x: -4000, y: 200, width: 1180, height: 800), display: true)
                viewer.window.alphaValue = 0
                viewer.window.orderFrontRegardless()
                try await Task.sleep(nanoseconds: 700_000_000)
                let name = "\(language.rawValue)-\(dark ? "dark" : "light")"
                // The picture with Full Screen and More alone, as a live session shows it; then with every
                // button, the title strip and the line.
                viewer.container.chrome(shown: false, animated: false)
                try await Task.sleep(nanoseconds: 200_000_000)
                if let frame = viewer.window.contentView?.superview { try write(frame, "screen-window-bare-\(name)") }
                viewer.container.chrome(shown: true, animated: false)
                try await Task.sleep(nanoseconds: 300_000_000)
                if let frame = viewer.window.contentView?.superview { try write(frame, "screen-window-\(name)") }
                if language == .english, !dark {
                    let window = viewer.window
                    func click(_ point: NSPoint) async throws {
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                                NSApp.sendEvent(event)
                            }
                            try await Task.sleep(nanoseconds: 80_000_000)
                        }
                    }
                    // A click on the rail's Scaling button, as the mouse makes it, reaches it there (the
                    // container is the window's whole content, drawn from its top).
                    let before = viewer.info.scaled
                    let button = viewer.container.railFrame(of: ScreenRail.scalingIndex)
                    try await click(NSPoint(x: button.midX, y: window.frame.height - button.midY))
                    try await Task.sleep(nanoseconds: 300_000_000)
                    print("Scaling clicked: \(before) -> \(viewer.info.scaled)")
                    if viewer.info.scaled == before { throw VoiceError("A click on the rail did not reach its Scaling button.") }
                    viewer.act(.scaling(before))
                    // With the title strip gone, a click at the window's top left, under its title bar and
                    // where its buttons were, goes to that Mac.
                    viewer.container.chrome(shown: false, animated: false)
                    try await Task.sleep(nanoseconds: 200_000_000)
                    var sent: [Data] = []
                    let send = viewer.view.send
                    viewer.view.send = { sent.append($0) }
                    try await click(NSPoint(x: 40, y: window.frame.height - 20))
                    viewer.view.send = send
                    let pointer = ScreenWire.FromPage.pointer.rawValue
                    print("Pictured click sent: \(sent.filter { $0.first == pointer }.count) pointer frames")
                    if !sent.contains(where: { $0.first == pointer }) { throw VoiceError("A click at the top of the picture did not reach it.") }
                }
                let info = NSHostingView(rootView: ScreenInfoView(info: viewer.info, scrolls: false).background(Color(nsColor: .windowBackgroundColor)))
                info.appearance = appearance
                let height = ceil(info.fittingSize.height)
                let holder = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: ScreenInfoView.width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                holder.appearance = appearance
                holder.backgroundColor = .windowBackgroundColor
                holder.isReleasedWhenClosed = false
                holder.contentView = info
                holder.orderFrontRegardless()
                try await Task.sleep(nanoseconds: 400_000_000)
                try write(info, "screen-info-\(name)")
                holder.close()
                viewer.window.close()
            }
        }
    }

    private func fillForPreview() {
        ended = false
        live = true
        engaged = true
        applyControl()
        let layout = ScreenWire.Layout(width: 1512, height: 982, pictureWidth: 3024, pictureHeight: 1964)
        view.displayLayer = nil
        view.remoteLayout = layout
        view.showsPicture = true
        view.layer?.contents = NSImage(size: NSSize(width: 1512, height: 982), flipped: false) { rect in
            NSGradient(starting: NSColor(hue: 0.58, saturation: 0.5, brightness: 0.85, alpha: 1),
                       ending: NSColor(hue: 0.75, saturation: 0.6, brightness: 0.55, alpha: 1))?.draw(in: rect, angle: 60)
            return true
        }
        view.layer?.contentsGravity = .resizeAspect
        info.route = "tailnet"
        info.live = true
        info.layout = layout
        info.codec = "avc"
        info.account = "hopo"
        info.since = Date().addingTimeInterval(-754)
        info.helper = ["fps": 59.8, "kbps": 8420, "audio": 100, "lost": 0, "keyframes": 3, "bad": 0, "dropped": 0, "asks": 1]
        info.local = (59.6, 8390)
        for i in 0..<60 {
            let derp = i < 4
            let tailnet: [String: Any] = derp
                ? ["ok": true, "ms": 41.0 + Double(i), "via": "derp", "where": "tok", "node": "studio.tail1234.ts.net."]
                : ["ok": i != 30, "ms": 3.2 + Double(i % 7) * 0.4, "via": "direct", "where": "192.168.1.23:41641", "node": "studio.tail1234.ts.net.",
                   "why": i == 30 ? "timeout" : ""]
            let tailcat: [String: Any] = ["ok": true, "ms": 18.0 + Double(i % 5), "via": "peer-relay", "where": "100.88.12.4:7777", "node": "study"]
            info.add(["tailnet": tailnet, "tailcat": tailcat])
        }
        publish()
    }
    #endif
}

/// The connection of one session: frames in and out, the picture decoded into a display layer and
/// the sound into a player. Frames are read on a queue of its own.
final class ScreenLink: @unchecked Sendable {
    var onStatus: (@MainActor ([String: Any]) -> Void)?
    /// A hello that asks for an account, and the codecs both sides take.
    var onHello: (@MainActor ([String: Any], [String]) -> Void)?
    var onLayout: (@MainActor (ScreenWire.Layout) -> Void)?
    /// The codec of the pictures, as each decoder record names it ("avc", "hevc").
    var onCodec: (@MainActor (String) -> Void)?
    var onClipboard: (@MainActor (String) -> Void)?
    var onCursor: (@MainActor (RemoteCursor) -> Void)?
    var onEnd: (@MainActor (String) -> Void)?
    /// The first picture after a decoder record (the session's first, or a new display's once its
    /// size changed) has gone to the display layer.
    var onPicture: (@MainActor () -> Void)?

    let displayLayer = AVSampleBufferDisplayLayer()
    private let name: String
    private let queue = DispatchQueue(label: "local.hopo.qingyan.screen.viewer")
    private var connection: NWConnection?
    private var parser = ScreenWire.Parser(limit: ScreenWire.frameLimit + 8)
    private var closed = false
    private var opened = false
    /// A layout frame has said the display's size: live's own is then not taken (from a helper
    /// before 2026.11.22.5 it is the size the handshake gave, which for a display of the session's
    /// own is that of whatever the Mac showed before; the pointer went by it and drifted).
    private var laidOut = false
    private var scale: CGFloat = 2

    private var format: CMVideoFormatDescription?
    private var awaitingKey = true
    /// No picture has gone to the display layer since the last decoder record.
    private var fresh = false
    private var cursors: [UInt32: RemoteCursor.Shape] = [:]
    private let sound = ScreenSound()
    /// Pictures and their bytes taken in, for the window's count.
    private var framesIn = 0
    private var bytesIn = 0
    /// A screenshot waiting for the next whole picture.
    private var shot: (id: Int, done: @MainActor (CGImage?) -> Void)?
    private var shots = 0

    init(name: String) {
        self.name = name
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    /// The sound is not played (nor decoded) while muted; the picture goes on.
    var muted: Bool {
        get { sound.muted }
        set { sound.muted = newValue }
    }

    func start(_ connection: NWConnection, scale: CGFloat) {
        queue.async {
            self.connection = connection
            self.scale = scale
            self.receive()
        }
    }

    func send(_ frame: Data) {
        queue.async {
            guard !self.closed, let connection = self.connection else { return }
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.queue.async { self?.finish("lost") } }
            })
        }
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.connection?.cancel()
            self.sound.stop()
            self.dropShot()
        }
    }

    /// The pictures and bytes taken in so far.
    func tally(_ done: @escaping @MainActor (Int, Int) -> Void) {
        queue.async {
            let frames = self.framesIn, bytes = self.bytesIn
            self.main { done(frames, bytes) }
        }
    }

    /// The next whole picture as an image: asked for at once, and nil when none comes in five seconds.
    func capture(_ done: @escaping @MainActor (CGImage?) -> Void) {
        queue.async {
            guard !self.closed, self.format != nil else { self.main { done(nil) }; return }
            self.dropShot()
            self.shots += 1
            let id = self.shots
            self.shot = (id, done)
            self.keyAsked = .distantPast
            self.askKey()
            self.queue.asyncAfter(deadline: .now() + 5) {
                guard let waiting = self.shot, waiting.id == id else { return }
                self.dropShot()
            }
        }
    }

    private func dropShot() {
        guard let waiting = shot else { return }
        shot = nil
        main { waiting.done(nil) }
    }

    private func receive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] data, _, complete, error in
            self?.queue.async {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.take(data) }
                if complete || error != nil { self.finish("lost"); return }
                if !self.closed { self.receive() }
            }
        }
    }

    private func finish(_ why: String) {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        sound.stop()
        dropShot()
        let onEnd = onEnd
        DispatchQueue.main.async { MainActor.assumeIsolated { onEnd?(why) } }
    }

    private func main(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    private func take(_ data: Data) {
        guard let frames = parser.feed(data) else { finish("failed"); return }
        for frame in frames {
            guard !closed else { return }
            switch ScreenWire.ToPage(rawValue: frame.kind) {
            case .status:
                guard let status = (try? JSONSerialization.jsonObject(with: frame.body)) as? [String: Any], let state = status["s"] as? String else { continue }
                switch state {
                case "hello":
                    guard !opened else { continue }
                    opened = true
                    let theirs = status["codecs"] as? [String] ?? ["avc"]
                    var codecs: [String] = []
                    var hevc = theirs.contains("hevc") && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
                    #if DEBUG
                    if preferAVC { hevc = false }
                    #endif
                    if hevc { codecs.append("hevc") }
                    if theirs.contains("avc") || theirs.isEmpty { codecs.append("avc") }
                    if status["signin"] as? Bool == true {
                        // That Mac's Screen Sharing: the window asks for its account, then opens.
                        let onHello = onHello, chosen = codecs
                        main { onHello?(status, chosen) }
                        continue
                    }
                    // An out before 0.1.60 records its screen itself and asks for nothing.
                    connection?.send(content: ScreenWire.control(["t": "open", "codecs": codecs, "audio": true, "kbps": ScreenWire.kbpsDefault]),
                                     completion: .contentProcessed { _ in })
                case "live":
                    count("live")
                    if status["audio"] as? Bool == true { sound.start() }
                    if !laidOut, let w = status["w"] as? Int, let h = status["h"] as? Int, let cw = status["cw"] as? Int, let ch = status["ch"] as? Int,
                       w > 0, h > 0, cw > 0, ch > 0 {
                        let layout = ScreenWire.Layout(width: w, height: h, pictureWidth: cw, pictureHeight: ch)
                        let onLayout = onLayout
                        main { onLayout?(layout) }
                    }
                    let onStatus = onStatus
                    main { onStatus?(status) }
                case "end":
                    finish(status["why"] as? String ?? "stopped")
                default:
                    let onStatus = onStatus
                    main { onStatus?(status) }
                }
            case .videoConfig:
                configure(frame.body)
            case .videoFrame:
                picture(frame.body)
            case .audio:
                if let packet = ScreenWire.audioPacket(frame.body) { count("soundPackets"); sound.play(packet.bytes, codec: packet.codec) }
            case .layout:
                if let layout = ScreenWire.layout(frame.body) {
                    count("layouts")
                    laidOut = true
                    let onLayout = onLayout
                    main { onLayout?(layout) }
                }
            case .cursorStore:
                if let shape = ScreenWire.cursorShape(frame.body) {
                    count("cursorShapes")
                    cursors[shape.id] = RemoteCursor.Shape(shape)
                    if cursors.count > 64, let oldest = cursors.keys.min() { cursors.removeValue(forKey: oldest) }
                }
            case .cursorSelect:
                if let id = ScreenWire.cursorID(frame.body), let shape = cursors[id] {
                    let onCursor = onCursor
                    main { onCursor?(RemoteCursor(shape: shape)) }
                }
            case .clipboard:
                if let text = String(data: frame.body, encoding: .utf8) {
                    let onClipboard = onClipboard
                    main { onClipboard?(text) }
                }
            case .none:
                break
            }
        }
    }

    // MARK: The picture

    #if DEBUG
    /// For the self-test: each picture made for the display layer, and what the session counted.
    var onSample: ((CMSampleBuffer) -> Void)?
    var preferAVC = false
    private(set) var counted: [String: Int] = [:]
    private func count(_ what: String) { counted[what, default: 0] += 1 }
    var counts: [String: Int] { queue.sync { counted.merging(["soundBuffers": sound.played]) { a, _ in a } } }
    #else
    private func count(_ what: String) {}
    #endif

    /// The format a decoder reads the pictures with, from the decoder record the other Mac sent.
    static func format(codec: ScreenWire.Codec, record: Data) -> CMVideoFormatDescription? {
        guard let sets = codec == .hevc ? ScreenWire.hevcParameterSets(record) : ScreenWire.avcParameterSets(record) else { return nil }
        let pointers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let unsafe = pointers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var made: CMFormatDescription?
        let status: OSStatus = unsafe.withUnsafeBufferPointer { sp in
            sizes.withUnsafeBufferPointer { zp in
                codec == .hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                         parameterSetPointers: sp.baseAddress!, parameterSetSizes: zp.baseAddress!,
                                                                         nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &made)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                         parameterSetPointers: sp.baseAddress!, parameterSetSizes: zp.baseAddress!,
                                                                         nalUnitHeaderLength: 4, formatDescriptionOut: &made)
            }
        }
        return status == noErr ? made : nil
    }

    /// One picture as a sample for the display layer: shown as soon as it is decoded.
    static func sample(units: Data, stamp: UInt32, key: Bool, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let count = units.count
        var block: CMBlockBuffer?
        guard count > 0, CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count, blockAllocator: kCFAllocatorDefault,
                                                            customBlockSource: nil, offsetToData: 0, dataLength: count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                            blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = units.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) == kCMBlockBufferNoErr
        }
        guard copied else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(stamp), timescale: 90000), decodeTimeStamp: .invalid)
        var size = count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !key {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    /// A whole picture decoded on its own into an image (a screenshot): the display layer keeps its
    /// pictures to itself.
    static func image(_ sample: CMSampleBuffer, format: CMVideoFormatDescription) -> CGImage? {
        var made: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &made) == noErr,
              let session = made else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        final class Box { var image: CGImage? }
        let box = Box()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            guard status == noErr, let buffer else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            box.image = image
        }
        guard status == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return box.image
    }

    private func configure(_ body: Data) {
        guard body.count > 1, let codec = ScreenWire.Codec(rawValue: body[body.startIndex]),
              let made = Self.format(codec: codec, record: Data(body.dropFirst())) else { count("badConfig"); return }
        count(codec == .hevc ? "configHEVC" : "configAVC")
        format = made
        awaitingKey = true
        fresh = true
        let onCodec = onCodec
        main { onCodec?(codec.name) }
    }

    private func picture(_ body: Data) {
        guard let format, let frame = ScreenWire.videoFrame(body), !frame.units.isEmpty else { return }
        count("frames")
        framesIn += 1
        bytesIn += body.count
        if awaitingKey {
            // A picture that builds on one this window never had cannot be shown: wait for a whole one.
            guard frame.key else { count("waitedForKey"); askKey(); return }
            awaitingKey = false
        }
        guard let sample = Self.sample(units: frame.units, stamp: frame.stamp, key: frame.key, format: format) else { count("badSample"); return }
        #if DEBUG
        onSample?(sample)
        #endif
        if frame.key, let waiting = shot, let image = Self.image(sample, format: format) {
            shot = nil
            main { waiting.done(image) }
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            // The decoder gave up: start again from a whole picture.
            count("rendererFailed")
            renderer.flush()
            awaitingKey = true
            askKey()
            return
        }
        renderer.enqueue(sample)
        count("enqueued")
        if fresh {
            fresh = false
            let onPicture = onPicture
            main { onPicture?() }
        }
    }

    private var keyAsked = Date.distantPast
    private func askKey() {
        guard Date().timeIntervalSince(keyAsked) > 0.5 else { return }
        keyAsked = Date()
        connection?.send(content: ScreenWire.control(["t": "key"]), completion: .contentProcessed { _ in })
    }
}

/// The other Mac's sound: AAC-ELD from its Screen Sharing (AAC-LC from an out before 0.1.60), 48 kHz,
/// stereo, decoded and played as it comes, never more than a fifth of a second behind.
final class ScreenSound: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var input: AVAudioFormat?
    private var codec: UInt8 = 0
    private let pcm = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
    private let lock = NSLock()
    private var pending = 0
    private var running = false
    private var silent = false
    /// Buffers decoded and handed to the player (for the self-test).
    private(set) var played = 0

    /// What comes is let go undecoded.
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return silent }
        set { lock.lock(); silent = newValue; lock.unlock() }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running, let pcm else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcm)
        do { try engine.start(); player.play(); running = true } catch {}
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        // Stopping calls the handlers of the buffers not yet played, which take the lock.
        player.stop()
        engine.stop()
    }

    /// The decoder for a codec, made the first time it is heard. Called with the lock held.
    private func decoder(_ codec: UInt8) -> (AVAudioConverter, AVAudioFormat)? {
        if codec == self.codec, let converter, let input { return (converter, input) }
        guard let pcm else { return nil }
        let format: AVAudioFormat?
        let cookie: Data
        switch codec {
        case ScreenWire.audioAACLC:
            format = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
            // AAC-LC, 48 kHz, two channels, as out's encoder on the other Mac made it.
            cookie = Data([0x11, 0x90])
        case ScreenWire.audioAACELD:
            var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0, mBytesPerPacket: 0,
                                                          mFramesPerPacket: 480, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            format = AVAudioFormat(streamDescription: &description)
            // AAC-ELD, 48 kHz, two channels, 480 samples a packet, as Screen Sharing sends it.
            cookie = Data([0xF8, 0xE6, 0x50, 0x00])
        default:
            return nil
        }
        guard let format, let made = AVAudioConverter(from: format, to: pcm) else { return nil }
        made.magicCookie = cookie
        converter = made
        input = format
        self.codec = codec
        return (made, format)
    }

    func play(_ bytes: Data, codec: UInt8) {
        lock.lock()
        guard running, !silent, let pcm, pending < 10, bytes.count > 0, bytes.count <= 8192, let (converter, input) = decoder(codec) else { lock.unlock(); return }
        lock.unlock()
        let packet = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: bytes.count)
        bytes.withUnsafeBytes { raw in if let base = raw.baseAddress { packet.data.copyMemory(from: base, byteCount: bytes.count) } }
        packet.byteLength = UInt32(bytes.count)
        packet.packetCount = 1
        packet.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 2048) else { return }
        var given = false
        var failure: NSError?
        let status = converter.convert(to: out, error: &failure) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return packet
        }
        guard status != .error, out.frameLength > 0 else { return }
        lock.lock(); pending += 1; played += 1; lock.unlock()
        player.scheduleBuffer(out) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
        }
    }
}

/// The account a Mac's Screen Sharing is signed in to with, kept in this Mac's keychain (Vault) for
/// each Mac by its key once a session has opened with it.
struct ScreenSignIn: Codable {
    let account: String
    let password: String

    /// The keychain's name for a Mac's entry: its key hashed, as the key itself (helper:<agent>, or
    /// base64) has characters Vault does not take.
    private static func entry(_ key: String) -> String {
        "screen-signin." + SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ key: String) -> ScreenSignIn? {
        guard let data = try? Vault.read(entry(key)) else { return nil }
        return try? JSONDecoder().decode(ScreenSignIn.self, from: data)
    }

    /// Keeps it; what went wrong otherwise, to be said.
    func save(for key: String) -> String? {
        do {
            try Vault.save(try JSONEncoder().encode(self), account: Self.entry(key))
            return nil
        } catch { return error.localizedDescription }
    }

    static func forget(_ key: String) { try? Vault.delete(entry(key)) }
}

/// The other Mac's pointer shape, as a cursor for the window at its scale.
struct RemoteCursor {
    struct Shape {
        let hotX: Int, hotY: Int, width: Int, height: Int, scale: Int
        let image: NSImage?
        /// How the shape looks, for finding this Mac's own pointer of the same look (SystemCursors).
        let signature: ScreenWire.CursorSignature?
        init(_ shape: ScreenWire.CursorShape) {
            hotX = shape.hotX; hotY = shape.hotY; width = shape.width; height = shape.height; scale = shape.scale
            var pixels = [UInt8](shape.rgba)
            signature = ScreenWire.CursorSignature(rgba: pixels, width: shape.width, height: shape.height, hotX: Double(shape.hotX), hotY: Double(shape.hotY))
            let rep = pixels.withUnsafeMutableBufferPointer { buffer -> NSBitmapImageRep? in
                var planes: UnsafeMutablePointer<UInt8>? = buffer.baseAddress
                return NSBitmapImageRep(bitmapDataPlanes: &planes, pixelsWide: shape.width, pixelsHigh: shape.height, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bitmapFormat: .alphaNonpremultiplied, bytesPerRow: shape.width * 4, bitsPerPixel: 32)?.copy() as? NSBitmapImageRep
            }
            if let rep {
                let image = NSImage(size: NSSize(width: shape.width, height: shape.height))
                image.addRepresentation(rep)
                self.image = image
            } else { image = nil }
        }
    }
    let shape: Shape

    /// The cursor for a window that shows a point of that display as `pointsPerPoint` of its own.
    func cursor(pointsPerPoint k: CGFloat) -> NSCursor? {
        guard let source = shape.image else { return nil }
        let size = NSSize(width: CGFloat(shape.width) / CGFloat(shape.scale) * k, height: CGFloat(shape.height) / CGFloat(shape.scale) * k)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let image = NSImage(size: size)
        image.addRepresentations(source.representations)
        return NSCursor(image: image, hotSpot: NSPoint(x: CGFloat(shape.hotX) / CGFloat(shape.scale) * k, y: CGFloat(shape.hotY) / CGFloat(shape.scale) * k))
    }
}

/// This Mac's own pointers, each known by how it looks at a few sizes. The other Mac sends its pointer
/// as a picture at a pixel a point, whatever its display (its Screen Sharing reads it that way), so
/// drawn here it is soft on a display of two pixels a point (user 2026-11-23: the pointer in the
/// screen window is not sharp enough). A shape that is one of these is shown as this Mac's pointer of
/// that kind, which the system draws at this display's scale; any other is shown as it was sent.
@MainActor
enum SystemCursors {
    private static let known: [(NSCursor, [ScreenWire.CursorSignature])] = {
        var cursors: [NSCursor] = [.arrow, .iBeam, .crosshair, .closedHand, .openHand, .pointingHand, .iBeamCursorForVerticalLayout]
        if #available(macOS 15.0, *) {
            cursors += [.columnResize(directions: .left), .columnResize(directions: .right), .columnResize(directions: .all),
                        .rowResize(directions: .up), .rowResize(directions: .down), .rowResize(directions: .all)]
            // A window's edges and corners: opposite ones share a pointer.
            cursors += [NSCursor.FrameResizePosition.top, .left, .topLeft, .topRight].map { NSCursor.frameResize(position: $0, directions: .all) }
        } else {
            cursors += [.resizeLeft, .resizeRight, .resizeLeftRight, .resizeUp, .resizeDown, .resizeUpDown]
        }
        // Another Mac's pointer may be set larger or smaller than this one's.
        return cursors.map { cursor in (cursor, [1, 1.5, 2, 3].compactMap { signature(cursor, at: $0) }) }.filter { !$0.1.isEmpty }
    }()

    static func like(_ shape: ScreenWire.CursorSignature) -> NSCursor? { ScreenWire.cursor(like: shape, among: known) }

    private static func signature(_ cursor: NSCursor, at scale: CGFloat) -> ScreenWire.CursorSignature? {
        let image = cursor.image
        let width = Int((image.size.width * scale).rounded()), height = Int((image.size.height * scale).rounded())
        guard width > 0, height > 0, width <= 512, height <= 512,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let data = bitmap.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ScreenWire.CursorSignature(rgba: Array(UnsafeBufferPointer(start: data, count: width * height * 4)), width: width, height: height,
                                          hotX: Double(cursor.hotSpot.x * scale), hotY: Double(cursor.hotSpot.y * scale))
    }
}

/// The window's content. While the screen is shown, the picture fills the window (user 2026-11-23:
/// the whole window is the remote desktop, with no frame and no title row), and two round buttons
/// float over its right side, Full Screen and More (user 2026-11-23: no buttons at the top; two
/// floating buttons at the right). The pointer on More, or a press of it, brings the rest of the
/// buttons under them, and with them the title strip (the window's close, minimize and zoom buttons
/// and the Mac's name) over the picture's top and the line of what is known of the connection (a
/// click there opens Info) over its bottom; all go again soon after the pointer is back on the
/// picture. While the window connects, asks for an account or says why the screen is not shown, they
/// stay. Behind it all, glass as out's panel is, seen around the picture where its proportions leave room.
final class ScreenContainer: NSView {
    static let barHeight: CGFloat = 24
    /// The title strip: the window's own buttons and the Mac's name.
    static let rowHeight: CGFloat = 32
    /// The rail's distance from the window's right edge, and from the strip and the line.
    private static let railInset: CGFloat = 12
    private static let railClear: CGFloat = 6
    /// Where the window's close, minimize and zoom buttons are, as macOS places them: the middle of
    /// the row's icons and of the Mac's name is level with theirs.
    static let lightsMiddle: CGFloat = 16
    /// How long the buttons, the title strip and the line stay after the pointer is back on the picture.
    private static let lingering: TimeInterval = 0.6
    let screen = ScreenView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    let overlay = ScreenOverlay(frame: .zero)
    var onInfo: (() -> Void)?
    var onAct: ((ScreenAction) -> Void)?
    var scaled = true {
        didSet {
            guard scaled != oldValue else { return }
            screen.actual = !scaled
            needsLayout = true
        }
    }
    /// The screen is shown: the buttons under More, the title strip and the line come and go. Otherwise they stay.
    var live = false {
        didSet {
            guard live != oldValue else { return }
            if live { follow(pointer) } else { chrome(shown: true, animated: false) }
        }
    }
    private let info: ScreenInfo
    private let glass = NSVisualEffectView()
    /// In full screen the room around the picture is black, not glass (user 2026-11-23), and what is
    /// drawn over it (the title strip, the line, the words while there is no picture) is dark with it.
    private let black = NSView()
    var fullScreen = false {
        didSet {
            guard fullScreen != oldValue else { return }
            glass.isHidden = fullScreen
            black.isHidden = !fullScreen
            let dark = fullScreen ? NSAppearance(named: .darkAqua) : nil
            for view in [top, bottom, overlay, rail] as [NSView] { view.appearance = dark }
        }
    }
    private let scroll = NSScrollView()
    private let top = NSVisualEffectView()
    private let bottom = NSVisualEffectView()
    private let titleRow: NSHostingView<ScreenTitleRow>
    private let bar: NSHostingView<ScreenInfoBar>
    private let rail: ScreenRailHost
    private(set) var chromeShown = true
    private var hideTimer: Timer?
    private var tracking: NSTrackingArea?
    private var watchingInfo: AnyCancellable?

    init(frame: NSRect, info: ScreenInfo) {
        self.info = info
        titleRow = NSHostingView(rootView: ScreenTitleRow(info: info))
        bar = NSHostingView(rootView: ScreenInfoBar(info: info))
        rail = ScreenRailHost(rootView: ScreenRail(info: info))
        super.init(frame: frame)
        bar.rootView = ScreenInfoBar(info: info) { [weak self] in self?.onInfo?() }
        rail.rootView = ScreenRail(info: info, act: { [weak self] action in self?.onAct?(action) },
                                   more: { [weak self] in self?.chrome(shown: true, animated: true) })
        // Laid out here, not by their content; the title strip also ignores the title bar's safe area,
        // as the panel's does.
        titleRow.sizingOptions = []; titleRow.safeAreaRegions = []
        bar.sizingOptions = []; bar.safeAreaRegions = []
        rail.sizingOptions = []; rail.safeAreaRegions = []
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        black.wantsLayer = true
        black.layer?.backgroundColor = NSColor.black.cgColor
        black.isHidden = true
        black.frame = bounds
        black.autoresizingMask = [.width, .height]
        // Over the picture, the picture under them blurred.
        for (pane, content) in [(top, titleRow as NSView), (bottom, bar as NSView)] {
            pane.material = .hudWindow
            pane.blendingMode = .withinWindow
            pane.state = .active
            pane.addSubview(content)
        }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // From the window's very top: not set below the title bar, as a scroll view sets itself by default.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        // No scroll bars, in this window as in every other (user 2026-11-23): at its own size the
        // picture moves when the pointer reaches an edge, and with the wheel while observing.
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = screen
        screen.onLayout = { [weak self] in self?.needsLayout = true }
        for sub in [glass, black, scroll, overlay, bottom, top, rail] as [NSView] { addSubview(sub) }
        // Info open keeps them; once it closes they go as the pointer says.
        watchingInfo = info.$showingInfo.dropFirst().sink { [weak self] showing in
            guard !showing else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.follow(self?.pointer) } }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// The room the picture has: the whole window.
    var pictureSize: NSSize { bounds.size }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLights()
    }

    override func layout() {
        super.layout()
        top.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.rowHeight)
        titleRow.frame = top.bounds
        bottom.frame = NSRect(x: 0, y: bounds.height - Self.barHeight, width: bounds.width, height: Self.barHeight)
        bar.frame = bottom.bounds
        rail.frame = railRoom
        rail.buttons = railRegion
        overlay.top = chromeShown ? Self.rowHeight : 0
        // AppKit shows the window's buttons again as it lays its title bar out.
        applyLights()
        let room = bounds
        scroll.frame = room
        overlay.frame = room
        var size = room.size
        if !scaled, let layout = screen.remoteLayout {
            size = NSSize(width: max(CGFloat(layout.width), size.width), height: max(CGFloat(layout.height), size.height))
        }
        if screen.frame.size != size { screen.frame = NSRect(origin: .zero, size: size) }
    }

    // MARK: The buttons at the right, and the title strip and the line, over the picture

    /// The room the rail has: down the window's right side, clear of the title strip and of the line.
    private var railRoom: NSRect {
        let top = Self.rowHeight + Self.railClear, least = ScreenRail.side * 2 + ScreenRail.gap
        return NSRect(x: 0, y: top, width: max(bounds.width - Self.railInset, ScreenRail.side),
                      height: max(bounds.height - top - Self.barHeight - Self.railClear, least))
    }
    /// Where the rail's buttons are now: Full Screen and More, or all of them.
    private var railRegion: NSRect { ScreenRail.region(shown: chromeShown ? ScreenRail.most : 2, in: railRoom) }
    /// Where one of the rail's buttons is, once they are all shown.
    func railFrame(of index: Int) -> NSRect { ScreenRail.frame(of: index, in: railRoom) }
    /// The pointer there keeps what More brought: on the title strip, on the line, or among the buttons.
    private func onChrome(_ point: NSPoint) -> Bool {
        top.frame.contains(point) || bottom.frame.contains(point) || railRegion.insetBy(dx: -ScreenRail.gap, dy: -ScreenRail.gap).contains(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        follow(convert(event.locationInWindow, from: nil))
    }
    override func mouseEntered(with event: NSEvent) { follow(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { follow(nil) }

    /// Where the pointer is over the window, if it is.
    private var pointer: NSPoint? {
        guard let window else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) ? point : nil
    }

    /// The pointer on More brings the rest of the buttons, the title strip and the line; on them,
    /// they stay; anywhere else, they go a moment later.
    private func follow(_ point: NSPoint?) {
        guard live else { return }
        let over: Bool
        if let point {
            over = chromeShown ? onChrome(point) : railFrame(of: ScreenRail.moreIndex).contains(point)
        } else { over = false }
        if over {
            hideTimer?.invalidate()
            hideTimer = nil
            if !chromeShown { chrome(shown: true, animated: true) }
            return
        }
        guard chromeShown, hideTimer == nil else { return }
        // Only in the default mode: not while a menu from a button (Keys) is open.
        let timer = Timer(timeInterval: Self.lingering, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfAway() }
        }
        RunLoop.main.add(timer, forMode: .default)
        hideTimer = timer
    }

    private func hideIfAway() {
        hideTimer = nil
        guard live, chromeShown, !info.showingInfo else { return }
        if let point = pointer, onChrome(point) { return }
        chrome(shown: false, animated: true)
    }

    func chrome(shown: Bool, animated: Bool) {
        hideTimer?.invalidate()
        hideTimer = nil
        guard shown != chromeShown || top.isHidden == shown else { return }
        chromeShown = shown
        applyLights()
        overlay.top = shown ? Self.rowHeight : 0
        rail.buttons = railRegion
        let panes = [top, bottom]
        if shown { for pane in panes { pane.isHidden = false } }
        let done = { [weak self] in
            guard let self, self.chromeShown == shown else { return }
            for pane in panes { pane.isHidden = !shown }
        }
        guard animated, !Motion.reduced, window != nil else {
            info.railOpen = shown
            for pane in panes { pane.alphaValue = shown ? 1 : 0 }
            done()
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { info.railOpen = shown }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            for pane in panes { pane.animator().alphaValue = shown ? 1 : 0 }
        }, completionHandler: { MainActor.assumeIsolated { done() } })
    }

    /// The window's close, minimize and zoom buttons go with the title strip, and so does its title
    /// bar: under the picture's top it would take a click there for a move of the window.
    private func applyLights() {
        guard let window else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind), button.isHidden == chromeShown { button.isHidden = !chromeShown }
        }
        // The buttons' bar and what holds it; never anything the content is in. In full screen the
        // title bar comes down with the menu bar, over the picture only then.
        guard let titleBar = window.standardWindowButton(.closeButton)?.superview?.superview,
              let content = window.contentView, !content.isDescendant(of: titleBar) else { return }
        let hidden = !chromeShown && !window.styleMask.contains(.fullScreen)
        if titleBar.isHidden != hidden { titleBar.isHidden = hidden }
    }

    func say(_ words: String?, again offered: Bool) { overlay.say(words, again: offered) }
    func askSignIn(device: String, account: String, error: String?) { overlay.askSignIn(device: device, account: account, error: error) }
    var banner: String? {
        get { overlay.banner }
        set { overlay.banner = newValue }
    }
}

/// The rail's buttons in the window. Its room is the whole of the window's right side, for a button's
/// name to be drawn at its left; a click stops only where the buttons are, and anywhere else in the
/// room goes on to the picture.
final class ScreenRailHost: NSHostingView<ScreenRail> {
    /// Where the buttons are, in the superview's coordinates.
    var buttons = NSRect.zero

    override func hitTest(_ point: NSPoint) -> NSView? { buttons.contains(point) ? super.hitTest(point) : nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// What the window says over the picture: why it is not shown and Connect Again, the sign-in form,
/// and a line at the top for a while. A click anywhere else goes through to the picture.
final class ScreenOverlay: NSView {
    var onReconnect: (() -> Void)?
    /// The account typed into the sign-in form, and whether to keep it.
    var onSignIn: ((String, String, Bool) -> Void)?
    var banner: String? {
        didSet { bannerLabel.stringValue = banner ?? ""; bannerLabel.isHidden = banner == nil; needsLayout = true }
    }
    /// The line at the top goes under the title row while it is shown.
    var top: CGFloat = 0 { didSet { if top != oldValue { needsLayout = true } } }

    /// A label a click goes through.
    private final class Quiet: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let label = NSTextField(wrappingLabelWithString: "")
    private let bannerLabel = Quiet(labelWithString: "")
    private let again = NSButton(title: tr("Connect Again"), target: nil, action: nil)
    private let accountField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let rememberBox = NSButton(checkboxWithTitle: tr("Remember in this Mac’s keychain"), target: nil, action: nil)
    private let signInButton = NSButton(title: tr("Sign In"), target: nil, action: nil)
    private var signInViews: [NSView] { [accountField, passwordField, rememberBox, signInButton] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        // On the window's glass, as the panel's words are.
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 14)
        label.maximumNumberOfLines = 6
        label.isHidden = true
        bannerLabel.textColor = .white
        bannerLabel.font = .systemFont(ofSize: 11)
        bannerLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        bannerLabel.drawsBackground = true
        bannerLabel.isHidden = true
        again.bezelStyle = .rounded
        again.target = self
        again.action = #selector(reconnect)
        again.isHidden = true
        accountField.placeholderString = tr("Account name")
        passwordField.placeholderString = tr("Password")
        for field in [accountField, passwordField] as [NSTextField] {
            field.bezelStyle = .roundedBezel
            field.font = .systemFont(ofSize: 13)
        }
        passwordField.target = self
        passwordField.action = #selector(submitSignIn)
        rememberBox.state = .on
        rememberBox.font = .systemFont(ofSize: 12)
        signInButton.bezelStyle = .rounded
        signInButton.keyEquivalent = "\r"
        signInButton.target = self
        signInButton.action = #selector(submitSignIn)
        for sub in [label, bannerLabel, again] + signInViews { addSubview(sub) }
        for sub in signInViews { sub.isHidden = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Asks for the account that Mac's Screen Sharing takes: its name filled in with what that Mac
    /// suggests, and why it is asked again.
    func askSignIn(device: String, account: String, error: String?) {
        var words = tr("Sign in to %@’s Screen Sharing with an account on that Mac.", device)
        if let error { words = error + "\n" + words }
        label.stringValue = words
        label.isHidden = false
        again.isHidden = true
        if accountField.stringValue.isEmpty || error == nil { accountField.stringValue = account }
        passwordField.stringValue = ""
        for sub in signInViews { sub.isHidden = false }
        needsLayout = true
        window?.makeFirstResponder(accountField.stringValue.isEmpty ? accountField : passwordField)
    }

    @objc private func submitSignIn() {
        let account = accountField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue
        guard !account.isEmpty, !password.isEmpty else { return }
        for sub in signInViews { sub.isHidden = true }
        passwordField.stringValue = ""
        onSignIn?(account, password, rememberBox.state == .on)
    }

    @objc private func reconnect() { onReconnect?() }

    /// Words over the picture (nil: none), and whether Connect Again is offered under them.
    func say(_ words: String?, again offered: Bool) {
        for sub in signInViews { sub.isHidden = true }
        label.stringValue = words ?? ""
        label.isHidden = words == nil
        again.isHidden = !offered
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width - 40, 520)
        let fitted = label.sizeThatFits(NSSize(width: width, height: 400))
        label.frame = NSRect(x: bounds.midX - width / 2, y: bounds.midY - fitted.height / 2 - 18, width: width, height: fitted.height)
        again.sizeToFit()
        again.frame.origin = NSPoint(x: bounds.midX - again.frame.width / 2, y: label.frame.maxY + 12)
        let field = min(bounds.width - 40, 280)
        var y = label.frame.maxY + 14
        for sub in [accountField, passwordField] as [NSView] {
            sub.frame = NSRect(x: bounds.midX - field / 2, y: y, width: field, height: 24)
            y += 32
        }
        rememberBox.sizeToFit()
        rememberBox.frame.origin = NSPoint(x: bounds.midX - field / 2, y: y)
        signInButton.sizeToFit()
        signInButton.frame.origin = NSPoint(x: bounds.midX + field / 2 - signInButton.frame.width, y: y + 26)
        bannerLabel.sizeToFit()
        bannerLabel.frame = NSRect(x: 8, y: top + 8, width: min(bannerLabel.frame.width + 8, bounds.width - 16), height: bannerLabel.frame.height + 4)
    }
}

/// The picture, and the pointer, keys and wheel over it, sent as the page sends them. Scaled, it
/// fills the scroll view and the picture fits it; at its own size it is that display's size (or
/// the window's, if larger, the picture in the middle), and the window scrolls when the pointer
/// reaches an edge, as Screen Sharing's does.
final class ScreenView: NSView {
    var send: ((Data) -> Void)?
    /// The display's size changed: the scroll view sizes the picture again.
    var onLayout: (() -> Void)?
    var remoteLayout: ScreenWire.Layout? {
        didSet {
            guard remoteLayout != oldValue else { return }
            needsLayout = true
            window?.invalidateCursorRects(for: self)
            onLayout?()
        }
    }
    /// At its own size: a point of that display is a point here.
    var actual = false { didSet { needsLayout = true; window?.invalidateCursorRects(for: self); if !actual { stopEdge() } } }
    var canControl = false { didSet { if canControl != oldValue { window?.invalidateCursorRects(for: self) } } }
    /// A double-click on the picture while the window does not work that Mac.
    var onEngage: (() -> Void)?
    /// The picture is drawn: not before a session is live, nor once it has ended (the window's glass
    /// shows behind what it says then).
    var showsPicture = false { didSet { needsLayout = true } }
    var cursorInPicture = false { didSet { window?.invalidateCursorRects(for: self) } }
    var remoteCursor: RemoteCursor? {
        didSet {
            systemCursor = remoteCursor?.shape.signature.flatMap { SystemCursors.like($0) }
            applyCursor()
        }
    }
    /// This Mac's own pointer of the look the other Mac's has, when it is one of them.
    private var systemCursor: NSCursor?
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            if oldValue !== held?.layer { oldValue?.removeFromSuperlayer() }
            guard let displayLayer else { return }
            if let veil { layer?.insertSublayer(displayLayer, below: veil) } else { layer?.addSublayer(displayLayer) }
            needsLayout = true
        }
    }

    /// Over the picture while that Mac makes its display again: what is behind it blurred, as Screen
    /// Sharing's own window blurs (a backdrop with a 25-point Gaussian blur, its edges kept hard, cleared
    /// by a spring of half a second without bounce; read from macOS 27's Screen Sharing, 2026-11-23).
    private var veil: CALayer?
    /// Each blur and clearing, so that a clearing overtaken by a new blur leaves the veil in place.
    private var veilTurn = 0
    private static let blurRadius = 25.0
    private static let blurPath = "backgroundFilters.blur.inputRadius"
    /// The picture of the session before, kept under the blur while the next opens, at that display's size.
    private var held: (layer: AVSampleBufferDisplayLayer, layout: ScreenWire.Layout)?

    private var buttons: UInt8 = 0
    private var keysDown: Set<UInt16> = []
    private var pending: (x: Int, y: Int)?
    private var tracking: NSTrackingArea?
    private var edgeTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The veil's blur is a Core Image filter.
        layerUsesCoreImageFilters = true
        // Around the picture, the window's glass.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The picture reaches the window's top: a click there, under the title bar, is that Mac's, not a move of the window.
    override var mouseDownCanMoveWindow: Bool { false }

    /// A new session: nothing goes to that Mac until it is live (ScreenViewer.applyControl).
    func reset() {
        remoteLayout = nil; remoteCursor = nil; cursorInPicture = false; canControl = false
        buttons = 0; keysDown = []
        stopEdge()
    }

    /// Where the picture is drawn: as large as fits, in that display's proportions; or at its own size, in the middle.
    private var picture: CGRect { remoteLayout.map(place) ?? bounds }

    private func place(_ layout: ScreenWire.Layout) -> CGRect {
        if actual {
            let w = CGFloat(layout.width), h = CGFloat(layout.height)
            return CGRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
        }
        return ScreenWire.fit((layout.width, layout.height), in: bounds)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The session's picture waits for its first under the one kept from before.
        let shown = showsPicture && remoteLayout != nil && held == nil
        // On whole pixels: off them, the veil's blur takes in the glass around the picture and its
        // edges go soft.
        let drawn = backingAlignedRect(picture, options: .alignAllEdgesNearest)
        displayLayer?.isHidden = !shown
        displayLayer?.frame = drawn
        displayLayer?.contentsScale = window?.backingScaleFactor ?? 2
        let kept = held.map { backingAlignedRect(place($0.layout), options: .alignAllEdgesNearest) }
        if let held, let kept {
            held.layer.frame = kept
            held.layer.contentsScale = window?.backingScaleFactor ?? 2
        }
        veil?.frame = kept ?? drawn
        veil?.isHidden = !shown && held == nil
        CATransaction.commit()
    }

    // MARK: The blur while that Mac makes its display again

    /// Keeps the picture shown now under the blur while the session opens again; false when none is shown.
    func hold() -> Bool {
        guard showsPicture, let displayLayer, let remoteLayout, !displayLayer.isHidden else { return false }
        held?.layer.removeFromSuperlayer()
        held = (displayLayer, remoteLayout)
        return true
    }

    func blur() {
        veilTurn += 1
        let veil = self.veil ?? {
            let made = CALayer()
            made.masksToBounds = true
            // The picture's edge carried outward before the blur, so that the edges stay hard.
            let clamp = CIFilter(name: "CIAffineClamp")
            clamp?.setValue(NSAffineTransform(), forKey: kCIInputTransformKey)
            let blur = CIFilter(name: "CIGaussianBlur")
            blur?.name = "blur"
            made.backgroundFilters = [clamp, blur].compactMap { $0 }
            layer?.addSublayer(made)
            self.veil = made
            return made
        }()
        veil.removeAnimation(forKey: "clear")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        veil.setValue(Self.blurRadius, forKeyPath: Self.blurPath)
        CATransaction.commit()
        needsLayout = true
    }

    /// Clears the blur and lets go of the picture kept under it.
    func unblur(animated: Bool) {
        held?.layer.removeFromSuperlayer()
        held = nil
        needsLayout = true
        guard let veil else { return }
        veilTurn += 1
        let turn = veilTurn
        guard animated, !Motion.reduced, !veil.isHidden else {
            veil.removeFromSuperlayer()
            self.veil = nil
            return
        }
        let spring = CASpringAnimation(perceptualDuration: 0.5, bounce: 0)
        spring.keyPath = Self.blurPath
        spring.fromValue = Self.blurRadius
        spring.toValue = 0
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.veilTurn == turn else { return }
                self.veil?.removeFromSuperlayer()
                self.veil = nil
            }
        }
        veil.setValue(0.0, forKeyPath: Self.blurPath)
        veil.add(spring, forKey: "clear")
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: The pointer's shape

    private var cursor: NSCursor {
        // This Mac's own arrow until the window works that Mac.
        guard canControl, !cursorInPicture, let remoteCursor, let layout = remoteLayout else { return .arrow }
        if let systemCursor { return systemCursor }
        let k = picture.width / CGFloat(layout.width)
        return remoteCursor.cursor(pointsPerPoint: k) ?? .arrow
    }

    override func resetCursorRects() { addCursorRect(picture, cursor: cursor) }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    private func applyCursor() {
        window?.invalidateCursorRects(for: self)
        guard let window, window.isKeyWindow else { return }
        let inside = picture.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if inside { cursor.set() }
    }

    // MARK: The pointer

    /// Where a point of this view is on that display; `edge`: outside the picture, at its nearest
    /// edge (a button let go out there, a drag that left it).
    private func place(_ point: CGPoint, edge: Bool = false) -> (x: Int, y: Int)? {
        guard let layout = remoteLayout else { return nil }
        var point = point
        let shown = picture
        if edge {
            point.x = min(max(point.x, shown.minX), shown.maxX - 0.01)
            point.y = min(max(point.y, shown.minY), shown.maxY - 0.01)
        }
        return ScreenWire.remotePoint(point, picture: shown, display: (layout.width, layout.height), flipped: true)
    }

    private func pointer(_ event: NSEvent, bit: UInt8? = nil, down: Bool = false) {
        let point = convert(event.locationInWindow, from: nil)
        if bit == nil { followEdge(point) }
        // A press starts only in the picture; a release, or a drag, is taken wherever it is.
        let held = buttons != 0 || (bit != nil && !down)
        guard canControl, let at = place(point, edge: held) else { return }
        if let bit {
            buttons = down ? buttons | bit : buttons & ~bit
            pending = nil
            send?(ScreenWire.pointerFrame(buttons: buttons, x: at.x, y: at.y))
            return
        }
        move(to: at)
    }

    /// One position a turn of the run loop: a mouse says where it is more often than that.
    private func move(to at: (x: Int, y: Int)) {
        let first = pending == nil
        pending = at
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let at = self.pending else { return }
            self.pending = nil
            self.send?(ScreenWire.pointerFrame(buttons: self.buttons, x: at.x, y: at.y))
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A window that does not work that Mac yet: a press moves it, and a double-click starts
        // working that Mac (user 2026-11-23). Neither goes to that Mac.
        guard canControl else {
            if event.clickCount >= 2 { onEngage?() } else { window?.performDrag(with: event) }
            return
        }
        pointer(event, bit: 1, down: true)
    }
    override func mouseUp(with event: NSEvent) { pointer(event, bit: 1, down: false) }
    override func rightMouseDown(with event: NSEvent) { pointer(event, bit: 4, down: true) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, bit: 4, down: false) }
    override func otherMouseDown(with event: NSEvent) { pointer(event, bit: 2, down: true) }
    override func otherMouseUp(with event: NSEvent) { pointer(event, bit: 2, down: false) }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseExited(with event: NSEvent) { if buttons == 0 { stopEdge() } }

    override func scrollWheel(with event: NSEvent) {
        // Observing, the wheel moves the window over a screen shown at its own size.
        guard canControl else { super.scrollWheel(with: event); return }
        guard let at = place(convert(event.locationInWindow, from: nil)) else { return }
        let wheel = ScreenWire.wheel(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        guard wheel.dx != 0 || wheel.dy != 0 else { return }
        send?(ScreenWire.scrollFrame(dx: wheel.dx, dy: wheel.dy, x: at.x, y: at.y))
    }

    // MARK: Scrolling at an edge, at its own size

    /// Which way the window moves over the picture with the pointer at `point`: toward an edge it
    /// is near, while there is more that way; faster the nearer it is.
    private func edgePush(_ point: CGPoint) -> CGVector {
        guard actual else { return .zero }
        let visible = visibleRect
        let zone: CGFloat = 28
        func speed(_ depth: CGFloat) -> CGFloat { 4 + 26 * min(max(depth / zone, 0), 1) }
        var push = CGVector.zero
        if point.x < visible.minX + zone, visible.minX > bounds.minX { push.dx = -speed(visible.minX + zone - point.x) }
        if point.x > visible.maxX - zone, visible.maxX < bounds.maxX { push.dx = speed(point.x - (visible.maxX - zone)) }
        if point.y < visible.minY + zone, visible.minY > bounds.minY { push.dy = -speed(visible.minY + zone - point.y) }
        if point.y > visible.maxY - zone, visible.maxY < bounds.maxY { push.dy = speed(point.y - (visible.maxY - zone)) }
        return push
    }

    private func followEdge(_ point: CGPoint) {
        guard edgePush(point) != .zero else { stopEdge(); return }
        guard edgeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.edgeStep() } }
        RunLoop.main.add(timer, forMode: .common)
        edgeTimer = timer
    }

    private func edgeStep() {
        guard let window, let clip = enclosingScrollView?.contentView else { stopEdge(); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let push = edgePush(point)
        guard push != .zero else { stopEdge(); return }
        var origin = clip.bounds.origin
        origin.x = min(max(origin.x + push.dx, 0), max(bounds.width - clip.bounds.width, 0))
        origin.y = min(max(origin.y + push.dy, 0), max(bounds.height - clip.bounds.height, 0))
        guard origin != clip.bounds.origin else { stopEdge(); return }
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        // The picture moved under the pointer: it is over another place of that display now.
        if canControl, let at = place(convert(window.mouseLocationOutsideOfEventStream, from: nil), edge: buttons != 0) { move(to: at) }
    }

    private func stopEdge() { edgeTimer?.invalidate(); edgeTimer = nil }

    // MARK: The keys, by their place on the keyboard: that Mac's own input method makes the words

    private func key(_ code: UInt16, down: Bool) {
        guard canControl, code <= 0x7E else { return }
        if down { keysDown.insert(code) } else { keysDown.remove(code) }
        send?(ScreenWire.keyFrame(down: down, code: code))
    }

    override func keyDown(with event: NSEvent) { key(event.keyCode, down: true) }
    override func keyUp(with event: NSEvent) { key(event.keyCode, down: false) }

    /// Command shortcuts are that Mac's too (⌘Q quits an app there, not out here): they are taken
    /// before this Mac's menus see them.
    /// Not while observing: then they are this Mac's (⌘W closes the window).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard canControl, window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        key(event.keyCode, down: true)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        if code == 0x39 {
            // Caps Lock is a state there, changed on its way down.
            key(code, down: true); key(code, down: false)
            return
        }
        guard let bit = Shortcut.modifierBits[Int(code)], code != 63 else { return }
        key(code, down: UInt64(event.modifierFlags.rawValue) & bit != 0)
    }

    /// Keys pressed together and let go in turn, as from a menu (keys this Mac's system keeps).
    func combo(_ codes: [UInt16]) {
        guard canControl else { return }
        for code in codes where code <= 0x7E { send?(ScreenWire.keyFrame(down: true, code: code)) }
        for code in codes.reversed() where code <= 0x7E { send?(ScreenWire.keyFrame(down: false, code: code)) }
    }

    /// What is held here is let go there: the window went to the back, or the session ended.
    func releaseAll() {
        for code in keysDown { send?(ScreenWire.keyFrame(down: false, code: code)) }
        keysDown = []
        stopEdge()
        if buttons != 0 {
            buttons = 0
            if let layout = remoteLayout, let window {
                let at = ScreenWire.remotePoint(convert(window.mouseLocationOutsideOfEventStream, from: nil), picture: picture,
                                                display: (layout.width, layout.height), flipped: true) ?? (0, 0)
                send?(ScreenWire.pointerFrame(buttons: 0, x: at.x, y: at.y))
            }
        }
    }
}
