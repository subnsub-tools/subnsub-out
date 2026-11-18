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
              // The private pairing of devices the system makes for its own use is not a microphone to choose.
              !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
        self.id = device; self.uid = uid; self.name = name
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

    func setLevel(_ next: Float) {
        let clamped = min(1, max(0, next))
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
    }
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
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var configurationObserver: NSObjectProtocol?
    private nonisolated let monitorQueue = DispatchQueue(label: "local.hopo.qingyan.recorder-guard", qos: .userInteractive)
    private nonisolated(unsafe) var deviceListener: AudioObjectPropertyListenerBlock?

    /// `microphone` is the lasting UID of the permanently bound device; empty follows the system.
    /// Strict binding: when `microphone` is non-empty and that device is absent, recording is
    /// refused rather than silently falling back to another microphone.
    func start(microphone: String, microphoneName: String = "", onLevel: @escaping @MainActor (Float) -> Void) throws -> AsyncThrowingStream<Data, Error> {
        stop()
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

        let engine = AVAudioEngine()
        let input = engine.inputNode
        var boundLabel = ""
        if case .boundAvailable(let info) = resolution,
           let chosen = available.first(where: { $0.uid == info.uid }) {
            boundLabel = chosen.name
            guard let unit = input.audioUnit else {
                throw VoiceError(tr("Could not lock input to the microphone “%@”. The audio input is not ready.", chosen.name))
            }
            var selected = chosen.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &selected, UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else {
                throw VoiceError(tr("Could not switch to the locked microphone “%@”. Reconnect it or switch to another microphone.", chosen.name))
            }
            var actual = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let verified = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size)
            guard verified == noErr, actual == chosen.id else {
                throw VoiceError(tr("Could not lock the microphone to “%@”. Input stopped.", chosen.name))
            }
        }
        // A device switch can leave the output bus at the previous device's rate. The input
        // scope describes the hardware; an input node cannot resample it when installing a tap.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw VoiceError(tr("The microphone offers no usable audio format. Check the sound input in System Settings."))
        }
        let (stream, sink) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(120))
        continuation = sink
        final class MeterGate: @unchecked Sendable { var lastReport: CFAbsoluteTime = 0 }
        let gate = MeterGate()
        // A route can change between reading the format and starting. Swift do/catch cannot
        // catch AVFAudio's NSException, so installation and startup stay in Objective-C.
        let started = QYStartAudioCapture(engine, format, { buffer, _ in
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
        guard started else {
            sink.finish()
            continuation = nil
            throw VoiceError(tr("Could not start the microphone. Check the permission, the input device and other apps that record."))
        }
        self.engine = engine
        let engineID = ObjectIdentifier(engine)
        let lockedUID = microphone
        let lockedLabel = boundLabel.isEmpty ? MicrophoneBinding.displayLabel(boundName: microphoneName, uid: microphone) : boundLabel
        if !lockedUID.isEmpty {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                let stillPresent = Microphone.available().contains { $0.uid == lockedUID }
                guard !stillPresent else { return }
                Task { @MainActor [weak self] in
                    guard let self, let current = self.engine, ObjectIdentifier(current) == engineID else { return }
                    self.stop(error: VoiceError(tr("The locked microphone “%@” was disconnected. Input stopped; what was recorded so far is kept.", lockedLabel)))
                }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, monitorQueue, listener) == noErr {
                deviceListener = listener
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { [weak self] _ in
                // The notification is posted on the engine's queue. Teardown there can deadlock.
                let boundGone = !lockedUID.isEmpty && !Microphone.available().contains(where: { $0.uid == lockedUID })
                Task { @MainActor [weak self] in
                    guard let self, let engine = self.engine, ObjectIdentifier(engine) == engineID else { return }
                    if boundGone {
                        self.stop(error: VoiceError(tr("The locked microphone “%@” was disconnected. Input stopped; what was recorded so far is kept.", lockedLabel)))
                    } else if !engine.isRunning {
                        self.stop(error: VoiceError(tr("The audio input device was interrupted. The recording so far is saved.")))
                    }
                }
            }
        // Also cover a change between successful startup and installing the observer.
        guard engine.isRunning, lockedUID.isEmpty || Microphone.available().contains(where: { $0.uid == lockedUID }) else {
            stop()
            if !lockedUID.isEmpty {
                throw VoiceError(tr("The locked microphone “%@” is disconnected, so there is no input.", lockedLabel))
            }
            throw VoiceError(tr("Could not start the microphone. Check the permission, the input device and other apps that record."))
        }
        return stream
    }

    func stop() {
        stop(error: nil)
    }

    private func stop(error: Error?) {
        if let listener = deviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, monitorQueue, listener)
            deviceListener = nil
        }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        if let error { continuation?.finish(throwing: error) }
        else { continuation?.finish() }
        continuation = nil
    }
}
