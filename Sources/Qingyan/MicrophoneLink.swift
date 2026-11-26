import AVFoundation
import CoreAudio
import Foundation
import os
import QingyanCore

/// This Mac's microphone sent to another Mac, where it is the out Mic microphone; and another Mac's
/// microphone coming in here (user 2026-11-27: a virtual microphone on the Mac worked from another
/// one, for meetings). The out Mic driver, inside the app, is installed here once with the Mac's
/// password; out plays what arrives into its hidden feed, and meeting apps pick out Mic.
@MainActor
final class MicrophoneLink: ObservableObject {
    /// The Mac this Mac's microphone goes to, and the one it is being opened to, by key.
    @Published private(set) var sendingTo: String?
    @Published private(set) var opening: String?
    /// What went wrong the last time, by the Mac's key.
    @Published private(set) var problems: [String: String] = [:]
    /// The Mac whose microphone comes in here, by key.
    @Published private(set) var receivingFrom: String?
    @Published private(set) var driver = MicrophoneLink.driverState()
    @Published private(set) var installing = false

    private var out: MicrophoneOut?
    private var capture: AVAudioEngine?
    private var drain: DispatchSourceTimer?
    private var inbound: MicrophoneIn?
    private var playback: AVAudioEngine?

    // MARK: Sending

    func toggle(_ device: TrustedDevice, identity: DeviceIdentity?, name: String, listening: Int, microphone: String) {
        if sendingTo == device.key || opening == device.key { stop(); return }
        stop()
        guard let identity else { problems[device.key] = tr("This Mac has no device key yet. Pair the Macs first."); return }
        problems[device.key] = nil
        opening = device.key
        Task { [weak self] in
            do {
                let out = try await MicrophoneOut.open(device, identity: identity, name: name, listening: listening)
                guard let self, self.opening == device.key else { out.close(); return }
                self.opening = nil
                do { try self.startCapture(into: out, microphone: microphone) }
                catch { out.close(); self.problems[device.key] = error.localizedDescription; return }
                self.out = out
                self.sendingTo = device.key
                // Registered after the stream is set up; an end that came meanwhile is told at once.
                out.whenEnded { [weak self] in
                    Task { @MainActor in
                        guard let self, self.out === out else { return }
                        self.stop()
                        self.problems[device.key] = tr("%@ stopped taking this Mac's microphone.", device.label)
                    }
                }
            } catch {
                guard let self, self.opening == device.key else { return }
                self.opening = nil
                self.problems[device.key] = error.localizedDescription
            }
        }
    }

    func stop() {
        opening = nil
        drain?.cancel()
        drain = nil
        capture?.stop()
        capture = nil
        out?.whenEnded(nil)
        out?.close()
        out = nil
        sendingTo = nil
    }

    /// Only what is still allowed goes on: this Mac's microphone to a Mac still in the list, and a
    /// Mac's microphone here while that Mac may still type here (as another Mac's view of this screen).
    func keep(sendingTo allowedOut: Set<String>, receivingFrom allowedIn: Set<String>) {
        if let key = sendingTo ?? opening, !allowedOut.contains(key) { stop() }
        if let key = receivingFrom, !allowedIn.contains(key) { endReceiving() }
    }

    /// The microphone dictation uses (the locked one, or the system's), every hardware cycle (an
    /// engine tap waits for 100 ms), at 48 kHz mono, 10 ms a frame. The audio thread only copies
    /// into a ring made beforehand, and never waits; a timer off that thread converts and sends.
    private func startCapture(into out: MicrophoneOut, microphone: String) throws {
        let engine = AVAudioEngine()
        if !microphone.isEmpty {
            guard let id = Self.device(uid: microphone), let unit = engine.inputNode.audioUnit else {
                throw VoiceError(tr("Locked microphone not connected"))
            }
            try Self.use(id, on: unit)
        }
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

    /// Another Mac's microphone, played into out Mic's feed and nowhere else; a new one takes the
    /// place of the last.
    func adopt(_ input: MicrophoneIn) {
        endReceiving()
        let jitter = MicJitter(milliseconds: 60)
        let engine = AVAudioEngine()
        guard let feed = Self.device(uid: MicWire.feedUID), let unit = engine.outputNode.audioUnit,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MicWire.rate, channels: 1, interleaved: false),
              (try? Self.use(feed, on: unit)) != nil else {
            // Never the speakers: without the feed, nothing is played.
            input.close()
            return
        }
        let source = AVAudioSourceNode(format: mono) { _, _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            if let data = buffers.first?.mData { jitter.take(Int(frames), into: data.assumingMemoryBound(to: Float.self)) }
            return 0
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)
        do { try engine.start() } catch { input.close(); return }
        playback = engine
        inbound = input
        receivingFrom = input.key
        Task.detached {
            while let frame = await input.next() { jitter.put(at: frame.at, samples: frame.samples) }
            await MainActor.run { [weak self] in
                guard let self, self.inbound === input else { return }
                self.endReceiving()
            }
        }
    }

    func endReceiving() {
        inbound?.close()
        inbound = nil
        playback?.stop()
        playback = nil
        receivingFrom = nil
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

    /// Why this Mac cannot take another Mac's microphone now, or nil.
    nonisolated static func refusal() -> String? {
        device(uid: MicWire.feedUID) == nil ? tr("out Mic is not installed on the other Mac. Install it there in Settings, under Audio and shortcut.") : nil
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
    /// with `remove`, and starts Core Audio again: every app's sound stops for a moment.
    func install(remove: Bool = false) {
        let bundled = Self.bundledDriver
        guard !installing, remove || bundled != nil else { return }
        installing = true
        let source = remove ? "" : bundled!.path
        let prompt = remove ? tr("out is removing out Mic.") : tr("out is installing out Mic, a microphone that another of your Macs speaks into.")
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
                self?.installing = false
                self?.refreshDriver()
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
