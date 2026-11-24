//
//  ScreenSRTP.swift
//
//  SRTP and SRTCP for the UDP media of Apple Screen Sharing in its High
//  Performance mode: the host's video and sound arrive as SRTP packets, and
//  the viewer's RTCP feedback (reports and requests for a key frame) goes back
//  as SRTCP. This is a port of the Go client's srtp.go (helper/go/applehp),
//  checked against it byte for byte, including where it departs from RFC 3711.
//
//  Keys. Message 0x1c carries four key blobs of 46 bytes, which the viewer
//  makes: a master key for AES-256 (32 bytes) followed by a master salt (14
//  bytes). The "S" blobs key what the host sends (video, sound, and its RTCP),
//  the "V" blobs what the viewer sends. Each blob yields six session keys by
//  the AES counter-mode derivation of RFC 3711 with a key derivation rate of
//  zero: labels 0, 1 and 2 give the SRTP cipher key, authentication key and
//  salt, labels 3, 4 and 5 the same three for SRTCP.
//
//  Packets. The payload is encrypted with AES-256 in counter mode; the
//  counter block is the session salt with the SSRC, the rollover counter and
//  the sequence number folded in (SRTP), or the SSRC and the SRTCP index
//  (SRTCP). The tag is the first 10 bytes of HMAC-SHA1 over the packet, with
//  the rollover counter appended for SRTP. A received packet's header (fixed
//  part, CSRCs, extension) is returned in the clear and its padding is left
//  in the payload, as the Go code does.
//
//  Rollover. The receiver keeps, for each SSRC it has accepted a packet
//  from, the highest rollover counter and sequence number seen. A packet is
//  tried with a guessed rollover counter (the current one, one less when its
//  sequence number is more than 0x7fff above the highest, one more when it is
//  more than 0x7fff below), then the current one, the guess plus one and the
//  guess minus one, and accepted with the first whose tag matches. There is no
//  replay window: a packet received twice is accepted twice.
//
//  Speed. Cipher and MAC keys are set up once per key blob; a packet costs one
//  HMAC (one more per extra rollover counter tried) and one AES counter-mode
//  pass, with no allocation when it is decrypted in place.
//

import Foundation
import CommonCrypto

/// Why a key blob or a control packet was refused.
public enum ScreenSRTPError: Error, Equatable {
    /// A key blob that is not 46 bytes long; its length.
    case keyBlobLength(Int)
    /// CommonCrypto refused to set up or run AES; its status. Not expected on a working system.
    case cipherUnavailable(Int32)
    /// An SRTCP packet shorter than 22 bytes (8 of header, 4 of index, 10 of tag).
    case shortControlPacket
    /// An SRTCP packet whose tag does not match.
    case controlAuthenticationFailed
    /// An RTCP packet shorter than its 8-byte header, given to be encrypted.
    case shortRTCPPacket
}

/// The key blob of message 0x1c.
public enum ScreenSRTPKeyBlob {
    /// 32 bytes of AES-256 master key, then 14 bytes of master salt.
    public static let length = 46
}

/// What the receiver knows of one SSRC: the highest packet index it accepted.
public struct ScreenSRTPStreamState: Equatable, Sendable {
    /// The rollover counter of that packet (the number of times its sequence number wrapped).
    public var rolloverCounter: UInt32
    /// Its sequence number.
    public var highestSequence: UInt16

    public init(rolloverCounter: UInt32, highestSequence: UInt16) {
        self.rolloverCounter = rolloverCounter
        self.highestSequence = highestSequence
    }

    /// The extended highest sequence number of a receiver report: the rollover counter in the high
    /// 16 bits (its own high bits are lost), the sequence number in the low 16.
    public var extendedHighestSequence: UInt32 { (rolloverCounter << 16) | UInt32(highestSequence) }
}

/// A packet decrypted in place: where its parts are in the caller's buffer, and its header fields.
public struct ScreenSRTPPacketInfo: Equatable, Sendable {
    public let ssrc: UInt32
    public let sequence: UInt16
    public let timestamp: UInt32
    public let marker: Bool
    /// The low 7 bits of the second header byte.
    public let payloadType: UInt8
    /// The rollover counter the packet was authenticated with.
    public let rolloverCounter: UInt32
    /// Bytes of clear header at the start of the buffer: 12, the CSRCs, and the extension.
    public let headerLength: Int
    /// Bytes of decrypted payload after the header (padding included). The tag follows it.
    public let payloadLength: Int

    /// Where the payload is in the buffer that was decrypted.
    public var payloadRange: Range<Int> { headerLength ..< headerLength + payloadLength }
}

/// A packet decrypted into fresh storage.
public struct ScreenSRTPPacket: Equatable, Sendable {
    /// The clear header: 12 bytes, the CSRCs, and the extension.
    public let header: Data
    /// The decrypted payload (padding included); empty for a packet that is only a header.
    public let payload: Data
    public let ssrc: UInt32
    public let sequence: UInt16
    public let timestamp: UInt32
    public let marker: Bool
    /// The low 7 bits of the second header byte.
    public let payloadType: UInt8
    /// The rollover counter the packet was authenticated with.
    public let rolloverCounter: UInt32
}

// MARK: - Receiving SRTP

/// Authenticates and decrypts the SRTP packets of one key blob (the host's video, or its sound),
/// from any number of SSRCs, and keeps each SSRC's rollover counter.
///
/// Safe to use from several threads: every method takes the decryptor's lock, so a report built
/// from `stateSnapshot()` on one thread sees whole packets of the receiving thread. Packets are
/// meant to come from one receiving thread; two threads decrypting at once are serialised.
public final class ScreenSRTPDecryptor: @unchecked Sendable {

    /// The shortest datagram that can be a packet: a 12-byte header and the 10-byte tag.
    public static let minimumPacketLength = rtpHeaderLength + tagLength

    private struct Stream {
        var rolloverCounter: UInt32
        var highestSequence: UInt16
        var count: Int
    }

    private let keys: SessionKeys
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var streams: [UInt32: Stream] = [:]

    /// A receiver for a 46-byte key blob (Go: NewSRTPDecryptor).
    public init<Blob: ContiguousBytes>(keyBlob: Blob) throws {
        keys = try SessionKeys(keyBlob: keyBlob, firstLabel: 0)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Authenticates `packet` and decrypts its payload where it is (Go: Decrypt, without the copies).
    /// Returns nil, and leaves the buffer and the state as they were, for a packet that is too short,
    /// whose header runs past its end, or whose tag matches no rollover counter tried.
    public func decryptInPlace(_ packet: UnsafeMutableRawBufferPointer) -> ScreenSRTPPacketInfo? {
        guard packet.count >= Self.minimumPacketLength, let base = packet.baseAddress else { return nil }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let found = authenticateLocked(UnsafeRawPointer(base), packet.count) else { return nil }
        let (info, slot) = found
        if info.payloadLength > 0 {
            let at = base + info.headerLength
            guard keys.apply(srtpCounter(info), at, at, info.payloadLength) else { return nil }
        }
        commitLocked(info, slot)
        return info
    }

    /// Authenticates `packet` and returns its header and decrypted payload as new storage (Go: Decrypt).
    /// Returns nil, and leaves the state as it was, for a packet that is too short, whose header runs
    /// past its end, or whose tag matches no rollover counter tried.
    public func decrypt(_ packet: UnsafeRawBufferPointer) -> ScreenSRTPPacket? {
        guard packet.count >= Self.minimumPacketLength, let base = packet.baseAddress else { return nil }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let found = authenticateLocked(base, packet.count) else { return nil }
        let (info, slot) = found
        var payload = Data(count: info.payloadLength)
        if info.payloadLength > 0 {
            let done = payload.withUnsafeMutableBytes { out in
                keys.apply(srtpCounter(info), base + info.headerLength, out.baseAddress!, info.payloadLength)
            }
            guard done else { return nil }
        }
        commitLocked(info, slot)
        return ScreenSRTPPacket(header: Data(bytes: base, count: info.headerLength), payload: payload,
                                ssrc: info.ssrc, sequence: info.sequence, timestamp: info.timestamp,
                                marker: info.marker, payloadType: info.payloadType,
                                rolloverCounter: info.rolloverCounter)
    }

    /// `decrypt(_:)` for a packet held in `Data`.
    public func decrypt(_ packet: Data) -> ScreenSRTPPacket? {
        packet.withUnsafeBytes { decrypt($0) }
    }

    /// The highest packet index accepted from each SSRC, for receiver reports (Go: StateSnapshot).
    public func stateSnapshot() -> [UInt32: ScreenSRTPStreamState] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return streams.mapValues { ScreenSRTPStreamState(rolloverCounter: $0.rolloverCounter, highestSequence: $0.highestSequence) }
    }

    /// The number of packets accepted from each SSRC, replays included (Go: SSRCCounts).
    public func ssrcCounts() -> [UInt32: Int] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return streams.mapValues { $0.count }
    }

    // The header is checked first: it does not depend on the rollover counter, so a header that runs
    // past the end fails with every one of them (the Go code finds the same after the tag).
    private func authenticateLocked(_ base: UnsafeRawPointer, _ count: Int)
        -> (ScreenSRTPPacketInfo, Dictionary<UInt32, Stream>.Index?)? {
        let bodyLength = count - tagLength
        let first = base.load(as: UInt8.self)
        let second = base.load(fromByteOffset: 1, as: UInt8.self)
        var headerLength = rtpHeaderLength + Int(first & 0x0f) * 4
        if first & 0x10 != 0 {
            guard headerLength + 4 <= bodyLength else { return nil }
            headerLength += 4 + Int(loadBE16(base, headerLength + 2)) * 4
        }
        guard headerLength <= bodyLength else { return nil }
        let sequence = loadBE16(base, 2)
        let ssrc = loadBE32(base, 8)

        // The rollover counters to try, in the Go code's order, without repeats.
        let slot = streams.index(forKey: ssrc)
        var current: UInt32 = 0
        var guess: UInt32 = 0
        if let slot {
            let stream = streams.values[slot]
            current = stream.rolloverCounter
            let difference = Int32(sequence) - Int32(stream.highestSequence)
            if difference > 0x7fff {
                guess = current > 0 ? current - 1 : 0
            } else if difference < -0x7fff {
                guess = current &+ 1
            } else {
                guess = current
            }
        }
        var candidates: (UInt32, UInt32, UInt32, UInt32) = (guess, 0, 0, 0)
        var candidateCount = 1
        withUnsafeMutableBytes(of: &candidates) { raw in
            let list = raw.bindMemory(to: UInt32.self)
            func add(_ value: UInt32) {
                for i in 0..<candidateCount where list[i] == value { return }
                list[candidateCount] = value
                candidateCount += 1
            }
            add(current)
            add(guess &+ 1)
            if guess > 0 { add(guess - 1) }
        }

        guard let rolloverCounter = keys.authenticate(base, bodyLength, candidates, candidateCount) else { return nil }
        let info = ScreenSRTPPacketInfo(ssrc: ssrc, sequence: sequence, timestamp: loadBE32(base, 4),
                                        marker: second & 0x80 != 0, payloadType: second & 0x7f,
                                        rolloverCounter: rolloverCounter, headerLength: headerLength,
                                        payloadLength: bodyLength - headerLength)
        return (info, slot)
    }

    private func commitLocked(_ info: ScreenSRTPPacketInfo, _ slot: Dictionary<UInt32, Stream>.Index?) {
        guard let slot else {
            streams[info.ssrc] = Stream(rolloverCounter: info.rolloverCounter, highestSequence: info.sequence, count: 1)
            return
        }
        let new = UInt64(info.rolloverCounter) << 16 | UInt64(info.sequence)
        let old = UInt64(streams.values[slot].rolloverCounter) << 16 | UInt64(streams.values[slot].highestSequence)
        if new > old {
            streams.values[slot].rolloverCounter = info.rolloverCounter
            streams.values[slot].highestSequence = info.sequence
        }
        streams.values[slot].count += 1
    }

    private func srtpCounter(_ info: ScreenSRTPPacketInfo) -> (UInt64, UInt64) {
        (keys.saltHigh ^ UInt64(info.ssrc),
         keys.saltLow ^ UInt64(info.rolloverCounter) << 32 ^ UInt64(info.sequence) << 16)
    }
}

// MARK: - Sending SRTP

/// Makes SRTP packets of one SSRC (Go: SRTPEncryptor). The Go client sets one up for its sound
/// (AudioEnc) but sends nothing with it; the Go mock host sends its media with it.
///
/// Safe to use from several threads: `encrypt` takes the encryptor's lock, so packets get distinct
/// sequence numbers in the order the lock is taken.
public final class ScreenSRTPEncryptor: @unchecked Sendable {

    public let ssrc: UInt32
    private let keys: SessionKeys
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var sequence: UInt16
    private var rolloverCounter: UInt32
    private var timestamp: UInt32

    /// A sender for a 46-byte key blob and an SSRC (Go: NewSRTPEncryptor), whose first packet has
    /// the given sequence number, rollover counter and timestamp (Go starts all three at 0).
    public init<Blob: ContiguousBytes>(keyBlob: Blob, ssrc: UInt32, sequence: UInt16 = 0,
                                       rolloverCounter: UInt32 = 0, timestamp: UInt32 = 0) throws {
        keys = try SessionKeys(keyBlob: keyBlob, firstLabel: 0)
        self.ssrc = ssrc
        self.sequence = sequence
        self.rolloverCounter = rolloverCounter
        self.timestamp = timestamp
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// The timestamp of the next packet. Each packet adds 480 to it; the Go mock host sets it
    /// before each packet instead.
    public var nextTimestamp: UInt32 {
        get {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return timestamp
        }
        set {
            os_unfair_lock_lock(lock)
            timestamp = newValue
            os_unfair_lock_unlock(lock)
        }
    }

    /// One packet: a 12-byte header (version 2, no CSRC, no extension; the low 7 bits of
    /// `payloadType` and the marker), the encrypted payload and the 10-byte tag (Go: Encrypt).
    /// Throws only if CommonCrypto fails.
    public func encrypt(_ payload: Data, payloadType: UInt8, marker: Bool) throws -> Data {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let sequence = self.sequence, rolloverCounter = self.rolloverCounter, timestamp = self.timestamp
        if self.sequence == 0xffff {
            self.sequence = 0
            self.rolloverCounter &+= 1
        } else {
            self.sequence += 1
        }
        self.timestamp &+= 480

        let bodyLength = rtpHeaderLength + payload.count
        var out = Data(count: bodyLength + tagLength)
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            base.storeBytes(of: 0x80, as: UInt8.self)
            base.storeBytes(of: payloadType & 0x7f | (marker ? 0x80 : 0), toByteOffset: 1, as: UInt8.self)
            storeBE16(base, 2, sequence)
            storeBE32(base, 4, timestamp)
            storeBE32(base, 8, ssrc)
            if !payload.isEmpty {
                let counter = (keys.saltHigh ^ UInt64(ssrc),
                               keys.saltLow ^ UInt64(rolloverCounter) << 32 ^ UInt64(sequence) << 16)
                let status = payload.withUnsafeBytes { source in
                    keys.run(counter, source.baseAddress!, base + rtpHeaderLength, payload.count)
                }
                guard status == kCCSuccess else { return status }
            }
            keys.writeTag(base, bodyLength, rolloverCounter: rolloverCounter, into: base + bodyLength)
            return CCCryptorStatus(kCCSuccess)
        }
        guard status == kCCSuccess else { throw ScreenSRTPError.cipherUnavailable(status) }
        return out
    }
}

// MARK: - SRTCP

/// Encrypts and authenticates compound RTCP packets (Go: SRTCPEncryptor), with the "E" flag set
/// and an index that counts up from the first.
///
/// Safe to use from several threads: `protect` takes the encryptor's lock.
public final class ScreenSRTPControlEncryptor: @unchecked Sendable {

    private let keys: SessionKeys
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var index: UInt32

    /// A sender for a 46-byte key blob (Go: NewSRTCPEncryptor); the first packet gets index `index`
    /// (Go starts at 0).
    public init<Blob: ContiguousBytes>(keyBlob: Blob, index: UInt32 = 0) throws {
        keys = try SessionKeys(keyBlob: keyBlob, firstLabel: 3)
        self.index = index
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// The SRTCP packet for `packet` (Go: Protect): its first 8 bytes in the clear, the rest
    /// encrypted, then the index with the top bit set, then the 10-byte tag. The SSRC in bytes 4 to
    /// 7 keys the cipher. An index of 2^31 or more is written over the flag and used whole for the
    /// cipher, as the Go code does. A packet shorter than 8 bytes is refused and uses no index.
    public func protect(_ packet: Data) throws -> Data {
        guard packet.count >= 8 else { throw ScreenSRTPError.shortRTCPPacket }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let index = self.index
        self.index &+= 1

        var out = Data(count: packet.count + 4 + tagLength)
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            return packet.withUnsafeBytes { source in
                let input = source.baseAddress!
                base.copyMemory(from: input, byteCount: 8)
                if packet.count > 8 {
                    let counter = (keys.saltHigh ^ UInt64(loadBE32(input, 4)), keys.saltLow ^ UInt64(index) << 16)
                    let status = keys.run(counter, input + 8, base + 8, packet.count - 8)
                    guard status == kCCSuccess else { return status }
                }
                storeBE32(base, packet.count, 0x8000_0000 | index)
                keys.writeTag(base, packet.count + 4, rolloverCounter: nil, into: base + packet.count + 4)
                return CCCryptorStatus(kCCSuccess)
            }
        }
        guard status == kCCSuccess else { throw ScreenSRTPError.cipherUnavailable(status) }
        return out
    }
}

/// Authenticates and decrypts SRTCP packets (Go: SRTCPDecryptor). The Go client sets one up for
/// the host's RTCP (CtrlDec) but reads nothing with it.
///
/// Safe to use from several threads: `unprotect` takes the decryptor's lock.
public final class ScreenSRTPControlDecryptor: @unchecked Sendable {

    private let keys: SessionKeys
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    /// A receiver for a 46-byte key blob (Go: NewSRTCPDecryptor).
    public init<Blob: ContiguousBytes>(keyBlob: Blob) throws {
        keys = try SessionKeys(keyBlob: keyBlob, firstLabel: 3)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// The RTCP packet inside `packet` (Go: Unprotect): its first 8 bytes and the rest, decrypted
    /// when the index's top bit says so. No replay check is made.
    public func unprotect(_ packet: Data) throws -> Data {
        guard packet.count >= 8 + 4 + tagLength else { throw ScreenSRTPError.shortControlPacket }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try packet.withUnsafeBytes { source in
            let input = source.baseAddress!
            let bodyLength = packet.count - tagLength
            guard keys.tagMatches(input, bodyLength) else { throw ScreenSRTPError.controlAuthenticationFailed }
            let flagged = loadBE32(input, bodyLength - 4)
            let encryptedLength = bodyLength - 4 - 8
            var out = Data(count: 8 + encryptedLength)
            let status: CCCryptorStatus = out.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!
                base.copyMemory(from: input, byteCount: 8)
                guard encryptedLength > 0 else { return CCCryptorStatus(kCCSuccess) }
                guard flagged & 0x8000_0000 != 0 else {
                    (base + 8).copyMemory(from: input + 8, byteCount: encryptedLength)
                    return CCCryptorStatus(kCCSuccess)
                }
                let counter = (keys.saltHigh ^ UInt64(loadBE32(input, 4)),
                               keys.saltLow ^ UInt64(flagged & 0x7fff_ffff) << 16)
                return keys.run(counter, input + 8, base + 8, encryptedLength)
            }
            guard status == kCCSuccess else { throw ScreenSRTPError.cipherUnavailable(status) }
            return out
        }
    }
}

// MARK: - RTCP packets

/// The RTCP packets the viewer sends (Go: BuildEmptySR, BuildRR, BuildAVPFFIR, BuildPLI,
/// BuildLegacyFIR). The Go client sends a sender report and a receiver report every second,
/// with the three requests for a key frame after them when it wants one.
public enum ScreenSRTPControlPacket {

    /// A sender report (type 200) with no report blocks and zero counts, so the host takes the
    /// viewer's SSRC as live, stamped with the current time.
    public static func emptySenderReport(senderSSRC: UInt32) -> Data {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return emptySenderReport(senderSSRC: senderSSRC, unixSeconds: Int64(now.tv_sec), nanoseconds: Int(now.tv_nsec))
    }

    /// The sender report for a given time (seconds since 1970 and nanoseconds within the second).
    /// The RTP timestamp is the Go code's: Unix time in nanoseconds times 90000, wrapped to 64 bits,
    /// over 10^9, cut to 32 bits.
    public static func emptySenderReport(senderSSRC: UInt32, unixSeconds: Int64, nanoseconds: Int) -> Data {
        let unixNanoseconds = unixSeconds &* 1_000_000_000 &+ Int64(nanoseconds)
        var bytes = [UInt8](repeating: 0, count: 28)
        bytes[0] = 0x80
        bytes[1] = 200
        bytes[3] = 6
        putBE32(&bytes, 4, senderSSRC)
        putBE32(&bytes, 8, UInt32(truncatingIfNeeded: unixSeconds &+ ntpEpochOffset))
        putBE32(&bytes, 12, UInt32(truncatingIfNeeded: (UInt64(truncatingIfNeeded: nanoseconds) << 32) / 1_000_000_000))
        putBE32(&bytes, 16, UInt32(truncatingIfNeeded: (UInt64(bitPattern: unixNanoseconds) &* 90_000) / 1_000_000_000))
        return Data(bytes)
    }

    /// A receiver report (type 201) with a block for each of the first 31 `sources`, in that order,
    /// carrying only the SSRC and its extended highest sequence number from `states` (zero for a
    /// source not in it). With no sources it is the 8-byte header alone.
    public static func receiverReport(senderSSRC: UInt32, sources: [UInt32],
                                      states: [UInt32: ScreenSRTPStreamState]) -> Data {
        let count = min(sources.count, 31)
        var bytes = [UInt8](repeating: 0, count: 8 + count * 24)
        bytes[0] = 0x80 | UInt8(count)
        bytes[1] = 201
        putBE16(&bytes, 2, UInt16(1 + count * 6))
        putBE32(&bytes, 4, senderSSRC)
        for i in 0..<count {
            let source = sources[i]
            putBE32(&bytes, 8 + i * 24, source)
            putBE32(&bytes, 8 + i * 24 + 8, states[source]?.extendedHighestSequence ?? 0)
        }
        return Data(bytes)
    }

    /// The full intra request of RFC 2032 (type 192), which the host's screensharingd reliably
    /// answers with a key frame.
    public static func legacyFullIntraRequest(targetSSRC: UInt32) -> Data {
        var bytes: [UInt8] = [0x80, 192, 0, 1, 0, 0, 0, 0]
        putBE32(&bytes, 4, targetSSRC)
        return Data(bytes)
    }

    /// The full intra request of RFC 5104 (type 206, format 4) with one entry.
    public static func fullIntraRequest(senderSSRC: UInt32, targetSSRC: UInt32, sequenceNumber: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x80 | 4
        bytes[1] = 206
        bytes[3] = 4
        putBE32(&bytes, 4, senderSSRC)
        putBE32(&bytes, 12, targetSSRC)
        bytes[16] = sequenceNumber
        return Data(bytes)
    }

    /// The picture loss indication of RFC 4585 (type 206, format 1).
    public static func pictureLossIndication(senderSSRC: UInt32, mediaSSRC: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = 0x80 | 1
        bytes[1] = 206
        bytes[3] = 2
        putBE32(&bytes, 4, senderSSRC)
        putBE32(&bytes, 8, mediaSSRC)
        return Data(bytes)
    }
}

// MARK: - Keys and primitives

fileprivate let rtpHeaderLength = 12
fileprivate let tagLength = 10
fileprivate let masterKeyLength = 32
fileprivate let masterSaltLength = 14
fileprivate let ntpEpochOffset: Int64 = 2_208_988_800
fileprivate let sha1Algorithm = CCHmacAlgorithm(kCCHmacAlgSHA1)

/// Whether a copy of a CCHmacContext carries on independently of the original. The context is a
/// plain block of storage in CommonCrypto; this is checked once anyway, and without it every MAC
/// starts from the key again.
fileprivate let hmacContextCopies: Bool = {
    let key = (0..<20).map { UInt8($0 * 13 + 1) }
    let message = (0..<200).map { UInt8(truncatingIfNeeded: $0 * 7) }
    var expected = [UInt8](repeating: 0, count: 20)
    CCHmac(sha1Algorithm, key, key.count, message, message.count, &expected)
    var template = CCHmacContext()
    CCHmacInit(&template, sha1Algorithm, key, key.count)
    var half = template
    message.withUnsafeBytes { CCHmacUpdate(&half, $0.baseAddress, 100) }
    for _ in 0..<2 {
        var copy = half
        message.withUnsafeBytes { CCHmacUpdate(&copy, $0.baseAddress! + 100, 100) }
        var got = [UInt8](repeating: 0, count: 20)
        CCHmacFinal(&copy, &got)
        if got != expected { return false }
    }
    var whole = template
    CCHmacUpdate(&whole, message, message.count)
    var got = [UInt8](repeating: 0, count: 20)
    CCHmacFinal(&whole, &got)
    return got == expected
}()

/// The three session keys of one key blob for SRTP (labels 0 to 2) or SRTCP (labels 3 to 5): an
/// AES-256 counter-mode cryptor, an HMAC-SHA1 context keyed once, and the session salt as two
/// big-endian words (the low 16 bits of the second are the block counter's place).
fileprivate final class SessionKeys {
    let saltHigh: UInt64
    let saltLow: UInt64
    private let cryptor: CCCryptorRef
    private let authenticationKey: [UInt8]
    private var macTemplate = CCHmacContext()
    private let copies = hmacContextCopies

    init<Blob: ContiguousBytes>(keyBlob: Blob, firstLabel: UInt8) throws {
        let derived: (cipher: [UInt8], authentication: [UInt8], salt: [UInt8]) = try keyBlob.withUnsafeBytes { blob in
            guard blob.count == ScreenSRTPKeyBlob.length else { throw ScreenSRTPError.keyBlobLength(blob.count) }
            let masterKey = UnsafeRawBufferPointer(rebasing: blob[0..<masterKeyLength])
            let masterSalt = UnsafeRawBufferPointer(rebasing: blob[masterKeyLength..<ScreenSRTPKeyBlob.length])
            return (try deriveSessionKey(masterKey, masterSalt, label: firstLabel, length: 32),
                    try deriveSessionKey(masterKey, masterSalt, label: firstLabel + 1, length: 20),
                    try deriveSessionKey(masterKey, masterSalt, label: firstLabel + 2, length: 14))
        }
        var salt = derived.salt + [0, 0]
        saltHigh = loadBE64(&salt, 0)
        saltLow = loadBE64(&salt, 8)

        var made: CCCryptorRef?
        let zeroCounter = [UInt8](repeating: 0, count: 16)
        let status = CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                             CCPadding(ccNoPadding), zeroCounter, derived.cipher, derived.cipher.count,
                                             nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &made)
        guard status == kCCSuccess, let made else { throw ScreenSRTPError.cipherUnavailable(status) }
        cryptor = made
        authenticationKey = derived.authentication
        CCHmacInit(&macTemplate, sha1Algorithm, authenticationKey, authenticationKey.count)
    }

    deinit {
        CCCryptorRelease(cryptor)
    }

    /// AES-256 in counter mode from the counter block `counter`, `count` bytes from `source` to
    /// `destination` (which may be the same place).
    func run(_ counter: (UInt64, UInt64), _ source: UnsafeRawPointer, _ destination: UnsafeMutableRawPointer,
             _ count: Int) -> CCCryptorStatus {
        var block = (counter.0.bigEndian, counter.1.bigEndian)
        let reset = withUnsafeBytes(of: &block) { CCCryptorReset(cryptor, $0.baseAddress) }
        guard reset == kCCSuccess else { return reset }
        var moved = 0
        let status = CCCryptorUpdate(cryptor, source, count, destination, count, &moved)
        return status == kCCSuccess && moved != count ? CCCryptorStatus(kCCUnspecifiedError) : status
    }

    func apply(_ counter: (UInt64, UInt64), _ source: UnsafeRawPointer, _ destination: UnsafeMutableRawPointer,
               _ count: Int) -> Bool {
        run(counter, source, destination, count) == kCCSuccess
    }

    private func startMAC() -> CCHmacContext {
        if copies { return macTemplate }
        var context = CCHmacContext()
        CCHmacInit(&context, sha1Algorithm, authenticationKey, authenticationKey.count)
        return context
    }

    /// The first of `candidates` (the first `count` of them) whose SRTP tag, over the `bodyLength`
    /// bytes at `base` and that rollover counter, is the 10 bytes after them.
    func authenticate(_ base: UnsafeRawPointer, _ bodyLength: Int, _ candidates: (UInt32, UInt32, UInt32, UInt32),
                      _ count: Int) -> UInt32? {
        var candidates = candidates
        return withUnsafeBytes(of: &candidates) { raw -> UInt32? in
            let list = raw.bindMemory(to: UInt32.self)
            var body = startMAC()
            if copies { CCHmacUpdate(&body, base, bodyLength) }
            for i in 0..<count {
                var context: CCHmacContext
                if copies {
                    context = body
                } else {
                    context = startMAC()
                    CCHmacUpdate(&context, base, bodyLength)
                }
                var rolloverCounter = list[i].bigEndian
                CCHmacUpdate(&context, &rolloverCounter, 4)
                if finishAndCompare(&context, base + bodyLength) { return list[i] }
            }
            return nil
        }
    }

    /// Whether the SRTCP tag over the `bodyLength` bytes at `base` is the 10 bytes after them.
    func tagMatches(_ base: UnsafeRawPointer, _ bodyLength: Int) -> Bool {
        var context = startMAC()
        CCHmacUpdate(&context, base, bodyLength)
        return finishAndCompare(&context, base + bodyLength)
    }

    /// Writes the tag over the `bodyLength` bytes at `base` (and the rollover counter, for SRTP).
    func writeTag(_ base: UnsafeRawPointer, _ bodyLength: Int, rolloverCounter: UInt32?,
                  into destination: UnsafeMutableRawPointer) {
        var context = startMAC()
        CCHmacUpdate(&context, base, bodyLength)
        if let rolloverCounter {
            var big = rolloverCounter.bigEndian
            CCHmacUpdate(&context, &big, 4)
        }
        var mac: (UInt64, UInt64, UInt32) = (0, 0, 0)
        withUnsafeMutableBytes(of: &mac) { CCHmacFinal(&context, $0.baseAddress) }
        withUnsafeBytes(of: &mac) { destination.copyMemory(from: $0.baseAddress!, byteCount: tagLength) }
    }

    // Compares in constant time, as Go's hmac.Equal does.
    private func finishAndCompare(_ context: inout CCHmacContext, _ tag: UnsafeRawPointer) -> Bool {
        var mac: (UInt64, UInt64, UInt32) = (0, 0, 0)
        withUnsafeMutableBytes(of: &mac) { CCHmacFinal(&context, $0.baseAddress) }
        return withUnsafeBytes(of: &mac) { computed in
            let head = computed.loadUnaligned(as: UInt64.self) ^ tag.loadUnaligned(as: UInt64.self)
            let tail = computed.loadUnaligned(fromByteOffset: 8, as: UInt16.self)
                ^ tag.loadUnaligned(fromByteOffset: 8, as: UInt16.self)
            return head | UInt64(tail) == 0
        }
    }
}

/// RFC 3711 section 4.3.1 with a key derivation rate of zero: AES-256 of the master salt with the
/// label in byte 7 and a block counter in bytes 14 and 15, as many blocks as `length` needs.
fileprivate func deriveSessionKey(_ masterKey: UnsafeRawBufferPointer, _ masterSalt: UnsafeRawBufferPointer,
                                  label: UInt8, length: Int) throws -> [UInt8] {
    let blocks = (length + 15) / 16
    var input = [UInt8](repeating: 0, count: blocks * 16)
    for block in 0..<blocks {
        for i in 0..<masterSaltLength { input[block * 16 + i] = masterSalt[i] }
        input[block * 16 + 7] ^= label
        input[block * 16 + 14] = UInt8(block >> 8)
        input[block * 16 + 15] = UInt8(block & 0xff)
    }
    var output = [UInt8](repeating: 0, count: blocks * 16)
    var moved = 0
    let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                         masterKey.baseAddress, masterKey.count, nil, input, input.count,
                         &output, output.count, &moved)
    guard status == kCCSuccess else { throw ScreenSRTPError.cipherUnavailable(status) }
    return Array(output[0..<length])
}

fileprivate func loadBE16(_ base: UnsafeRawPointer, _ offset: Int) -> UInt16 {
    UInt16(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
}

fileprivate func loadBE32(_ base: UnsafeRawPointer, _ offset: Int) -> UInt32 {
    UInt32(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
}

fileprivate func loadBE64(_ base: UnsafeRawPointer, _ offset: Int) -> UInt64 {
    UInt64(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
}

fileprivate func storeBE16(_ base: UnsafeMutableRawPointer, _ offset: Int, _ value: UInt16) {
    base.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt16.self)
}

fileprivate func storeBE32(_ base: UnsafeMutableRawPointer, _ offset: Int, _ value: UInt32) {
    base.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt32.self)
}

fileprivate func putBE16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
    bytes[offset] = UInt8(value >> 8)
    bytes[offset + 1] = UInt8(value & 0xff)
}

fileprivate func putBE32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
    for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * i)) }
}
