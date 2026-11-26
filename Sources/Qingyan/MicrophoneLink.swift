import AVFoundation
import CoreAudio
import Foundation
import os
import QingyanCore

/// This Mac's microphone lent to another Mac, and another Mac's microphone lent to this one (user
/// 2026-11-27: this Mac's microphone takes over the remote Mac's; any microphone clicked anywhere there
/// turns this one on, and any app there can use it). Lent, the other Mac makes out Mic its input; when
/// any app there starts recording it says so, and this Mac's microphone turns on and is heard there
/// until the app stops. The out Mic driver, inside the app, is installed once on the Mac that takes
/// the microphone, with that Mac's password; asked for there when it is first needed.
@MainActor
final class MicrophoneLink: ObservableObject {
    /// What lending needs from the rest of out, read at every attempt.
    struct Context {
        let identity: DeviceIdentity?
        let name: String
        let listening: Int
        /// The microphone dictation uses: its UID, or empty for the system's.
        let microphone: String
        let device: (String) -> TrustedDevice?
    }
    var context: (() -> Context?)?

    /// What the link waits on, said beside the Mac: being made, or out Mic being installed there.
    struct Note: Equatable {
        let text: String
        let installing: Bool
    }

    /// The Mac this Mac's microphone is lent to, by key; kept across launches until taken back.
    @Published private(set) var lentTo: String?
    /// The link to it is up; and an app there records, so this Mac's microphone is on.
    @Published private(set) var linked = false
    @Published private(set) var live = false
    @Published private(set) var notes: [String: Note] = [:]
    /// What went wrong, by the Mac's key: lending stopped, or this Mac's microphone did not open.
    @Published private(set) var problems: [String: String] = [:]
    /// The Mac whose microphone is lent here, by key; and whether an app here records from it now.
    @Published private(set) var receivingFrom: String?
    @Published private(set) var heardHere = false
    @Published private(set) var driver = MicrophoneLink.driverState()
    @Published private(set) var installing = false

    private var out: MicrophoneOut?
    private var connecting: Task<Void, Never>?
    private var leaseCheck: Task<Void, Never>?
    private var linkedAt = Date.distantPast
    private var capture: AVAudioEngine?
    private var drain: DispatchSourceTimer?
    private var inbound: MicrophoneIn?
    private var playback: AVAudioEngine?
    private var jitter: MicJitter?
    private var useListener: AudioObjectPropertyListenerBlock?
    private var useDevice = AudioObjectID(0)
    private var toldUse: Bool?
    private var renewUse: Task<Void, Never>?
    private var giveBackLater: Task<Void, Never>?
    /// The lending Mac whose microphone took this Mac's input, by key: its link coming back does not
    /// take the input again (it may have been changed by hand meanwhile).
    private var inputTakenFor: String?
    /// When an install asked for by another Mac's lending last did not happen: for a minute, no other
    /// Mac's lending asks for the password here again.
    private var installFailedAt: Date?

    private static let lentKey = "microphoneLentTo"
    private static let previousInputKey = "microphonePreviousInput"

    init() {
        lentTo = UserDefaults.standard.string(forKey: Self.lentKey)
        // out ended while a Mac's microphone was lent here: the input it took goes back.
        Self.giveBackInput()
    }

    // MARK: Lending

    func toggle(_ device: TrustedDevice) {
        if lentTo == device.key { takeBack(); return }
        takeBack()
        problems[device.key] = nil
        lend(device.key, again: false)
    }

    func takeBack() {
        if let key = lentTo { notes[key] = nil }
        setLent(nil)
        connecting?.cancel()
        connecting = nil
        unlink(takenBack: true)
    }

    /// out is quitting: the links end, and what is lent stays lent for the next launch.
    func close() {
        connecting?.cancel()
        connecting = nil
        unlink()
        endReceiving()
    }

    /// Only what is still allowed goes on. Multiple Macs turned off takes a lent microphone back; a
    /// Mac gone from the list (its helper away for a moment) holds the lending until it is back. A
    /// Mac's microphone here goes on while that Mac may still type here (as another Mac's view of
    /// this screen). A microphone lent and not linked (out just started) is linked again.
    func keep(linkOn: Bool, sendingTo allowedOut: Set<String>, receivingFrom allowedIn: Set<String>) {
        if let key = lentTo {
            if !linkOn { takeBack() }
            else if !allowedOut.contains(key) {
                connecting?.cancel()
                connecting = nil
                unlink()
            } else if out == nil, connecting == nil { lend(key, again: true) }
        }
        if let key = receivingFrom, !allowedIn.contains(key) { endReceiving() }
    }

    private func setLent(_ key: String?) {
        lentTo = key
        UserDefaults.standard.set(key, forKey: Self.lentKey)
    }

    /// `takenBack`: the other Mac is told, and gives its input back at once; else it keeps out Mic
    /// as its input for a while, for the link to come back.
    private func unlink(takenBack: Bool = false) {
        stopCapture()
        leaseCheck?.cancel()
        leaseCheck = nil
        out?.whenEnded(nil)
        out?.whenWantChanges(nil)
        if takenBack { out?.end() } else { out?.close() }
        out = nil
        linked = false
    }

    /// Makes the link, and makes it again for as long as the microphone stays lent: while the other
    /// Mac is away, after a few seconds and then less often; while out Mic is installed there, every
    /// two seconds until it is. A no from it ends the lending and says why.
    private func lend(_ key: String, again: Bool, after delay: UInt64 = 0) {
        setLent(key)
        connecting?.cancel()
        notes[key] = Note(text: tr("Connecting…"), installing: false)
        connecting = Task { [weak self] in
            var again = again
            var pause: UInt64 = 2
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
            while !Task.isCancelled {
                guard let self, self.lentTo == key else { return }
                // Not in the list now (its helper away for a moment): keep() links it again when it is back.
                guard let context = self.context?(), let device = context.device(key) else { self.connecting = nil; return }
                guard let identity = context.identity else {
                    self.takeBack()
                    self.problems[key] = tr("This Mac has no device key yet. Pair the Macs first.")
                    return
                }
                if device.reachable {
                    do {
                        let out = try await MicrophoneOut.open(device, identity: identity, name: context.name, listening: context.listening, again: again)
                        // Taken back meanwhile: the other Mac may have taken it already, and is told.
                        guard !Task.isCancelled, self.lentTo == key else { out.end(); return }
                        self.connecting = nil
                        self.link(out, key: key)
                        return
                    } catch let refusal as MicrophoneRefusal {
                        guard !Task.isCancelled, self.lentTo == key else { return }
                        guard refusal.wait else {
                            self.takeBack()
                            self.problems[key] = refusal.message
                            return
                        }
                        self.notes[key] = Note(text: refusal.message, installing: true)
                        pause = 2
                    } catch {
                        guard !Task.isCancelled, self.lentTo == key else { return }
                        self.notes[key] = Note(text: error.localizedDescription, installing: false)
                    }
                }
                again = true
                try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
                if self.notes[key]?.installing != true { pause = min(pause * 2, 30) }
            }
        }
    }

    private func link(_ out: MicrophoneOut, key: String) {
        self.out = out
        linked = true
        linkedAt = Date()
        notes[key] = nil
        problems[key] = nil
        out.whenWantChanges { [weak self] in
            Task { @MainActor in self?.follow(out) }
        }
        // Registered after the link is up; an end that came meanwhile is told at once. A link that
        // ends soon after it was made is made again only after a while, not at once and on and on.
        out.whenEnded { [weak self] in
            Task { @MainActor in
                guard let self, self.out === out else { return }
                let quick = Date().timeIntervalSince(self.linkedAt) < 10
                self.unlink()
                if self.lentTo == key { self.lend(key, again: true, after: quick ? 10 : 1) }
            }
        }
        // The lease: the other Mac's word that an app records runs out unless it is said again.
        leaseCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.follow(out)
            }
        }
        follow(out)
    }

    /// An app on the other Mac starts or stops recording, or its word ran out: this Mac's microphone follows.
    private func follow(_ out: MicrophoneOut) {
        guard self.out === out, let key = lentTo else { return }
        guard out.isWanted else { stopCapture(); return }
        guard capture == nil else { return }
        do {
            try startCapture(into: out, microphone: context?()?.microphone ?? "")
            live = true
            problems[key] = nil
        } catch {
            problems[key] = error.localizedDescription
        }
    }

    private func stopCapture() {
        drain?.cancel()
        drain = nil
        capture?.stop()
        capture = nil
        live = false
    }

    /// The microphone dictation uses (the locked one, or the system's), every hardware cycle (an
    /// engine tap waits for 100 ms), at 48 kHz mono, 10 ms a frame. Always a device named here, never
    /// left to the system's default, which could become out Mic meanwhile; and never out Mic itself,
    /// another Mac's microphone: then this Mac's own one. The audio thread only copies into a ring
    /// made beforehand, and never waits; a timer off that thread converts and sends.
    private func startCapture(into out: MicrophoneOut, microphone: String) throws {
        let engine = AVAudioEngine()
        var chosen = microphone.isEmpty ? (Microphone.systemDefault()?.uid ?? "") : microphone
        if chosen.isEmpty || chosen == MicWire.micUID {
            let own = Microphone.available().filter { $0.uid != MicWire.micUID }
            guard let pick = own.first(where: { $0.uid.localizedCaseInsensitiveContains("BuiltIn") }) ?? own.first else {
                throw VoiceError(tr("This Mac has no microphone of its own to lend."))
            }
            chosen = pick.uid
        }
        guard let id = Self.device(uid: chosen), let unit = engine.inputNode.audioUnit else {
            throw VoiceError(tr("Locked microphone not connected"))
        }
        try Self.use(id, on: unit)
        out.beginSession()
        // The device's own format: after a change of device the node's output format is still the old one's.
        let input = engine.inputNode.inputFormat(forBus: 0)
        guard input.sampleRate > 0,
              let one = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false),
              let wanted = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MicWire.rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: one, to: wanted) else { throw VoiceError(tr("The microphone could not be opened.")) }
        let ring = CaptureRing(capacity: Int(input.sampleRate))
        let sink = AVAudioSinkNode { _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            if let data = buffers.first?.mData { ring.write(data.assumingMemoryBound(to: Float.self), count: Int(frames)) }
            return 0
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: one)
        try engine.start()
        let queue = DispatchQueue(label: "local.hopo.qingyan.mic.send")
        var pending: [Int16] = []
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler {
            let chunk = ring.read()
            guard !chunk.isEmpty,
                  let piece = AVAudioPCMBuffer(pcmFormat: one, frameCapacity: AVAudioFrameCount(chunk.count)),
                  let converted = AVAudioPCMBuffer(pcmFormat: wanted, frameCapacity: AVAudioFrameCount(Double(chunk.count) * MicWire.rate / one.sampleRate) + 32)
            else { return }
            piece.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { piece.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
            var given = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true; status.pointee = .haveData; return piece
            }
            let samples = UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength))
            pending.append(contentsOf: samples.map { Int16(max(-1, min(1, $0)) * 32767) })
            while pending.count >= MicWire.block {
                out.send(Array(pending.prefix(MicWire.block)))
                pending.removeFirst(MicWire.block)
            }
        }
        timer.resume()
        capture = engine
        drain = timer
    }

    // MARK: Receiving

    /// Another Mac's microphone, lent here: played into out Mic's feed and nowhere else, and out Mic
    /// made this Mac's input, so that every app that records hears it. Whether an app records from
    /// out Mic is told to the lending Mac as it changes, and again every two seconds. A link of the
    /// same lending coming back takes the place of the last one, and leaves the input as it is.
    func adopt(_ input: MicrophoneIn) {
        giveBackLater?.cancel()
        endReceiving(input: .keep)
        let jitter = MicJitter(milliseconds: 60)
        let engine = AVAudioEngine()
        guard let feed = Self.device(uid: MicWire.feedUID), let unit = engine.outputNode.audioUnit,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MicWire.rate, channels: 1, interleaved: false),
              (try? Self.use(feed, on: unit)) != nil else {
            // Never the speakers: without the feed, nothing is played, and the input goes back.
            input.close()
            Self.giveBackInput(); inputTakenFor = nil
            return
        }
        let source = AVAudioSourceNode(format: mono) { _, _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            if let data = buffers.first?.mData { jitter.take(Int(frames), into: data.assumingMemoryBound(to: Float.self)) }
            return 0
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)
        guard (try? engine.start()) != nil else {
            input.close()
            Self.giveBackInput(); inputTakenFor = nil
            return
        }
        playback = engine
        inbound = input
        self.jitter = jitter
        receivingFrom = input.key
        // Without knowing when apps record, the other Mac's microphone would never turn on.
        guard watchUse() else { endReceiving(); return }
        if inputTakenFor != input.key {
            Self.giveBackInput()
            inputTakenFor = takeInput() ? input.key : nil
        }
        renewUse = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.inbound === input, let told = self.toldUse else { return }
                input.want(told)
            }
        }
        Task.detached {
            while let frame = await input.next() { jitter.put(at: frame.at, samples: frame.samples) }
            await MainActor.run { [weak self] in
                guard let self, self.inbound === input else { return }
                // Taken back: the input goes back now. The link lost: out Mic stays the input for
                // half a minute, so that apps here do not switch back and forth while it comes back.
                self.endReceiving(input: input.takenBack ? .giveBack : .giveBackLater)
            }
        }
    }

    enum Input { case giveBack, giveBackLater, keep }

    func endReceiving(input afterwards: Input = .giveBack) {
        unwatchUse()
        renewUse?.cancel()
        renewUse = nil
        inbound?.close()
        inbound = nil
        playback?.stop()
        playback = nil
        jitter = nil
        receivingFrom = nil
        heardHere = false
        switch afterwards {
        case .giveBack:
            giveBackLater?.cancel()
            Self.giveBackInput()
            inputTakenFor = nil
        case .giveBackLater:
            giveBackLater?.cancel()
            giveBackLater = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self, self.inbound == nil else { return }
                Self.giveBackInput()
                self.inputTakenFor = nil
            }
        case .keep: break
        }
    }

    /// Another Mac would lend its microphone here. Another Mac's is lent here already: no, until it
    /// is taken back there. out Mic not installed: its install is asked for here, with this Mac's
    /// password, and the lending Mac waits and asks again; after a no to the password, not again by
    /// that Mac's asking by itself, and by no Mac's for a minute.
    func answer(key: String, from asker: String, again: Bool, here: String) -> MicrophoneAnswer {
        if let current = inbound, current.key != key {
            return .no(tr("%@’s microphone is lent to %@ already. Take it back there first.", current.name, here))
        }
        if Self.device(uid: MicWire.feedUID) != nil { return .yes }
        let waiting = MicrophoneAnswer.wait(tr("out Mic is being installed on %@. Type its password in the window on its screen.", here))
        if installing { return waiting }
        if let failed = installFailedAt, again || Date().timeIntervalSince(failed) < 60 {
            return .no(tr("out Mic was not installed on %@. Click the microphone button again in a minute to be asked for its password once more, or install it there in Settings, under Audio and shortcut.", here))
        }
        guard Self.bundledDriver != nil else { return .no(tr("out on the other Mac cannot take a microphone.")) }
        install(for: asker)
        return waiting
    }

    /// out Mic becomes this Mac's input; the input it was is kept, to go back to afterwards. Nothing
    /// is switched when that input could not be kept. Already out Mic: nothing to keep or switch.
    private func takeInput() -> Bool {
        guard let mic = Self.device(uid: MicWire.micUID), let current = Self.defaultInput() else { return false }
        if current == mic { return true }
        guard let uid = Microphone.available().first(where: { $0.id == current })?.uid, uid != MicWire.micUID else { return false }
        UserDefaults.standard.set(uid, forKey: Self.previousInputKey)
        guard Self.setDefaultInput(mic) else {
            UserDefaults.standard.removeObject(forKey: Self.previousInputKey)
            return false
        }
        return true
    }

    /// The input out Mic took the place of comes back, if out Mic is still the input; that input
    /// gone (unplugged meanwhile), this Mac's own one, so that out Mic is not left as the input.
    private static func giveBackInput() {
        guard let previous = UserDefaults.standard.string(forKey: previousInputKey) else { return }
        guard let mic = device(uid: MicWire.micUID), defaultInput() == mic else {
            UserDefaults.standard.removeObject(forKey: previousInputKey)
            return
        }
        let own = Microphone.available().filter { $0.uid != MicWire.micUID }
        let back = device(uid: previous)
            ?? own.first(where: { $0.uid.localizedCaseInsensitiveContains("BuiltIn") }).flatMap { device(uid: $0.uid) }
            ?? own.first.flatMap { device(uid: $0.uid) }
        guard let back, setDefaultInput(back) else { return }
        UserDefaults.standard.removeObject(forKey: previousInputKey)
    }

    private static let inUseAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    /// Whether any app records from out Mic, now and as it changes; false when that cannot be watched.
    private func watchUse() -> Bool {
        guard let mic = Self.device(uid: MicWire.micUID) else { return false }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.tellUse() }
        }
        var address = Self.inUseAddress
        guard AudioObjectAddPropertyListenerBlock(mic, &address, DispatchQueue.main, block) == noErr else { return false }
        useListener = block
        useDevice = mic
        toldUse = nil
        tellUse()
        return true
    }

    private func unwatchUse() {
        guard let block = useListener else { return }
        var address = Self.inUseAddress
        AudioObjectRemovePropertyListenerBlock(useDevice, &address, DispatchQueue.main, block)
        useListener = nil
        toldUse = nil
    }

    /// Said to the lending Mac when it changes. A recording here that ended takes what is left of
    /// it out of the way, so the next one starts with nothing of it.
    private func tellUse() {
        guard let inbound, useListener != nil else { return }
        var address = Self.inUseAddress
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let inUse = AudioObjectGetPropertyData(useDevice, &address, 0, nil, &size, &running) == noErr && running != 0
        heardHere = inUse
        guard toldUse != inUse else { return }
        toldUse = inUse
        if !inUse { jitter?.reset() }
        inbound.want(inUse)
    }

    // MARK: The driver

    enum DriverState: Equatable { case absent, current, older }

    nonisolated static let installedDriver = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/OutMic.driver")
    nonisolated static var bundledDriver: URL? { Bundle.main.url(forResource: "OutMic", withExtension: "driver") }

    nonisolated private static func version(_ bundle: URL) -> Int {
        (NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
    }

    /// Whether out Mic is there and is the one this out carries.
    nonisolated static func driverState() -> DriverState {
        guard FileManager.default.fileExists(atPath: installedDriver.path), device(uid: MicWire.feedUID) != nil else { return .absent }
        if let bundled = bundledDriver, version(installedDriver) < version(bundled) { return .older }
        return .current
    }

    func refreshDriver() { driver = Self.driverState() }

    /// The shell steps, fixed: the paths and the prompt come in as arguments and are quoted by
    /// AppleScript. A new driver is copied beside the old one, checked to be out's and whole, and
    /// only then put in its place.
    private static let installer = """
    on run argv
        set source to item 1 of argv
        set prompt to item 2 of argv
        set target to "/Library/Audio/Plug-Ins/HAL/OutMic.driver"
        set staged to "/Library/Audio/Plug-Ins/HAL/.OutMic.driver.new"
        if source is "" then
            do shell script "rm -rf " & quoted form of target & " && (killall coreaudiod || true)" with administrator privileges with prompt prompt
        else
            do shell script "mkdir -p /Library/Audio/Plug-Ins/HAL && rm -rf " & quoted form of staged & " && cp -R " & quoted form of source & " " & quoted form of staged & " && chown -R root:wheel " & quoted form of staged & " && codesign --verify --strict " & quoted form of staged & " && codesign -dv " & quoted form of staged & " 2>&1 | grep -qx Identifier=local.hopo.qingyan.mic && rm -rf " & quoted form of target & " && mv " & quoted form of staged & " " & quoted form of target & " && (killall coreaudiod || true)" with administrator privileges with prompt prompt
        end if
    end run
    """

    /// Puts the driver in the system's folder (the Mac's password, asked by macOS), or takes it out
    /// with `remove`, and starts Core Audio again: every app's sound stops for a moment. `asker`:
    /// the Mac whose lending asked for it, named in the window.
    func install(remove: Bool = false, for asker: String? = nil) {
        let bundled = Self.bundledDriver
        guard !installing, remove || bundled != nil else { return }
        installing = true
        let source = remove ? "" : bundled!.path
        let prompt = remove ? tr("out is removing out Mic.")
            : asker.map { tr("out is installing out Mic, so that apps here can use %@’s microphone.", $0) }
            ?? tr("out is installing out Mic, so that apps here can use the microphone of another of your Macs.")
        let script = Self.installer
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, source, prompt]
            try? process.run()
            process.waitUntilExit()
            // Core Audio takes a moment to come back and list the devices again.
            for _ in 0..<20 {
                let state = MicrophoneLink.driverState()
                if remove ? state == .absent : state == .current { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.installing = false
                self.refreshDriver()
                if !remove, self.driver == .absent, asker != nil { self.installFailedAt = Date() }
            }
        }
    }

    // MARK: Devices

    /// A device by its UID, hidden ones too (out Mic Feed is not in the system's list of devices).
    nonisolated static func device(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        return status == 0 && id != 0 ? id : nil
    }

    nonisolated private static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    /// The system's input, as System Settings > Sound > Input sets it; no permission is asked for.
    nonisolated private static func setDefaultInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    /// Points an engine's unit at a device, and reads it back: a refused switch would leave the
    /// system's default microphone or speakers in its place.
    private static func use(_ device: AudioDeviceID, on unit: AudioUnit) throws {
        var wanted = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var actual = AudioDeviceID(0)
        var read = size
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &wanted, size) == noErr,
              AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &read) == noErr,
              actual == device else { throw VoiceError(tr("The microphone could not be opened.")) }
    }
}

/// What the microphone hears, on its way off the audio thread: a ring made beforehand, written by
/// the audio thread without ever waiting (held, the cycle is dropped) and read by the sending timer.
private final class CaptureRing: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var head = 0
    private var count = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 4_096)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit { storage.deallocate() }

    func write(_ samples: UnsafePointer<Float>, count frames: Int) {
        _ = lock.withLockIfAvailable {
            for index in 0..<min(frames, capacity) {
                storage[(head + count) % capacity] = samples[index]
                if count < capacity { count += 1 } else { head = (head + 1) % capacity }
            }
        }
    }

    func read() -> [Float] {
        lock.withLock {
            var out = [Float](repeating: 0, count: count)
            for index in 0..<count { out[index] = storage[(head + index) % capacity] }
            head = 0
            count = 0
            return out
        }
    }
}
