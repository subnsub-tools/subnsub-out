import AppKit
import AVFoundation
import Carbon
import Combine
import Network
import QingyanCore
import SystemConfiguration

enum DictationPhase: Equatable {
    case idle, recording, processing, done, error
}

@MainActor
final class DictationController: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var partial = ""
    @Published var result = ""
    @Published var message = ""
    @Published var connected = false
    @Published var networkAvailable = true
    @Published var retryingID: UUID?
    @Published var latency: Double?
    @Published var hotkeyInstalled = false
    @Published var shortcutStatus = tr("Waiting for Accessibility permission.")
    @Published var remoteListening = false
    @Published var remoteStatus = ""
    @Published private(set) var tailnetAddress: String?
    /// Per paired Mac: the last test result, and which tests are running.
    @Published var peerStatus: [String: String] = [:]
    @Published var peerTesting: Set<String> = []
    /// Whether each paired Mac answered the last time it was asked; absent means not asked yet.
    @Published var peerReachable: [String: Bool] = [:]
    /// Other Macs asking to be trusted, waiting for an answer.
    @Published var pairRequests: [RemoteReceiver.PairRequest] = []
    /// Macs running input that were found on the tailnet and are not trusted yet.
    @Published var found: [RemoteSender.Found] = []
    @Published var searching = false
    @Published var searchNote = ""
    /// For each address this Mac asked to pair with: what is happening.
    @Published var pairing: [String: String] = [:]
    enum PairingStep { case connecting, confirming }
    /// The addresses in `pairing` whose pairing is still under way, and at which step.
    @Published var pairingStep: [String: PairingStep] = [:]
    /// Why working with other Macs is not possible, when it is not.
    @Published var linkProblem = ""
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
    private var legacyTried = Date.distantPast
    private var peersTested = Date.distantPast
    let settings: SettingsStore
    let shortcut = GlobalShortcut()
    /// The shared clipboard shelf at the bottom of the panel.
    let shelf: ShelfModel
    let updater: Updater
    private let recorder = AudioRecorder()
    private var client: (any Transcriber)?
    private var job: Task<Void, Never>?
    private var captureJob: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var audioFile: RecordedAudio?
    private var entry: HistoryEntry?
    private var connectionError: Error?
    private let network = NWPathMonitor()
    private var retryJob: Task<Void, Never>?
    private var retryClient: (any Transcriber)?
    private var retryAfter: [UUID: Date] = [:]
    private var sessionID = UUID()
    private var stopTime: Date?
    private var hadSignal = false
    private let receiver = RemoteReceiver()
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
    private var microphoneSubscriptions: Set<AnyCancellable> = []
    /// Whether the bound microphone was connected at the last look; nil when nothing is bound.
    private var boundWasPresent: Bool?
    /// What the status capsule names while processing, and once done. Each is set together with
    /// `message`, so the capsule never has to read the message's words.
    enum CapsuleStep { case recognizing, polishing, editing, sending, typing }
    /// `notWritten`: the text did not go into a text field on the Mac it was meant for; a title naming
    /// that Mac and a line saying why and where the text is.
    enum CapsuleResult { case inserted, onClipboard, savedToHistory, typed, notWritten(String, String) }
    var capsuleStep = CapsuleStep.recognizing
    var capsuleResult = CapsuleResult.inserted
    var presentOverlay: (() -> Void)?
    var dismissOverlay: (() -> Void)?
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

    /// Compact summary tailored for the miniature floating status capsule.
    var capsuleSummary: String {
        switch phase {
        case .idle:
            return ""
        case .recording:
            let clockText = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            return connected ? clockText : tr("%@ · Offline", clockText)
        case .processing:
            switch capsuleStep {
            case .recognizing: return tr("Recognizing")
            case .polishing: return tr("Polishing")
            case .editing: return tr("Editing")
            case .sending: return tr("Sending")
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
        }
    }

    init(settings: SettingsStore) {
        self.settings = settings
        microphones = Microphones(preview: settings.preview)
        shelf = ShelfModel(preview: settings.preview)
        updater = Updater(settings: settings)
        receiver.shelf = shelf.sync
        updater.isBusy = { [weak self] in self.map { $0.busy || $0.retryingID != nil } ?? false }
        shortcut.onToggle = { [weak self] in Task { @MainActor in self?.toggle() } }
        shortcut.onCancel = { [weak self] in
            guard let self, self.busy else { return false }
            Task { @MainActor in self.cancel() }
            return true
        }
        shortcut.onKnock = { [weak self] nonce in self?.receiver.knocked(nonce) }
        shortcut.onTypeClipboard = { [weak self] in Task { @MainActor in self?.typeClipboard(from: .shortcut) } }
        // Where the panel's Type the Clipboard types into: the last app in front other than this one.
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { lastOtherApp = front }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated {
                self?.lastOtherApp = app
                // Another app in front: the keys pressed from now on are meant for it.
                if self?.recordingShortcut == true { self?.endShortcutRecording() }
            }
        }
        receiver.onChange = { [weak self] in
            guard let self, self.settings.preferences.linkEnabled else { return }
            if self.remoteListening != self.receiver.listening { self.remoteListening = self.receiver.listening }
            if self.remoteStatus != self.receiver.status { self.remoteStatus = self.receiver.status }
        }
        receiver.name = deviceName
        receiver.trusted = { [weak self] key in self?.settings.preferences.devices.first { $0.key == key } }
        // Told to a trusted Mac that asks: the Macs this one sees through Tailscale, and the ones it
        // is paired with, so that a Mac without Tailscale finds the others through this one.
        receiver.peers = { [weak self] in await self?.sharedPeers() ?? [] }
        receiver.onPairRequest = { [weak self] request in
            self?.pairRequests.append(request)
            self?.settings.section = .remote
            self?.openSettings?()
        }
        receiver.onPairEnded = { [weak self] id in self?.pairRequests.removeAll { $0.id == id } }
        receiver.onPaired = { [weak self] device, legacy in self?.trust(device, viaLegacyCode: legacy) }
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
                self.warnMicrophone(tr("The locked microphone “%@” was disconnected. put does not switch to another microphone and records nothing until it is reconnected. Another one can be chosen under Microphone in the panel.", name))
            }
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
            refreshTailnetAddress()
            network.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    let satisfied = path.status == .satisfied
                    let restored = !self.networkAvailable && satisfied
                    if self.networkAvailable != satisfied { self.networkAvailable = satisfied }
                    self.refreshTailnetAddress()
                    if restored { self.retryAfter.removeAll() }
                    self.retryQueued()
                }
            }
            network.start(queue: DispatchQueue(label: "local.hopo.qingyan.network"))
        }
    }

    func refreshTailnetAddress() {
        guard !settings.preview else { return }
        Task.detached(priority: .utility) {
            let address = RemoteWire.localTailnetAddress()
            await MainActor.run { [weak self] in
                if self?.tailnetAddress != address { self?.tailnetAddress = address }
            }
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
        shelf.sync?.listening = settings.preferences.remotePort
        shelf.sync?.maintain(devices: settings.preferences.linkEnabled && identity != nil ? settings.preferences.devices : [])
        adoptLegacyPairings()
        retryQueued()
    }

    /// Keeps the listener in step with the settings; called on every refresh.
    private func syncRemote() {
        guard settings.preferences.linkEnabled, identity != nil else {
            receiver.stop()
            if remoteListening { remoteListening = false }
            return
        }
        receiver.legacyCode = settings.preferences.remoteRole == "receive" ? settings.preferences.remoteCode : ""
        receiver.tailscaleOnly = settings.preferences.tailscaleOnly
        receiver.start(port: settings.preferences.remotePort,
            probe: { AXIsProcessTrusted()
                ? (true, tr("Ready to receive text."))
                : (false, tr("Connected, but the other Mac has not granted Accessibility permission, so it cannot paste.")) },
            context: { TextTarget.field() },
            deliver: { [weak self] request in
                guard let self else { throw VoiceError(tr("put is quitting on the other Mac.")) }
                return try self.receive(request)
            })
    }

    // MARK: Trust

    private func trust(_ device: TrustedDevice, viaLegacyCode: Bool = false) {
        if let index = settings.preferences.devices.firstIndex(where: { $0.key == device.key }) {
            if !device.name.isEmpty { settings.preferences.devices[index].name = device.name }
            if !device.host.isEmpty { settings.preferences.devices[index].host = device.host; settings.preferences.devices[index].port = device.port }
        } else {
            settings.preferences.devices.append(device)
        }
        found.removeAll { $0.key == device.key }
        if viaLegacyCode && settings.preferences.remoteRole == "receive" { settings.preferences.remoteCode = ""; settings.preferences.remoteRole = "off" }
        peersTested = .distantPast
        refresh()
        testPeers()
    }

    func removeDevice(_ key: String) {
        settings.preferences.devices.removeAll { $0.key == key }
        peerStatus[key] = nil; peerReachable[key] = nil
        refresh()
    }

    func answer(_ request: RemoteReceiver.PairRequest, agree: Bool) {
        pairRequests.removeAll { $0.id == request.id }
        request.answer(agree)
    }

    func pair(host: String, port: Int, legacyCode: String? = nil, key: String? = nil) {
        guard let identity, pairingStep[host] != .confirming else { return }
        pairing[host] = tr("Connecting…"); pairingStep[host] = .connecting
        let name = deviceName, listening = settings.preferences.remotePort
        Task { [weak self] in
            do {
                let device = try await RemoteSender.pair(host: host, port: port, identity: identity, name: name, listening: listening,
                                                         legacyCode: legacyCode, expecting: key) { code in
                    Task { @MainActor in
                        guard legacyCode == nil else { return }
                        self?.pairing[host] = tr("Waiting for the other Mac to confirm · code %@", code)
                        self?.pairingStep[host] = .confirming
                    }
                }
                guard let self else { return }
                self.pairing[host] = nil; self.pairingStep[host] = nil
                self.trust(device)
                if legacyCode != nil {
                    self.settings.preferences.remotePeers.removeAll { $0.host == host }
                    if self.settings.preferences.remotePeers.isEmpty { self.settings.preferences.remoteRole = "off"; self.settings.preferences.remoteHost = "" }
                }
            } catch {
                guard let self else { return }
                self.pairing[host] = legacyCode == nil ? error.localizedDescription : nil
                self.pairingStep[host] = nil
            }
        }
    }

    private func adoptLegacyPairings() {
        guard settings.preferences.linkEnabled, identity != nil, !settings.preferences.remotePeers.isEmpty,
              Date().timeIntervalSince(legacyTried) > 20 else { return }
        legacyTried = Date()
        for peer in settings.preferences.remotePeers where !peer.host.isEmpty && !peer.code.isEmpty {
            pair(host: peer.host, port: peer.port, legacyCode: peer.code)
        }
    }

    /// The Macs running put that this one sees through Tailscale, told to a trusted Mac that asks: one
    /// lookup at a time, kept for 30 seconds, and only Macs that answered as put at a Tailscale address.
    private var peerDirectory: (at: Date, list: [[String: Any]])?
    private var peerLookup: Task<[[String: Any]], Never>?

    private func sharedPeers() async -> [[String: Any]] {
        if let cached = peerDirectory, Date().timeIntervalSince(cached.at) < 30 { return cached.list }
        if let peerLookup { return await peerLookup.value }
        guard let identity else { return [] }
        let name = deviceName, port = settings.preferences.remotePort
        let lookup = Task { () -> [[String: Any]] in
            let nodes = await TailscalePeers.online()
            let answers = await Self.identifyAll(nodes.map { RemoteSender.Peer(name: $0.name, host: $0.address, port: port) },
                                                 identity: identity, name: name, listening: port)
            return answers.filter { RemoteWire.isTailnetAddress($0.host) && $0.key != identity.publicKey }
                .map { ["name": $0.name, "host": $0.host, "port": $0.port] }
        }
        peerLookup = lookup
        let list = await lookup.value
        peerLookup = nil
        peerDirectory = (Date(), list)
        return list
    }

    /// Asks each place who is there, eight at a time.
    nonisolated static func identifyAll(_ places: [RemoteSender.Peer], identity: DeviceIdentity, name: String, listening: Int) async -> [RemoteSender.Found] {
        await withTaskGroup(of: RemoteSender.Found?.self, returning: [RemoteSender.Found].self) { group in
            var answers: [RemoteSender.Found] = []
            var next = places.makeIterator()
            func start(_ place: RemoteSender.Peer) {
                group.addTask { try? await RemoteSender.identify(host: place.host, port: place.port, identity: identity, name: name, listening: listening) }
            }
            for _ in 0..<8 { guard let place = next.next() else { break }; start(place) }
            while let answer = await group.next() {
                if let answer { answers.append(answer) }
                if let place = next.next() { start(place) }
            }
            return answers
        }
    }

    func discover() {
        guard let identity, !searching, !settings.preview else { return }
        searching = true; searchNote = ""
        refreshTailnetAddress()
        let name = deviceName, port = settings.preferences.remotePort
        let paired = settings.preferences.devices
        Task { [weak self] in
            // This Mac's Tailscale first: its Macs are asked as soon as the list is there.
            let local = await TailscalePeers.online().map { RemoteSender.Peer(name: $0.name, host: $0.address, port: port) }
            async let localAnswers = Self.identifyAll(local, identity: identity, name: name, listening: port)
            // Then every paired Mac's word on the Macs it sees, for a Mac with no Tailscale of its own
            // (behind a router that has it). A paired Mac points this one at numeric Tailscale
            // addresses on ports from 1024 and nowhere else, 64 places at most in all.
            let told = await withTaskGroup(of: [RemoteSender.Peer].self, returning: [RemoteSender.Peer].self) { group in
                for device in paired {
                    group.addTask { (try? await RemoteSender.peers(of: device, identity: identity, name: name, listening: port)) ?? [] }
                }
                var all: [RemoteSender.Peer] = []
                for await list in group { all += list }
                return all
            }
            var places = Set(local.map { "\($0.host):\($0.port)" })
            let referred = Array(told.filter {
                RemoteWire.isTailnetAddress($0.host) && $0.port >= 1024 && places.insert("\($0.host):\($0.port)").inserted
            }.prefix(64))
            let answers = await localAnswers + Self.identifyAll(referred, identity: identity, name: name, listening: port)
            let candidates = local.count + referred.count
            // One row per Mac: by key, a Tailscale address found here before one a paired Mac told of.
            let localHosts = Set(local.map(\.host))
            var byKey: [String: RemoteSender.Found] = [:]
            for answer in answers where answer.key != identity.publicKey {
                if let have = byKey[answer.key], localHosts.contains(have.host) || !localHosts.contains(answer.host) { continue }
                byKey[answer.key] = answer
            }
            guard let self else { return }
            let known = Dictionary(self.settings.preferences.devices.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            // A paired Mac's saved address changes only when the saved one no longer answers, and the Mac
            // at the new one proves its key over the encrypted channel (a who-are-you alone proves nothing).
            for (key, answer) in byKey {
                guard let saved = known[key], saved.host != answer.host || saved.port != answer.port else { continue }
                if (try? await RemoteSender.ping(saved, identity: identity, name: name, listening: port)) != nil { continue }
                var moved = saved
                moved.host = answer.host; moved.port = answer.port
                if (try? await RemoteSender.ping(moved, identity: identity, name: name, listening: port)) != nil {
                    self.trust(TrustedDevice(key: key, name: answer.name, host: answer.host, port: answer.port))
                }
            }
            self.found = byKey.values.filter { known[$0.key] == nil }.sorted { $0.name < $1.name }
            self.searching = false
            if candidates == 0 {
                self.searchNote = !TailscalePeers.installed && paired.isEmpty
                    ? tr("This Mac has no Tailscale and no paired Mac to ask. Enter the address of a Mac running put below; once the two are paired, the others are found through it.")
                    : tr("Tailscale reported no devices online. Enter an address below to pair by hand.")
            } else if !self.found.isEmpty {
                self.searchNote = ""
            } else if candidates == 1 {
                self.searchNote = tr("Scanned 1 online Mac. No unpaired Mac running put was found.")
            } else {
                self.searchNote = tr("Scanned %ld online Macs. No unpaired Mac running put was found.", candidates)
            }
        }
    }

    private func receive(_ request: RemoteReceiver.Request) throws -> DeliveryOutcome {
        if !request.text.isEmpty && request.field == nil {
            do { try settings.addHistory(HistoryEntry(text: request.text, mode: request.mode, seconds: request.seconds)) }
            catch { settings.historyMessage = tr("Text from another Mac was received but could not be saved to History on this Mac. Check the disk space.") }
        }
        let id = UUID()
        do {
            let outcome: WriteResult
            if let field = request.field {
                outcome = try TextTarget.rewriteField(from: field, to: request.text)
                pasted = nil
            } else {
                outcome = try request.replace.map { try TextTarget.replace($0, with: request.text, untouched: cursorUntouched(after: $0)) }
                    ?? TextTarget.insertAtFocus(request.text)
                if outcome.miss == nil { notePasted(request.text) } else { pasted = nil }
            }
            guard !busy else { return DeliveryOutcome(message: outcome.summary, miss: outcome.miss) }
            sessionID = id
            result = request.field == nil ? request.text : ""; latency = nil
            phase = .done
            if let miss = outcome.miss { capsuleResult = .notWritten(Self.missTitle(miss, peer: nil), Self.missLine(miss, clipboard: .here)) }
            else { capsuleResult = outcome.onClipboard ? .onClipboard : .inserted }
            message = tr("From another Mac · %@ · Saved to History", outcome.summary)
            presentOverlay?()
            let linger: UInt64 = outcome.miss == nil ? 2_200_000_000 : 5_000_000_000
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: linger)
                guard let self, self.sessionID == id, self.phase == .done else { return }
                self.dismissOverlay?()
            }
            return DeliveryOutcome(message: outcome.summary, miss: outcome.miss)
        } catch {
            let kept = keepOnClipboard(request.text)
            if !busy {
                sessionID = id
                result = request.text; latency = nil
                phase = .error
                message = kept ? tr("Text from another Mac could not be written: %@ · Saved to the clipboard (⌘V)", error.localizedDescription)
                    : tr("Text from another Mac could not be written: %@", error.localizedDescription)
                presentOverlay?()
            }
            let miss = (error as? TargetProblem)?.miss ?? .other
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

    func linkChanged() {
        remoteStatus = ""; peerStatus = [:]; peerReachable = [:]; peersTested = .distantPast
        refresh()
        testPeers()
    }

    func testRemote(_ key: String) {
        guard let identity, !peerTesting.contains(key), let device = settings.preferences.devices.first(where: { $0.key == key }) else { return }
        guard device.reachable else { peerStatus[key] = tr("This device’s address is not known yet. Wait for it to connect, or click “Scan”."); return }
        peerTesting.insert(key); peerStatus[key] = tr("Checking the connection…")
        let name = deviceName, listening = settings.preferences.remotePort
        Task { [weak self] in
            var outcome: String, called = "", ok = false
            do {
                let reply = try await RemoteSender.ping(device, identity: identity, name: name, listening: listening)
                outcome = reply.message; called = reply.name; ok = reply.ok
            } catch { outcome = error.localizedDescription }
            guard let self else { return }
            self.peerTesting.remove(key); self.peerStatus[key] = outcome; self.peerReachable[key] = ok
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
                  settings.preferences.devices[index].name != name else { continue }
            settings.preferences.devices[index].name = name
        }
    }

    private func scoutRemote() {
        endRemote()
        let devices = settings.preferences.devices.filter(\.reachable)
        guard let identity, settings.sendsRemotely, !settings.preview, !devices.isEmpty, AXIsProcessTrusted() else { return }
        let session = RemoteSession(devices: devices, identity: identity, name: deviceName, listening: settings.preferences.remotePort)
        remoteSession = session
        remoteScout = Task { @MainActor [weak self] in
            await session.arm(timeout: 1.5)
            self?.remember(session.names)
            self?.peerReachable.merge(session.reachable) { _, new in new }
            let mark = FocusMark.current()
            let found = await session.locate { await KnockKeys.post(nonce: session.nonce) }
            return (mark, found)
        }
    }

    private func endRemote() {
        remoteSession?.close(); remoteSession = nil; remoteScout = nil
    }

    private func recentDictation(on peer: String?) -> String? {
        guard let last = lastDelivered, last.peer == peer, Date().timeIntervalSince(last.at) < 600,
              last.mark?.same(as: FocusMark.current()) == true else { return nil }
        return last.text
    }

    private func destination() async -> Int? {
        guard let session = remoteSession, let scout = remoteScout else { return nil }
        let (mark, early) = await scout.value
        if mark?.same(as: FocusMark.current()) ?? false { return early }
        return await session.locate { await KnockKeys.post(nonce: session.nonce) }
    }

    private enum Revision {
        case edit(text: String, plan: Plan)
        case content
        case blind
    }

    private func revise(_ transcript: String, request: SavedDictation, target: Int?) async -> Revision {
        var context: (before: String, after: String)?
        var plan = Plan.insert
        var peer: String?
        if let target, let session = remoteSession {
            peer = session.key(target)
            if let field = await session.context(of: target) { context = field; plan = .field(old: field.before + field.after) }
        } else if remoteSession == nil || !RemoteWire.showsAnotherScreen(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            if let field = TextTarget.field() { context = field; plan = .field(old: field.before + field.after) }
        } else { return .content }
        let previous = recentDictation(on: peer)
        if context == nil, let previous { context = (previous, ""); plan = .previous(previous) }
        guard let context else { return .blind }
        guard !(context.before + context.after).isEmpty else { return .content }
        guard let service = try? settings.service(request.textPlatform),
              let output = try? await TextClient(service: service).revise(transcript: transcript, before: context.before,
                  after: context.after, previous: previous ?? "", model: request.textModel) else { return .content }
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

    private func deliver(_ text: String, plan: Plan, resolved: Int??, mode: WritingMode, seconds: Double) async throws -> WriteResult {
        let session = remoteSession
        defer { session?.close(); if remoteSession === session { remoteSession = nil; remoteScout = nil } }
        let target: Int?
        if let resolved { target = resolved } else { target = await destination() }
        if let session, let target {
            let name = session.name(target), id = session.key(target)
            capsuleStep = .sending
            message = tr("Sending to %@…", name)
            var replace: String?, field: String?
            switch plan {
            case .insert: break
            case .field(let old): field = old
            case .previous(let previous): replace = previous
            }
            let reply: SendReply
            do { reply = try await session.send(to: target, text: text, mode: mode, seconds: seconds, replace: replace, field: field) }
            catch let refusal as RemoteRefusal { throw refusal }
            catch is CancellationError { throw CancellationError() }
            catch let error as RemoteUnreachable { throw RemoteRefusal(peer: name, miss: .unreachable, description: error.description) }
            catch let error as DeliveryUnconfirmed { throw RemoteRefusal(peer: name, miss: .unconfirmed, description: error.localizedDescription) }
            catch { throw RemoteRefusal(peer: name, miss: .other, description: error.localizedDescription) }
            // A text that may not be in a field is nothing to take back by backspace later.
            lastDelivered = text.isEmpty || field != nil || reply.miss != nil ? nil
                : Delivered(text: text, peer: id, mark: FocusMark.current(), at: Date())
            return WriteResult(summary: tr("%@: %@", name, reply.message), onClipboard: reply.onClipboard, miss: reply.miss, peer: name)
        }
        if let session, RemoteWire.showsAnotherScreen(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            if session.armedCount == 0 {
                let problems = session.problems.joined(separator: " ")
                // A Mac that said no, and why, before one that could not be reached.
                if let refusal = session.refusals.first {
                    throw RemoteRefusal(peer: refusal.peer, miss: refusal.miss,
                                        description: tr("A remote desktop window is in front, but none of the paired Macs can be reached. %@", problems))
                }
                throw RemoteRefusal(peer: nil, miss: .unreachable,
                                    description: problems.isEmpty ? tr("A remote desktop window is in front, but none of the paired Macs can be reached.")
                                        : tr("A remote desktop window is in front, but none of the paired Macs can be reached. %@", problems))
            }
            throw RemoteRefusal(peer: nil, miss: .noAnswer,
                                description: tr("A remote desktop window is in front, but no paired Mac answered. Make sure put is running on the other Mac and allows writing."))
        }
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
            outcome = try TextTarget.insertAtFocus(text)
            if outcome.miss == nil {
                notePasted(text)
                lastDelivered = Delivered(text: text, peer: nil, mark: FocusMark.current(), at: Date())
            } else { pasted = nil; lastDelivered = nil }
        }
        return outcome
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
        case .noAnswer: why = tr("No paired Mac answered")
        case .unconfirmed: why = tr("No answer after sending")
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
        begin()
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

    private func begin() {
        endShortcutRecording()
        settings.refreshPermissions()
        guard settings.microphoneAllowed else {
            message = tr("Allow microphone access first.")
            settings.reveal(.keyboard)
            openSettings?()
            return
        }
        let prefs = settings.preferences
        let liveAvailable = Microphone.available()
        let liveDefault = Microphone.systemDefault()
        let micCheck = MicrophoneBinding.resolve(
            boundUID: prefs.microphone,
            boundName: prefs.microphoneName,
            available: liveAvailable.map { .init(uid: $0.uid, name: $0.name) },
            systemDefault: liveDefault.map { .init(uid: $0.uid, name: $0.name) }
        )
        if let problem = micCheck.missingMessage {
            microphones.refresh()
            warnMicrophone(problem)
            return
        }
        if case .boundAvailable(let matched) = micCheck, settings.preferences.microphoneName != matched.name {
            settings.preferences.microphoneName = matched.name
        }
        stopRetry()
        endRemote()
        let id = UUID()
        sessionID = id
        entry = nil; audioFile = nil; connectionError = nil
        let selection = prefs.mode == .rewrite && settings.accessibilityAllowed ? (try? TextTarget.capture().selectedText) ?? "" : ""
        let mode: WritingMode = prefs.mode == .rewrite && (selection.isEmpty || selection.count > 30000) ? .dictate : prefs.mode
        let request = SavedDictation(mode: mode, polish: prefs.polish, targetLanguage: prefs.targetLanguage,
            speechModel: prefs.speechModel, textModel: prefs.textModel, dictionary: prefs.dictionary,
            selection: mode == .rewrite ? selection : "",
            speechPlatform: prefs.speechPlatform, textPlatform: prefs.textPlatform)
        do {
            result = ""; partial = ""; meter.reset(); latency = nil; connected = false; hadSignal = false; stopTime = nil
            let (record, savedAudio) = try settings.beginHistory(request)
            entry = record; audioFile = savedAudio
            let audio = try recorder.start(microphone: prefs.microphone, microphoneName: prefs.microphoneName) { [weak self] value in
                guard let self, self.sessionID == id, self.phase == .recording else { return }
                self.meter.setLevel(min(1, value * 12))
                if value > 0.002 { self.hadSignal = true }
            }
            phase = .recording
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
                    guard self.networkAvailable else { throw VoiceError(tr("The network is unavailable"), retryable: true) }
                    let client = try await self.transcriber(for: request)
                    self.client = client
                    let transcript = try await client.run(audio: savedAudio.stream(), model: request.speechModel, dictionary: request.dictionary,
                        onReady: { [weak self] in
                            guard let self, self.sessionID == id else { return }
                            self.connected = true
                            if self.phase == .recording { self.message = tr("Listening · Tap again to stop") }
                        }, onPartial: { [weak self] text in
                            guard let self, self.sessionID == id else { return }
                            if self.partial != text { self.partial = text }
                            self.entry?.text = text
                        })
                    try Task.checkCancellation()
                    guard self.sessionID == id else { return }
                    guard !transcript.isEmpty else { throw VoiceError(tr("No speech was recognized. Check the microphone input.")) }
                    self.result = transcript
                    self.entry?.text = transcript; self.entry?.transcript = transcript
                    try self.saveActive()
                    self.capsuleStep = .polishing
                    self.message = tr("Polishing the text…")
                    let screened = try await self.edit(transcript, request: request,
                                                       screening: request.mode == .dictate && request.polish)
                    try Task.checkCancellation()
                    guard self.sessionID == id else { return }
                    var final = screened.text
                    var plan = Plan.insert
                    var resolved: Int?? = nil
                    var notes: [String] = screened.asSaid ? [tr("Polish changed the meaning; the original transcript was kept")] : []
                    if screened.maybe {
                        self.capsuleStep = .editing
                        self.message = tr("Checking the edit to the text field…")
                        let target = await self.destination()
                        resolved = .some(target)
                        switch await self.revise(transcript, request: request, target: target) {
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
                    // Meant for another Mac and not typed there: said on the capsule at once, with why.
                    var notTyped: (title: String, detail: String)?
                    do {
                        let written = try await self.deliver(final, plan: plan, resolved: resolved,
                                                             mode: request.mode, seconds: self.entry?.seconds ?? 0)
                        var parts = [written.summary] + notes
                        parts.append(tr("Saved to History"))
                        outcome = parts.joined(separator: " · ")
                        onClipboard = written.onClipboard
                        if let miss = written.miss, let peer = written.peer {
                            notTyped = (Self.missTitle(miss, peer: peer), Self.missLine(miss, clipboard: .there))
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
                    self.capsuleResult = notTyped.map { .notWritten($0.title, $0.detail) } ?? (onClipboard ? .onClipboard : .inserted)
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
            try? audioFile?.finish()
            if let entry { settings.removeHistory(id: entry.id) }
            entry = nil; audioFile = nil
            phase = .error; message = error.localizedDescription; presentOverlay?()
        }
    }

    private func transcriber(for request: SavedDictation) async throws -> any Transcriber {
        let service = try await settings.serviceAsync(request.speechPlatform)
        guard !request.speechModel.isEmpty else { throw VoiceError(tr("The recognition model name is empty. Enter it in Settings.")) }
        return service.platform.streams(model: request.speechModel) ? RealtimeTranscriber(key: service.key) : UploadTranscriber(service: service)
    }

    private func edit(_ transcript: String, request: SavedDictation,
                      screening: Bool = false) async throws -> (text: String, maybe: Bool, asSaid: Bool) {
        if !request.polish && request.mode == .dictate { return (transcript, false, false) }
        let service = try await settings.serviceAsync(request.textPlatform)
        guard !request.textModel.isEmpty else { throw VoiceError(tr("The text polishing model name is empty. Enter it in Settings.")) }
        let output = try await TextClient(service: service).edit(transcript: transcript, mode: request.mode,
            targetLanguage: request.targetLanguage, selection: request.selection, model: request.textModel, screening: screening)
        guard request.mode == .dictate else { return (output, false, false) }
        let answer = screening ? OpenAIWire.splitMarker(output) : (marker: nil, text: output)
        guard !answer.text.isEmpty else { throw VoiceError(tr("The model returned no usable text. The original transcript was kept.")) }
        let text = answer.text
        let faithful = await Task.detached(priority: .userInitiated) { OpenAIWire.keepsWording(of: transcript, in: text) }.value
        return (faithful ? text : transcript, answer.marker == "@@MAYBE", !faithful)
    }

    private func saveActive() throws {
        guard let entry else { return }
        try settings.updateHistory(entry)
    }

    private func keepForRetry(_ error: Error) {
        endRemote()
        guard settings.history.first(where: { $0.id == entry?.id })?.state != .completed else {
            phase = .error; message = tr("The text is saved, but the original audio could not be removed. Delete it in History."); return
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
    }

    private func localFailure(_ error: Error? = nil) {
        endRemote()
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
        endRemote()
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
    private var activationObserver: NSObjectProtocol?

    /// Types the clipboard's text key by key into the field in front: for fields and screens that
    /// refuse a paste. Line breaks are typed as Return; a password field is typed into too (both the
    /// user's choice for this action alone: dictation still never does either). Nothing typed is
    /// kept: not in History, not in the result.
    func typeClipboard(from origin: ClipboardTyper.Origin) {
        guard !busy else { return }
        settings.refreshPermissions()
        guard settings.accessibilityAllowed else {
            showTypingProblem(tr("Accessibility permission is not granted. Allow put in System Settings.")); return
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
        let id = UUID()
        sessionID = id
        result = ""; partial = ""; latency = nil; message = ""
        typedCount = 0; typingTotal = 0
        phase = .processing; capsuleStep = .typing
        presentOverlay?()
        typingJob = Task { @MainActor [weak self] in
            do {
                let count = try await ClipboardTyper.type(text, into: target, from: origin,
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
        stopRetry()
        endRemote()
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

    func retry(_ id: UUID) {
        guard !busy, retryingID == nil,
              var record = settings.history.first(where: { $0.id == id }), record.canRetry else { return }
        record.request?.speechModel = settings.preferences.speechModel
        record.request?.textModel = settings.preferences.textModel
        record.request?.speechPlatform = settings.preferences.speechPlatform
        record.request?.textPlatform = settings.preferences.textPlatform
        record.status = .pending; record.failures = nil
        do { try settings.updateHistory(record) }
        catch { settings.historyMessage = tr("Could not update the retry status. Check the disk space on this Mac."); return }
        retryAfter[id] = nil
        retryQueued(preferred: id)
    }

    private func retryQueued(preferred: UUID? = nil) {
        guard !settings.preview, !busy, retryingID == nil, networkAvailable, settings.hasKey,
              var record = settings.history.reversed().first(where: {
                  $0.state == .pending && (preferred == nil || preferred == $0.id) &&
                  (retryAfter[$0.id] ?? .distantPast) <= Date()
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
                    let client = try await self.transcriber(for: request)
                    self.retryClient = client
                    transcript = try await client.run(audio: audio.stream(), model: request.speechModel, dictionary: request.dictionary,
                        onReady: {}, onPartial: { _ in })
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
                if self.keepOnClipboard(final), !self.busy {
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
                } else { self.settings.historyMessage = tr("The text is saved, but the original audio could not be removed. Delete this record to remove it.") }
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
        PasteboardLease.general.keep(result)
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
