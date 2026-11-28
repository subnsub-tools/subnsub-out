import AVFoundation
import AudioToolbox
import AudioCapture
import Combine
import CoreAudio
import QingyanCore

/// A device sound can be recorded from.
struct Microphone: Identifiable, Equatable, Sendable {
    /// The system's number for it now. It changes when the device is plugged in again.
    let id: UInt32
    /// The system's lasting name for it, which is what a choice is remembered by.
    let uid: String
    let name: String

    private static func text(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private init?(_ device: AudioDeviceID) {
        var input = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &input, 0, nil, &bytes) == noErr, bytes > 0,
              let uid = Self.text(device, kAudioDevicePropertyDeviceUID), let name = Self.text(device, kAudioObjectPropertyName),
              // The private pairings of devices the system makes for its own use (also the one voice
              // processing makes while recording) are not microphones to choose.
              !uid.hasPrefix("CADefaultDeviceAggregate"), !uid.hasPrefix("VPAUAggregateAudioDevice"),
              !Self.privateAggregate(device) else { return nil }
        self.id = device; self.uid = uid; self.name = name
    }

    /// Whether `device` is an aggregate that its maker keeps private. One made by the user in Audio
    /// MIDI Setup is not.
    private static func privateAggregate(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyComposition,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return false }
        let composition = value.takeRetainedValue() as NSDictionary
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    /// Every device with an input, in the system's order.
    nonisolated static func available() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { Microphone($0) }
    }

    /// The one chosen in the system's sound settings.
    nonisolated static func systemDefault() -> Microphone? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return Microphone(device)
    }
}

/// Isolated live audio meter so waveform and timer ticks never invalidate the main panel or settings views.
@MainActor
final class AudioMeter: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: Int = 0
    /// The recording's levels as they came and when (seconds since the reference date), newest last,
    /// for the waveform that runs across the bar kept on top: some seconds of them, more than its
    /// widest shows. Not published: that view redraws every frame.
    private(set) var trace: [(at: TimeInterval, level: Float)] = []

    func setLevel(_ next: Float) {
        let clamped = min(1, max(0, next))
        trace.append((Date.timeIntervalSinceReferenceDate, clamped))
        if trace.count > 240 { trace.removeFirst(trace.count - 200) }
        guard abs(level - clamped) >= 0.015 || (clamped == 0 && level != 0) else { return }
        level = clamped
    }

    func setElapsed(_ next: Int) {
        guard elapsed != next else { return }
        elapsed = next
    }

    func reset() {
        if level != 0 { level = 0 }
        if elapsed != 0 { elapsed = 0 }
        trace = []
    }

    #if DEBUG
    /// A spoken sentence's worth of levels, for the previews.
    func previewTrace() {
        // Running on past the moment it is made, so the picture taken a little later is full too.
        let now = Date.timeIntervalSinceReferenceDate
        trace = (0..<180).map { index in
            let t = Float(index)
            let syllables = max(0, sin(t * 0.55)) * (0.55 + 0.45 * sin(t * 0.13 + 1))
            return (now - 6 + Double(index) * 0.05, index % 37 > 30 ? 0.02 : 0.05 + syllables * 0.85)
        }
    }
    #endif
}

/// The microphones this Mac has at the moment, kept current off the main thread as devices are
/// connected, disconnected, or switched in System Settings.
@MainActor
final class Microphones: ObservableObject {
    @Published private(set) var all: [Microphone] = []
    @Published private(set) var systemDefault: Microphone?
    @Published private(set) var loaded = false
    private nonisolated let queue = DispatchQueue(label: "local.hopo.qingyan.audio-hal", qos: .utility)
    private nonisolated(unsafe) var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

    init(preview: Bool = false) {
        guard !preview else {
            loaded = true
            return
        }
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleRefresh()
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                listeners.append((selector, block))
            }
        }
    }

    deinit {
        for (selector, block) in listeners {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    nonisolated private func scheduleRefresh() {
        queue.async { [weak self] in
            let found = Microphone.available()
            let chosen = Microphone.systemDefault()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.all != found { self.all = found }
                if self.systemDefault != chosen { self.systemDefault = chosen }
                if !self.loaded { self.loaded = true }
            }
        }
    }

    func refresh() {
        scheduleRefresh()
    }
}

@MainActor
final class AudioRecorder {
    /// Every call into the audio system runs on this queue, never on the main thread: on 2026-11-20
    /// the audio system stopped answering after it refused a device switch, and out froze with it.
    private nonisolated static let audio = DispatchQueue(label: "local.hopo.qingyan.audio", qos: .userInitiated)
    /// How long a start may take before out says that the audio system did not answer.
    private nonisolated static let startLimit: Double = 5
    /// Engines whose switch to the locked microphone was refused, kept for the life of the process.
    /// The audio system keeps listeners of a released input unit and refuses the device switch of a
    /// later unit made at the same address, with the microphone connected (2026-11-20). While a
    /// refused engine lives, no new engine is made at its address. Touched only on `audio`.
    private nonisolated(unsafe) static var refused: [AVAudioEngine] = []
    /// The same for voice-processing engines, apart, so they never use up the plain path's room.
    /// When it is full, a locked microphone is recorded plainly. Touched only on `audio`.
    private nonisolated(unsafe) static var refusedProcessed: [AVAudioEngine] = []

    private var capture: Capture?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    /// The start the current capture belongs to. A stop clears it, and a start that finishes after
    /// that closes what it opened.
    private var session: UUID?
    /// A problem reported while a start was still opening the microphone; that start throws it.
    private var startFailure: Error?

    /// `microphone` is the lasting UID of the permanently bound device; empty follows the system.
    /// Strict binding: when `microphone` is non-empty and that device is absent, recording is
    /// refused rather than silently falling back to another microphone.
    func start(microphone: String, microphoneName: String = "", onLevel: @escaping @MainActor (Float) -> Void) async throws -> AsyncThrowingStream<Data, Error> {
        stop()
        startFailure = nil
        let session = UUID()
        self.session = session
        let (stream, sink) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(120))
        continuation = sink
        // What the capture notices later (the locked microphone gone, the input moved, the device
        // interrupted) ends this session only.
        let report: @Sendable (Error) -> Void = { error in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                if self.capture == nil { self.startFailure = error }
                self.stop(error: error)
            }
        }
        let opened: Capture
        do {
            opened = try await Self.withinLimit { expired in
                try Self.open(microphone: microphone, microphoneName: microphoneName, sink: sink, onLevel: onLevel,
                              report: report, expired: expired)
            }
        } catch {
            sink.finish()
            if self.session == session { self.session = nil; continuation = nil }
            throw error
        }
        guard self.session == session else {
            Self.audio.async { opened.close() }
            let failure = startFailure
            startFailure = nil
            throw failure ?? CancellationError()
        }
        capture = opened
        if opened.processed { offerMicrophoneModes(session: session) }
        return stream
    }

    /// Set once the system's Mic Mode panel has been offered on this Mac.
    private static let modesOfferedKey = "microphoneModesOffered"

    /// Once, during the first recording through voice processing, opens the system's Mic Mode panel
    /// so Voice Isolation can be chosen for out; the system keeps that choice for out from then on.
    /// Skipped when it is chosen already.
    private func offerMicrophoneModes(session: UUID) {
        guard !UserDefaults.standard.bool(forKey: Self.modesOfferedKey) else { return }
        Task { @MainActor [weak self] in
            // The panel lists out only while its processed input is running.
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.session == session else { return }
            UserDefaults.standard.set(true, forKey: Self.modesOfferedKey)
            // The system's media service answers this, so it is asked off the main thread.
            let isolated = await withCheckedContinuation { done in
                DispatchQueue.global(qos: .userInitiated).async {
                    done.resume(returning: AVCaptureDevice.preferredMicrophoneMode == .voiceIsolation)
                }
            }
            guard !isolated, self.session == session else { return }
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        }
    }

    func stop() {
        stop(error: nil)
    }

    private func stop(error: Error?) {
        session = nil
        if let capture {
            self.capture = nil
            Self.audio.async { capture.close() }
        }
        if let error { continuation?.finish(throwing: error) }
        else { continuation?.finish() }
        continuation = nil
    }

    /// Runs `work` on `audio` and waits for it for at most `startLimit` seconds. A capture that
    /// opens after the limit is closed at once; `work` is told whether the limit has passed.
    private nonisolated static func withinLimit(_ work: @escaping @Sendable (_ expired: @Sendable () -> Bool) throws -> Capture) async throws -> Capture {
        try await withCheckedThrowingContinuation { continuation in
            let answer = FirstAnswer(continuation)
            audio.async {
                // A start that has run out of time does not open the microphone any more.
                guard !answer.given else { return }
                let result = Result { try work { answer.given } }
                if !answer.give(result), case .success(let late) = result { late.close() }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + startLimit) {
                _ = answer.give(.failure(VoiceError(tr("The Mac's audio system did not respond while the microphone was starting. Quit and reopen out."))))
            }
        }
    }

    /// Opens the microphone for one recording, through the system's voice processing when the Mac
    /// and the device take it. Runs on `audio`.
    private nonisolated static func open(microphone: String, microphoneName: String,
                                         sink: AsyncThrowingStream<Data, Error>.Continuation,
                                         onLevel: @escaping @MainActor (Float) -> Void,
                                         report: @escaping @Sendable (Error) -> Void,
                                         expired: @Sendable () -> Bool) throws -> Capture {
        let available = Microphone.available()
        let currentDefault = Microphone.systemDefault()
        let resolution = MicrophoneBinding.resolve(
            boundUID: microphone,
            boundName: microphoneName,
            available: available.map { .init(uid: $0.uid, name: $0.name) },
            systemDefault: currentDefault.map { .init(uid: $0.uid, name: $0.name) }
        )
        if let problem = resolution.missingMessage {
            throw VoiceError(problem)
        }
        var locked: Microphone?
        if case .boundAvailable(let info) = resolution { locked = available.first { $0.uid == info.uid } }
        let label = locked?.name ?? MicrophoneBinding.displayLabel(boundName: microphoneName, uid: microphone)
        // The engine records from the system's input. A locked microphone that is not the system's
        // input is switched to; one that is needs no switch, and the system's input is watched instead.
        let switched = locked.flatMap { $0.uid == currentDefault?.uid ? nil : $0 }
        let throughSystem = !microphone.isEmpty && switched == nil
        // The system's voice processing is tried first: echo cancellation, noise suppression, the
        // Mic Mode chosen for out (Voice Isolation keeps only the nearest voice), and other sound
        // turned down while recording. A Mac or device that does not take it records the plain input.
        let engine: AVAudioEngine
        let processed: Bool
        if let voiced = processedEngine(switched),
           (try? startTap(voiced.engine, format: voiced.format, sink: sink, onLevel: onLevel)) == true {
            engine = voiced.engine
            processed = true
        } else {
            // A start that ran out of time while trying does not open the microphone any more.
            guard !expired() else { throw CancellationError() }
            engine = try switched.map(lockedEngine) ?? AVAudioEngine()
            processed = false
            // A device switch can leave the output bus at the previous device's rate. The input
            // scope describes the hardware; an input node cannot resample it when installing a tap.
            guard try startTap(engine, format: engine.inputNode.inputFormat(forBus: 0), sink: sink, onLevel: onLevel) else {
                throw VoiceError(tr("Could not start the microphone. Check the permission, the input device and other apps that record."))
            }
        }
        let capture = Capture(engine: engine, processed: processed)
        // The stream ends here at once, so no more audio is taken while the main thread catches up.
        let fail: @Sendable (Error) -> Void = { error in
            sink.finish(throwing: error)
            report(error)
        }
        if !microphone.isEmpty {
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                if let lost = lockLost(uid: microphone, throughSystem: throughSystem) { fail(lost.error(label)) }
            }
            capture.listener = listener
            let selectors = throughSystem ? [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] : [kAudioHardwarePropertyDevices]
            for selector in selectors {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, Capture.monitor, listener) == noErr {
                    capture.watched.append(selector)
                }
            }
        }
        capture.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { [weak capture] _ in
                // The notification is posted on the engine's queue. Teardown there can deadlock.
                audio.async {
                    guard let capture else { return }
                    if let lost = lockLost(uid: microphone, throughSystem: throughSystem) {
                        fail(lost.error(label))
                    } else if !capture.engine.isRunning {
                        fail(VoiceError(tr("The audio input device was interrupted. The recording so far is saved.")))
                    }
                }
            }
        // Also cover a change between successful startup and installing the watchers.
        guard engine.isRunning else {
            capture.close()
            throw VoiceError(tr("Could not start the microphone. Check the permission, the input device and other apps that record."))
        }
        if let lost = lockLost(uid: microphone, throughSystem: throughSystem) {
            capture.close()
            throw lost == .gone ? VoiceError(tr("The locked microphone “%@” is disconnected, so there is no input.", label)) : lost.error(label)
        }
        return capture
    }

    /// An engine with the system's voice processing on its input, switched to `device` when one is
    /// given, and the format its processed input is tapped in; nil when this Mac or the device does
    /// not take it. Not started. Runs on `audio`.
    private nonisolated static func processedEngine(_ device: Microphone?) -> (engine: AVAudioEngine, format: AVAudioFormat)? {
        if device != nil, refusedProcessed.count >= 12 { return nil }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // AVFAudio can raise here as well as fail; both are kept in Objective-C.
        guard QYEnableVoiceProcessing(input) else { return nil }
        if let device {
            guard let unit = input.audioUnit else { return nil }
            // The voice-processing unit takes its input device on the input element.
            var selected = device.id
            var actual = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1,
                                              &selected, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr,
                  AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &actual, &size) == noErr,
                  actual == device.id else {
                // A refused switch marks the address, as in lockedEngine.
                if status == kAudioHardwareIllegalOperationError { refusedProcessed.append(engine) }
                return nil
            }
        }
        // Other apps are turned down as far as the system goes, for the whole recording.
        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false, duckingLevel: .max)
        // The processed input is one voice, at the device's rate: after a device switch the output
        // bus can still describe the previous device, the input scope describes the hardware.
        let rate = input.inputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            return nil
        }
        return (engine, format)
    }

    /// Starts `engine` with a tap that turns its input, in `format`, into the 24 kHz mono stream.
    /// False when the engine did not start; it is stopped again then. Runs on `audio`.
    private nonisolated static func startTap(_ engine: AVAudioEngine, format: AVAudioFormat,
                                             sink: AsyncThrowingStream<Data, Error>.Continuation,
                                             onLevel: @escaping @MainActor (Float) -> Void) throws -> Bool {
        guard format.sampleRate > 0, format.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw VoiceError(tr("The microphone offers no usable audio format. Check the sound input in System Settings."))
        }
        final class MeterGate: @unchecked Sendable { var lastReport: CFAbsoluteTime = 0 }
        let gate = MeterGate()
        // A route can change between reading the format and starting. Swift do/catch cannot
        // catch AVFAudio's NSException, so installation and startup stay in Objective-C.
        return QYStartAudioCapture(engine, format, { buffer, _ in
            guard buffer.format == format else {
                sink.finish(throwing: VoiceError(tr("The audio format changed. Start recording again."))); return
            }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 24000 / format.sampleRate)) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else { sink.finish(throwing: VoiceError(tr("The audio could not be converted. Choose the input device again."))); return }
            guard let samples = converted.int16ChannelData?[0], converted.frameLength > 0 else { return }
            let count = Int(converted.frameLength)
            let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
            let now = CFAbsoluteTimeGetCurrent()
            if now - gate.lastReport >= 0.045 {
                gate.lastReport = now
                var squares: Double = 0
                for i in 0..<count { let value = Double(samples[i]) / 32768; squares += value * value }
                let level = Float(sqrt(squares / Double(count)))
                Task { @MainActor in onLevel(level) }
            }
            if case .dropped = sink.yield(data) { sink.finish(throwing: VoiceError(tr("Audio was written too slowly on this Mac. Recording stopped; what was recorded is kept in History."))) }
        }, nil)
    }

    /// An engine whose input is switched to `device`. A refused switch is tried again with a new
    /// engine while `refused` has room for the refused one; every start tries at least once. Runs on `audio`.
    private nonisolated static func lockedEngine(_ device: Microphone) throws -> AVAudioEngine {
        for _ in 0..<3 {
            let engine = AVAudioEngine()
            guard let unit = engine.inputNode.audioUnit else {
                throw VoiceError(tr("Could not lock input to the microphone “%@”. The audio input is not ready.", device.name))
            }
            var selected = device.id
            var actual = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &selected, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr,
               AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr,
               actual == device.id {
                return engine
            }
            // Only a refusal ('nope') comes from a reused address. Any other failure is the device's own.
            guard status == noErr || status == kAudioHardwareIllegalOperationError else {
                throw VoiceError(tr("Could not start the microphone. Check the permission, the input device and other apps that record."))
            }
            guard refused.count < 12 else { break }
            refused.append(engine)
        }
        throw VoiceError(tr("macOS did not switch the input to the locked microphone “%@”, although it is connected. Quit and reopen out.", device.name))
    }

    /// How input stopped coming from the locked microphone.
    private enum LockLost {
        case gone, moved

        func error(_ label: String) -> VoiceError {
            switch self {
            case .gone: VoiceError(tr("The locked microphone “%@” was disconnected. Input stopped; what was recorded so far is kept.", label))
            case .moved: VoiceError(tr("The system input switched from the locked microphone “%@” to another device. Input stopped.", label))
            }
        }
    }

    /// Whether input no longer comes from the locked microphone `uid`: it is gone, or, when it is
    /// recorded as the system's input, the system's input is now another device.
    private nonisolated static func lockLost(uid: String, throughSystem: Bool) -> LockLost? {
        guard !uid.isEmpty else { return nil }
        if !Microphone.available().contains(where: { $0.uid == uid }) { return .gone }
        if throughSystem, let current = Microphone.systemDefault(), current.uid != uid { return .moved }
        return nil
    }
}

/// One open microphone: the engine whose tap feeds the stream, and the watchers that stop it.
/// Opened, used and closed only on the recorder's audio queue.
private final class Capture: @unchecked Sendable {
    static let monitor = DispatchQueue(label: "local.hopo.qingyan.recorder-guard", qos: .userInteractive)
    let engine: AVAudioEngine
    /// Whether the input comes through the system's voice processing.
    let processed: Bool
    var listener: AudioObjectPropertyListenerBlock?
    var watched: [AudioObjectPropertySelector] = []
    var observer: NSObjectProtocol?

    init(engine: AVAudioEngine, processed: Bool) { self.engine = engine; self.processed = processed }

    func close() {
        if let listener {
            for selector in watched {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, Self.monitor, listener)
            }
        }
        listener = nil
        watched = []
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}

/// Hands a waiting start the first of two answers: the audio queue's, or the time limit's.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Capture, Error>?

    init(_ waiting: CheckedContinuation<Capture, Error>) { self.waiting = waiting }

    var given: Bool {
        lock.lock(); defer { lock.unlock() }
        return waiting == nil
    }

    /// False when the other answer was given first.
    func give(_ result: Result<Capture, Error>) -> Bool {
        lock.lock()
        let waiting = self.waiting
        self.waiting = nil
        lock.unlock()
        guard let waiting else { return false }
        waiting.resume(with: result)
        return true
    }
}
