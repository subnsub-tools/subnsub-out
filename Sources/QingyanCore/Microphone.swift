import Foundation
import Network
import os

/// Another Mac's microphone as this Mac's out Mic (user 2026-11-27: the local microphone takes over the
/// remote Mac's, for any app there). The Mac that lends its microphone keeps a channel open to the
/// one it is lent to (Channel, trusted and sealed); that Mac says when an app there starts and stops
/// recording from out Mic (`{"want": true|false}`), and only meanwhile does the microphone run and
/// its sound travel, as frames of 10 ms: 48 kHz, one channel, 16 bits, as recorded. Out Mic Feed, a
/// hidden device of the out Mic driver, is where it is played, and out Mic gives it back to apps.
public enum MicWire {
    public static let rate = 48_000.0
    public static let block = 480
    /// The driver's two devices: the microphone apps pick, and the hidden one out plays into.
    public static let micUID = "OutMic_UID"
    public static let feedUID = "OutMicFeed_UID"

    /// One frame: its number, where its first sample is in the stream, and the samples.
    public static func frame(seq: UInt32, at: UInt64, samples: [Int16]) -> Data {
        var data = Data(capacity: 12 + samples.count * 2)
        withUnsafeBytes(of: seq.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: at.littleEndian) { data.append(contentsOf: $0) }
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    public static func parse(_ body: Data) -> (seq: UInt32, at: UInt64, samples: [Int16])? {
        // Exactly one block, at a place in the stream that cannot overflow on its way to a sample index.
        guard body.count == 12 + 2 * block else { return nil }
        let bytes = [UInt8](body)
        func value<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var result: T = 0
            for index in 0..<MemoryLayout<T>.size { result |= T(bytes[offset + index]) << (8 * index) }
            return result
        }
        var samples = [Int16](repeating: 0, count: (body.count - 12) / 2)
        for index in samples.indices { samples[index] = Int16(bitPattern: value(12 + index * 2, UInt16.self)) }
        let at = value(4, UInt64.self)
        guard at < 1 << 52 else { return nil }
        return (value(0, UInt32.self), at, samples)
    }
}

/// The samples that came, by their place in the sender's stream, played a fixed time behind the
/// newest. What stays deeper than that for two seconds (the two Macs' clocks drifting apart) is
/// skipped; a burst that the next moments drain is not. Nothing left to play (the microphone was
/// stopped, or the link stalled): silence, and the place waits until that fixed time has come in
/// again, so the stream stays whole and does not play on the edge. A frame far ahead of the place
/// (the sender went on through a stall) starts the stream again from it. Each slot keeps the index
/// of the sample in it, so a slot skipped or left from a turn of the ring before plays as silence.
public final class MicJitter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let size = 96_000
    private var ring: [Float]
    private var stamps: [Int64]
    private var newest: Int64 = -1
    private var reading: Int64 = -1
    private var lowest: Int64 = .max
    private var window = 0
    /// Waiting for `target` to come in before playing: at the start, and after running dry.
    private var filling = true
    /// Frames before this place belong to a recording that has ended, and are dropped.
    private var floor: Int64 = 0
    public let target: Int64
    public private(set) var skipped = 0
    public private(set) var waited = 0
    public private(set) var restarted = 0

    public init(milliseconds: Int = 60) {
        target = Int64(Double(milliseconds) / 1000 * MicWire.rate)
        ring = [Float](repeating: 0, count: size)
        stamps = [Int64](repeating: -1, count: size)
    }

    public func put(at frame: UInt64, samples: [Int16]) {
        guard samples.count == MicWire.block, frame < 1 << 52 else { return }
        let start = Int64(frame), end = start + Int64(samples.count)
        lock.withLock {
            guard start >= floor else { return }
            if reading < 0 || end - reading > Int64(size) {
                if reading >= 0 { restarted += 1 }
                reading = start
                newest = start
                filling = true
                lowest = .max
                window = 0
            }
            guard end > reading else { return }
            for (index, sample) in samples.enumerated() {
                let at = start + Int64(index)
                let slot = Int(at % Int64(size))
                ring[slot] = Float(sample) / 32767
                stamps[slot] = at
            }
            newest = max(newest, end)
        }
    }

    /// On the audio thread: it never waits for the lock; held by the network side, this cycle is silence.
    public func take(_ count: Int, into out: UnsafeMutablePointer<Float>) {
        let done = lock.withLockIfAvailable { () -> Bool in
            guard reading >= 0 else { return false }
            if filling {
                guard newest - reading >= target else { return false }
                filling = false
            }
            lowest = min(lowest, newest - reading)
            window += count
            if window >= Int(MicWire.rate * 2) {
                if lowest > target + Int64(MicWire.rate * 0.02) {
                    reading += lowest - target
                    skipped += 1
                }
                lowest = .max
                window = 0
            }
            let available = Int(max(0, min(Int64(count), newest - reading)))
            if available < count { filling = true; waited += 1; lowest = .max; window = 0 }
            guard available > 0 else { return false }
            for index in 0..<available {
                let at = reading + Int64(index)
                let slot = Int(at % Int64(size))
                out[index] = stamps[slot] == at ? ring[slot] : 0
            }
            for index in available..<count { out[index] = 0 }
            reading += Int64(available)
            return true
        }
        if done != true { for index in 0..<count { out[index] = 0 } }
    }

    /// The recording here ended: what is left is dropped, and so is any frame of it still on the way
    /// (the sender starts each time its microphone turns on at least a ring further on).
    public func reset() {
        lock.withLock {
            // Frames of it still on the way are at most a quarter second past the newest; the next
            // recording starts two rings on (MicrophoneOut.sessionGap), past this.
            floor = max(floor, max(newest, reading) + Int64(size))
            reading = -1
            newest = -1
            filling = true
            lowest = .max
            window = 0
        }
    }

    /// How far behind the newest sample the stream is played now, in milliseconds.
    public var depth: Double {
        lock.withLock { reading < 0 ? 0 : Double(newest - reading) / MicWire.rate * 1000 }
    }
}

/// This Mac's microphone on its way to another Mac: frames are sealed and sent without waiting; a
/// link that cannot keep up loses frames here rather than piling them up into delay.
public final class MicrophoneOut: @unchecked Sendable {
    private let channel: Channel
    private let lock = NSLock()
    private var seq: UInt32 = 0
    private var at: UInt64 = 0
    private var inFlight = 0
    private var closed = false
    private var ended = false
    private var endHandler: (@Sendable () -> Void)?
    private var wanted = false
    private var wantedAt: UInt64 = 0
    private var wantHandler: (@Sendable () -> Void)?
    /// The other Mac says again every two seconds that an app records; without that for this long,
    /// the microphone stops here (the other Mac hung, or its word was lost).
    private static let lease: UInt64 = 6_000_000_000
    /// Each time the microphone turns on, the stream goes on this far ahead (twice the receiving
    /// ring), so the other Mac can tell its frames from those of the recording before.
    public static let sessionGap: UInt64 = 192_000
    /// Frames waiting to leave at most: 250 ms.
    private static let mostInFlight = 25

    /// Called once, when the other Mac or the link ends the stream; at once if it has ended already.
    public func whenEnded(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        if ended { lock.unlock(); handler?(); return }
        endHandler = handler
        lock.unlock()
    }

    /// Called when the other Mac's apps start or stop recording; `isWanted` says which, now.
    public func whenWantChanges(_ handler: (@Sendable () -> Void)?) {
        lock.lock(); wantHandler = handler; lock.unlock()
    }

    /// Whether an app on the other Mac records from out Mic now, as it said within the lease: the
    /// microphone should run.
    public var isWanted: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && !ended && wanted && DispatchTime.now().uptimeNanoseconds - wantedAt < Self.lease
    }

    /// The microphone turned on: its frames start a session further on in the stream.
    public func beginSession() {
        lock.lock(); at += Self.sessionGap; lock.unlock()
    }

    private init(_ channel: Channel) { self.channel = channel }

    /// Asks a trusted Mac to take this Mac's microphone as its out Mic; its no says why, and whether
    /// to ask again soon (out Mic is being installed there). `again`: asked again by itself, not by a
    /// click, so the other Mac does not ask its owner for the password once more.
    public static func open(_ device: TrustedDevice, identity: DeviceIdentity, name: String, listening: Int, again: Bool,
                            timeout: TimeInterval = 8) async throws -> MicrophoneOut {
        let channel = try await Channel.open(host: device.host, port: device.port, identity: identity, name: name, listening: listening,
                                             queue: DispatchQueue(label: "local.hopo.qingyan.remote.mic"), timeout: timeout)
        guard channel.peerKey == device.key else {
            channel.close()
            throw VoiceError(tr("A different Mac answers at this address, not the paired “%@”.", device.label))
        }
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            channel.close()
        }
        defer { deadline.cancel() }
        let reply: [String: Any]
        do {
            try await channel.write(["mic": "open", "v": 2, "again": again])
            reply = try await channel.readObject()
        } catch {
            channel.close()
            throw VoiceError(tr("%@ did not answer. Make sure out is running there.", device.label))
        }
        guard reply["ok"] as? Bool == true else {
            channel.close()
            throw MicrophoneRefusal(message: reply["message"] as? String ?? tr("The two Macs run different versions of out. Update both to the same version."),
                                    wait: reply["wait"] as? Bool == true)
        }
        // An earlier out takes the stream at once and keeps it: the microphone would be on all the time.
        guard reply["demand"] as? Bool == true else {
            channel.close()
            throw MicrophoneRefusal(message: tr("The two Macs run different versions of out. Update both to the same version."), wait: false)
        }
        let out = MicrophoneOut(channel)
        out.watch()
        return out
    }

    /// Ten milliseconds of samples (`MicWire.block`).
    public func send(_ samples: [Int16]) {
        lock.lock()
        let count = UInt64(samples.count)
        defer { at += count; lock.unlock() }
        guard !closed, inFlight < Self.mostInFlight else { return }
        let body = MicWire.frame(seq: seq, at: at, samples: samples)
        seq &+= 1
        inFlight += 1
        channel.post(body: body) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.inFlight -= 1; self.lock.unlock()
        }
    }

    public func close() {
        lock.lock(); closed = true; lock.unlock()
        channel.close()
    }

    /// Taken back: the other Mac is told so (and gives its input back at once), then the channel closes.
    public func end() {
        lock.lock(); closed = true; lock.unlock()
        guard let body = try? JSONSerialization.data(withJSONObject: ["end": true]) else { channel.close(); return }
        let channel = channel
        channel.post(body: body) { channel.close() }
    }

    /// What the other Mac says: that its apps record, or stop; and the end, when it closes the channel.
    private func watch() {
        Task { [weak self] in
            guard let channel = self?.channel else { return }
            while let body = try? await channel.readBody() {
                guard let self, let object = try? RemoteWire.object(body), let want = object["want"] as? Bool else { continue }
                self.wantChanged(want)?()
            }
            self?.finished()
        }
    }

    private func wantChanged(_ want: Bool) -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        wanted = want
        wantedAt = DispatchTime.now().uptimeNanoseconds
        return wantHandler
    }

    private func finished() {
        lock.lock()
        ended = true
        let handler = endHandler
        endHandler = nil
        let want = wantHandler
        lock.unlock()
        want?()
        handler?()
    }
}

/// Another Mac's microphone coming in, from the moment this Mac said yes.
public final class MicrophoneIn: @unchecked Sendable {
    private let channel: Channel
    /// The sending Mac's key and its name in the list of Macs.
    public let key: String
    public let name: String

    init(channel: Channel, key: String, name: String) {
        self.channel = channel; self.key = key; self.name = name
    }

    /// The lending Mac took its microphone back, rather than the link ending.
    public private(set) var takenBack = false

    /// The next frame, or nil once the stream has ended.
    public func next() async -> (seq: UInt32, at: UInt64, samples: [Int16])? {
        while true {
            guard let body = try? await channel.readBody() else { return nil }
            if let frame = MicWire.parse(body) { return frame }
            if (try? RemoteWire.object(body))?["end"] as? Bool == true { takenBack = true; return nil }
        }
    }

    /// Tells the lending Mac whether an app here records from out Mic now; said again every two
    /// seconds, as the lease on its microphone.
    public func want(_ on: Bool) { channel.post(["want": on]) }

    public func close() { channel.close() }
}

/// The other Mac's no to a microphone; `wait`: ask again in a moment (out Mic is being installed there).
public struct MicrophoneRefusal: LocalizedError, Sendable {
    public let message: String
    public let wait: Bool
    public var errorDescription: String? { message }
}

/// What this Mac says to another Mac that would lend it its microphone.
public enum MicrophoneAnswer: Sendable {
    case yes
    /// Not yet: out Mic is being installed here.
    case wait(String)
    case no(String)
}
