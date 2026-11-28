import AppKit
import AVFoundation
import Carbon
import Combine
import Network
import QingyanCore
import SystemConfiguration

enum DictationPhase: Equatable {
    /// `receiving`: another Mac's text is on its way here (this Mac answered its knock). Not busy:
    /// a recording of this Mac's own can start meanwhile.
    case idle, recording, processing, done, error, receiving
}

@MainActor
final class DictationController: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var partial = ""
    /// The result and the message, while they are the ones `receive` set for text another Mac sent,
    /// are left to the Received card: the result card does not show them again. Anything set later
    /// is the result card's (a message alone shows there without the received text).
    @Published var result = "" { didSet { resultIsReceived = false } }
    @Published var message = "" { didSet { messageIsReceived = false } }
    @Published private(set) var resultIsReceived = false
    @Published private(set) var messageIsReceived = false
    /// The text another Mac sent last, kept on the panel whether or not it went in here, until the
    /// next one (user 2026-11-25: even when it did not get pasted in, the text was received, so the
    /// main panel has to show it).
    @Published var lastReceived: ReceivedText?
    /// Counts texts as they arrive: one that arrived earlier and finished later does not replace the card.
    private var receivedCount = 0

    struct ReceivedText: Equatable {
        let id = UUID()
        /// Its place among the texts received (receivedCount when it arrived).
        var order = 0
        let text: String
        /// The sending Mac's name.
        let from: String
        let date: Date
        /// Typed here as far as out can tell.
        let written: Bool
        /// What became of it here, and whether it was copied to the clipboard, as it was then.
        let status: String
    }
    @Published var connected = false
    @Published var networkAvailable = true
    @Published var retryingID: UUID?
    /// A word the user corrected after a dictation, offered for the personal dictionary (Learn from corrections).
    @Published var learnedWord: String?
    @Published var latency: Double?
    @Published var hotkeyInstalled = false
    @Published var shortcutStatus = tr("Waiting for Accessibility permission.")
    @Published var remoteListening = false
    @Published var remoteStatus = ""
    /// Per paired Mac: the last test result, and which tests are running.
    @Published var peerStatus: [String: String] = [:]
    @Published var peerTesting: Set<String> = []
    /// Whether each paired Mac answered the last time it was asked; absent means not asked yet.
    @Published var peerReachable: [String: Bool] = [:]
    /// Whether each paired Mac has Apple silicon, as its out last said (its answer to a test, or to
    /// opening its screen); absent until it has. A Mac without has no screen button: out shows a
    /// screen in High Performance alone, which needs it (user 2026-11-25). Kept across launches.
    @Published private(set) var peerAppleSilicon: [String: Bool] =
        (UserDefaults.standard.dictionary(forKey: "screen.appleSilicon") as? [String: Bool]) ?? [:]

    func learnChip(_ key: String, appleSilicon: Bool) {
        guard peerAppleSilicon[key] != appleSilicon else { return }
        peerAppleSilicon[key] = appleSilicon
        UserDefaults.standard.set(peerAppleSilicon, forKey: "screen.appleSilicon")
    }
    /// Other Macs asking to be trusted, waiting for an answer.
    /// Macs running input that were found on the tailnet and are not trusted yet.
    /// For each address this Mac asked to pair with: what is happening.
    /// The addresses in `pairing` whose pairing is still under way, and at which step.
    /// Why working with other Macs is not possible, when it is not.
    @Published var linkProblem = ""
    /// The Monitor helper on this Mac, which carries put to the owner's other Macs (HelperLink).
    enum HelperState: Equatable { case checking, missing, stopped, noTunnel, ready }
    @Published var helperState = HelperState.checking
    private var helperAsked = Date.distantPast
    private var helperAsking = false
    /// Isolated live audio meter so waveform and clock updates only refresh the floating capsule.
    let meter = AudioMeter()
    /// Shared microphone monitor so opening Settings never blocks on CoreAudio enumeration.
    let microphones: Microphones
    var level: Float {
        get { meter.level }
        set { meter.setLevel(newValue) }
    }
    var elapsed: Int {
        get { meter.elapsed }
        set { meter.setElapsed(newValue) }
    }
    /// This Mac's identity; nil when the keychain could not be read.
    private(set) var identity: DeviceIdentity?
    let deviceName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    private var peersTested = Date.distantPast
    let settings: SettingsStore
    let shortcut = GlobalShortcut()
    /// The shared clipboard shelf at the bottom of the panel.
    let shelf: ShelfModel
    /// This Mac's microphone sent to another Mac as its out Mic, and another Mac's coming in.
    let microphone = MicrophoneLink()
    let updater: Updater
    private let recorder = AudioRecorder()
    private var client: (any Transcriber)?
    private var job: Task<Void, Never>?
    private var captureJob: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var audioFile: RecordedAudio?
    private var entry: HistoryEntry?
    /// History in step with the owner's other Macs (HistorySync).
    private var historySync: HistorySync?
    /// The screenshots macOS saves, for the Shelf.
    private let screenshots = ScreenshotWatcher()
    /// The Monitor helper's version on this Mac, as it last said; empty when it is not answering.
    @Published private(set) var helperVersion = ""

    /// Which Mac a History record is from, for its row (user 2026-11-27: this Mac, or the other Mac by
    /// name, after the time): shown while History is kept in step with other Macs, or when the
    /// record came from one. Another Mac goes by its name on the Monitor page, else the one it gave.
    func sourceLabel(_ origin: String?, _ name: String?) -> String? {
        guard origin != nil || settings.sendsRemotely else { return nil }
        // This Mac's own records, come back from another Mac before this one knew its own key.
        guard let origin, origin != historySync?.selfKey else { return tr("This Mac") }
        if let device = settings.preferences.devices.first(where: { $0.key == origin }) { return device.label }
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? tr("Unnamed Mac")
    }
    private var connectionError: Error?
    private let network = NWPathMonitor()
    private var retryJob: Task<Void, Never>?
    private var retryClient: (any Transcriber)?
    private var retryAfter: [UUID: Date] = [:]
    private var sessionID = UUID()
    private var stopTime: Date?
    /// When the recording began, for how long no other Mac was expected to be touched.
    private var recordingBegan: Date?
    /// A write watched for a correction (Learn from corrections), bound to the very field it went
    /// into by the focused AX element captured right after the write; `before`/`after` are the
    /// baseline read one second later, split at the cursor.
    private struct CorrectionWatch {
        let id: UUID
        var written: String
        var before: String?
        var after: String?
        var mark: FocusMark?
        var element: AXUIElement?
        var at: Date
    }
    private var correctionWatch: CorrectionWatch?
    private var watchJob: Task<Void, Never>?
    private var checkJob: Task<Void, Never>?
    private var hadSignal = false
    private let receiver = RemoteReceiver()
    /// The History, for the Monitor page's Clipboard tab through the helper on this Mac.
    private let historyFeed = HistoryFeed()
    /// What is copied on this Mac, and the window it is chosen from (Control + Option + C).
    let clipboard: ClipboardHistory
    let picker: ClipboardPicker
    /// The History page of the panel's drawer.
    let historyPage: HistoryPageModel
    /// This Mac's screen on the owner's Monitor page.
    let screen = ScreenHost()
    @Published var screenState = ScreenHost.State.off
    /// The Macs whose screen is on its way to a window (ScreenViewer): their row says so.
    @Published var screenOpening: Set<String> = []
    /// Sender side, one dictation: the armed links, and the knock typed when recording stopped.
    private var remoteSession: RemoteSession?
    private struct Delivered {
        let text: String
        let peer: String?
        let mark: FocusMark?
        let at: Date
    }
    private var lastDelivered: Delivered?
    private var pasted: (text: String, mark: FocusMark?)?
    private enum Plan {
        case insert
        case field(old: String)
        case previous(String)
    }
    private var remoteScout: Task<(FocusMark?, Int?), Never>?
    /// Macs no channel reached the last time they were tried (by key): tried last when looking for
    /// the Mac behind a remote desktop, until one answers again.
    private var unopened: Set<String> = []
    /// The names put on the other Macs gave while arming (by key): a remote desktop's title often
    /// says that name rather than the one on the Monitor page.
    private var armedNames: [String: String] = [:]
    /// How long the helper may take to reach a Mac while looking for the one behind a remote desktop.
    private static let scoutDial: TimeInterval = 3
    private var microphoneSubscriptions: Set<AnyCancellable> = []
    /// How many starts are opening the microphone now.
    private var micOpening = 0
    /// Whether a recording kept in History may start playing: not while the microphone records or opens.
    var canPlayRecording: Bool { phase != .recording && micOpening == 0 }
    /// Whether the bound microphone was connected at the last look; nil when nothing is bound.
    private var boundWasPresent: Bool?
    /// What the status capsule names while processing, and once done. Each is set together with
    /// `message`, so the capsule never has to read the message's words.
    enum CapsuleStep { case recognizing, polishing, writing, editing, sending, typing }
    /// `notWritten`: the text did not go into a text field on the Mac it was meant for; a title naming
    /// that Mac and a line saying why and where the text is.
    enum CapsuleResult { case inserted, onClipboard, savedToHistory, typed, notWritten(String, String) }
    var capsuleStep = CapsuleStep.recognizing
    var capsuleResult = CapsuleResult.inserted
    /// The Mac the text is being sent to (`sending`), and the Mac whose text is on its way here (`receiving`).
    var sendingTo = ""
    var receivingFrom = ""
    private var receivingID: UUID?
    var presentOverlay: (() -> Void)?
    var dismissOverlay: (() -> Void)?
    /// Between `presentOverlay` and `dismissOverlay`: what the capsule shows is current. The bar kept
    /// on top shows it in its first row instead of the capsule, and its own idle row otherwise
    /// (a result stays the phase after the capsule has gone).
    @Published var capsuleShown = false
    var openSettings: (() -> Void)?
    var busy: Bool { phase == .recording || phase == .processing }

    /// Current microphone binding state, strictly enforced without falling back to system default.
    var microphoneResolution: MicrophoneBinding.Resolution {
        let prefs = settings.preferences
        if settings.preview {
            if prefs.microphone.isEmpty {
                return .systemDefault(.init(uid: "preview-default", name: tr("Built-in Microphone")))
            }
            return .boundAvailable(.init(uid: prefs.microphone, name: MicrophoneBinding.displayLabel(boundName: prefs.microphoneName, uid: prefs.microphone)))
        }
        if !microphones.loaded {
            if prefs.microphone.isEmpty {
                return .systemDefault(.init(uid: "loading", name: tr("Checking input devices…")))
            }
            return .boundAvailable(.init(uid: prefs.microphone, name: MicrophoneBinding.displayLabel(boundName: prefs.microphoneName, uid: prefs.microphone)))
        }
        return MicrophoneBinding.resolve(
            boundUID: prefs.microphone,
            boundName: prefs.microphoneName,
            available: microphones.all.map { .init(uid: $0.uid, name: $0.name) },
            systemDefault: microphones.systemDefault.map { .init(uid: $0.uid, name: $0.name) }
        )
    }

    var boundMicrophoneMissing: Bool {
        if case .boundMissing = microphoneResolution { return true }
        return false
    }

    var boundMicrophoneLabel: String {
        switch microphoneResolution {
        case .boundAvailable(let info):
            return info.name
        case .boundMissing(_, let name):
            return name
        case .systemDefault(let info):
            return info.name
        case .noInputDevices:
            return tr("No input device found")
        }
    }

    /// Whether the capsule shows the recording as online: its recognition is ready for it (a live
    /// one once its connection is up; one that takes the finished file at once, as it needs none
    /// before the end) and, unless it recognizes on this Mac, the network is there. Before this, a
    /// model that takes the finished file (gpt-transcribe) kept "Offline" up through every
    /// recording on a working network (user 2026-11-26).
    var recordingOnline: Bool {
        connected && (networkAvailable || entry?.request.map { Platform.named($0.speechPlatform).wire == .onDevice } == true)
    }

    /// Compact summary tailored for the miniature floating status capsule.
    var capsuleSummary: String {
        switch phase {
        case .idle:
            return ""
        case .recording:
            let clockText = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            return recordingOnline ? clockText : tr("%@ · Offline", clockText)
        case .processing:
            switch capsuleStep {
            case .recognizing: return tr("Recognizing")
            case .polishing: return tr("Polishing")
            case .writing: return tr("Writing")
            case .editing: return tr("Editing")
            case .sending: return sendingTo.isEmpty ? tr("Sending") : tr("Sending to %@…", sendingTo)
            case .typing: return tr("Typing %ld / %ld", typedCount, typingTotal)
            }
        case .done:
            switch capsuleResult {
            case .inserted: return tr("Inserted")
            case .onClipboard: return tr("On the clipboard · ⌘V")
            case .savedToHistory: return tr("Saved to History")
            case .typed: return tr("Typed")
            case .notWritten(let title, let detail): return tr("%@ · %@", title, detail)
            }
        case .error:
            return message.isEmpty ? tr("Not finished") : message
        case .receiving:
            return tr("Receiving from %@…", receivingFrom)
        }
    }

    init(settings: SettingsStore) {
        self.settings = settings
        microphones = Microphones(preview: settings.preview)
        shelf = ShelfModel(preview: settings.preview)
        let support = settings.preview ? FileManager.default.temporaryDirectory.appendingPathComponent("out-preview-\(getpid())")
            : (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
                .appendingPathComponent("Qingyan", isDirectory: true) ?? FileManager.default.temporaryDirectory
        clipboard = ClipboardHistory(directory: support.appendingPathComponent("Clipboard", isDirectory: true))
        picker = ClipboardPicker(history: clipboard)
        historyPage = HistoryPageModel(clipboard: clipboard)
        updater = Updater(settings: settings)
        // Macs paired before put went through the Monitor helper are not the owner's Macs as the
        // helper knows them: they go before anything dials them.
        if !settings.preview { settings.preferences.devices.removeAll { HelperLink.agent(of: $0.host) == nil } }
        receiver.shelf = shelf.sync
        // History in step on the owner's Macs, over the Shelf's links (user 2026-11-27).
        if let sync = shelf.sync, !settings.preview {
            let history = HistorySync(shelf: sync, clipboard: clipboard, voice: HistorySync.Voice(
                entries: { [weak settings] in settings?.history ?? [] },
                horizon: { [weak settings] in settings?.historyHorizon ?? .distantPast },
                take: { [weak settings] entry in settings?.takeHistory(entry) ?? false },
                drop: { [weak settings] ids in settings?.dropHistory(ids) },
                dropCleared: { [weak settings] moment in settings?.dropHistory(clearedAt: moment) }),
                stateURL: support.appendingPathComponent("history-sync.json"))
            history.keepsCopies = { [weak settings] in settings?.preferences.clipHistory ?? false }
            history.sharing = { [weak settings] in settings?.sendsRemotely ?? false }
            history.selfName = deviceName
            settings.historyChanged = { [weak history] change in history?.voiceChanged(change) }
            historySync = history
        }
        updater.isBusy = { [weak self] in self.map { $0.busy || $0.starting || $0.retryingID != nil } ?? false }
        // Whatever is a file in History is on the Shelf too (user 2026-11-27).
        clipboard.onKept = { [weak self] entry, files in
            guard entry.kind == .files else { return }
            self?.shelf.shelveCopied(files)
        }
        shortcut.onToggle = { [weak self] in Task { @MainActor in self?.toggle() } }
        shortcut.onHoldBegan = { [weak self] in self?.holdBegan() ?? false }
        // Stopping and dropping a recording touch the disk: they run once the key event has gone back.
        shortcut.onHoldReleased = { [weak self] stop in Task { @MainActor in self?.holdReleased(stop: stop) } }
        shortcut.onHoldBroken = { [weak self] in Task { @MainActor in self?.holdBroken() } }
        shortcut.onCancel = { [weak self] in
            guard let self, self.busy || self.starting else { return false }
            Task { @MainActor in self.cancel() }
            return true
        }
        shortcut.onKnock = { [weak self] nonce in
            self?.receiver.knocked(nonce)
            // The text is coming to the app in front here.
            Task { @MainActor in TextTarget.prepareFront() }
        }
        shortcut.onTypeClipboard = { [weak self] in Task { @MainActor in self?.typeClipboard(from: .shortcut) } }
        // Where the keyboard was in the app a click on out's panel or menu takes it from.
        shortcut.onClickHere = { [weak self] in
            self?.clickedHere = Date()
            self?.focusLeft = FocusReturn.capture()
        }
        shortcut.onClipboardHistory = { [weak self] in Task { @MainActor in self?.picker.toggle() } }
        clipboard.policy = { [weak settings] in
            guard let prefs = settings?.preferences else { return ClipboardHistory.Policy(record: false) }
            return ClipboardHistory.Policy(record: prefs.clipHistory, limit: prefs.clipLimit, days: prefs.clipDays,
                                           ignored: Set(prefs.clipIgnored.map(\.bundle)))
        }
        // What out puts on the clipboard for a moment while it pastes is not something copied.
        clipboard.isOwn = { PasteboardLease.general.isTemporary($0) }
        picker.isOn = { [weak settings] in settings?.preferences.clipHistory ?? false }
        picker.onTurnOn = { [weak settings] in settings?.preferences.clipHistory = true }
        picker.onType = { [weak self] in self?.typeClipboard(from: .shortcut) }
        picker.model.source = { [weak self] entry in self?.sourceLabel(entry.origin, entry.originName) }
        picker.model.syncing = { [weak settings] in settings?.sendsRemotely ?? false }
        picker.onShelf = { [weak self] entry in
            guard let self else { return }
            self.shelf.put(entry, from: self.clipboard)
        }
        // Where the panel's Type the Clipboard types into: the last app in front other than this one.
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { lastOtherApp = front }
        // out in front with no click on it (⌘Tab, the Dock): where the app it came from had the keyboard,
        // read as it has just let go. Not after a click on out whose reading found nothing: what that
        // app shows once it is no longer in front is not taken in its place.
        ownActivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.focusLeft == nil, let app = self.lastOtherApp,
                      Date().timeIntervalSince(self.clickedHere ?? .distantPast) > 1 else { return }
                self.focusLeft = FocusReturn.capture(of: app)
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated {
                self?.lastOtherApp = app
                // Back in an app, the user may move its keyboard: where it was is no longer known.
                self?.focusLeft = nil
                // Another app in front: the keys pressed from now on are meant for it.
                if self?.recordingShortcut == true { self?.endShortcutRecording() }
            }
        }
        screen.onChange = { [weak self] in
            guard let self else { return }
            if self.screenState != self.screen.state { self.screenState = self.screen.state }
        }
        receiver.onChange = { [weak self] in
            guard let self, self.settings.preferences.linkEnabled else { return }
            if self.remoteListening != self.receiver.listening { self.remoteListening = self.receiver.listening }
            if self.remoteStatus != self.receiver.status { self.remoteStatus = self.receiver.status }
        }
        receiver.name = deviceName
        receiver.trusted = { [weak self] key in
            guard let self, self.settings.preferences.linkEnabled else { return nil }
            return self.settings.preferences.devices.first { $0.key == key }
        }
        receiver.onIncoming = { [weak self] from in
            self?.receivingStarted(from: from)
            // The text is coming to the app in front here, told by a knock or by this Mac's input.
            TextTarget.prepareFront()
        }
        // Told to a Mac about to send text, which may tell from it alone that the text is for this one.
        receiver.activity = { (TextTarget.secondsSinceInput(), TextTarget.caretInFront()) }
        // Another Mac's out shows this screen in its window (user 2026-11-21: no switch for that).
        receiver.onScreen = { [weak self] connection, key, viewer in
            guard let self else { connection.cancel(); return }
            self.screen.serveRemote(connection, key: key, viewer: viewer)
        }
        receiver.onIncomingEnded = { [weak self] in self?.receivingEnded() }
        // Another Mac types its clipboard here through a remote desktop: letters must not go into an
        // input method's composition (user 2026-11-27).
        receiver.holdLayout = { await LayoutHold.begin() }
        receiver.releaseLayout = { LayoutHold.end() }
        // Another Mac's microphone, to come out here as out Mic (user 2026-11-27).
        receiver.onMicrophone = { [weak self] input in
            Task { @MainActor in
                guard let self else { input.close(); return }
                self.microphone.adopt(input)
            }
        }
        receiver.microphoneAnswer = { [weak self] key, asker, again in
            await MainActor.run { () -> MicrophoneAnswer? in
                guard let self else { return nil }
                return self.microphone.answer(key: key, from: asker, again: again, here: self.deviceName)
            } ?? .no(tr("out on the other Mac is not ready."))
        }
        // What lending this Mac's microphone needs, read at every attempt.
        microphone.context = { [weak self] in
            guard let self else { return nil }
            let preferences = self.settings.preferences
            return MicrophoneLink.Context(identity: self.identity, name: self.deviceName, listening: preferences.remotePort,
                                          microphone: preferences.microphone,
                                          device: { key in preferences.devices.first { $0.key == key } })
        }
        microphone.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &microphoneSubscriptions)
        microphones.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &microphoneSubscriptions)
        // The bound microphone's name follows the device, and the moment it goes away is said out
        // loud, recording or not (operator 2026-11-18: even when the device is gone, say that it is gone;
        // then either switch, or stay with no input). A recording in progress is stopped by the recorder itself.
        microphones.$all.receive(on: DispatchQueue.main).sink { [weak self] list in
            MainActor.assumeIsolated {
                guard let self, self.microphones.loaded, !self.settings.preview else { return }
                let uid = self.settings.preferences.microphone
                guard !uid.isEmpty else { self.boundWasPresent = nil; return }
                let matched = list.first(where: { $0.uid == uid })
                if let matched, self.settings.preferences.microphoneName != matched.name {
                    self.settings.preferences.microphoneName = matched.name
                }
                let present = matched != nil
                defer { self.boundWasPresent = present }
                guard self.boundWasPresent == true, !present, !self.busy else { return }
                let name = MicrophoneBinding.displayLabel(boundName: self.settings.preferences.microphoneName, uid: uid)
                self.warnMicrophone(tr("The locked microphone “%@” was disconnected. out does not switch to another microphone and records nothing until it is reconnected. Another one can be chosen under Microphone in the panel.", name))
            }
        }.store(in: &microphoneSubscriptions)
        // Each screenshot macOS saves goes on the Shelf too, as a copied file does, once a click on the
        // Shelf's title turned that on (user 2026-11-27); the file stays where macOS put it. Off, the
        // watcher is not started and the folder is not opened.
        screenshots.onScreenshot = { [weak self] url in self?.shelf.shelveScreenshot(url) }
        screenshots.onUnreadable = { [weak self] _ in self?.shelf.saidScreenshotsUnreadable() }
        // A recording playing from History stops when History closes or gives way to Settings, and
        // when its record goes (deleted, cleared, past the last hundred, removed on another Mac):
        // its Stop button would be out of reach.
        settings.$historyOpen.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] open in
            MainActor.assumeIsolated { if !open { self?.historyPage.player.stop() } }
        }.store(in: &microphoneSubscriptions)
        settings.$page.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.historyPage.player.stop() }
        }.store(in: &microphoneSubscriptions)
        settings.$history.receive(on: DispatchQueue.main).sink { [weak self] entries in
            MainActor.assumeIsolated {
                guard let self, let id = self.historyPage.player.playing, !entries.contains(where: { $0.id == id }) else { return }
                self.historyPage.player.stop()
            }
        }.store(in: &microphoneSubscriptions)
        settings.$preferences.map(\.screenshotsToShelf).removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] on in
            MainActor.assumeIsolated {
                guard let self, !self.settings.preview else { return }
                self.screenshots.set(on: on)
            }
        }.store(in: &microphoneSubscriptions)
        // The clipboard history turned on or off: the other Macs are told whether copies go both ways.
        settings.$preferences.map(\.clipHistory).removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.historySync?.refresh() }
        }.store(in: &microphoneSubscriptions)
        // A binding made or changed by hand starts from what is connected now.
        settings.$preferences.map(\.microphone).removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] uid in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.boundWasPresent = uid.isEmpty ? nil : self.microphones.all.contains(where: { $0.uid == uid })
            }
        }.store(in: &microphoneSubscriptions)
        if !settings.preview {
            do {
                let identity = try DeviceKeychain.load()
                self.identity = identity
                receiver.identity = identity
                shelf.sync?.identity = identity
            } catch { linkProblem = error.localizedDescription }
            network.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    let satisfied = path.status == .satisfied
                    let restored = !self.networkAvailable && satisfied
                    if self.networkAvailable != satisfied { self.networkAvailable = satisfied }
                    if restored { self.retryAfter.removeAll() }
                    self.retryQueued()
                }
            }
            network.start(queue: DispatchQueue(label: "local.hopo.qingyan.network"))
        }
    }

    func refresh() {
        guard !settings.preview else { return }
        settings.refreshPermissions()
        shortcut.choice = settings.preferences.shortcut
        if settings.accessibilityAllowed { shortcut.start() } else { shortcut.stop() }
        let installed = shortcut.installed && (shortcut.active != .fn || shortcut.fnExclusive)
        if hotkeyInstalled != installed { hotkeyInstalled = installed }
        let nextStatus: String
        if !settings.accessibilityAllowed {
            nextStatus = tr("Accessibility permission is not granted, so the shortcut is not active.")
        } else if !shortcut.installed {
            nextStatus = tr("The shortcut could not start. Grant Accessibility permission again.")
        } else if shortcut.active != .fn {
            nextStatus = tr("The shortcut is %@. The Fn key is returned to macOS.", settings.shortcutLabel)
        } else if shortcut.fnExclusive {
            nextStatus = tr("Fn is taken over · A single press no longer changes the input source, opens emoji or starts system dictation.")
        } else {
            nextStatus = tr("The system Fn action is still on. Click “Take over Fn”, or set it to “Do Nothing” in Keyboard settings.")
        }
        if shortcutStatus != nextStatus { shortcutStatus = nextStatus }
        syncRemote()
        // Another Mac's view lasts only while that Mac is still trusted to type here.
        if let key = screen.viewerKey,
           !settings.preferences.linkEnabled || !settings.preferences.devices.contains(where: { $0.key == key && $0.canWrite }) {
            screen.stopViewing()
        }
        // A microphone goes on only while the Mac at the other end is still trusted: this Mac's to a Mac
        // still in the list, and another Mac's here while that Mac may still type here.
        let linked = settings.preferences.linkEnabled ? settings.preferences.devices : []
        microphone.keep(linkOn: settings.preferences.linkEnabled, sendingTo: Set(linked.map(\.key)), receivingFrom: Set(linked.filter(\.canWrite).map(\.key)))
        shelf.sync?.listening = settings.preferences.remotePort
        shelf.sync?.maintain(devices: settings.preferences.linkEnabled && identity != nil ? settings.preferences.devices : [])
        refreshHelper()
        clipboard.start()
        // This Mac's own records: each Mac answers the Dashboard for itself, though History is in step.
        historyFeed.start(entries: { [weak self] in self?.settings.history.filter { $0.origin == nil } ?? [] },
                          copies: { [weak self] in self?.clipboard.entries.filter { $0.origin == nil } ?? [] },
                          shared: { [weak self] in self?.settings.preferences.showOnDashboard ?? false })
        retryQueued()
    }

    /// Keeps the listener in step with the settings; called on every refresh.
    private func syncRemote() {
        guard settings.preferences.linkEnabled, identity != nil else {
            receiver.stop()
            if remoteListening { remoteListening = false }
            return
        }
        receiver.startHelper(
            probe: { AXIsProcessTrusted()
                ? (true, tr("Ready to receive text."))
                : (false, tr("Connected, but the other Mac has not granted Accessibility permission, so it cannot paste.")) },
            context: { TextTarget.field() },
            deliver: { [weak self] request in
                guard let self else { throw VoiceError(tr("out is quitting on the other Mac.")) }
                if request.field == nil && !request.clipboardOnly { await TextTarget.awaitFocus() }
                return try await self.receive(request)
            })
    }

    // MARK: Trust

    /// The Macs running put that this one sees through Tailscale, told to a trusted Mac that asks: one
    /// lookup at a time, kept for 30 seconds, and only Macs that answered as put at a Tailscale address.

    /// Another Mac's knock was answered here: its text is on the way, and the capsule says from which
    /// Mac until the text is written (`receive` takes the capsule over) or that Mac's connection ends
    /// without it. A recording, processing or typing of this Mac's own keeps its capsule.
    private func receivingStarted(from name: String) {
        guard !busy, !starting, typingJob == nil else { return }
        let id = UUID()
        sessionID = id; receivingID = id
        receivingFrom = name
        phase = .receiving
        presentOverlay?()
    }

    private func receivingEnded() {
        guard let id = receivingID else { return }
        receivingID = nil
        guard sessionID == id, phase == .receiving else { return }
        phase = .idle
        dismissOverlay?()
    }

    private func receive(_ request: RemoteReceiver.Request) async throws -> DeliveryOutcome {
        if !request.text.isEmpty && request.field == nil {
            // The sending Mac's record of it, under the same identifier and named after that Mac: with
            // History in step, the two are one record.
            var record = HistoryEntry(text: request.text, mode: request.mode, seconds: request.seconds)
            if !request.fromKey.isEmpty { record.origin = request.fromKey; record.originName = request.from }
            // That Mac's own record, which it keeps in step itself: this one stands in for it until it
            // comes, dated as it is, and gives way to it.
            let standIn = request.entry != nil
            if let same = request.entry { record.id = same; record.date = request.entryDate ?? record.date; record.updated = record.date }
            // Already here, from that Mac through History in step: not kept twice.
            if !settings.history.contains(where: { $0.id == record.id }) {
                do { try settings.addHistory(record, announce: !standIn) }
                catch { settings.historyMessage = tr("Text from another Mac was received but could not be saved to History on this Mac. Check the disk space.") }
            }
        }
        let id = UUID()
        // New text, not a field rewritten or a deletion: the panel's Received card, and this Mac's
        // clipboard whatever became of it (user 2026-11-25: and copied automatically, on the receiving Mac).
        let fresh = request.field == nil && !request.text.isEmpty
        Trace.note(request.clipboardOnly ? "receive: putting it on the clipboard, not typing it" : "receive: writing into \(Self.frontApp)")
        receivedCount += 1
        let order = receivedCount, arrived = Date()
        func show(written: Bool, status: [String]) {
            guard fresh, order > lastReceived?.order ?? 0 else { return }
            lastReceived = ReceivedText(order: order, text: request.text, from: request.from, date: arrived, written: written,
                                        status: status.joined(separator: " · "))
        }
        if request.clipboardOnly {
            // No Mac claimed the sender's knock: the text is left on the clipboard here, not typed into
            // whatever is in front (user 2026-11-26: at least the receiving Mac has it).
            keepOnClipboard(request.text)
            show(written: false, status: [Self.missTitle(.unclaimed, peer: nil), Self.missLine(.unclaimed, clipboard: nil), tr("Copied to the clipboard")])
            if !busy, !starting {
                sessionID = id
                result = request.text; latency = nil
                phase = .done
                capsuleResult = .notWritten(Self.missTitle(.unclaimed, peer: nil), Self.missLine(.unclaimed, clipboard: .here))
                message = tr("From another Mac · %@ · Saved to History", tr("Saved to the clipboard (⌘V)"))
                resultIsReceived = fresh; messageIsReceived = fresh
                presentOverlay?()
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self, self.sessionID == id, self.phase == .done else { return }
                    self.dismissOverlay?()
                }
            }
            return DeliveryOutcome(message: tr("Copied to the clipboard"), miss: .unclaimed, onClipboard: true)
        }
        do {
            let outcome: WriteResult
            if let field = request.field {
                outcome = try TextTarget.rewriteField(from: field, to: request.text)
                pasted = nil
            } else {
                if let previous = request.replace {
                    outcome = try TextTarget.replace(previous, with: request.text, untouched: cursorUntouched(after: previous), keep: fresh)
                } else {
                    outcome = try await TextTarget.insertAtFocus(request.text, keep: fresh)
                }
                if outcome.miss == nil, !outcome.unseen { notePasted(request.text) } else { pasted = nil }
            }
            // Typed in, the paste left the text on the clipboard in place of what it held (keep);
            // not typed, it is there already, unless something newer was put there meanwhile.
            if let miss = outcome.miss {
                show(written: false, status: [Self.missTitle(miss, peer: nil), Self.missLine(miss, clipboard: nil)] + (outcome.onClipboard ? [tr("Copied to the clipboard")] : []))
            } else {
                show(written: true, status: [outcome.summary, tr("Copied to the clipboard")])
            }
            // A recording of this Mac's own, or one starting, keeps its capsule (and its session).
            guard !busy, !starting else { return DeliveryOutcome(message: outcome.summary, miss: outcome.miss, onClipboard: outcome.onClipboard) }
            sessionID = id
            result = request.field == nil ? request.text : ""; latency = nil
            phase = .done
            if let miss = outcome.miss { capsuleResult = .notWritten(Self.missTitle(miss, peer: nil), Self.missLine(miss, clipboard: outcome.onClipboard ? .here : nil)) }
            else { capsuleResult = outcome.onClipboard ? .onClipboard : .inserted }
            message = tr("From another Mac · %@ · Saved to History", outcome.summary)
            resultIsReceived = fresh; messageIsReceived = fresh
            presentOverlay?()
            let linger: UInt64 = outcome.miss == nil ? 2_200_000_000 : 5_000_000_000
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: linger)
                guard let self, self.sessionID == id, self.phase == .done else { return }
                self.dismissOverlay?()
            }
            return DeliveryOutcome(message: outcome.summary, miss: outcome.miss, onClipboard: outcome.onClipboard)
        } catch {
            let kept = keepOnClipboard(request.text)
            let miss = (error as? TargetProblem)?.miss ?? .other
            show(written: false, status: [Self.missTitle(miss, peer: nil), miss == .other ? error.localizedDescription : Self.missLine(miss, clipboard: nil)]
                 + (kept ? [tr("Copied to the clipboard")] : []))
            if !busy, !starting {
                sessionID = id
                result = request.text; latency = nil
                phase = .error
                message = kept ? tr("Text from another Mac could not be written: %@ · Saved to the clipboard (⌘V)", error.localizedDescription)
                    : tr("Text from another Mac could not be written: %@", error.localizedDescription)
                resultIsReceived = fresh; messageIsReceived = fresh
                presentOverlay?()
            }
            guard kept else { throw DeliveryProblem(miss: miss, message: error.localizedDescription, onClipboard: false) }
            throw DeliveryProblem(miss: miss, message: tr("%@ The text is on the other Mac’s clipboard.", error.localizedDescription), onClipboard: true)
        }
    }

    @discardableResult
    private func keepOnClipboard(_ text: String) -> Bool {
        guard !text.isEmpty, !settings.preview else { return false }
        PasteboardLease.general.keep(text)
        return true
    }

    /// Asks the helper on this Mac for the owner's other Macs, at most every 15 seconds; they are
    /// the devices put works with. Without a helper there are none: put works across Macs only
    /// through it.
    func refreshHelper(force: Bool = false) {
        guard !settings.preview, !helperAsking, force || Date().timeIntervalSince(helperAsked) > 15 else { return }
        helperAsking = true; helperAsked = Date()
        Task { [weak self] in
            var next: HelperState = .ready
            var roster: HelperLink.Roster?
            do { roster = try await HelperLink.roster() }
            catch HelperLink.Absence.notInstalled { next = .missing }
            catch { next = .stopped }
            guard let self else { return }
            self.helperAsking = false
            if let roster, !roster.tunnel { next = .noTunnel }
            if self.helperState != next { self.helperState = next }
            let version = roster?.version ?? ""
            if self.helperVersion != version { self.helperVersion = version }
            if let roster {
                self.shelf.sync?.selfID = HelperLink.id(roster.agent)
                // What the other Macs know this one by, so its own records coming back are its own.
                self.historySync?.selfKey = HelperLink.id(roster.agent)
                if !roster.name.isEmpty { self.historySync?.selfName = roster.name }
            }
            // Without an answer the helper is not there to make a link either.
            self.shelf.helperSaid(linkable: roster?.host ?? false)
            // A helper that is down for a moment keeps the Macs it named; one that is not there has none.
            guard roster != nil || next == .missing else { return }
            let devices = (roster?.peers ?? []).map { peer -> TrustedDevice in
                TrustedDevice(key: HelperLink.id(peer.agent), name: peer.name, host: HelperLink.id(peer.agent), port: RemoteWire.defaultPort)
            }
            if self.settings.preferences.devices != devices {
                self.settings.preferences.devices = devices
                self.peersTested = .distantPast
                self.shelf.sync?.maintain(devices: self.settings.preferences.linkEnabled && self.identity != nil ? devices : [])
                self.testPeers()
            }
        }
    }

    func linkChanged() {
        remoteStatus = ""; peerStatus = [:]; peerReachable = [:]; peersTested = .distantPast
        refresh()
        testPeers()
    }

    /// This Mac's microphone to a trusted Mac as its out Mic, or back (user 2026-11-27).
    func toggleMicrophone(_ device: TrustedDevice) {
        microphone.toggle(device)
    }

    func testRemote(_ key: String) {
        guard let identity, !peerTesting.contains(key), let device = settings.preferences.devices.first(where: { $0.key == key }) else { return }
        guard device.reachable else { peerStatus[key] = tr("This device’s address is not known yet. Wait for it to connect, or click “Scan”."); return }
        peerTesting.insert(key); peerStatus[key] = tr("Checking the connection…")
        let name = deviceName, listening = settings.preferences.remotePort
        Task { [weak self] in
            var outcome: String, called = "", ok = false
            var chip: Bool?
            do {
                let reply = try await RemoteSender.ping(device, identity: identity, name: name, listening: listening)
                outcome = reply.message; called = reply.name; ok = reply.ok; chip = reply.appleSilicon
            } catch { outcome = error.localizedDescription }
            guard let self else { return }
            if let chip { self.learnChip(key, appleSilicon: chip) }
            self.peerTesting.remove(key); self.peerStatus[key] = outcome; self.peerReachable[key] = ok
            if ok { self.unopened.remove(key) }
            if !called.isEmpty { self.remember([key: called]) }
        }
    }

    func testPeers() {
        guard !settings.preview, settings.sendsRemotely, Date().timeIntervalSince(peersTested) > 15 else { return }
        peersTested = Date()
        for device in settings.preferences.devices where device.reachable { testRemote(device.key) }
    }

    private func remember(_ names: [String: String]) {
        for (key, name) in names {
            guard let index = settings.preferences.devices.firstIndex(where: { $0.key == key }),
                  HelperLink.agent(of: settings.preferences.devices[index].host) == nil,
                  settings.preferences.devices[index].name != name else { continue }
            settings.preferences.devices[index].name = name
        }
    }

    /// Whether the window in front shows another computer's screen: only then can the text be for
    /// one of the other Macs, and only then are they asked.
    /// The Mac whose screen out shows in the window in front (ScreenViewer): the text is for it, and
    /// no knock is needed to say which Mac that is.
    private var viewedInFront: TrustedDevice? {
        guard let key = ScreenViewer.frontKey else { return nil }
        return settings.preferences.devices.first { $0.key == key }
    }
    /// A window in front that shows another Mac's screen: a remote desktop's, or out's own.
    private var anotherScreenInFront: Bool {
        viewedInFront != nil || RemoteWire.showsAnotherScreen(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
    /// The session armed for the Mac in out's own screen window, and which Mac.
    private var remoteViewing: String?

    private var remoteInFront: Bool { viewedInFront != nil || KeystrokePlan.isRemoteClient(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }

    /// Starts looking for the Mac behind the remote desktop in front, while the recording is being
    /// transcribed. In front of any other window there is nothing to look for: the text is typed on
    /// this Mac and no other Mac holds it up.
    private func scoutRemote() {
        endRemote("looking again at the window in front")
        let devices = settings.preferences.devices.filter(\.reachable)
        guard let identity, settings.sendsRemotely, !settings.preview, !devices.isEmpty, AXIsProcessTrusted(), remoteInFront else { return }
        if let shown = viewedInFront {
            Trace.note("send: out's screen window of \(shown.label) is in front; getting that Mac ready, no knock")
            // out's own window of that Mac's screen: only that Mac is armed, and nothing is knocked.
            let session = RemoteSession(devices: [shown], identity: identity, name: deviceName, listening: settings.preferences.remotePort)
            remoteSession = session
            remoteViewing = shown.key
            remoteScout = Task { @MainActor [weak self] in
                await session.arm([0], timeout: 1.5, dial: Self.scoutDial)
                guard let self, self.remoteSession === session else { return (nil, nil) }
                self.peerReachable.merge(session.reachable) { _, new in new }
                // No mark: the claim is that window's, which destination() checks itself.
                return (nil, session.armedCount > 0 ? 0 : nil)
            }
            return
        }
        let session = RemoteSession(devices: devices, identity: identity, name: deviceName, listening: settings.preferences.remotePort)
        Trace.note("send: a remote desktop (\(Self.frontApp)) is in front; getting \(devices.count) Mac(s) ready and knocking")
        remoteSession = session
        remoteScout = Task { @MainActor [weak self] in
            guard let self else { return (nil, nil) }
            return await self.locate(in: session)
        }
    }

    /// The app a focus mark is in, by name, for the log.
    private static func appName(_ mark: FocusMark?) -> String {
        mark.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName } ?? "no app"
    }

    /// The app in front, by name, for the log (no Accessibility query).
    private static var frontApp: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "no app" }

    /// Which Macs were ready, which said no and why, and how many could not be reached: names and
    /// codes only, for the log (the words of a Mac's answer stay out of it).
    private static func readiness(_ session: RemoteSession) -> String {
        let refused = session.refusals.map { "\($0.peer) said no (\($0.miss.rawValue))" }
        let unreached = session.reachable.values.filter { !$0 }.count - session.refusals.count
        return (["\(session.armedCount) ready"] + refused + (unreached > 0 ? ["\(unreached) not reached"] : [])).joined(separator: ", ")
    }

    /// Which Mac the front window shows, and the focus when the knock that told it was typed: the
    /// Mac the window's title names is armed and knocked at first, the others only if it does not
    /// claim the knock (RemoteSession.find).
    /// No knock is typed once the window in front is no longer a remote desktop: it would reach an
    /// app on this Mac, and the text is then for this Mac anyway.
    /// `byInput`: first ask every Mac at once and go by what each says of its input; false when
    /// what they said is older than the window in front.
    private func locate(in session: RemoteSession, byInput: Bool = true) async -> (FocusMark?, Int?) {
        var mark: FocusMark?
        let first = session.index(namedIn: FocusMark.current()?.title ?? "", learned: armedNames)
        let started = Date()
        var knocks = 0
        var found: Int?
        var worked = false
        if byInput {
            // The Macs reached the last time, all at once: what each says of its input may tell which
            // one is being worked, with no knock (user 2026-11-26: the Mac whose pointer or keys moved,
            // one with a text cursor first). The others come only if the knock comes to them.
            await session.arm(session.places(except: unopened), timeout: 1.5, dial: Self.scoutDial)
            let quiet = recordingBegan.map { Date().timeIntervalSince($0) } ?? 0
            if remoteSession === session, remoteInFront, let index = session.worked(quietFor: quiet) {
                mark = FocusMark.current()
                session.choose(index)
                found = index; worked = true
            } else if remoteSession === session, session.armedCount > 0 {
                Trace.note("send: no Mac stands out by its input (\(session.inputs)); knocking")
            }
        }
        if !worked {
            found = await session.find(first: first, doubtful: unopened, timeout: 1.5, dial: Self.scoutDial) {
                guard self.remoteInFront else {
                    Trace.note("send: no knock: the window in front is no longer a remote desktop (\(Self.frontApp))")
                    return false
                }
                // Every knock of a search goes into one window, so an answer to any of them is one for it.
                let now = FocusMark.current()
                if let mark, !mark.same(as: now) {
                    Trace.note("send: no more knocks: the window in front is not the one the first knock was typed in")
                    return false
                }
                mark = mark ?? now
                knocks += 1
                await KnockKeys.post(nonce: session.nonce)
                return true
            }
        }
        let named = first.map { session.name($0) } ?? "none"
        // A search whose dictation is over (its links closed under it) says nothing about the Macs.
        if remoteSession === session {
            if worked, let found {
                Trace.note("send: \(session.name(found)) is the Mac being worked (\(session.input(found))), told after \(Trace.ms(since: started)) ms; no knock")
            } else if let found {
                Trace.note("send: \(session.name(found)) saw knock \(knocks) after \(Trace.ms(since: started)) ms (the window's title names \(named))")
            } else if knocks > 0 {
                Trace.note("send: no Mac saw the knock (\(knocks) typed, \(Trace.ms(since: started)) ms; \(Self.readiness(session)); the title names \(named))")
            }
            remember(session.names)
            armedNames.merge(session.names) { _, new in new }
            peerReachable.merge(session.reachable) { _, new in new }
            let tried = Set(session.reachable.keys), missed = session.unopened
            unopened = unopened.subtracting(tried).union(missed)
        }
        return (mark, found)
    }

    /// `why`: for the log, when there were connections to close.
    private func endRemote(_ why: String) {
        if remoteSession != nil { Trace.note("send: closing the connections to the other Macs: \(why)") }
        remoteSession?.close(); remoteSession = nil; remoteScout = nil; remoteViewing = nil
    }

    private func recentDictation(on peer: String?) -> String? {
        guard let last = lastDelivered, last.peer == peer, Date().timeIntervalSince(last.at) < 600,
              last.mark?.same(as: FocusMark.current()) == true else { return nil }
        return last.text
    }

    /// Where the text goes: the session that looked, and the Mac in it that claimed the knock (nil
    /// for this Mac).
    private struct Destination {
        let session: RemoteSession?
        let target: Int?
        /// No Mac claimed the knock in the window still in front: the Mac that may have the text on
        /// its clipboard alone (RemoteSession.fallback).
        var fallback: Int? = nil
    }

    /// Typing on this Mac waits for no other Mac; a remote desktop brought to the front after the
    /// recording stopped is looked behind now. A claim counts only for the window still in front.
    private func destination() async -> Destination {
        guard remoteInFront else {
            if remoteSession != nil { Trace.note("send: text ready; the window in front (\(Self.frontApp)) is not a remote desktop, so it is for this Mac") }
            return Destination(session: remoteSession, target: nil)
        }
        if let shown = viewedInFront {
            // The window in front is out's own of that Mac's screen: the text is for that Mac.
            if remoteViewing != shown.key || remoteScout == nil { scoutRemote() }
            guard let session = remoteSession, let scout = remoteScout else { return Destination(session: remoteSession, target: nil) }
            let (_, armed) = await scout.value
            let target = viewedInFront?.key == shown.key ? armed : nil
            Trace.note("send: text ready for out's screen window of \(shown.label): \(target == nil ? "that Mac is not ready, or the window went" : "sending there")")
            return Destination(session: session, target: target)
        }
        // What was armed for out's own window says nothing about the remote desktop in front now.
        if remoteViewing != nil { scoutRemote() }
        if remoteSession == nil { scoutRemote() }
        guard let session = remoteSession, let scout = remoteScout else { return Destination(session: remoteSession, target: nil) }
        let (mark, early) = await scout.value
        guard remoteInFront else {
            Trace.note("send: text ready; the remote desktop is no longer in front (\(Self.frontApp)), so it is for this Mac")
            return Destination(session: session, target: nil)
        }
        let now = FocusMark.current()
        if mark?.same(as: now) ?? false {
            return settle(session, early, in: now)
        }
        Trace.note("send: text ready, but the window in front is not the one the knock was typed in (\(mark == nil ? "no knock was typed" : "\(Self.appName(mark)) then, \(Self.appName(now)) now\(mark?.pid == now?.pid ? ", the same app" : "")")); looking again with new connections")
        // New connections and a new knock: a late answer from the Mac of the earlier window cannot
        // be taken for one from this window's Mac.
        scoutRemote()
        guard let fresh = remoteSession, let again = remoteScout else { return Destination(session: nil, target: nil) }
        let (seen, found) = await again.value
        let current = FocusMark.current()
        guard seen?.same(as: current) == true else {
            if let found { Trace.note("send: the window in front changed again while looking; not sending to \(fresh.name(found))") }
            return Destination(session: fresh, target: nil)
        }
        return settle(fresh, found, in: current)
    }

    /// The Mac for the window `now`, which the knocks of `session` all went into: the one that
    /// claimed a knock, during the search or since; else none, with the Mac whose clipboard alone
    /// may have the text, by the window's title as it is now.
    private func settle(_ session: RemoteSession, _ found: Int?, in now: FocusMark?) -> Destination {
        if let found {
            Trace.note("send: text ready in the window the knock was typed in: for \(session.name(found))")
            return Destination(session: session, target: found)
        }
        if let late = session.claimed {
            Trace.note("send: text ready in the window the knock was typed in: \(session.name(late)) answered after the search gave up")
            return Destination(session: session, target: late)
        }
        Trace.note("send: text ready in the window the knock was typed in: no Mac saw that knock")
        let named = session.index(namedIn: now?.title ?? "", learned: armedNames)
        return Destination(session: session, target: nil, fallback: session.fallback(named: named))
    }

    private enum Revision {
        case edit(text: String, plan: Plan)
        case content
        case blind
    }

    /// `service` and `model` are those that wrote the text; nil when nothing wrote it.
    private func revise(_ transcript: String, at found: Destination, service: Service?, model: String) async -> Revision {
        var context: (before: String, after: String)?
        var plan = Plan.insert
        var peer: String?
        if let target = found.target, let session = found.session {
            peer = session.key(target)
            if let field = await session.context(of: target) { context = field; plan = .field(old: field.before + field.after) }
        } else if found.session == nil || !anotherScreenInFront {
            if let field = TextTarget.field() { context = field; plan = .field(old: field.before + field.after) }
        } else { return .content }
        let previous = recentDictation(on: peer)
        if context == nil, let previous { context = (previous, ""); plan = .previous(previous) }
        guard let context else { return .blind }
        guard !(context.before + context.after).isEmpty else { return .content }
        guard let service,
              let output = try? await TextClient(service: service).revise(transcript: transcript, before: context.before,
                  after: context.after, previous: previous ?? "", model: model) else { return .content }
        let answer = OpenAIWire.splitMarker(output)
        guard answer.marker == "@@EDIT" else { return .content }
        if case .field(let old) = plan { return .edit(text: OpenAIWire.keepingEdges(of: old, answer.text), plan: plan) }
        return .edit(text: answer.text, plan: plan)
    }

    private func cursorUntouched(after previous: String) -> Bool {
        guard let pasted, pasted.text == previous, !shortcut.touched else { return false }
        return pasted.mark?.same(as: FocusMark.current()) == true
    }

    private func notePasted(_ text: String) {
        pasted = text.isEmpty ? nil : (text, FocusMark.current())
        shortcut.touched = false
    }

    private func deliver(_ text: String, plan: Plan, resolved: Destination?, mode: WritingMode, seconds: Double) async throws -> WriteResult {
        let found: Destination
        if let resolved { found = resolved } else { found = await destination() }
        // The session that looked, which may have been opened just now; never a later dictation's.
        let session = found.session, target = found.target
        defer {
            if session != nil { Trace.note("send: done; closing the connections to the other Macs") }
            session?.close(); if remoteSession === session { remoteSession = nil; remoteScout = nil }
        }
        // Cancelled while looking: nothing is sent or typed.
        do { try Task.checkCancellation() } catch {
            if session != nil { Trace.note("send: cancelled before sending") }
            throw error
        }
        // No Mac claimed the knock: plain text still goes to the Mac the window's title names (or the
        // only one ready), for its clipboard alone (user 2026-11-26).
        var plain = false
        if case .insert = plan { plain = true }
        let spare = target == nil && plain ? found.fallback : nil
        if let session, let target = target ?? spare {
            let clipboardOnly = found.target == nil
            let name = session.name(target), id = session.key(target)
            sendingTo = name
            capsuleStep = .sending
            message = tr("Sending to %@…", name)
            if clipboardOnly {
                Trace.note("send: no Mac claimed the knock; \(name) gets the text for its clipboard only (\(Self.readiness(session)))")
            }
            var replace: String?, field: String?
            switch plan {
            case .insert: break
            case .field(let old): field = old
            case .previous(let previous): replace = previous
            }
            let reply: SendReply
            let kind = field != nil ? "a field's new content" : replace != nil ? "a replacement for the last text" : "text"
            Trace.note("send: sending \(kind) to \(name), \(text.count) characters")
            let started = Date()
            do { reply = try await session.send(to: target, text: text, mode: mode, seconds: seconds, replace: replace, field: field, clipboardOnly: clipboardOnly, entry: entry?.id, entryDate: entry?.date) }
            catch let refusal as RemoteRefusal {
                Trace.note("send: \(name) did not type it (\(refusal.miss.rawValue)) after \(Trace.ms(since: started)) ms\(refusal.onClipboard ? ", on its clipboard" : "")")
                throw refusal
            }
            catch is CancellationError { Trace.note("send: cancelled while sending to \(name)"); throw CancellationError() }
            catch let error as RemoteUnreachable {
                Trace.note("send: \(name) could not be reached after \(Trace.ms(since: started)) ms")
                throw RemoteRefusal(peer: name, miss: .unreachable, description: error.description)
            }
            catch let error as DeliveryUnconfirmed {
                Trace.note("send: no answer from \(name) after \(Trace.ms(since: started)) ms, once the text was out")
                throw RemoteRefusal(peer: name, miss: .unconfirmed, description: error.localizedDescription)
            }
            catch {
                Trace.note("send: sending to \(name) failed (\(type(of: error))) after \(Trace.ms(since: started)) ms")
                throw RemoteRefusal(peer: name, miss: .other, description: error.localizedDescription)
            }
            Trace.note("send: \(name) answered after \(Trace.ms(since: started)) ms: \(reply.miss.map { "not typed (\($0.rawValue))" } ?? "typed")\(reply.onClipboard ? ", on its clipboard" : "")")
            let miss = clipboardOnly ? reply.miss ?? .unclaimed : reply.miss
            // A text that may not be in a field is nothing to take back by backspace later.
            lastDelivered = text.isEmpty || field != nil || miss != nil ? nil
                : Delivered(text: text, peer: id, mark: FocusMark.current(), at: Date())
            return WriteResult(summary: tr("%@: %@", name, reply.message), onClipboard: reply.onClipboard, miss: miss, peer: name)
        }
        if settings.preferences.linkEnabled, anotherScreenInFront,
           session != nil || helperState != .ready || !settings.preferences.devices.isEmpty {
            // A remote desktop in front, and Macs to send to (or a helper that should name them): the
            // text is for the Mac behind it, never this one.
            guard let session else {
                Trace.note("send: a remote desktop is in front, but no other Mac could be asked (helper \(helperState))")
                throw RemoteRefusal(peer: nil, miss: .unreachable,
                                    description: helperState == .ready ? tr("A remote desktop window is in front, but none of your other Macs can be reached.")
                                        : tr("A remote desktop window is in front, but the Monitor helper on this Mac cannot reach your other Macs."))
            }
            if session.armedCount == 0 {
                let problems = session.problems.joined(separator: " ")
                Trace.note("send: a remote desktop is in front, but no other Mac was ready (\(Self.readiness(session))): not typed")
                // A Mac that said no, and why, before one that could not be reached.
                if let refusal = session.refusals.first {
                    throw RemoteRefusal(peer: refusal.peer, miss: refusal.miss,
                                        description: tr("A remote desktop window is in front, but none of your other Macs can be reached. %@", problems))
                }
                throw RemoteRefusal(peer: nil, miss: .unreachable,
                                    description: problems.isEmpty ? tr("A remote desktop window is in front, but none of your other Macs can be reached.")
                                        : tr("A remote desktop window is in front, but none of your other Macs can be reached. %@", problems))
            }
            Trace.note("send: a remote desktop is in front, but no Mac is the one for the window in front now (none saw the knock, or the window changed since; \(Self.readiness(session))): not typed")
            throw RemoteRefusal(peer: nil, miss: .noAnswer,
                                description: tr("A remote desktop window is in front, but none of your other Macs answered. Make sure out is running on the Mac you are controlling."))
        }
        if session != nil { Trace.note("send: writing the text on this Mac") }
        let outcome: WriteResult
        switch plan {
        case .field(let old):
            outcome = try TextTarget.rewriteField(from: old, to: text)
            pasted = nil; lastDelivered = nil
        case .previous(let previous):
            outcome = try TextTarget.replace(previous, with: text, untouched: cursorUntouched(after: previous))
            notePasted(text)
            lastDelivered = text.isEmpty ? nil : Delivered(text: text, peer: nil, mark: FocusMark.current(), at: Date())
        case .insert:
            await TextTarget.awaitFocus()
            outcome = try await TextTarget.insertAtFocus(text)
            if outcome.miss == nil, !outcome.unseen {
                notePasted(text)
                lastDelivered = Delivered(text: text, peer: nil, mark: FocusMark.current(), at: Date())
                if settings.preferences.learnCorrections { startWatch(written: text) }
            } else { pasted = nil; lastDelivered = nil }
        }
        return outcome
    }

    /// "Learn from corrections": after the text landed in a field on this Mac, keep the write, the
    /// window and the field it went to. One second later the field is read once — before the user
    /// can have reacted — as `before`/`after` at the cursor; 30 seconds after the write it is read
    /// again for a correction. A new write replaces the watch; nothing read ever leaves this Mac.
    private func startWatch(written: String) {
        watchJob?.cancel(); checkJob?.cancel()
        let watch = CorrectionWatch(id: UUID(), written: written, before: nil, after: nil,
                                  mark: FocusMark.current(), element: TextTarget.fieldWithElement()?.element, at: Date())
        correctionWatch = watch
        let id = watch.id
        watchJob = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.correctionWatch?.id == id else { return }
            guard let live = self.boundField(), live.before.hasSuffix(watch.written) else {
                self.correctionWatch = nil; return
            }
            self.correctionWatch?.before = live.before
            self.correctionWatch?.after = live.after
        }
        checkJob = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.correctionWatch?.id == id else { return }
            self.checkCorrection()
        }
    }

    /// The field the watch is bound to, read now, or nil when another window or field is in front.
    private func boundField() -> (before: String, after: String)? {
        guard let watch = correctionWatch,
              let mark = watch.mark, mark.same(as: FocusMark.current()),
              let element = watch.element,
              let live = TextTarget.fieldWithElement(), CFEqual(element, live.element) else { return nil }
        return (live.before, live.after)
    }

    /// Whether the watched write was corrected: only while the same window and field are still in
    /// front and within ten minutes of the write, and only a word that is not already in the
    /// dictionary, was not declined before, and still fits it. Offered once; the watch is then
    /// cleared — as it is when the window or field no longer matches.
    private func checkCorrection() {
        guard let watch = correctionWatch, let before = watch.before, let after = watch.after else { return }
        guard Date().timeIntervalSince(watch.at) < 600, let field = boundField() else {
            correctionWatch = nil; return
        }
        correctionWatch = nil
        guard let word = CorrectionLearning.suggestion(before: before, after: after, written: watch.written,
                                                       current: field.before + field.after),
              OpenAIWire.cleanDictionary([word]).contains(word),
              !settings.preferences.dictionary.contains(word),
              !settings.preferences.declinedWords.contains(word),
              settings.preferences.dictionary.count < 80 else { return }
        learnedWord = word
    }

    /// The offered correction joins the personal dictionary.
    func acceptLearned() {
        guard let word = learnedWord else { return }
        learnedWord = nil
        if settings.preferences.dictionary.count < 80, !settings.preferences.dictionary.contains(word) {
            settings.preferences.dictionary.append(word)
        }
    }

    /// The offered correction is declined and not offered again; at most 200 are kept.
    func declineLearned() {
        guard let word = learnedWord else { return }
        learnedWord = nil
        if !settings.preferences.declinedWords.contains(word) {
            settings.preferences.declinedWords.append(word)
            if settings.preferences.declinedWords.count > 200 {
                settings.preferences.declinedWords.removeFirst(settings.preferences.declinedWords.count - 200)
            }
        }
    }

    /// Learn from corrections switched off: the pending watch and offer go with it.
    func clearLearned() {
        correctionWatch = nil; watchJob?.cancel(); checkJob?.cancel(); learnedWord = nil
    }

    enum ClipboardPlace { case here, thisMac, there }

    /// The capsule's first line. Pasted with no text field in sight, or sent with no answer back, the
    /// text may still have gone in: that is not confirmed, rather than not typed.
    static func missTitle(_ miss: MissReason, peer: String?) -> String {
        let unsure = [MissReason.noField, .previousGone, .unconfirmed].contains(miss)
        guard let peer else { return unsure ? tr("Not confirmed on this Mac") : tr("Not typed on this Mac") }
        return unsure ? tr("Not confirmed on %@", peer) : tr("Not typed on %@", peer)
    }

    /// Why the text is not in a text field, and where it is, in few enough words for the capsule.
    static func missLine(_ miss: MissReason, clipboard: ClipboardPlace?) -> String {
        let why: String
        switch miss {
        case .noField: why = tr("No text field found")
        case .previousGone: why = tr("The earlier text was not found")
        case .secureInput: why = tr("Secure input is on")
        case .passwordField: why = tr("A password field is in front")
        case .noApp: why = tr("No app in front")
        case .accessibility: why = tr("No Accessibility permission")
        case .pasteFailed: why = tr("The paste keystroke failed")
        case .notAllowed: why = tr("Typing from this Mac is not allowed")
        case .unreachable: why = tr("Could not be reached")
        case .noAnswer: why = tr("None of your other Macs answered")
        case .unconfirmed: why = tr("No answer after sending")
        case .unclaimed: why = tr("Not sure it is the Mac you are controlling")
        case .other: why = tr("The panel shows the reason")
        }
        switch clipboard {
        case .here?: return tr("%@ · On the clipboard (⌘V)", why)
        case .thisMac?: return tr("%@ · On this Mac’s clipboard (⌘V)", why)
        case .there?: return tr("%@ · On its clipboard", why)
        case nil: return why
        }
    }

    // MARK: - Recording a new shortcut (user 2026-11-19)

    @Published private(set) var recordingShortcut = false
    /// Why the last key pressed cannot be the shortcut; empty until one is refused.
    @Published private(set) var shortcutNote = ""
    private var shortcutDeadline: Task<Void, Never>?
    /// When a click or Esc last ended the recording of a shortcut: the click on the badge that ends it
    /// reaches the key monitor first, and must not start it again.
    private var shortcutEndedByInput = Date.distantPast

    /// The shortcut badge was clicked: the next shortcut pressed becomes the one that starts and stops
    /// a recording. A second click, Esc or 20 seconds without a usable key leave it as it was.
    func recordShortcut() {
        if recordingShortcut { endShortcutRecording(); return }
        guard !busy, Date().timeIntervalSince(shortcutEndedByInput) > 0.8 else { return }
        if settings.preview { recordingShortcut = true; return }
        settings.refreshPermissions()
        guard settings.accessibilityAllowed else { settings.requestAccessibility(); refresh(); return }
        if !shortcut.installed { refresh() }
        guard shortcut.installed else { return }
        shortcutNote = ""
        recordingShortcut = true
        shortcut.onRecorded = { [weak self] verdict in self?.recorded(verdict) }
        shortcutDeadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.endShortcutRecording()
        }
    }

    func endShortcutRecording() {
        shortcutDeadline?.cancel(); shortcutDeadline = nil
        if !settings.preview { shortcut.onRecorded = nil }
        if recordingShortcut { recordingShortcut = false }
        if !shortcutNote.isEmpty { shortcutNote = "" }
    }

    private func recorded(_ verdict: Shortcut.Verdict?) {
        switch verdict {
        case nil: shortcutEndedByInput = Date(); endShortcutRecording()
        case .refuse(let why)?: shortcutNote = why
        case .accept(let next)?:
            endShortcutRecording()
            settings.preferences.shortcut = next.stored
            refresh()
        }
    }

    func takeOverFn() {
        guard !settings.preview, !busy else { return }
        endShortcutRecording()
        shortcut.stop()
        settings.preferences.shortcut = "fn"
        settings.refreshPermissions()
        if !settings.accessibilityAllowed { settings.requestAccessibility() }
        refresh()
    }

    func toggle() {
        if phase == .recording { finish(); return }
        guard phase != .processing else { return }
        // A press while the microphone is starting stops the recording once it has started.
        if starting { stopWhenStarted.toggle(); return }
        starting = true
        stopWhenStarted = false
        cancelWhenStarted = false
        Task {
            await begin()
            starting = false
            if cancelWhenStarted { cancelWhenStarted = false; if phase == .recording { cancel() } }
            else if stopWhenStarted, phase == .recording { finish() }
        }
    }

    /// The microphone is starting; nothing else that records, retries or types begins meanwhile.
    private var starting = false
    private var stopWhenStarted = false
    /// A held Fn turned out to be a key combination while the microphone was starting: its recording
    /// goes as soon as it has started (cancelling sooner would leave begin() to start a fresh one).
    private var cancelWhenStarted = false

    // MARK: Holding the shortcut while speaking (push-to-talk, user 2026-11-21)

    /// A recording that the shortcut, still held, started.
    private var heldRecording = false

    /// The shortcut held while nothing records (Fn past the tap time, or an F key or combination
    /// pressed): a recording starts, which the shortcut's release stops.
    func holdBegan() -> Bool {
        guard phase != .recording, phase != .processing, !starting else { return false }
        heldRecording = true
        toggle()
        return true
    }

    /// The shortcut that started the recording was let go: `stop` when it was held past the tap time.
    func holdReleased(stop: Bool) {
        guard heldRecording else { return }
        heldRecording = false
        guard stop else { return }
        if starting { stopWhenStarted = true } else if phase == .recording { finish() }
    }

    /// A key or click soon after a held Fn started the recording: the press was a key combination
    /// (Fn with an arrow or Delete), so the recording goes, as with Esc.
    func holdBroken() {
        guard heldRecording else { return }
        heldRecording = false
        if starting { cancelWhenStarted = true } else if phase == .recording { cancel() }
    }

    /// Says why there is no input — the bound microphone is away, or there is none at all — on the
    /// status capsule for a few seconds and on the panel until the next dictation. Nothing records.
    private func warnMicrophone(_ problem: String) {
        let alertID = UUID()
        sessionID = alertID
        result = ""; partial = ""; meter.reset(); latency = nil
        phase = .error
        message = problem
        presentOverlay?()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.sessionID == alertID, self.phase == .error else { return }
            self.dismissOverlay?()
        }
    }

    private func begin() async {
        checkCorrection()
        endShortcutRecording()
        settings.refreshPermissions()
        guard settings.microphoneAllowed else {
            message = tr("Allow microphone access first.")
            settings.reveal(.keyboard)
            openSettings?()
            return
        }
        // The text is written in front once it is ready; some apps need a moment to show their fields.
        TextTarget.prepareFront()
        let prefs = settings.preferences
        // The device list kept off the main thread: reading the audio system here could hang the
        // app. The recorder checks the devices again as it opens the microphone.
        let micCheck = microphoneResolution
        if let problem = micCheck.missingMessage {
            microphones.refresh()
            warnMicrophone(problem)
            return
        }
        if microphones.loaded, case .boundAvailable(let matched) = micCheck, settings.preferences.microphoneName != matched.name {
            settings.preferences.microphoneName = matched.name
        }
        stopRetry()
        endRemote("a new recording starts")
        let id = UUID()
        sessionID = id
        entry = nil; audioFile = nil; connectionError = nil
        let selection = prefs.mode == .rewrite && settings.accessibilityAllowed ? (try? TextTarget.capture().selectedText) ?? "" : ""
        let mode: WritingMode = prefs.mode == .rewrite && (selection.isEmpty || selection.count > 30000) ? .dictate : prefs.mode
        let style = prefs.dictationStyle
        let request = SavedDictation(mode: mode, polish: style != .raw, targetLanguage: prefs.targetLanguage,
            speechModel: prefs.speechModel, textModel: prefs.textModel, dictionary: prefs.dictionary,
            selection: mode == .rewrite ? selection : "",
            speechPlatform: prefs.speechPlatform, textPlatform: prefs.textPlatform, style: style)
        do {
            result = ""; partial = ""; meter.reset(); latency = nil; connected = false; hadSignal = false; stopTime = nil
            // The microphone opens off the main thread, so an audio system that stops answering ends in
            // an error instead of a frozen out. History gets the recording only once it has started.
            // A recording playing from History would be recorded with this one: it stops before the
            // microphone opens, and none starts while it opens (see canPlayRecording).
            historyPage.player.stop()
            micOpening += 1
            let audio: AsyncThrowingStream<Data, Error>
            do {
                audio = try await recorder.start(microphone: prefs.microphone, microphoneName: prefs.microphoneName) { [weak self] value in
                    guard let self, self.sessionID == id, self.phase == .recording else { return }
                    self.meter.setLevel(min(1, value * 12))
                    if value > 0.002 { self.hadSignal = true }
                }
            } catch { micOpening -= 1; throw error }
            micOpening -= 1
            // Cancelled or replaced while starting: the stream is this start's, so stopping it is safe.
            guard sessionID == id else { recorder.stop(); return }
            let (record, savedAudio) = try settings.beginHistory(request)
            entry = record; audioFile = savedAudio
            phase = .recording
            recordingBegan = Date()
            message = mode != prefs.mode ? tr("No text selected · Handled as dictation") : tr("Recording · Tap again to stop")
            presentOverlay?()
            startClock(id: id)
            captureJob = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await chunk in audio {
                        try Task.checkCancellation()
                        guard self.sessionID == id else { return }
                        try savedAudio.append(chunk)
                    }
                    try Task.checkCancellation()
                    guard self.sessionID == id else { return }
                    try savedAudio.finish()
                    self.entry?.seconds = savedAudio.seconds
                    if let error = self.connectionError { self.keepForRetry(error) }
                    else { self.entry?.status = .processing; try self.saveActive() }
                    self.captureJob = nil
                } catch {
                    guard self.sessionID == id else { return }
                    self.localFailure(error)
                }
            }
            job = Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    guard self.networkAvailable || Platform.named(request.speechPlatform).wire == .onDevice else { throw VoiceError(tr("The network is unavailable"), retryable: true) }
                    let recognized = try await self.recognize(request, audio: { try savedAudio.stream() },
                        using: { [weak self] client in
                            guard let self, self.sessionID == id else { return }
                            self.client = client
                            // One that takes the finished file connects to nothing while the recording is
                            // made: there is nothing to wait for, so the recording is not offline.
                            self.connected = !client.live
                            // Taken over after Stop: its answer is due within the same bounded time.
                            if self.phase != .recording { client.finishDeadline() }
                        },
                        switching: { [weak self] failed, next in
                            guard let self, self.sessionID == id else { return }
                            // The words the failed key heard go; the next one hears the recording from its start.
                            self.partial = ""; self.entry?.text = ""
                            self.message = tr("%@ failed. Trying %@…", self.settings.label(failed), self.settings.label(next))
                        },
                        onReady: { [weak self] in
                            guard let self, self.sessionID == id else { return }
                            self.connected = true
                            if self.phase == .recording { self.message = tr("Listening · Tap again to stop") }
                        }, onPartial: { [weak self] text in
                            guard let self, self.sessionID == id else { return }
                            if self.partial != text { self.partial = text }
                            self.entry?.text = text
                        })
                    let transcript = recognized.text
                    try Task.checkCancellation()
                    guard self.sessionID == id else { return }
                    guard !transcript.isEmpty else { throw VoiceError(tr("No speech was recognized. Check the microphone input.")) }
                    self.result = transcript
                    self.entry?.text = transcript; self.entry?.transcript = transcript
                    try self.saveActive()
                    // Only Polish tidies; the other styles rewrite, and Raw is over at once.
                    let polishing = request.mode == .dictate && request.writing == .polish
                    self.capsuleStep = polishing ? .polishing : .writing
                    self.message = polishing ? tr("Polishing the text…") : tr("Writing the text…")
                    // Read right before the request, only for a live dictation on this Mac.
                    // Not while a remote desktop is in front with other Macs to send to, whether it was
                    // there when the recording stopped (a session) or came there since.
                    let context = prefs.fieldContext && remoteSession == nil && !(settings.sendsRemotely && self.remoteInFront)
                        && settings.accessibilityAllowed
                        && request.mode == .dictate && request.writing != .raw
                        ? String((TextTarget.field()?.before ?? "").suffix(1000)) : ""
                    let screened = try await self.edit(transcript, request: request, context: context,
                                                       screening: request.mode == .dictate && request.writing == .polish,
                                                       switching: { [weak self] failed, next in
                                                           guard let self, self.sessionID == id else { return }
                                                           self.message = tr("%@ failed. Trying %@…", self.settings.label(failed), self.settings.label(next))
                                                       })
                    try Task.checkCancellation()
                    guard self.sessionID == id else { return }
                    var final = screened.text
                    var plan = Plan.insert
                    var resolved: Destination?
                    var notes: [String] = screened.asSaid ? [tr("Polish changed the meaning; the original transcript was kept")] : []
                    // A fallback key did the job: said with the result, so a failing key is noticed.
                    if recognized.fellBack { notes.append(tr("Recognized with %@", self.settings.label(recognized.route))) }
                    if let route = screened.route, screened.fellBack {
                        notes.append(polishing ? tr("Polished with %@", self.settings.label(route)) : tr("Written with %@", self.settings.label(route)))
                    }
                    if screened.maybe {
                        self.capsuleStep = .editing
                        self.message = tr("Checking the edit to the text field…")
                        let found = await self.destination()
                        resolved = found
                        switch await self.revise(transcript, at: found, service: screened.service, model: screened.model) {
                        case .edit(let text, let chosen): final = text; plan = chosen
                        case .content: break
                        case .blind: notes.append(tr("Text field not read; inserted as plain text"))
                        }
                        try Task.checkCancellation()
                        guard self.sessionID == id else { return }
                    }
                    self.result = screened.text
                    if var completed = self.entry {
                        completed.text = self.result; completed.status = .completed
                        completed.request = nil; completed.transcript = nil; completed.problem = nil
                        try self.settings.updateHistory(completed)
                        self.entry = completed
                    }
                    var outcome = ""
                    var onClipboard = false
                    var missed = false
                    // Missed a field on this Mac and not on the clipboard either: in History alone.
                    var historyOnly = false
                    // Meant for another Mac and not typed there: said on the capsule at once, with why.
                    var notTyped: (title: String, detail: String)?
                    do {
                        let written = try await self.deliver(final, plan: plan, resolved: resolved,
                                                             mode: request.mode, seconds: self.entry?.seconds ?? 0)
                        var parts = [written.summary] + notes
                        parts.append(tr("Saved to History"))
                        outcome = parts.joined(separator: " · ")
                        onClipboard = written.onClipboard
                        historyOnly = written.miss != nil && written.peer == nil && !written.onClipboard
                        if let miss = written.miss, let peer = written.peer {
                            notTyped = (Self.missTitle(miss, peer: peer), Self.missLine(miss, clipboard: written.onClipboard ? .there : nil))
                        }
                    }
                    catch {
                        if Task.isCancelled || error is CancellationError { return }
                        let kept = self.keepOnClipboard(final)
                        var parts = [error.localizedDescription]
                        if kept { parts.append(tr("Saved to the clipboard (⌘V)")) }
                        parts.append(tr("Saved to History"))
                        outcome = parts.joined(separator: " · ")
                        onClipboard = kept
                        missed = true
                        if let refusal = error as? RemoteRefusal {
                            notTyped = (refusal.peer.map { Self.missTitle(refusal.miss, peer: $0) } ?? tr("Not sent to another Mac"),
                                        Self.missLine(refusal.miss, clipboard: kept ? .thisMac : (refusal.onClipboard ? .there : nil)))
                        }
                    }
                    guard self.sessionID == id else { return }
                    self.capsuleResult = notTyped.map { .notWritten($0.title, $0.detail) }
                        ?? (onClipboard ? .onClipboard : historyOnly ? .savedToHistory : .inserted)
                    self.message = outcome
                    self.latency = self.stopTime.map { Date().timeIntervalSince($0) }
                    self.phase = .done
                    self.client = nil; self.audioFile = nil
                    self.clock?.cancel()
                    self.job = nil
                    let linger: UInt64 = missed || notTyped != nil ? 5_000_000_000 : 2_000_000_000
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: linger)
                        guard let self, self.sessionID == id, self.phase == .done else { return }
                        self.dismissOverlay?()
                    }
                } catch {
                    guard self.sessionID == id else { return }
                    if Task.isCancelled || error is CancellationError { return }
                    self.client?.cancel(); self.client = nil; self.connected = false
                    self.connectionError = error
                    if self.phase == .recording {
                        self.message = tr("Recording on this Mac · Will transcribe when online")
                    } else if self.captureJob == nil { self.keepForRetry(error) }
                    self.job = nil
                }
            }
        } catch {
            guard sessionID == id else { return }
            recorder.stop()
            microphones.refresh()
            try? audioFile?.finish()
            if let entry { settings.removeHistory(id: entry.id) }
            entry = nil; audioFile = nil
            phase = .error; message = error.localizedDescription; presentOverlay?()
        }
    }

    private func transcriber(for route: SettingsStore.Route) async throws -> any Transcriber {
        if route.platform.wire == .onDevice {
            guard #available(macOS 26, *) else {
                throw VoiceError(tr("This Mac cannot recognize this language on the device. Choose another in Settings."))
            }
            return OnDeviceTranscriber(locale: route.model)
        }
        let service = try await settings.serviceAsync(route.platform, key: route.key)
        guard !route.model.isEmpty else { throw VoiceError(tr("The recognition model name is empty. Enter it in Settings.")) }
        // A service spoken to in its own way: its live socket, or the finished recording in its own request.
        if let wire = service.platform.liveWire(model: route.model, base: service.base) {
            return LiveSocketTranscriber(wire: wire, key: service.key, name: service.platform.name)
        }
        if let wire = service.platform.fileWire(model: route.model) {
            return FileTranscriber(wire: wire, key: service.key, name: service.platform.name)
        }
        if service.platform.wire == .alibaba {
            return QwenRealtimeTranscriber(key: service.key,
                endpoint: Platform.realtimeURL(base: service.base, model: route.model))
        }
        return service.platform.streams(model: route.model) ? RealtimeTranscriber(key: service.key) : UploadTranscriber(service: service)
    }

    /// Recognizes the recording with the job's first key and, each time one fails for its key, its
    /// quota or its service, with the next fallback key, from the start of the recording (which is
    /// still being made when that happens while recording). `using` is told each transcriber as it
    /// starts, `switching` the route that failed and the one tried next.
    private func recognize(_ request: SavedDictation, audio: () throws -> AsyncThrowingStream<Data, Error>,
                           using: (any Transcriber) -> Void,
                           switching: (SettingsStore.Route, SettingsStore.Route) -> Void = { _, _ in },
                           onReady: @escaping () -> Void, onPartial: @escaping (String) -> Void) async throws
        -> (text: String, route: SettingsStore.Route, fellBack: Bool) {
        let routes = settings.routes(speech: true, platform: request.speechPlatform, model: request.speechModel)
        for (index, route) in routes.enumerated() {
            var client: (any Transcriber)?
            do {
                let made = try await transcriber(for: route)
                client = made
                using(made)
                let text = try await made.run(audio: try audio(), model: route.model, dictionary: request.dictionary,
                                              onReady: onReady, onPartial: onPartial)
                return (text, route, index > 0)
            } catch {
                guard index + 1 < routes.count, (error as? VoiceError)?.fallback == true, !Task.isCancelled else { throw error }
                client?.cancel()
                Trace.note("recognition: \(route.platform.id) failed for its key, quota or service; the next key is tried")
                switching(route, routes[index + 1])
            }
        }
        throw CancellationError()
    }

    /// The text as polishing or a style wrote it, and what wrote it: nil and empty for Raw.
    private struct Written {
        let text: String
        let maybe: Bool
        let asSaid: Bool
        let service: Service?
        let model: String
        let route: SettingsStore.Route?
        let fellBack: Bool
    }

    /// Writes the transcript with the job's first key and, each time one fails for its key, its
    /// quota or its service, with the next fallback key. `switching` as for `recognize`.
    private func edit(_ transcript: String, request: SavedDictation, context: String = "", screening: Bool = false,
                      switching: (SettingsStore.Route, SettingsStore.Route) -> Void = { _, _ in }) async throws -> Written {
        if request.mode == .dictate && request.writing == .raw {
            return Written(text: transcript, maybe: false, asSaid: false, service: nil, model: "", route: nil, fellBack: false)
        }
        let routes = settings.routes(speech: false, platform: request.textPlatform, model: request.textModel)
        var answered: (output: String, service: Service, route: SettingsStore.Route, fellBack: Bool)?
        for (index, route) in routes.enumerated() {
            do {
                let service = try await settings.serviceAsync(route.platform, key: route.key)
                guard !route.model.isEmpty else { throw VoiceError(tr("The text polishing model name is empty. Enter it in Settings.")) }
                let output = try await TextClient(service: service).edit(transcript: transcript, mode: request.mode,
                    targetLanguage: request.targetLanguage, selection: request.selection, model: route.model,
                    style: request.writing, screening: screening, context: context)
                answered = (output, service, route, index > 0)
                break
            } catch {
                guard index + 1 < routes.count, (error as? VoiceError)?.fallback == true, !Task.isCancelled else { throw error }
                Trace.note("polishing: \(route.platform.id) failed for its key, quota or service; the next key is tried")
                switching(route, routes[index + 1])
            }
        }
        guard let answered else { throw CancellationError() }
        let output = answered.output
        func written(_ text: String, maybe: Bool = false, asSaid: Bool = false) -> Written {
            Written(text: text, maybe: maybe, asSaid: asSaid, service: answered.service, model: answered.route.model,
                    route: answered.route, fellBack: answered.fellBack)
        }
        guard request.mode == .dictate else { return written(output) }
        // The rewriting styles are used as returned; only Polish is held to the words that were said.
        guard request.writing == .polish else { return written(output) }
        let answer = screening ? OpenAIWire.splitMarker(output) : (marker: nil, text: output)
        guard !answer.text.isEmpty else { throw VoiceError(tr("The model returned no usable text. The original transcript was kept.")) }
        let text = answer.text
        let faithful = await Task.detached(priority: .userInitiated) { OpenAIWire.keepsWording(of: transcript, in: text) }.value
        return written(faithful ? text : transcript, maybe: answer.marker == "@@MAYBE", asSaid: !faithful)
    }

    private func saveActive() throws {
        guard let entry else { return }
        try settings.updateHistory(entry)
    }

    private func keepForRetry(_ error: Error) {
        endRemote("the recording is kept to try again (\(type(of: error)))")
        guard settings.history.first(where: { $0.id == entry?.id })?.state != .completed else {
            // The text and its recording are saved already: nothing is left to try again.
            phase = .error; message = tr("Saved to History"); return
        }
        let pending = (error as? VoiceError)?.retryable == true || error is URLError
        entry?.status = pending ? .pending : .failed
        entry?.problem = error is VoiceError ? error.localizedDescription : tr("The network request failed. The original recording is kept.")
        entry?.seconds = audioFile?.seconds ?? entry?.seconds ?? 0
        entry?.failures = networkAvailable ? 1 : nil
        do { try saveActive() }
        catch { localFailure(); return }
        if let entry { retryAfter[entry.id] = Date().addingTimeInterval(networkAvailable ? RetryPace.wait(afterFailures: 1) ?? 60 : 0) }
        result = entry?.text ?? partial
        phase = .done; capsuleResult = .savedToHistory
        message = pending ? tr("Recording saved to History · Will transcribe when online") : tr("Recording saved to History · It can be retried there")
        audioFile = nil
        presentOverlay?()
        // It goes like any other result: it used to stay until the next dictation, and the bar kept
        // on top showed it instead of its Record button.
        let shown = sessionID
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.sessionID == shown, self.phase == .done, case .savedToHistory = self.capsuleResult else { return }
            self.dismissOverlay?()
        }
    }

    private func localFailure(_ error: Error? = nil) {
        endRemote("it failed on this Mac\(error.map { " (\(type(of: $0)))" } ?? "")")
        microphones.refresh()
        sessionID = UUID()
        recorder.stop(); captureJob?.cancel(); job?.cancel(); clock?.cancel(); client?.cancel()
        try? audioFile?.finish()
        entry?.seconds = audioFile?.seconds ?? entry?.seconds ?? 0
        let specific = (error as? VoiceError)?.localizedDescription
        entry?.status = .failed
        entry?.problem = specific ?? tr("The recording could not be saved, or the input device failed. Check the disk space and the microphone.")
        try? saveActive()
        phase = .error
        message = specific ?? tr("Recording interrupted by a device or disk problem. The audio so far is kept in History.")
        client = nil; audioFile = nil
        presentOverlay?()
    }

    func finish() {
        guard phase == .recording else { return }
        heldRecording = false
        if !hadSignal {
            connectionError = VoiceError(tr("No clear sound was detected. The original recording is kept; check the microphone or retry by hand."))
            job?.cancel(); job = nil; client?.cancel(); client = nil
        }
        phase = .processing
        stopTime = Date()
        capsuleStep = .recognizing
        message = tr("Finishing recognition…")
        clock?.cancel()
        recorder.stop()
        client?.finishDeadline()
        if hadSignal && connectionError == nil { scoutRemote() }
    }

    func cancel() {
        // Typing has a cancel of its own: the recording state (and History) is not its to touch.
        if typingJob != nil { stopTyping(); return }
        heldRecording = false
        endRemote("cancelled")
        let discard = busy ? entry?.id : nil
        sessionID = UUID()
        recorder.stop(); client?.cancel(); client = nil
        captureJob?.cancel(); captureJob = nil
        try? audioFile?.finish(); audioFile = nil
        job?.cancel(); job = nil; clock?.cancel(); clock = nil
        if let discard { settings.removeHistory(id: discard) }
        entry = nil
        meter.reset()
        phase = .idle; partial = ""; result = ""; message = ""
        dismissOverlay?()
    }

    // MARK: - Type the Clipboard (merged from PasteForce, user 2026-11-19)

    @Published private(set) var typedCount = 0
    @Published private(set) var typingTotal = 0

    /// Stops typing now and puts the input source back; the capsule goes.
    private func stopTyping() {
        typingJob?.cancel(); typingJob = nil
        ClipboardTyper.stopNow()
        sessionID = UUID()
        phase = .idle; message = ""
        dismissOverlay?()
    }
    private var typingJob: Task<Void, Never>?
    private var lastOtherApp: NSRunningApplication?
    /// Where the keyboard was in `lastOtherApp` when a click on out's window took it away.
    private var focusLeft: FocusReturn?
    /// When a click last landed on out's window while another app was in front.
    private var clickedHere: Date?
    private var activationObserver: NSObjectProtocol?
    private var ownActivationObserver: NSObjectProtocol?

    /// Puts a copied item back and pastes it into the app in front, from History. Clicked there,
    /// out is in front: the app that was in front before it gets the paste.
    func pasteClip(_ entry: ClipEntry, plain: Bool) {
        pasteBack { clipboard.put(entry, plain: plain) }
    }

    /// The same for a recording's text, from History.
    func pasteText(_ text: String) {
        // While a dictation's own paste holds the clipboard, the text waits: nothing is pasted then.
        pasteBack {
            ClipboardCopy.copy(text)
            return NSPasteboard.general.string(forType: .string) == text
        }
    }

    func pasteHistory(_ item: HistoryItem, plain: Bool) {
        switch item {
        case .copied(let entry): pasteClip(entry, plain: plain)
        case .voice(let entry):
            if entry.text.isEmpty { NSSound.beep() } else { pasteText(entry.text) }
        }
    }

    /// Says the item chosen with the keys to VoiceOver, which the keys do not move.
    private func announce(_ item: HistoryItem) {
        let words: String
        switch item {
        case .copied(let entry): words = entry.kind == .image ? tr("Image") : String(entry.preview.prefix(160))
        case .voice(let entry): words = entry.text.isEmpty ? entry.state.title : String(entry.text.prefix(160))
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Keys on History while it shows: Up and Down choose, Return pastes the chosen item (Shift +
    /// Return as plain text), Command + 1 to 9 one of the first nine. False for a key it leaves alone.
    func historyKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let shown = historyPage.shown(voice: settings.history)
        guard !shown.isEmpty else { return false }
        let chosen = shown.firstIndex { $0.id == historyPage.selection }
        switch event.keyCode {
        case 125, 126:
            guard flags.isEmpty else { return false }
            let next = event.keyCode == 125 ? chosen.map { min($0 + 1, shown.count - 1) } ?? 0 : chosen.map { max($0 - 1, 0) } ?? 0
            historyPage.selection = shown[next].id
            historyPage.reveal = shown[next].id
            announce(shown[next])
            return true
        case 36, 76:
            guard flags.isEmpty || flags == .shift, let chosen else { return false }
            pasteHistory(shown[chosen], plain: flags == .shift)
            return true
        default:
            guard flags == .command, let typed = event.charactersIgnoringModifiers, let digit = Int(typed),
                  (1...9).contains(digit), digit <= shown.count else { return false }
            historyPage.selection = shown[digit - 1].id
            pasteHistory(shown[digit - 1], plain: false)
            return true
        }
    }

    private func pasteBack(_ put: () -> Bool) {
        guard put() else { NSSound.beep(); return }
        guard NSApp.isActive, let other = lastOtherApp, !other.isTerminated else { ClipboardPicker.pasteIntoFront(); return }
        // Only into that app, and only what was just put on the clipboard: an app that comes in
        // front meanwhile, or a copy made meanwhile, gets no paste.
        let pid = other.processIdentifier, count = NSPasteboard.general.changeCount
        other.activate()
        Task { @MainActor in
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                try? await Task.sleep(for: .milliseconds(50))
            }
            ClipboardPicker.pasteIntoFront(expecting: pid, count: count)
        }
    }

    /// Types the clipboard's text key by key into the field in front: for fields and screens that
    /// refuse a paste. Line breaks are typed as Return; a password field is typed into too (both the
    /// user's choice for this action alone: dictation still never does either). Nothing typed is
    /// kept: not in History, not in the result.
    func typeClipboard(from origin: ClipboardTyper.Origin) {
        guard !busy, !starting else { return }
        settings.refreshPermissions()
        guard settings.accessibilityAllowed else {
            showTypingProblem(tr("Accessibility permission is not granted. Allow out in System Settings.")); return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showTypingProblem(tr("The clipboard holds no text.")); return
        }
        guard text.count <= KeystrokePlan.longest else {
            showTypingProblem(tr("The clipboard text is too long to type: %ld characters (maximum %ld).", text.count, KeystrokePlan.longest)); return
        }
        // The app to type into is fixed now: the one in front, or (from the panel or the menu, while
        // this app is active) the one that was in front before it.
        let front = NSWorkspace.shared.frontmostApplication
        let target = front.flatMap { $0.processIdentifier == getpid() ? nil : $0 } ?? (origin == .shortcut ? nil : lastOtherApp)
        guard let target else { showTypingProblem(tr("Click the field you want to type into first.")); return }
        let returning = focusLeft?.pid == target.processIdentifier ? focusLeft : nil
        let id = UUID()
        sessionID = id
        result = ""; partial = ""; latency = nil; message = ""
        typedCount = 0; typingTotal = 0
        phase = .processing; capsuleStep = .typing
        presentOverlay?()
        typingJob = Task { @MainActor [weak self] in
            do {
                let count = try await ClipboardTyper.type(text, into: target, from: origin, returning: returning,
                                                          farSide: { [weak self] seconds in await self?.holdFarLayout(seconds: seconds) ?? .none },
                                                          userInputs: { [weak self] in self?.shortcut.userInputs ?? 0 }) { done, total in
                    guard let self, self.sessionID == id else { return }
                    self.typedCount = done; self.typingTotal = total
                }
                guard let self, self.sessionID == id else { return }
                self.typingJob = nil
                self.phase = .done; self.capsuleResult = .typed
                self.message = tr("Typed %ld characters", count)
                self.presentOverlay?()
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard self.sessionID == id, self.phase == .done else { return }
                self.dismissOverlay?()
            } catch is CancellationError {
                // cancel() has put everything back.
            } catch {
                guard let self, self.sessionID == id else { return }
                self.typingJob = nil
                self.showTypingProblem(error.localizedDescription)
            }
        }
    }

    /// Type the Clipboard into a remote desktop: the knock tells which of the owner's Macs it shows,
    /// and that Mac's out is asked to type with a keyboard layout for about `seconds` while the keys
    /// come. `.none` when cross-Mac typing is off, no Mac claims the knock (another computer, or one
    /// without out), or that Mac's out cannot (an earlier version): the keys are typed anyway.
    /// `.refused` when it can but did not.
    private func holdFarLayout(seconds: Double) async -> FarSide {
        let devices = settings.preferences.devices.filter(\.reachable)
        guard let identity, settings.sendsRemotely, !settings.preview, !devices.isEmpty else { return .none }
        let session = RemoteSession(devices: devices, identity: identity, name: deviceName, listening: settings.preferences.remotePort)
        let mark = FocusMark.current()
        let first = session.index(namedIn: mark?.title ?? "", learned: armedNames)
        Trace.note("type: a remote desktop (\(Self.frontApp)) is in front; knocking to find the Mac it shows")
        let found = await session.find(first: first, doubtful: unopened, timeout: 1.5, dial: Self.scoutDial) {
            // Every knock goes into the window the typing is for, and none once the typing is cancelled.
            guard !Task.isCancelled, let mark, mark.same(as: FocusMark.current()) else { return false }
            await KnockKeys.post(nonce: session.nonce)
            return true
        }
        armedNames.merge(session.names) { _, new in new }
        guard !Task.isCancelled else { session.close(); return .none }
        guard let found else {
            Trace.note("type: no Mac claimed the knock (\(Self.readiness(session))); typing without asking any")
            session.close(); return .none
        }
        guard session.canHoldLayout(at: found) else {
            Trace.note("type: \(session.name(found)) claimed the knock; its out is an earlier one, typing without a layout there")
            session.close(); return .none
        }
        let held = await session.holdLayout(at: found, seconds: seconds)
        guard held, !Task.isCancelled else {
            if !held { Trace.note("type: \(session.name(found)) selected no keyboard layout; nothing is typed") }
            let name = session.name(found)
            session.close()
            return held ? .none : .refused(name)
        }
        Trace.note("type: \(session.name(found)) types with a keyboard layout while the keys come")
        return .held(FarLayout(session: session, index: found))
    }

    private func showTypingProblem(_ problem: String) {
        let id = UUID()
        sessionID = id
        result = ""; partial = ""; latency = nil
        phase = .error; message = problem
        presentOverlay?()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.sessionID == id, self.phase == .error else { return }
            self.dismissOverlay?()
        }
    }

    /// Sleep/quit preserve unfinished work; only an explicit Cancel discards it.
    func suspend() {
        if typingJob != nil { stopTyping() }
        LayoutHold.end(now: true)
        stopRetry()
        endRemote("this Mac sleeps or out quits")
        // A recording still starting is dropped; nothing has reached History yet.
        if starting { sessionID = UUID(); recorder.stop() }
        if busy {
            sessionID = UUID()
            recorder.stop(); captureJob?.cancel(); job?.cancel(); client?.cancel(); clock?.cancel()
            try? audioFile?.finish()
            entry?.seconds = audioFile?.seconds ?? entry?.seconds ?? 0
            entry?.status = .failed; entry?.problem = tr("Processing stopped for sleep or quit. The original recording is kept and can be retried by hand.")
            try? saveActive()
            audioFile = nil; client = nil
            phase = .done; capsuleResult = .savedToHistory; message = tr("Unfinished recording saved to History; it can be retried by hand")
        }
        dismissOverlay?()
    }

    /// Whether a recorded request needs the network: on-device speech does not,
    /// and a Raw dictation skips the remote text step entirely.
    func needsNetwork(_ r: SavedDictation) -> Bool {
        let textSkipped = r.mode == .dictate && r.writing == .raw
        return !(Platform.named(r.speechPlatform).wire == .onDevice && textSkipped)
    }

    /// Whether this recorded request could run right now: each step still to do possible with its
    /// first key or a fallback (recognition is not, once `transcribed`), and the network unless the
    /// request needs none.
    func canRun(_ r: SavedDictation, transcribed: Bool = false) -> Bool {
        let textSkipped = r.mode == .dictate && r.writing == .raw
        return (transcribed || settings.usable(speech: true, platform: r.speechPlatform))
            && (textSkipped || settings.usable(speech: false, platform: r.textPlatform))
            && (networkAvailable || !needsNetwork(r))
    }

    /// The request a manual retry of this record would run: its recorded request
    /// updated to the platforms, models and style chosen now.
    func retryRequest(_ record: HistoryEntry) -> SavedDictation? {
        guard var request = record.request else { return nil }
        request.speechModel = settings.preferences.speechModel
        request.textModel = settings.preferences.textModel
        request.speechPlatform = settings.preferences.speechPlatform
        request.textPlatform = settings.preferences.textPlatform
        request.style = settings.preferences.dictationStyle
        request.polish = settings.preferences.dictationStyle != .raw
        return request
    }

    func retry(_ id: UUID) {
        guard !busy, !starting, retryingID == nil,
              var record = settings.history.first(where: { $0.id == id }), record.canRetry else { return }
        record.request = retryRequest(record)
        record.status = .pending; record.failures = nil
        do { try settings.updateHistory(record) }
        catch { settings.historyMessage = tr("Could not update the retry status. Check the disk space on this Mac."); return }
        retryAfter[id] = nil
        retryQueued(preferred: id)
    }

    private func retryQueued(preferred: UUID? = nil) {
        guard !settings.preview, !busy, !starting, retryingID == nil,
              var record = settings.history.reversed().first(where: { candidate in
                  candidate.state == .pending && (preferred == nil || preferred == candidate.id) &&
                  (retryAfter[candidate.id] ?? .distantPast) <= Date() &&
                  (candidate.request.map { canRun($0, transcribed: candidate.transcript != nil) } ?? false)
              }), let request = record.request, let archive = settings.archive else { return }
        let id = record.id
        record.status = .processing; record.problem = nil
        do { try settings.updateHistory(record) }
        catch { settings.historyMessage = tr("Could not update the retry status. Check the disk space on this Mac."); return }
        retryingID = id
        retryJob = Task { [weak self] in
            guard let self else { return }
            defer { if self.retryingID == id { self.retryingID = nil; self.retryClient = nil; self.retryJob = nil } }
            do {
                try Task.checkCancellation()
                let transcript: String
                if let saved = record.transcript { transcript = saved }
                else {
                    let audio = try RecordedAudio(url: archive.audioURL(id), create: false)
                    transcript = try await self.recognize(request, audio: { try audio.stream() },
                        using: { [weak self] in self?.retryClient = $0 }, onReady: {}, onPartial: { _ in }).text
                }
                try Task.checkCancellation()
                guard self.retryingID == id else { return }
                guard !transcript.isEmpty else { throw VoiceError(tr("No speech was recognized. Check the original recording.")) }
                record.text = transcript; record.transcript = transcript
                try self.settings.updateHistory(record)
                let final = try await self.edit(transcript, request: request).text
                try Task.checkCancellation()
                guard self.retryingID == id else { return }
                var completed = record
                completed.text = final; completed.status = .completed; completed.request = nil; completed.transcript = nil
                completed.failures = nil
                try self.settings.updateHistory(completed)
                self.retryAfter[id] = nil
                // Another Mac's text on its way here keeps the capsule; the text is on the clipboard either way.
                if self.keepOnClipboard(final), !self.busy, self.phase != .receiving {
                    let session = UUID()
                    self.sessionID = session
                    self.result = final; self.latency = nil
                    self.phase = .done; self.capsuleResult = .onClipboard
                    self.message = tr("Transcription finished · Saved to the clipboard (⌘V) and History")
                    self.presentOverlay?()
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard let self, self.sessionID == session, self.phase == .done else { return }
                        self.dismissOverlay?()
                    }
                }
            } catch {
                guard self.retryingID == id, !(error is CancellationError) else { return }
                if self.settings.history.first(where: { $0.id == id })?.state != .completed {
                    let passing = (error as? VoiceError)?.retryable == true || error is URLError
                    let failures = (record.failures ?? 0) + 1
                    let wait = passing ? RetryPace.wait(afterFailures: failures) : nil
                    record.status = wait != nil ? .pending : .failed
                    record.problem = passing && wait == nil ? tr("Automatic retries did not succeed within 24 hours. The original recording is kept and can be retried by hand.")
                        : error is VoiceError ? error.localizedDescription : tr("Transcription did not finish. The original recording is kept; check the network or the file.")
                    record.failures = wait == nil ? nil : failures
                    do { try self.settings.updateHistory(record) }
                    catch { self.settings.historyMessage = tr("Could not save the retry result. Check the disk space.") }
                    self.retryAfter[id] = wait.map { Date().addingTimeInterval($0) } ?? .distantFuture
                }
            }
        }
    }

    private func stopRetry() {
        guard let id = retryingID else { return }
        retryingID = nil; retryJob?.cancel(); retryJob = nil; retryClient?.cancel(); retryClient = nil
        if var record = settings.history.first(where: { $0.id == id }) {
            record.status = .pending
            do { try settings.updateHistory(record) }
            catch { settings.historyMessage = tr("Could not save the status when pausing the retry. The original recording is kept.") }
        }
    }

    func copyResult() {
        guard !result.isEmpty else { return }
        // What out copies itself stays out of the clipboard history; the text is in History already.
        PasteboardLease.general.keep(result, unrecorded: true)
        capsuleResult = .inserted
        message = tr("Text copied")
    }

    private func startClock(id: UUID) {
        clock?.cancel()
        let started = Date()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                guard let self, self.sessionID == id, self.phase == .recording else { return }
                let seconds = Int(Date().timeIntervalSince(started))
                if seconds != self.elapsed {
                    self.elapsed = seconds
                    self.entry?.seconds = self.audioFile?.seconds ?? Double(seconds)
                    // Persist elapsed duration every 5 seconds instead of every second to avoid disk churn.
                    if seconds % 5 == 0 {
                        do { try self.saveActive() } catch { self.localFailure(); return }
                    }
                }
                if self.elapsed >= 900 { self.finish(); return }
            }
        }
    }
}
