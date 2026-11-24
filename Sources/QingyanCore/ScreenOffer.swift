//
//  ScreenOffer.swift
//
//  The media offer a client of Apple Screen Sharing sends in High Performance
//  mode, the binary property lists the offer and the answer travel in, and the
//  reading of the answer: the size the host's encoder will draw at.
//
//  An offer is a binary property list (bplist00) for each stream, the video in
//  negotiator mode 7 and the sound in mode 8, with four entries: the endpoint
//  information (a small protobuf message naming this Mac's hardware model and
//  system build), the mode, the media blob compressed with zlib, and a call
//  identifier. The media blob is a protobuf message. For video it describes
//  the stream in its field 5: the session's SSRC, the codec banks (the bank
//  numbered 123 makes the host send H.264 4:2:0 and the one numbered 100 HEVC,
//  the reverse of what their parameter strings say), the tiles each picture is
//  cut into, and whether long-term reference pictures are wanted. For sound it
//  describes the stream in its field 3, with a rate the host sends at (24191)
//  or one too low for it to send anything (1000). Both carry the bandwidth
//  table (field 9, repeated), whose ceilings can be lowered to a bit rate of
//  the caller's.
//
//  Everything here writes the same bytes as the Go helper it replaces, for the
//  same session identifier, timestamp and call identifier: the property list
//  writer, the protobuf writer, and the zlib stream, which follows Go 1.27's
//  compress/zlib at its default level (a port of its level 6 encoder and of
//  its block writer). The zlib reader is a port of Go's as well, so that a
//  blob that is cut short or broken gives no size in exactly the cases where
//  the helper gave none, and the same size where it read one.
//
//  The answer as macOS 15 sends it is a framebuffer update whose first
//  rectangle (encoding 0x3f2) holds a property list for each stream, the sound
//  first, laid out by lengths; an answer laid out otherwise is searched for
//  property lists. The size is in the video blob: width, height and tiles are
//  fields 4, 5 and 6 of its field 5. A size above 16384 is not a display and
//  is ignored, and no blob is read past 256 KiB.
//
//  Decoded property list strings are Swift strings: where the helper kept the
//  raw bytes of a string marked ASCII that is not valid UTF-8, the string here
//  has U+FFFD in their place, and two keys that differ only by Unicode
//  canonical equivalence are one key here. Neither can change a media blob or
//  a size, since the keys looked up are plain ASCII.
//

import Foundation

// MARK: - Options and results

/// What an offer asks of the host. The defaults are the Go helper's zero values.
public struct ScreenOfferOptions: Equatable, Sendable {
    /// "avc", "hevc" or "both", compared without case; any other text is "both". Empty is "avc".
    public var codec: String
    /// The tiles each picture is cut into. Zero or less picks 1 for "avc" and 4 otherwise.
    public var tilesPerFrame: Int
    /// When false the sound is offered at a rate too low for the host to send any.
    public var audioEnabled: Bool
    /// Long-term reference pictures. Never offered with "avc".
    public var ltrp: Bool
    /// Above zero, every bandwidth ceiling of the offer is lowered to at most this many bits a
    /// second. A ceiling, not a rate: the host's encoder stays under it.
    public var maxBitrate: Int

    public init(codec: String = "", tilesPerFrame: Int = 0, audioEnabled: Bool = false,
                ltrp: Bool = false, maxBitrate: Int = 0) {
        self.codec = codec
        self.tilesPerFrame = tilesPerFrame
        self.audioEnabled = audioEnabled
        self.ltrp = ltrp
        self.maxBitrate = maxBitrate
    }
}

/// The size an answer says the host's encoder draws at.
public struct ScreenOfferCanvas: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var tiles: Int

    public init(width: Int, height: Int, tiles: Int) {
        self.width = width
        self.height = height
        self.tiles = tiles
    }
}

/// The two offers of a session, as property lists, and the SSRCs they name.
public struct ScreenOfferPair: Equatable, Sendable {
    public var video: [UInt8]
    public var audio: [UInt8]
    public var videoSSRC: UInt32
    public var audioSSRC: UInt32
}

public enum ScreenOfferError: Error, Equatable, Sendable {
    /// A negotiator mode other than 7 (video) or 8 (sound).
    case unsupportedMode(Int)
}

// MARK: - Offers

public enum ScreenOffer {
    /// The negotiator mode of the video offer.
    public static let videoMode = 7
    /// The negotiator mode of the sound offer.
    public static let audioMode = 8
    /// The rectangle encoding of the answer as macOS 15 sends it (0x3f2).
    public static let mediaInitEncoding: Int32 = 1010
    /// Sizes above this in an answer are not a display, and are ignored.
    public static let canvasMax = 16384
    /// What is read of a compressed blob of an answer, at most.
    public static let blobReadLimit = 256 * 1024

    fileprivate static let audioF4On: UInt64 = 24191
    fileprivate static let audioF4Off: UInt64 = 1000

    /// The offers of a session: video (mode 7) and then sound (mode 8), each with a new random
    /// SSRC and call identifier.
    public static func createOffers(_ options: ScreenOfferOptions) throws -> ScreenOfferPair {
        let video = try offerPlist(mode: videoMode, options: options)
        let audio = try offerPlist(mode: audioMode, options: options)
        return ScreenOfferPair(video: video.plist, audio: audio.plist, videoSSRC: video.ssrc, audioSSRC: audio.ssrc)
    }

    /// One offer with a random SSRC (its return), the wall clock's nanoseconds as timestamp, a
    /// random call identifier, and this Mac's endpoint information.
    public static func offerPlist(mode: Int, options: ScreenOfferOptions) throws -> (plist: [UInt8], ssrc: UInt32) {
        var rng = SystemRandomNumberGenerator()
        let sid = UInt32.random(in: UInt32.min...UInt32.max, using: &rng)
        let ts = UInt64(clock_gettime_nsec_np(CLOCK_REALTIME))
        var callID = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { callID[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
        let plist = try offerPlist(mode: mode, options: options, sessionID: sid, timestamp: ts,
                                   callID: callID, endpointInfo: remoteEndpointInfo)
        return (plist, sid)
    }

    /// One offer from given parts: the same bytes as the helper's for the same parts. callID is
    /// 16 random bytes, made a version 4 UUID here (missing bytes count as zero).
    public static func offerPlist(mode: Int, options: ScreenOfferOptions, sessionID: UInt32, timestamp: UInt64,
                                  callID: [UInt8], endpointInfo: [UInt8]) throws -> [UInt8] {
        let blob = try mediaBlob(mode: mode, sessionID: sessionID, timestamp: timestamp, options: options)
        return try ScreenPlist.encodeDict([
            "avcMediaStreamOptionRemoteEndpointInfo": .data(endpointInfo),
            "avcMediaStreamNegotiatorMode": .int(Int64(mode)),
            "avcMediaStreamNegotiatorMediaBlob": .data(zlibCompress(blob)),
            "avcMediaStreamOptionCallID": .string(callIDString(callID)),
        ])
    }

    /// The call identifier's text: 16 bytes with the version and variant bits of a version 4
    /// UUID set, in upper-case hex.
    public static func callIDString(_ random: [UInt8]) -> String {
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<min(16, random.count) { b[i] = random[i] }
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        let digits = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        for (i, v) in b.enumerated() {
            if i == 4 || i == 6 || i == 8 || i == 10 { out.append(UInt8(ascii: "-")) }
            out.append(digits[Int(v >> 4)])
            out.append(digits[Int(v & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The media blob, before compression (the helper's buildMediaBlob).
    public static func mediaBlob(mode: Int, sessionID: UInt32, timestamp: UInt64,
                                 options opts: ScreenOfferOptions) throws -> [UInt8] {
        var codec = opts.codec.lowercased()
        if codec.isEmpty { codec = "avc" }
        var tiles = opts.tilesPerFrame
        if tiles <= 0 { tiles = codec == "avc" ? 1 : 4 }
        let ltrpOn = codec != "avc" && opts.ltrp

        var descField: [UInt8] = []
        switch mode {
        case 7:
            let hevcParams = Array((ltrpOn
                ? "FLS;MS:-1;LF:-1;LTR;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;"
                : "FLS;MS:-1;LF:-1;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;").utf8)
            let avcParams = Array("FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;AR:16/9,5/8;XR:16/9,5/8;".utf8)

            var resEntry: [UInt8] = []
            appendFieldVarint(&resEntry, 1, 1)
            appendFieldVarint(&resEntry, 2, 1)
            appendFieldVarint(&resEntry, 3, 50115)
            appendFieldVarint(&resEntry, 4, 0)
            var resEntryAlt: [UInt8] = []
            appendFieldVarint(&resEntryAlt, 1, 1)
            appendFieldVarint(&resEntryAlt, 2, 2)
            appendFieldVarint(&resEntryAlt, 3, 50115)
            appendFieldVarint(&resEntryAlt, 4, 0)

            // The host's answer is the reverse of the banks' parameter names: field 1 = 123
            // yields H.264 4:2:0, field 1 = 100 yields HEVC.
            var bankYieldsH264: [UInt8] = []
            appendFieldVarint(&bankYieldsH264, 1, 123)
            appendFieldBytes(&bankYieldsH264, 2, resEntry)
            appendFieldBytes(&bankYieldsH264, 2, resEntryAlt)
            appendFieldBytes(&bankYieldsH264, 2, resEntry)
            appendFieldBytes(&bankYieldsH264, 2, resEntryAlt)
            appendFieldBytes(&bankYieldsH264, 3, hevcParams)
            appendFieldVarint(&bankYieldsH264, 4, 1)

            var bankYieldsHEVC: [UInt8] = []
            appendFieldVarint(&bankYieldsHEVC, 1, 100)
            appendFieldBytes(&bankYieldsHEVC, 2, resEntry)
            appendFieldBytes(&bankYieldsHEVC, 2, resEntryAlt)
            appendFieldBytes(&bankYieldsHEVC, 3, avcParams)
            appendFieldVarint(&bankYieldsHEVC, 4, 14)

            var banks: [UInt8] = []
            switch codec {
            case "avc":
                appendFieldBytes(&banks, 3, bankYieldsH264)
            case "hevc":
                appendFieldBytes(&banks, 3, bankYieldsHEVC)
            default:
                appendFieldBytes(&banks, 3, bankYieldsH264)
                appendFieldBytes(&banks, 3, bankYieldsHEVC)
            }

            let ltrpBit: UInt64 = ltrpOn ? 1 : 0
            var desc: [UInt8] = []
            appendFieldVarint(&desc, 1, UInt64(sessionID))
            appendFieldVarint(&desc, 2, ltrpBit)
            desc += banks
            appendFieldVarint(&desc, 6, UInt64(tiles))
            appendFieldVarint(&desc, 7, ltrpBit)
            appendFieldVarint(&desc, 8, 63)
            appendFieldVarint(&desc, 9, 1)
            appendFieldVarint(&desc, 12, 1)
            appendFieldBytes(&descField, 5, desc)

        case 8:
            let f4 = opts.audioEnabled ? audioF4On : audioF4Off
            var desc: [UInt8] = []
            appendFieldVarint(&desc, 1, UInt64(sessionID))
            appendFieldVarint(&desc, 2, 0)
            appendFieldVarint(&desc, 3, 0)
            appendFieldVarint(&desc, 4, f4)
            appendFieldVarint(&desc, 5, 0)
            appendFieldVarint(&desc, 6, 0)
            appendFieldBytes(&descField, 3, desc)

        default:
            throw ScreenOfferError.unsupportedMode(mode)
        }

        var blob: [UInt8] = []
        appendFieldVarint(&blob, 1, 1)
        appendFieldVarint(&blob, 2, 1)
        blob += descField
        appendFieldBytes(&blob, 6, Array("subnsub-hp 1.0".utf8))
        appendFieldVarint(&blob, 8, 0)
        blob += opts.maxBitrate > 0 ? bandwidthBytes(maxBitrate: opts.maxBitrate) : audioF9Bytes
        appendFieldVarint(&blob, 13, timestamp)
        appendFieldVarint(&blob, 14, 2)
        appendFieldVarint(&blob, 16, 0)
        appendFieldVarint(&blob, 18, 1)
        return blob
    }

    /// An entry of the bandwidth table: field 1, field 2 (a ceiling in bits a second when it is
    /// a million or more), and field 3 when there is one.
    fileprivate struct AudioF9Level {
        var f1: UInt64
        var f2: UInt64
        var hasF3: Bool
        var f3: UInt64
    }

    fileprivate static let canonicalAudioF9Levels: [AudioF9Level] = [
        AudioF9Level(f1: 0, f2: 40_000_000, hasF3: true, f3: 12288),
        AudioF9Level(f1: 0, f2: 6_000_000, hasF3: true, f3: 131072),
        AudioF9Level(f1: 4074, f2: 0, hasF3: true, f3: 16384),
        AudioF9Level(f1: 16, f2: 4100, hasF3: false, f3: 0),
        AudioF9Level(f1: 0, f2: 75_000_000, hasF3: true, f3: 524288),
        AudioF9Level(f1: 0, f2: 20_000_000, hasF3: true, f3: 98304),
        AudioF9Level(f1: 4, f2: 6500, hasF3: false, f3: 0),
        AudioF9Level(f1: 0, f2: 60_000_000, hasF3: true, f3: 262144),
        AudioF9Level(f1: 1, f2: 299, hasF3: false, f3: 0),
        AudioF9Level(f1: 0, f2: 100_000_000, hasF3: true, f3: 1048576),
    ]

    /// The bandwidth table (the blob's repeated field 9; "audio" in the helper's names for it is
    /// historical). Entries that name a ceiling in bits a second are lowered to maxBitrate when it
    /// is above zero; the others go out as they are.
    public static func bandwidthBytes(maxBitrate: Int) -> [UInt8] {
        var out: [UInt8] = []
        for level in canonicalAudioF9Levels {
            var t = level
            if maxBitrate > 0 && t.f2 >= 1_000_000 && t.f2 > UInt64(maxBitrate) {
                t.f2 = UInt64(maxBitrate)
            }
            var body: [UInt8] = []
            appendFieldVarint(&body, 1, t.f1)
            appendFieldVarint(&body, 2, t.f2)
            if t.hasF3 { appendFieldVarint(&body, 3, t.f3) }
            appendFieldBytes(&out, 9, body)
        }
        return out
    }

    /// The bandwidth table as it goes out when no bit rate is set.
    public static let audioF9Bytes: [UInt8] = bandwidthBytes(maxBitrate: 0)

    /// This Mac's endpoint information: its hardware model (hw.model) and system build
    /// (kern.osversion, what sw_vers -buildVersion prints), read once.
    public static let remoteEndpointInfo: [UInt8] = {
        #if arch(x86_64)
        var model = "darwin-amd64"
        #else
        var model = "darwin-arm64"
        #endif
        var build = "1.0"
        if let s = sysctlString("hw.model")?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            model = s
        }
        if let s = sysctlString("kern.osversion")?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            build = s
        }
        return endpointInfo(hardwareModel: model, osBuild: build)
    }()

    /// The endpoint information for a hardware model and system build.
    public static func endpointInfo(hardwareModel: String, osBuild: String) -> [UInt8] {
        var b: [UInt8] = [0x08, 0x00, 0x10, 0x01]
        appendLengthPrefixedTag(&b, 0x1a, hardwareModel)
        appendLengthPrefixedTag(&b, 0x22, "1.0.0")
        appendLengthPrefixedTag(&b, 0x2a, osBuild)
        return b
    }

    /// A tag, a one-byte length and the text's UTF-8, cut to 127 bytes.
    public static func appendLengthPrefixedTag(_ dst: inout [UInt8], _ tag: UInt8, _ s: String) {
        var b = Array(s.utf8)
        if b.count > 127 { b = Array(b[0..<127]) }
        dst.append(tag)
        dst.append(UInt8(b.count))
        dst += b
    }

    /// The SSRC an offer names: field 1 of the blob's field 5 (video) or field 3 (sound). nil
    /// where the helper found none; also where a hostile length would have made the helper's
    /// reader panic or go round forever.
    public static func offerSSRC(_ offerPlist: [UInt8], isVideo: Bool) -> UInt32? {
        guard let value = try? ScreenPlist.decode(offerPlist), case .dict(let m) = value,
              case .data(let compressed)? = m[ScreenPlist.mediaBlobKey],
              let blob = zlibDecompress(compressed) else { return nil }
        let target: UInt64 = isVideo ? 5 : 3
        var pos = 0
        while pos < blob.count {
            guard let (tag, next) = readVarint(blob, pos) else { break }
            pos = next
            let fn = tag >> 3
            switch tag & 7 {
            case 0:
                guard let (_, next2) = readVarint(blob, pos) else { return nil }
                pos = next2
            case 2:
                guard let (ln, next2) = readVarint(blob, pos) else { return nil }
                pos = next2
                let end = pos &+ Int(truncatingIfNeeded: ln)
                if end > blob.count { return nil }
                if end < pos { return nil }
                if fn == target {
                    let sub = Array(blob[pos..<end])
                    if let (innerTag, sp) = readVarint(sub, 0), innerTag & 7 == 0, innerTag >> 3 == 1,
                       let (ssrc, _) = readVarint(sub, sp) {
                        return UInt32(truncatingIfNeeded: ssrc)
                    }
                }
                pos = end
            case 1:
                pos += 8
            case 5:
                pos += 4
            default:
                return nil
            }
        }
        return nil
    }

    // MARK: Varints and fields

    public static func appendVarint(_ dst: inout [UInt8], _ value: UInt64) {
        var v = value
        while v > 0x7f {
            dst.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        dst.append(UInt8(v))
    }

    /// A varint field: its tag (wire type 0) and value.
    public static func appendFieldVarint(_ dst: inout [UInt8], _ fieldNum: UInt64, _ value: UInt64) {
        appendVarint(&dst, (fieldNum << 3) | 0)
        appendVarint(&dst, value)
    }

    /// A length-delimited field: its tag (wire type 2), length and bytes.
    public static func appendFieldBytes(_ dst: inout [UInt8], _ fieldNum: UInt64, _ value: [UInt8]) {
        appendVarint(&dst, (fieldNum << 3) | 2)
        appendVarint(&dst, UInt64(value.count))
        dst += value
    }

    /// The varint at pos and the position after it; nil when it runs past the end or past ten
    /// bytes.
    public static func readVarint(_ data: [UInt8], _ pos: Int) -> (value: UInt64, next: Int)? {
        var val: UInt64 = 0
        var shift: UInt64 = 0
        var p = pos
        while p < data.count {
            let b = data[p]
            p += 1
            val |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return (val, p) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    /// Visits the fields of a protobuf message in order, a varint with its value and a
    /// length-delimited one with its bytes, and stops at the first field that does not fit.
    /// The visitor gets the field number, the wire type, the value (varints) and the bytes
    /// (length-delimited fields; empty otherwise).
    public static func walkFields(_ b: [UInt8], _ visit: (UInt64, Int, UInt64, [UInt8]) -> Void) {
        var pos = 0
        while pos < b.count {
            guard let (tag, next) = readVarint(b, pos) else { return }
            pos = next
            let field = tag >> 3
            let wire = Int(tag & 7)
            var v: UInt64 = 0
            var sub: [UInt8] = []
            switch wire {
            case 0:
                guard let (value, next2) = readVarint(b, pos) else { return }
                v = value
                pos = next2
            case 1:
                if b.count - pos < 8 { return }
                pos += 8
            case 2:
                guard let (ln, next2) = readVarint(b, pos), ln <= UInt64(b.count - next2) else { return }
                sub = Array(b[next2..<(next2 + Int(ln))])
                pos = next2 + Int(ln)
            case 5:
                if b.count - pos < 4 { return }
                pos += 4
            default:
                return
            }
            visit(field, wire, v, sub)
        }
    }

    // MARK: Answers

    /// The size in a server's answer to an offer (the helper's ExtractCanvasDims): a message
    /// beginning with byte 0, either a framebuffer update whose first rectangle is the 0x3f2
    /// answer, or anything else holding the property lists. The first blob with a size wins.
    public static func canvasDims(_ answer: [UInt8]) -> ScreenOfferCanvas? {
        if answer.isEmpty || answer[0] != 0x00 { return nil }
        var blobs: [[UInt8]] = []
        if answer.count >= 18 && Int32(bitPattern: be32(answer, 12)) == mediaInitEncoding {
            let end = 18 + Int(be16(answer, 16))
            if end <= answer.count {
                blobs = answerMediaBlobs(Array(answer[16..<end]))
            }
        } else {
            blobs = ScreenPlist.extractMediaBlobs(answer)
        }
        for compressed in blobs {
            if let canvas = canvas(fromBlob: compressed) { return canvas }
        }
        return nil
    }

    /// The video settings of a compressed media blob: width, height and tiles, fields 4, 5 and
    /// 6 of field 5. nil without a width and a height above zero.
    public static func canvas(fromBlob compressed: [UInt8]) -> ScreenOfferCanvas? {
        guard let dec = zlibDecompress(compressed, limit: blobReadLimit) else { return nil }
        var w = 0, h = 0, tiles = 0
        walkFields(dec) { field, wire, _, sub in
            if field != 5 || wire != 2 { return }
            walkFields(sub) { f, wt, v, _ in
                if wt != 0 || v > UInt64(canvasMax) { return }
                switch f {
                case 4: w = Int(v)
                case 5: h = Int(v)
                case 6: tiles = Int(v)
                default: break
                }
            }
        }
        if w > 0 && h > 0 { return ScreenOfferCanvas(width: w, height: h, tiles: tiles) }
        return nil
    }

    /// The media blobs in the body of an answer's 0x3f2 rectangle (from its u16 length on): by
    /// the lengths it declares where it is laid out as macOS 15 lays it out, else by looking
    /// for the property lists in it.
    public static func answerMediaBlobs(_ body: [UInt8]) -> [[UInt8]] {
        guard let plists = answerPlists(body) else { return ScreenPlist.extractMediaBlobs(body) }
        return plists.compactMap { ScreenPlist.mediaBlob(in: $0) }
    }

    /// The property lists of an answer's 0x3f2 body: u16 length (of the rest), u16 version, u16
    /// count, u32, a u16 length for each list from offset 10 (room for five), the lists from
    /// offset 20, ending with the body. nil when the body is not laid out so.
    public static func answerPlists(_ body: [UInt8]) -> [[UInt8]]? {
        let head = 20, slots = 5
        if body.count < head || Int(be16(body, 0)) + 2 != body.count { return nil }
        let count = Int(be16(body, 4))
        if count == 0 || count > slots { return nil }
        var out: [[UInt8]] = []
        var at = head
        for i in 0..<count {
            let n = Int(be16(body, 10 + 2 * i))
            if n == 0 || at + n > body.count { return nil }
            out.append(Array(body[at..<(at + n)]))
            at += n
        }
        if at != body.count { return nil }
        return out
    }

    // MARK: zlib

    /// data compressed as Go's compress/zlib writes it at the default level (one Write, then
    /// Close): the same bytes.
    public static func zlibCompress(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9C]
        let deflater = GoDeflater6()
        if !data.isEmpty { deflater.write(data) }
        out += deflater.close()
        let sum = adler32(data)
        out += [UInt8(sum >> 24), UInt8((sum >> 16) & 0xff), UInt8((sum >> 8) & 0xff), UInt8(sum & 0xff)]
        return out
    }

    /// A zlib stream read as Go's compress/zlib reads it to its end with io.ReadAll: nil where
    /// that fails. With a limit, as through io.LimitReader: at most that many bytes, and what
    /// lies after them (a break, the checksum) is not looked at.
    public static func zlibDecompress(_ data: [UInt8], limit: Int? = nil) -> [UInt8]? {
        goZlibRead(data, limit: limit)
    }
}

// MARK: - Binary property lists

/// A value of a binary property list. Decoding gives null, bool, int (every integer, as the
/// helper read them), real (dates too, as seconds), data, string, array and dict. Encoding takes
/// null, bool, int, uint, data, string and dict; real and array are refused, as by the helper.
public indirect enum ScreenPlistValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case real(Double)
    case data([UInt8])
    case string(String)
    case array([ScreenPlistValue])
    case dict([String: ScreenPlistValue])
}

public enum ScreenPlistError: Error, Equatable, Sendable {
    /// Not a binary property list as the helper reads one.
    case invalidPlist
    /// No property list with a media blob in the message.
    case mediaBlobNotFound
    /// A value the writer does not write (real, array).
    case unsupportedValue
}

public enum ScreenPlist {
    /// The key of the compressed media blob, in offers and answers.
    public static let mediaBlobKey = "avcMediaStreamNegotiatorMediaBlob"
    /// The property lists looked for in one message, at most: an answer has one per stream.
    public static let scanMax = 8

    fileprivate static let trailerSize = 32
    fileprivate static let magic = Array("bplist00".utf8)

    /// A top-level dictionary as an Apple binary property list (bplist00), written as the helper
    /// writes it: keys in byte order, every key just before its value, a string in ASCII when it
    /// is all ASCII and in UTF-16 otherwise, integers in the fewest bytes.
    public static func encodeDict(_ dict: [String: ScreenPlistValue]) throws -> [UInt8] {
        enum Slot {
            case raw([UInt8])
            case dict(header: [UInt8], refs: [Int])
        }
        var slots: [Slot] = []

        func add(_ value: ScreenPlistValue) throws -> Int {
            let idx = slots.count
            slots.append(.raw([]))
            switch value {
            case .null:
                slots[idx] = .raw([0x00])
            case .bool(let b):
                slots[idx] = .raw([b ? 0x09 : 0x08])
            case .int(let v):
                slots[idx] = .raw(plistInt(v))
            case .uint(let v):
                slots[idx] = .raw(plistUint(v))
            case .data(let d):
                slots[idx] = .raw(plistHeader(0x40, d.count) + d)
            case .string(let s):
                let utf8 = Array(s.utf8)
                if utf8.allSatisfy({ $0 < 0x80 }) {
                    slots[idx] = .raw(plistHeader(0x50, utf8.count) + utf8)
                } else {
                    let utf16 = Array(s.utf16)
                    var buf = plistHeader(0x60, utf16.count)
                    for ch in utf16 {
                        buf.append(UInt8(ch >> 8))
                        buf.append(UInt8(ch & 0xff))
                    }
                    slots[idx] = .raw(buf)
                }
            case .dict(let m):
                let keys = m.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                var keyRefs: [Int] = []
                var valRefs: [Int] = []
                for k in keys {
                    keyRefs.append(try add(.string(k)))
                    valRefs.append(try add(m[k]!))
                }
                slots[idx] = .dict(header: plistHeader(0xD0, keys.count), refs: keyRefs + valRefs)
            case .real, .array:
                throw ScreenPlistError.unsupportedValue
            }
            return idx
        }

        _ = try add(.dict(dict))

        let numObjects = slots.count
        var refSize = 1
        if numObjects > 0xFF { refSize = 2 }
        if numObjects > 0xFFFF { refSize = 4 }

        var out = magic
        var offsets: [UInt64] = []
        offsets.reserveCapacity(numObjects)
        for slot in slots {
            offsets.append(UInt64(out.count))
            switch slot {
            case .raw(let raw):
                out += raw
            case .dict(let header, let refs):
                out += header
                for r in refs { appendSized(&out, UInt64(r), refSize) }
            }
        }
        let offsetTableOffset = UInt64(out.count)
        var offsetSize = 1
        if offsetTableOffset > 0xFF { offsetSize = 2 }
        if offsetTableOffset > 0xFFFF { offsetSize = 4 }
        if offsetTableOffset > 0xFFFF_FFFF { offsetSize = 8 }
        for off in offsets { appendSized(&out, off, offsetSize) }

        out += [0, 0, 0, 0, 0, 0, UInt8(offsetSize), UInt8(refSize)]
        appendSized(&out, UInt64(numObjects), 8)
        appendSized(&out, 0, 8)
        appendSized(&out, offsetTableOffset, 8)
        return out
    }

    /// A binary property list read as the helper reads one.
    public static func decode(_ data: [UInt8]) throws -> ScreenPlistValue {
        guard let value = decodeCore(data, 0, data.count) else { throw ScreenPlistError.invalidPlist }
        return value
    }

    /// The compressed media blob of the first property list in msg that has one (the helper's
    /// ExtractPlistMediaBlob): every end is tried for every "bplist00" in msg.
    public static func extractMediaBlob(_ msg: [UInt8]) throws -> [UInt8] {
        var start = 0
        while start + 8 + trailerSize <= msg.count {
            guard let idx = indexOfMagic(msg, from: start) else { break }
            var end = idx + 8 + trailerSize
            while end <= msg.count {
                if trailer(msg, idx, end - idx) != nil, let value = decodeCore(msg, idx, end - idx),
                   let blob = mediaBlob(of: value) {
                    return blob
                }
                end += 1
            }
            start = idx + 8
        }
        throw ScreenPlistError.mediaBlobNotFound
    }

    /// The media blob of every property list in msg, in order (the helper's
    /// ExtractPlistMediaBlobs): each "bplist00" ends at the first end that reads, and at most
    /// scanMax of them are tried.
    public static func extractMediaBlobs(_ msg: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var tried = 0
        var start = 0
        while start + 8 + trailerSize <= msg.count && tried < scanMax {
            guard let idx = indexOfMagic(msg, from: start) else { break }
            tried += 1
            var next = idx + 8
            var end = idx + 8 + trailerSize
            while end <= msg.count {
                if trailer(msg, idx, end - idx) == nil { end += 1; continue }
                guard let value = decodeCore(msg, idx, end - idx) else { end += 1; continue }
                if let blob = mediaBlob(of: value) { out.append(blob) }
                next = end
                break
            }
            start = next
        }
        return out
    }

    /// The media blob of one property list: nil when it does not read, is not a dictionary, or
    /// has no blob of a byte or more.
    public static func mediaBlob(in plist: [UInt8]) -> [UInt8]? {
        guard let value = decodeCore(plist, 0, plist.count) else { return nil }
        return mediaBlob(of: value)
    }

    fileprivate static func mediaBlob(of value: ScreenPlistValue) -> [UInt8]? {
        guard case .dict(let m) = value, case .data(let blob)? = m[mediaBlobKey], !blob.isEmpty else { return nil }
        return blob
    }

    fileprivate static func indexOfMagic(_ msg: [UInt8], from start: Int) -> Int? {
        if msg.count < 8 { return nil }
        var i = start
        while i + 8 <= msg.count {
            if msg[i] == 0x62 && msg[i + 1] == 0x70 && msg[i + 2] == 0x6c && msg[i + 3] == 0x69
                && msg[i + 4] == 0x73 && msg[i + 5] == 0x74 && msg[i + 6] == 0x30 && msg[i + 7] == 0x30 {
                return i
            }
            i += 1
        }
        return nil
    }

    fileprivate static func plistHeader(_ tag: UInt8, _ length: Int) -> [UInt8] {
        if length < 15 { return [tag | UInt8(length)] }
        return [tag | 0x0F] + plistUint(UInt64(length))
    }

    fileprivate static func plistInt(_ v: Int64) -> [UInt8] {
        if v >= 0 { return plistUint(UInt64(v)) }
        var buf: [UInt8] = [0x13]
        appendSized(&buf, UInt64(bitPattern: v), 8)
        return buf
    }

    fileprivate static func plistUint(_ v: UInt64) -> [UInt8] {
        var buf: [UInt8]
        if v <= 0xFF {
            return [0x10, UInt8(v)]
        } else if v <= 0xFFFF {
            buf = [0x11]
            appendSized(&buf, v, 2)
        } else if v <= 0xFFFF_FFFF {
            buf = [0x12]
            appendSized(&buf, v, 4)
        } else {
            buf = [0x13]
            appendSized(&buf, v, 8)
        }
        return buf
    }

    fileprivate struct Trailer {
        var offsetIntSize: Int
        var objectRefSize: Int
        var numObjects: UInt64
        var topObject: UInt64
        var offsetTableOffset: UInt64
    }

    /// The trailer of the property list d[base..<base+n], when it is one the helper accepts.
    fileprivate static func trailer(_ d: [UInt8], _ base: Int, _ n: Int) -> Trailer? {
        if n < 8 + trailerSize { return nil }
        for i in 0..<8 where d[base + i] != magic[i] { return nil }
        let t = base + n - trailerSize
        for i in 0..<6 where d[t + i] != 0 { return nil }
        let offSz = Int(d[t + 6])
        let refSz = Int(d[t + 7])
        if !validIntSize(offSz) || !validIntSize(refSz) { return nil }
        let numObj = readSized(d, t + 8, 8)
        let topObj = readSized(d, t + 16, 8)
        let offTable = readSized(d, t + 24, 8)
        if numObj == 0 || numObj > 65536 || topObj >= numObj || offTable < 8 { return nil }
        let bodyLen = UInt64(n - trailerSize)
        if offTable > bodyLen { return nil }
        let tableBytes = numObj * UInt64(offSz)
        if offTable + tableBytes != bodyLen { return nil }
        switch offSz {
        case 1: if offTable > 0xFF { return nil }
        case 2: if offTable > 0xFFFF { return nil }
        case 4: if offTable > 0xFFFF_FFFF { return nil }
        default: break
        }
        return Trailer(offsetIntSize: offSz, objectRefSize: refSz, numObjects: numObj, topObject: topObj,
                       offsetTableOffset: offTable)
    }

    fileprivate static func validIntSize(_ n: Int) -> Bool { n == 1 || n == 2 || n == 4 || n == 8 }

    /// The property list d[base..<base+n] decoded as the helper's DecodePlist decodes it.
    fileprivate static func decodeCore(_ d: [UInt8], _ base: Int, _ n: Int) -> ScreenPlistValue? {
        guard let tr = trailer(d, base, n) else { return nil }
        let limit = Int(tr.offsetTableOffset)
        let refSize = tr.objectRefSize
        var offsets = [Int](repeating: 0, count: Int(tr.numObjects))
        for i in 0..<Int(tr.numObjects) {
            let off = readSized(d, base + limit + i * tr.offsetIntSize, tr.offsetIntSize)
            if off < 8 || off >= tr.offsetTableOffset { return nil }
            offsets[i] = Int(off)
        }

        func readLength(_ marker: UInt8, _ pos: Int) -> (Int, Int)? {
            let short = Int(marker & 0x0F)
            if short < 0x0F { return (short, pos) }
            if pos >= limit { return nil }
            let intMarker = d[base + pos]
            if intMarker & 0xF0 != 0x10 { return nil }
            let byteCount = 1 << Int(intMarker & 0x0F)
            let p = pos + 1
            if byteCount > 8 || p + byteCount > limit { return nil }
            let v = readSized(d, base + p, byteCount)
            if v > UInt64(Int32.max) { return nil }
            return (Int(v), p + byteCount)
        }

        func decodeAt(_ objIdx: UInt64, _ depth: Int) -> ScreenPlistValue? {
            if depth > 32 || objIdx >= tr.numObjects { return nil }
            let off = offsets[Int(objIdx)]
            if off >= limit { return nil }
            let marker = d[base + off]
            let pos = off + 1
            switch marker & 0xF0 {
            case 0x00:
                switch marker {
                case 0x00: return .null
                case 0x08: return .bool(false)
                case 0x09: return .bool(true)
                default: return nil
                }
            case 0x10:
                let byteCount = 1 << Int(marker & 0x0F)
                if byteCount > 16 || pos + byteCount > limit { return nil }
                if byteCount == 8 { return .int(Int64(bitPattern: readSized(d, base + pos, 8))) }
                if byteCount == 16 { return .int(Int64(bitPattern: readSized(d, base + pos + 8, 8))) }
                return .int(Int64(bitPattern: readSized(d, base + pos, byteCount)))
            case 0x20:
                let byteCount = 1 << Int(marker & 0x0F)
                if pos + byteCount > limit { return nil }
                switch byteCount {
                case 4: return .real(Double(Float(bitPattern: UInt32(readSized(d, base + pos, 4)))))
                case 8: return .real(Double(bitPattern: readSized(d, base + pos, 8)))
                default: return nil
                }
            case 0x30:
                if pos + 8 > limit { return nil }
                return .real(Double(bitPattern: readSized(d, base + pos, 8)))
            case 0x40:
                guard let (count, p) = readLength(marker, pos), p + count <= limit else { return nil }
                return .data(Array(d[(base + p)..<(base + p + count)]))
            case 0x50:
                guard let (count, p) = readLength(marker, pos), p + count <= limit else { return nil }
                return .string(String(decoding: d[(base + p)..<(base + p + count)], as: UTF8.self))
            case 0x60:
                guard let (count, p) = readLength(marker, pos), p + count * 2 <= limit else { return nil }
                var units = [UInt16](repeating: 0, count: count)
                for i in 0..<count {
                    units[i] = UInt16(d[base + p + 2 * i]) << 8 | UInt16(d[base + p + 2 * i + 1])
                }
                return .string(String(decoding: units, as: UTF16.self))
            case 0xA0:
                guard let (count, p) = readLength(marker, pos), p + count * refSize <= limit else { return nil }
                var arr: [ScreenPlistValue] = []
                arr.reserveCapacity(count)
                for i in 0..<count {
                    let ref = readSized(d, base + p + i * refSize, refSize)
                    guard let v = decodeAt(ref, depth + 1) else { return nil }
                    arr.append(v)
                }
                return .array(arr)
            case 0xD0:
                guard let (count, p) = readLength(marker, pos), p + 2 * count * refSize <= limit else { return nil }
                var m: [String: ScreenPlistValue] = [:]
                for i in 0..<count {
                    let kref = readSized(d, base + p + i * refSize, refSize)
                    let vref = readSized(d, base + p + (count + i) * refSize, refSize)
                    guard let kv = decodeAt(kref, depth + 1), case .string(let key) = kv else { return nil }
                    guard let vv = decodeAt(vref, depth + 1) else { return nil }
                    m[key] = vv
                }
                return .dict(m)
            default:
                return nil
            }
        }

        return decodeAt(tr.topObject, 0)
    }
}

// MARK: - Small helpers

fileprivate func be16(_ b: [UInt8], _ at: Int) -> UInt16 {
    UInt16(b[at]) << 8 | UInt16(b[at + 1])
}

fileprivate func be32(_ b: [UInt8], _ at: Int) -> UInt32 {
    UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
}

fileprivate func readSized(_ b: [UInt8], _ at: Int, _ size: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<size { v = (v << 8) | UInt64(b[at + i]) }
    return v
}

fileprivate func appendSized(_ dst: inout [UInt8], _ v: UInt64, _ size: Int) {
    var shift = (size - 1) * 8
    while shift >= 0 {
        dst.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        shift -= 8
    }
}

fileprivate func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

fileprivate func adler32(_ data: [UInt8]) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    var i = 0
    while i < data.count {
        let end = min(i + 5552, data.count)
        while i < end {
            a += UInt32(data[i])
            b += a
            i += 1
        }
        a %= 65521
        b %= 65521
    }
    return b << 16 | a
}

// MARK: - Deflate, as Go 1.27's compress/flate writes it at level 6

fileprivate enum GoFlate {
    static let maxStoreBlockSize = 65535
    static let maxMatchOffset = 1 << 15
    static let maxMatchLength = 258
    static let allocHistory = maxStoreBlockSize * 5
    static let bufferReset = (1 << 31) - allocHistory - maxStoreBlockSize - 1
    static let tableSize = 1 << 15
    static let endBlockMarker = 256
    static let maxPredefinedTokens = 250
    static let badCode: UInt8 = 255
    static let matchType: UInt32 = 1 << 30
    static let offsetMask: UInt32 = (1 << 22) - 1

    static let lengthCodes: [UInt8] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 15, 15, 15, 15,
        16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19,
        20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
        22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23,
        24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
        25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 28,
    ]
    static let lengthCodes1: [UInt8] = lengthCodes.map { $0 + 1 }

    static let offsetCodes: [UInt32] = [
        0, 1, 2, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9,
        10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    ]
    static let offsetCodes14: [UInt32] = offsetCodes.map { $0 + 14 }

    static let lengthExtraBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0, 0, 0,
    ]
    static let lengthBase: [UInt8] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 255, 0, 0, 0,
    ]
    static let offsetExtraBits: [Int8] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14,
    ]
    static let offsetCombined: [UInt32] = [
        0x0, 0x0, 0x0, 0x0, 0x401, 0x601, 0x802, 0xc02, 0x1003, 0x1803, 0x2004, 0x3004, 0x4005, 0x6005,
        0x8006, 0xc006, 0x10007, 0x18007, 0x20008, 0x30008, 0x40009, 0x60009, 0x8000a, 0xc000a, 0x10000b, 0x18000b,
        0x20000c, 0x30000c, 0x40000d, 0x60000d, 0x0, 0x0,
    ]
    static let codegenOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static func offsetCode(_ off: UInt32) -> UInt32 {
        if off < 256 { return offsetCodes[Int(off)] }
        return offsetCodes14[Int(UInt8(truncatingIfNeeded: off >> 7))]
    }

    static func reverse16(_ x: UInt16) -> UInt16 {
        var v = x
        v = (v >> 1) & 0x5555 | (v & 0x5555) << 1
        v = (v >> 2) & 0x3333 | (v & 0x3333) << 2
        v = (v >> 4) & 0x0F0F | (v & 0x0F0F) << 4
        return v >> 8 | v << 8
    }

    static func reverseBits(_ x: UInt16, _ b: Int) -> UInt16 {
        reverse16(x << UInt16((16 - b) & 15))
    }

    /// A Huffman code as Go keeps it: the length in the low byte, the (reversed) code above.
    static func hcode(_ code: UInt16, _ length: Int) -> UInt32 {
        UInt32(length) | UInt32(code) << 8
    }

    static let fixedLiteralCodes: [UInt32] = {
        var codes = [UInt32](repeating: 0, count: 512)
        for ch in 0..<286 {
            let bits: Int
            let size: Int
            switch ch {
            case ..<144: bits = ch + 48; size = 8
            case ..<256: bits = ch + 400 - 144; size = 9
            case ..<280: bits = ch - 256; size = 7
            default: bits = ch + 192 - 280; size = 8
            }
            codes[ch] = hcode(reverseBits(UInt16(bits), size), size)
        }
        return codes
    }()

    static let fixedOffsetCodes: [UInt32] = {
        var codes = [UInt32](repeating: 0, count: 32)
        for ch in 0..<30 { codes[ch] = hcode(reverseBits(UInt16(ch), 5), 5) }
        return codes
    }()

    /// The offset code of a block of literals only: one code of one bit.
    static let huffOffsetCodes: [UInt32] = {
        var codes = [UInt32](repeating: 0, count: 32)
        codes[0] = hcode(0, 1)
        return codes
    }()

    /// Go's fast approximation of log2. The multiply-adds are fused, as Go compiles them for
    /// arm64 (the helper on Apple silicon); Go for amd64 rounds each step, and its output can
    /// differ from this in rare streams of more than one 65535-byte window.
    static func mFastLog2(_ val: Float) -> Float {
        var ux = Int32(bitPattern: val.bitPattern)
        var log2 = Float(((ux >> 23) & 255) - 128)
        ux &= -0x7f80_0001
        ux &+= 127 << 23
        let uval = Float(bitPattern: UInt32(bitPattern: ux))
        let t1 = Float(2.02466578).addingProduct(-0.34484843, uval)
        log2 += (-Float(0.67487759)).addingProduct(t1, uval)
        return log2
    }
}

/// The tokens of a block and their histograms.
fileprivate final class GoTokens {
    var extraHist = [UInt16](repeating: 0, count: 32)
    var offHist = [UInt16](repeating: 0, count: 32)
    var litHist = [UInt16](repeating: 0, count: 256)
    var nFilled = 0
    var n = 0
    var tokens = [UInt32](repeating: 0, count: 65536)

    func reset() {
        if n == 0 { return }
        n = 0
        nFilled = 0
        for i in 0..<256 { litHist[i] = 0 }
        for i in 0..<32 { extraHist[i] = 0; offHist[i] = 0 }
    }

    func addLiteral(_ lit: UInt8) {
        tokens[n] = UInt32(lit)
        litHist[Int(lit)] &+= 1
        n += 1
    }

    func addMatchLong(_ length: Int, _ offset: UInt32) {
        let oc = GoFlate.offsetCode(offset)
        let xoffset = offset | oc << 16
        var xlength = length
        while xlength > 0 {
            var xl = xlength
            if xl > 258 {
                xl = xl > 258 + 3 ? 258 : 258 - 3
            }
            xlength -= xl
            xl -= 3
            extraHist[Int(GoFlate.lengthCodes1[Int(UInt8(truncatingIfNeeded: xl))])] &+= 1
            offHist[Int(oc & 31)] &+= 1
            tokens[n] = GoFlate.matchType | UInt32(truncatingIfNeeded: xl) << 22 | xoffset
            n += 1
        }
    }

    func addEOB() {
        tokens[n] = UInt32(GoFlate.endBlockMarker)
        extraHist[0] &+= 1
        n += 1
    }

    func estimatedBits() -> Int {
        var shannon: Float = 0
        var bits = 0
        var nMatches = 0
        let total = n + nFilled
        if total > 0 {
            let invTotal = 1.0 / Float(total)
            for v in litHist where v > 0 {
                let nf = Float(v)
                shannon = shannon.addingProduct(min(15, max(1, -GoFlate.mFastLog2(nf * invTotal))), nf)
            }
            shannon += 15
            for i in 0..<29 {
                let v = extraHist[i + 1]
                if v > 0 {
                    let nf = Float(v)
                    shannon = shannon.addingProduct(min(15, max(1, -GoFlate.mFastLog2(nf * invTotal))), nf)
                    bits += Int(GoFlate.lengthExtraBits[i & 31]) * Int(v)
                    nMatches += Int(v)
                }
            }
        }
        if nMatches > 0 {
            let invTotal = 1.0 / Float(nMatches)
            for i in 0..<30 {
                let v = offHist[i]
                if v > 0 {
                    let nf = Float(v)
                    shannon = shannon.addingProduct(min(15, max(1, -GoFlate.mFastLog2(nf * invTotal))), nf)
                    bits += Int(GoFlate.offsetExtraBits[i & 31]) * Int(v)
                }
            }
        }
        return Int(shannon) + bits
    }
}

fileprivate final class GoHuffmanEncoder {
    var codes: [UInt32]

    init(_ size: Int) {
        var bitsLen = 0
        var v = size - 1
        while v > 0 { bitsLen += 1; v >>= 1 }
        codes = [UInt32](repeating: 0, count: 1 << bitsLen)
    }

    func bitLength(_ freq: [UInt16]) -> Int {
        var total = 0
        for (i, f) in freq.enumerated() where f != 0 {
            total += Int(f) * Int(codes[i] & 0xff)
        }
        return total
    }

    func canEncodeLen(_ freq: [UInt16], _ count: Int) -> Int {
        var total = 0
        for i in 0..<count where freq[i] != 0 {
            let code = codes[i]
            if code == 0 { return Int(Int32.max) }
            total += Int(freq[i]) * Int(code & 0xff)
        }
        return total
    }

    struct Node {
        var literal: UInt16
        var freq: UInt16
    }

    struct LevelInfo {
        var level: Int32 = 0
        var lastFreq: Int32 = 0
        var nextCharFreq: Int32 = 0
        var nextPairFreq: Int32 = 0
        var needed: Int32 = 0
    }

    /// The codes for freq[0..<count], no longer than maxBits.
    func generate(_ freq: [UInt16], _ count: Int, _ maxBits: Int32) {
        var list: [Node] = []
        list.reserveCapacity(count + 1)
        for i in 0..<count {
            let f = freq[i]
            if f != 0 {
                list.append(Node(literal: UInt16(i), freq: f))
            } else {
                codes[i] = 0
            }
        }
        if list.count <= 2 {
            for (i, node) in list.enumerated() {
                codes[Int(node.literal)] = GoFlate.hcode(UInt16(i), 1)
            }
            return
        }
        list.sort { ((Int($0.freq) << 10) + Int($0.literal)) < ((Int($1.freq) << 10) + Int($1.literal)) }
        let bitCount = bitCounts(list, maxBits)
        var code: UInt16 = 0
        var end = list.count
        for (n, bits) in bitCount.enumerated() {
            code <<= 1
            if n == 0 || bits == 0 { continue }
            let b = Int(bits)
            var chunk = Array(list[(end - b)..<end])
            chunk.sort { $0.literal < $1.literal }
            for node in chunk {
                codes[Int(node.literal)] = GoFlate.hcode(GoFlate.reverseBits(code, n), n)
                code &+= 1
            }
            end -= b
        }
    }

    func bitCounts(_ sorted: [Node], _ maxBitsIn: Int32) -> [Int32] {
        var maxBits = maxBitsIn
        let n = Int32(sorted.count)
        var list = sorted
        list.append(Node(literal: 0xFFFF, freq: 0xFFFF))
        if maxBits > n - 1 { maxBits = n - 1 }

        var levels = [LevelInfo](repeating: LevelInfo(), count: 16)
        var leafCounts = [[Int32]](repeating: [Int32](repeating: 0, count: 16), count: 16)
        for level in 1...Int(maxBits) {
            levels[level] = LevelInfo(level: Int32(level), lastFreq: Int32(list[1].freq),
                                      nextCharFreq: Int32(list[2].freq),
                                      nextPairFreq: Int32(list[0].freq) + Int32(list[1].freq), needed: 0)
            leafCounts[level][level] = 2
            if level == 1 { levels[level].nextPairFreq = Int32.max }
        }
        levels[Int(maxBits)].needed = 2 * n - 4

        var level = Int(maxBits)
        while level < 16 {
            if levels[level].nextPairFreq == Int32.max && levels[level].nextCharFreq == Int32.max {
                levels[level].needed = 0
                levels[level + 1].nextPairFreq = Int32.max
                level += 1
                continue
            }
            let prevFreq = levels[level].lastFreq
            if levels[level].nextCharFreq < levels[level].nextPairFreq {
                let leaves = leafCounts[level][level] + 1
                levels[level].lastFreq = levels[level].nextCharFreq
                leafCounts[level][level] = leaves
                let e = list[Int(leaves)]
                levels[level].nextCharFreq = e.literal < 0xFFFF ? Int32(e.freq) : Int32.max
            } else {
                levels[level].lastFreq = levels[level].nextPairFreq
                let save = leafCounts[level][level]
                leafCounts[level] = leafCounts[level - 1]
                leafCounts[level][level] = save
                levels[Int(levels[level].level) - 1].needed = 2
            }
            levels[level].needed &-= 1
            if levels[level].needed == 0 {
                if levels[level].level == maxBits { break }
                levels[Int(levels[level].level) + 1].nextPairFreq = prevFreq &+ levels[level].lastFreq
                level += 1
            } else {
                while levels[level - 1].needed > 0 { level -= 1 }
            }
        }

        var bitCount = [Int32](repeating: 0, count: Int(maxBits) + 1)
        var bits = 1
        let counts = leafCounts[Int(maxBits)]
        var lv = Int(maxBits)
        while lv > 0 {
            bitCount[bits] = counts[lv] - counts[lv - 1]
            bits += 1
            lv -= 1
        }
        return bitCount
    }
}

fileprivate final class GoHuffmanBitWriter {
    var out: [UInt8] = []
    var bits: UInt64 = 0
    var nbits = 0

    var wroteHuffman = false
    var literalEncoding = GoHuffmanEncoder(286)
    var tmpLitEncoding = GoHuffmanEncoder(286)
    let offsetEncoding = GoHuffmanEncoder(30)
    let codegenEncoding = GoHuffmanEncoder(19)
    var prevHeader = 0
    let logNewTablePenalty: Int
    var literalFreq = [UInt16](repeating: 0, count: 257 + 32)
    var offsetFreq = [UInt16](repeating: 0, count: 32)
    var codegenFreq = [UInt16](repeating: 0, count: 19)
    var codegen = [UInt8](repeating: 0, count: 286 + 30 + 1)

    init(logNewTablePenalty: Int) {
        self.logNewTablePenalty = logNewTablePenalty
    }

    func writeBits(_ value: UInt64, _ nb: Int) {
        bits |= value << UInt64(nbits)
        nbits += nb
        while nbits >= 8 {
            out.append(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
            nbits -= 8
        }
    }

    func writeCode(_ c: UInt32) {
        writeBits(UInt64(c >> 8), Int(c & 0xff))
    }

    func flush() {
        if prevHeader > 0 {
            writeCode(literalEncoding.codes[GoFlate.endBlockMarker])
            prevHeader = 0
        }
        if nbits > 0 { out.append(UInt8(truncatingIfNeeded: bits)) }
        bits = 0
        nbits = 0
    }

    func writeBytes(_ bytes: [UInt8]) {
        out += bytes
    }

    func generateCodegen(_ numLiterals: Int, _ numOffsets: Int, _ litCodes: [UInt32], _ offCodes: [UInt32]) {
        for i in 0..<19 { codegenFreq[i] = 0 }
        for i in 0..<numLiterals { codegen[i] = UInt8(litCodes[i] & 0xff) }
        for i in 0..<numOffsets { codegen[numLiterals + i] = UInt8(offCodes[i] & 0xff) }
        codegen[numLiterals + numOffsets] = GoFlate.badCode

        var size = codegen[0]
        var count = 1
        var outIndex = 0
        var inIndex = 1
        while size != GoFlate.badCode {
            let nextSize = codegen[inIndex]
            if nextSize == size {
                count += 1
                inIndex += 1
                continue
            }
            if size != 0 {
                codegen[outIndex] = size
                outIndex += 1
                codegenFreq[Int(size)] += 1
                count -= 1
                while count >= 3 {
                    let n = min(6, count)
                    codegen[outIndex] = 16
                    outIndex += 1
                    codegen[outIndex] = UInt8(n - 3)
                    outIndex += 1
                    codegenFreq[16] += 1
                    count -= n
                }
            } else {
                while count >= 11 {
                    let n = min(138, count)
                    codegen[outIndex] = 18
                    outIndex += 1
                    codegen[outIndex] = UInt8(n - 11)
                    outIndex += 1
                    codegenFreq[18] += 1
                    count -= n
                }
                if count >= 3 {
                    codegen[outIndex] = 17
                    outIndex += 1
                    codegen[outIndex] = UInt8(count - 3)
                    outIndex += 1
                    codegenFreq[17] += 1
                    count = 0
                }
            }
            count -= 1
            while count >= 0 {
                codegen[outIndex] = size
                outIndex += 1
                codegenFreq[Int(size)] += 1
                count -= 1
            }
            size = nextSize
            count = 1
            inIndex += 1
        }
        codegen[outIndex] = GoFlate.badCode
    }

    func codegens() -> Int {
        var numCodegens = 19
        while numCodegens > 4 && codegenFreq[GoFlate.codegenOrder[numCodegens - 1]] == 0 { numCodegens -= 1 }
        return numCodegens
    }

    func headerSize() -> (size: Int, numCodegens: Int) {
        let numCodegens = codegens()
        let size = 3 + 5 + 5 + 4 + (3 * numCodegens) + codegenEncoding.bitLength(codegenFreq)
            + Int(codegenFreq[16]) * 2 + Int(codegenFreq[17]) * 3 + Int(codegenFreq[18]) * 7
        return (size, numCodegens)
    }

    func dynamicReuseSize() -> Int {
        literalEncoding.bitLength(literalFreq) + offsetEncoding.bitLength(offsetFreq)
    }

    func dynamicSize(_ extraBits: Int) -> (size: Int, numCodegens: Int) {
        let (header, numCodegens) = headerSize()
        let size = header + literalEncoding.bitLength(literalFreq) + offsetEncoding.bitLength(offsetFreq) + extraBits
        return (size, numCodegens)
    }

    func extraBitSize() -> Int {
        var total = 0
        for i in 0..<(286 - 257) { total += Int(literalFreq[257 + i]) * Int(GoFlate.lengthExtraBits[i & 31]) }
        for i in 0..<30 { total += Int(offsetFreq[i]) * Int(GoFlate.offsetExtraBits[i & 31]) }
        return total
    }

    func fixedSize(_ extraBits: Int) -> Int {
        var total = 3 + extraBits
        for (i, f) in literalFreq.enumerated() where f != 0 { total += Int(f) * Int(GoFlate.fixedLiteralCodes[i] & 0xff) }
        for (i, f) in offsetFreq.enumerated() where f != 0 { total += Int(f) * Int(GoFlate.fixedOffsetCodes[i] & 0xff) }
        return total
    }

    func storedSize(_ input: [UInt8]?) -> (Int, Bool) {
        guard let input = input else { return (0, false) }
        if input.count <= GoFlate.maxStoreBlockSize { return ((input.count + 5) * 8, true) }
        return (0, false)
    }

    func writeDynamicHeader(_ numLiterals: Int, _ numOffsets: Int, _ numCodegens: Int, _ isEof: Bool) {
        writeBits(isEof ? 5 : 4, 3)
        writeBits(UInt64(numLiterals - 257), 5)
        writeBits(UInt64(numOffsets - 1), 5)
        writeBits(UInt64(numCodegens - 4), 4)
        for i in 0..<numCodegens {
            writeBits(UInt64(codegenEncoding.codes[GoFlate.codegenOrder[i]] & 0xff), 3)
        }
        var i = 0
        while true {
            let codeWord = codegen[i]
            i += 1
            if codeWord == GoFlate.badCode { break }
            writeCode(codegenEncoding.codes[Int(codeWord)])
            switch codeWord {
            case 16:
                writeBits(UInt64(codegen[i]), 2)
                i += 1
            case 17:
                writeBits(UInt64(codegen[i]), 3)
                i += 1
            case 18:
                writeBits(UInt64(codegen[i]), 7)
                i += 1
            default:
                break
            }
        }
    }

    func writeStoredHeader(_ length: Int, _ isEof: Bool) {
        if prevHeader > 0 {
            writeCode(literalEncoding.codes[GoFlate.endBlockMarker])
            prevHeader = 0
        }
        if length == 0 && isEof {
            writeFixedHeader(isEof)
            writeBits(0, 7)
            flush()
            return
        }
        writeBits(isEof ? 1 : 0, 3)
        flush()
        writeBits(UInt64(length), 16)
        writeBits(UInt64(~UInt16(truncatingIfNeeded: length)), 16)
    }

    func writeFixedHeader(_ isEof: Bool) {
        if prevHeader > 0 {
            writeCode(literalEncoding.codes[GoFlate.endBlockMarker])
            prevHeader = 0
        }
        writeBits(isEof ? 3 : 2, 3)
    }

    func writeStored(_ input: [UInt8], _ eof: Bool) {
        writeStoredHeader(input.count, eof)
        writeBytes(input)
    }

    func writeBlockDynamic(_ tokens: GoTokens, _ eof: Bool, _ input: [UInt8]?, _ syncIn: Bool) {
        let sync = syncIn || eof
        if sync {
            tokens.addEOB()
        } else {
            tokens.extraHist[0] = 1
        }
        if (wroteHuffman || eof) && prevHeader > 0 {
            writeCode(literalEncoding.codes[GoFlate.endBlockMarker])
            prevHeader = 0
            wroteHuffman = false
        }
        if prevHeader > 0 && !canReuse(tokens) {
            writeCode(literalEncoding.codes[GoFlate.endBlockMarker])
            prevHeader = 0
        }

        let (numLiterals, numOffsets) = indexTokens(tokens)
        var extraBits = 0
        let (ssize, storable) = storedSize(input)
        if storable || prevHeader > 0 { extraBits = extraBitSize() }

        var size = 0
        if prevHeader > 0 {
            var newSize = prevHeader + tokens.estimatedBits()
            newSize += Int(literalEncoding.codes[GoFlate.endBlockMarker] & 0xff) + (newSize >> logNewTablePenalty)
            let reuseSize = dynamicReuseSize() + extraBits
            if newSize < reuseSize {
                writeCode(literalEncoding.codes[GoFlate.endBlockMarker])
                size = newSize
                prevHeader = 0
            } else {
                size = reuseSize
            }
            if tokens.n < GoFlate.maxPredefinedTokens {
                let preSize = fixedSize(extraBits) + 7
                if preSize < size {
                    if storable && ssize <= size {
                        writeStored(input!, eof)
                        return
                    }
                    writeFixedHeader(eof)
                    if !sync { tokens.addEOB() }
                    writeTokens(tokens, GoFlate.fixedLiteralCodes, GoFlate.fixedOffsetCodes)
                    return
                }
            }
            if storable && ssize <= size {
                writeStored(input!, eof)
                return
            }
        }

        if prevHeader == 0 {
            literalFreq[GoFlate.endBlockMarker] = 1
            generate()
            generateCodegen(numLiterals, numOffsets, literalEncoding.codes, offsetEncoding.codes)
            codegenEncoding.generate(codegenFreq, 19, 7)
            let dyn = dynamicSize(extraBits)
            size = dyn.size
            if tokens.n < GoFlate.maxPredefinedTokens {
                let preSize = fixedSize(extraBits)
                if preSize <= size {
                    if storable && ssize <= preSize {
                        writeStored(input!, eof)
                        return
                    }
                    writeFixedHeader(eof)
                    if !sync { tokens.addEOB() }
                    writeTokens(tokens, GoFlate.fixedLiteralCodes, GoFlate.fixedOffsetCodes)
                    return
                }
            }
            if storable && ssize <= size {
                writeStored(input!, eof)
                return
            }
            writeDynamicHeader(numLiterals, numOffsets, dyn.numCodegens, eof)
            if !sync { prevHeader = headerSize().size }
            wroteHuffman = false
        }

        if sync { prevHeader = 0 }
        writeTokens(tokens, literalEncoding.codes, offsetEncoding.codes)
    }

    func canReuse(_ t: GoTokens) -> Bool {
        for i in 0..<30 where t.offHist[i] != 0 && offsetEncoding.codes[i] == 0 { return false }
        for i in 0..<30 where t.extraHist[i] != 0 && literalEncoding.codes[256 + i] == 0 { return false }
        for i in 0..<256 where t.litHist[i] != 0 && literalEncoding.codes[i] == 0 { return false }
        return true
    }

    func indexTokens(_ t: GoTokens) -> (Int, Int) {
        for i in 0..<256 { literalFreq[i] = t.litHist[i] }
        for i in 0..<32 { literalFreq[256 + i] = t.extraHist[i] }
        for i in 0..<32 { offsetFreq[i] = t.offHist[i] }
        if t.n == 0 { return (0, 0) }
        var numLiterals = literalFreq.count
        while literalFreq[numLiterals - 1] == 0 { numLiterals -= 1 }
        var numOffsets = offsetFreq.count
        while numOffsets > 0 && offsetFreq[numOffsets - 1] == 0 { numOffsets -= 1 }
        if numOffsets == 0 {
            offsetFreq[0] = 1
            numOffsets = 1
        }
        return (numLiterals, numOffsets)
    }

    func generate() {
        literalEncoding.generate(literalFreq, 286, 15)
        offsetEncoding.generate(offsetFreq, 30, 15)
    }

    func writeTokens(_ t: GoTokens, _ lenCodes: [UInt32], _ offCodes: [UInt32]) {
        var count = t.n
        if count == 0 { return }
        var deferEOB = false
        if t.tokens[count - 1] == UInt32(GoFlate.endBlockMarker) {
            count -= 1
            deferEOB = true
        }
        for k in 0..<count {
            let tok = t.tokens[k]
            if tok < 256 {
                writeCode(lenCodes[Int(tok)])
                continue
            }
            let length = UInt8(truncatingIfNeeded: tok >> 22)
            let lenCode = Int(GoFlate.lengthCodes[Int(length)] & 31)
            writeCode(lenCodes[257 + lenCode])
            if lenCode >= 8 {
                writeBits(UInt64(length &- GoFlate.lengthBase[lenCode]), Int(GoFlate.lengthExtraBits[lenCode]))
            }
            let offset = tok & GoFlate.offsetMask
            let offCode = Int((offset >> 16) & 31)
            writeCode(offCodes[offCode])
            if offCode >= 4 {
                let comb = GoFlate.offsetCombined[offCode]
                writeBits(UInt64((offset &- (comb >> 8)) & 0xffff), Int(comb & 0xff))
            }
        }
        if deferEOB { writeCode(lenCodes[GoFlate.endBlockMarker]) }
    }

    func writeBlockHuff(_ eof: Bool, _ input: [UInt8], _ sync: Bool) {
        for i in 0..<literalFreq.count { literalFreq[i] = 0 }
        if !wroteHuffman {
            for i in 0..<offsetFreq.count { offsetFreq[i] = 0 }
        }
        let numLiterals = GoFlate.endBlockMarker + 1
        let guessHeaderSizeBits = 70 * 8
        for c in input { literalFreq[Int(c)] &+= 1 }
        let (ssize, storable) = storedSize(input)
        if storable && input.count > 1024 {
            var abs = 0.0
            let avg = Double(input.count) / 256
            let maxAbs = Double(input.count * 2)
            for i in 0..<256 {
                let diff = Double(literalFreq[i]) - avg
                abs += diff * diff
                if abs >= maxAbs { break }
            }
            if abs < maxAbs {
                writeStored(input, eof)
                return
            }
        }
        literalFreq[GoFlate.endBlockMarker] = 1
        tmpLitEncoding.generate(literalFreq, numLiterals, 15)
        var estBits = tmpLitEncoding.canEncodeLen(literalFreq, numLiterals)
        if estBits < Int(Int32.max) {
            estBits += prevHeader
            if prevHeader == 0 { estBits += guessHeaderSizeBits }
            estBits += estBits >> logNewTablePenalty
        }
        if storable && ssize <= estBits {
            writeStored(input, eof)
            return
        }
        if prevHeader > 0 {
            let reuseSize = literalEncoding.canEncodeLen(literalFreq, 256)
            if estBits < reuseSize {
                writeCode(literalEncoding.codes[GoFlate.endBlockMarker])
                prevHeader = 0
            }
        }
        if prevHeader == 0 {
            let used = literalEncoding
            literalEncoding = tmpLitEncoding
            tmpLitEncoding = used
            generateCodegen(numLiterals, 1, literalEncoding.codes, GoFlate.huffOffsetCodes)
            codegenEncoding.generate(codegenFreq, 19, 7)
            let numCodegens = codegens()
            writeDynamicHeader(numLiterals, 1, numCodegens, eof)
            wroteHuffman = true
            prevHeader = headerSize().size
        }
        let encoding = literalEncoding.codes
        for c in input { writeCode(encoding[Int(c)]) }
        if eof || sync {
            writeCode(literalEncoding.codes[GoFlate.endBlockMarker])
            prevHeader = 0
            wroteHuffman = false
        }
    }
}

/// Go's level 6 match finder: two tables, of 4-byte and 7-byte hashes, full indexing, and a
/// check for a repeat of the last offset.
fileprivate final class GoFastEncL6 {
    var hist: [UInt8] = []
    var histCap = 0
    var cur = GoFlate.maxStoreBlockSize
    var table = [Int32](repeating: 0, count: GoFlate.tableSize)
    var bCur = [Int32](repeating: 0, count: GoFlate.tableSize)
    var bPrev = [Int32](repeating: 0, count: GoFlate.tableSize)

    @inline(__always) func hash4(_ u: UInt64) -> Int {
        Int((UInt32(truncatingIfNeeded: u) &* 2_654_435_761) >> (32 - 15))
    }

    @inline(__always) func hash7(_ u: UInt64) -> Int {
        Int(truncatingIfNeeded: ((u << 8) &* 58_295_818_150_454_627) >> (64 - 15))
    }

    @inline(__always) func load32(_ i: Int) -> UInt32 {
        UInt32(hist[i]) | UInt32(hist[i + 1]) << 8 | UInt32(hist[i + 2]) << 16 | UInt32(hist[i + 3]) << 24
    }

    @inline(__always) func load64(_ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in (0..<8).reversed() { v = v << 8 | UInt64(hist[i + k]) }
        return v
    }

    /// The common length of hist[s...] and hist[t...], for at most `limit` bytes past s.
    @inline(__always) func matchLen(_ s: Int, _ t: Int, _ limit: Int) -> Int {
        let end = min(s + limit, hist.count)
        var n = 0
        while s + n < end && hist[s + n] == hist[t + n] { n += 1 }
        return n
    }

    func matchLenLimited(_ s: Int, _ t: Int) -> Int { matchLen(s, t, GoFlate.maxMatchLength - 4) }

    func matchLenLong(_ s: Int, _ t: Int) -> Int { matchLen(s, t, Int.max - s) }

    func addBlock(_ src: [UInt8]) -> Int {
        if hist.count + src.count > histCap {
            if histCap == 0 {
                histCap = GoFlate.allocHistory
                hist.reserveCapacity(histCap)
            } else {
                let offset = hist.count - GoFlate.maxMatchOffset
                for i in 0..<GoFlate.maxMatchOffset { hist[i] = hist[offset + i] }
                cur += offset
                hist.removeLast(hist.count - GoFlate.maxMatchOffset)
            }
        }
        let s = hist.count
        hist += src
        return s
    }

    func reset() {
        if histCap < GoFlate.allocHistory {
            histCap = GoFlate.allocHistory
            hist = []
            hist.reserveCapacity(histCap)
        }
        if cur <= GoFlate.bufferReset {
            cur += GoFlate.maxMatchOffset + hist.count
        }
        hist.removeAll(keepingCapacity: true)
    }

    func encode(_ dst: GoTokens, _ block: [UInt8]) {
        let inputMargin = 12 - 1
        let minNonLiteralBlockSize = 1 + 1 + inputMargin
        let maxMatchOffset = GoFlate.maxMatchOffset

        while cur >= GoFlate.bufferReset {
            if hist.isEmpty {
                for i in 0..<table.count { table[i] = 0; bCur[i] = 0; bPrev[i] = 0 }
                cur = maxMatchOffset
                break
            }
            let minOff = cur + hist.count - maxMatchOffset
            for i in 0..<table.count {
                let v = Int(table[i])
                table[i] = v <= minOff ? 0 : Int32(v - cur + maxMatchOffset)
            }
            for i in 0..<bCur.count {
                let vc = Int(bCur[i])
                let vp = Int(bPrev[i])
                if vc <= minOff {
                    bCur[i] = 0
                    bPrev[i] = 0
                } else {
                    bCur[i] = Int32(vc - cur + maxMatchOffset)
                    bPrev[i] = vp <= minOff ? 0 : Int32(vp - cur + maxMatchOffset)
                }
            }
            cur = maxMatchOffset
        }

        var s = addBlock(block)
        if block.count < minNonLiteralBlockSize {
            dst.n = block.count
            return
        }

        let srcCount = hist.count
        var nextEmit = s
        let sLimit = srcCount - inputMargin
        var cv = load64(s)
        var repeatDist = 1

        outer: while true {
            var nextS = s
            var l = 0
            var t = 0
            inner: while true {
                var nextHashS = hash4(cv)
                var nextHashL = hash7(cv)
                s = nextS
                nextS = s + 1 + ((s - nextEmit) >> 7)
                if nextS > sLimit { break outer }
                let sCandidate = Int(table[nextHashS])
                let lCandCur = Int(bCur[nextHashL])
                let lCandPrev = Int(bPrev[nextHashL])
                let next = load64(nextS)
                let entry = Int32(s + cur)
                table[nextHashS] = entry
                bPrev[nextHashL] = bCur[nextHashL]
                bCur[nextHashL] = entry

                nextHashS = hash4(next)
                nextHashL = hash7(next)

                t = lCandCur - cur
                if s - t < maxMatchOffset {
                    if UInt32(truncatingIfNeeded: cv) == load32(t) {
                        table[nextHashS] = Int32(nextS + cur)
                        bPrev[nextHashL] = bCur[nextHashL]
                        bCur[nextHashL] = Int32(nextS + cur)
                        let t2 = lCandPrev - cur
                        if s - t2 < maxMatchOffset && UInt32(truncatingIfNeeded: cv) == load32(t2) {
                            l = matchLenLimited(s + 4, t + 4) + 4
                            let ml1 = matchLenLimited(s + 4, t2 + 4) + 4
                            if ml1 > l {
                                t = t2
                                l = ml1
                                break inner
                            }
                        }
                        break inner
                    }
                    t = lCandPrev - cur
                    if s - t < maxMatchOffset && UInt32(truncatingIfNeeded: cv) == load32(t) {
                        table[nextHashS] = Int32(nextS + cur)
                        bPrev[nextHashL] = bCur[nextHashL]
                        bCur[nextHashL] = Int32(nextS + cur)
                        break inner
                    }
                }

                t = sCandidate - cur
                if s - t < maxMatchOffset && UInt32(truncatingIfNeeded: cv) == load32(t) {
                    l = matchLenLimited(s + 4, t + 4) + 4
                    let lc2Cur = Int(bCur[nextHashL])
                    let lc2Prev = Int(bPrev[nextHashL])
                    table[nextHashS] = Int32(nextS + cur)
                    bPrev[nextHashL] = bCur[nextHashL]
                    bCur[nextHashL] = Int32(nextS + cur)

                    let repOff = 1
                    var t2 = s - repeatDist + repOff
                    if load32(t2) == UInt32(truncatingIfNeeded: cv >> (8 * UInt64(repOff))) {
                        let ml = matchLenLimited(s + 4 + repOff, t2 + 4) + 4
                        if ml > l {
                            t = t2
                            l = ml
                            s += repOff
                            break inner
                        }
                    }
                    t2 = lc2Cur - cur
                    if nextS - t2 < maxMatchOffset {
                        if load32(t2) == UInt32(truncatingIfNeeded: next) {
                            let ml = matchLenLimited(nextS + 4, t2 + 4) + 4
                            if ml > l {
                                t = t2
                                s = nextS
                                l = ml
                            }
                        }
                        t2 = lc2Prev - cur
                        if nextS - t2 < maxMatchOffset && load32(t2) == UInt32(truncatingIfNeeded: next) {
                            let ml = matchLenLimited(nextS + 4, t2 + 4) + 4
                            if ml > l {
                                t = t2
                                s = nextS
                                l = ml
                                break inner
                            }
                        }
                    }
                    break inner
                }
                cv = next
            }

            if l == 0 {
                l = matchLenLong(s + 4, t + 4) + 4
            } else if l == GoFlate.maxMatchLength {
                l += matchLenLong(s + l, t + l)
            }

            let sAt = s + l
            if sAt < sLimit {
                let skipBeginning = 2
                let idx = hash7(load64(sAt))
                var t2 = Int(bCur[idx]) - cur - l + skipBeginning
                let s2 = s + skipBeginning
                let off = s2 - t2
                if off < maxMatchOffset {
                    if off > 0 && t2 >= 0 {
                        let l2 = matchLenLong(s2, t2)
                        if l2 > l {
                            t = t2
                            l = l2
                            s = s2
                        }
                    }
                    t2 = Int(bPrev[idx]) - cur - l + skipBeginning
                    let off2 = s2 - t2
                    if off2 > 0 && off2 < maxMatchOffset && t2 >= 0 {
                        let l2 = matchLenLong(s2, t2)
                        if l2 > l {
                            t = t2
                            l = l2
                            s = s2
                        }
                    }
                }
            }

            while t > 0 && s > nextEmit && hist[t - 1] == hist[s - 1] {
                s -= 1
                t -= 1
                l += 1
            }
            if nextEmit < s {
                for i in nextEmit..<s { dst.addLiteral(hist[i]) }
            }

            dst.addMatchLong(l, UInt32(s - t - 1))
            repeatDist = s - t
            s += l
            nextEmit = s
            if nextS >= s { s = nextS + 1 }

            if s >= sLimit {
                var i = nextS + 1
                while i < srcCount - 8 {
                    let v = load64(i)
                    table[hash4(v)] = Int32(i + cur)
                    let li = hash7(v)
                    bPrev[li] = bCur[li]
                    bCur[li] = Int32(i + cur)
                    i += 2
                }
                break outer
            }

            var i = nextS + 1
            while i < s - 1 {
                let v = load64(i)
                let te = Int32(i + cur)
                let te2 = te + 1
                let li = hash7(v)
                let li2 = hash7(v >> 8)
                table[hash4(v)] = te
                bPrev[li] = bCur[li]
                bCur[li] = te
                bPrev[li2] = bCur[li2]
                bCur[li2] = te2
                i += 2
            }
            cv = load64(s)
        }

        if nextEmit < srcCount {
            if dst.n == 0 { return }
            for i in nextEmit..<srcCount { dst.addLiteral(hist[i]) }
        }
    }
}

/// Go's compressor at level 6 (DefaultCompression): a window of up to 65535 bytes, encoded when
/// full and when closed.
fileprivate final class GoDeflater6 {
    let w = GoHuffmanBitWriter(logNewTablePenalty: 7)
    let fast = GoFastEncL6()
    let tokens = GoTokens()
    var window = [UInt8](repeating: 0, count: GoFlate.maxStoreBlockSize)
    var windowEnd = 0
    var sync = false

    func write(_ b: [UInt8]) {
        var off = 0
        while off < b.count {
            if windowEnd == window.count || sync { deflateFast() }
            let n = min(window.count - windowEnd, b.count - off)
            for i in 0..<n { window[windowEnd + i] = b[off + i] }
            windowEnd += n
            off += n
        }
    }

    func writeStoredBlock(_ buf: [UInt8]) {
        w.writeStoredHeader(buf.count, false)
        w.writeBytes(buf)
    }

    func deflateFast() {
        if windowEnd < window.count {
            if !sync { return }
            if windowEnd < 128 {
                if windowEnd == 0 { return }
                let input = Array(window[0..<windowEnd])
                if windowEnd <= 32 {
                    writeStoredBlock(input)
                } else {
                    w.writeBlockHuff(false, input, true)
                }
                tokens.reset()
                windowEnd = 0
                fast.reset()
                return
            }
        }
        let input = Array(window[0..<windowEnd])
        fast.encode(tokens, input)
        if tokens.n == 0 {
            writeStoredBlock(input)
        } else if tokens.n > windowEnd - (windowEnd >> 4) {
            w.writeBlockHuff(false, input, sync)
        } else {
            w.writeBlockDynamic(tokens, false, input, sync)
        }
        tokens.reset()
        windowEnd = 0
    }

    func close() -> [UInt8] {
        sync = true
        deflateFast()
        w.writeStoredHeader(0, true)
        w.flush()
        return w.out
    }
}

// MARK: - Inflate, as Go 1.27's compress/flate and compress/zlib read it

fileprivate struct GoHuffmanDecoder {
    var min = 0
    var chunks = [UInt32](repeating: 0, count: 512)
    var links: [[UInt32]] = []
    var linkMask: UInt32 = 0

    mutating func initialize(_ lengths: ArraySlice<Int>) -> Bool {
        if min != 0 { self = GoHuffmanDecoder() }
        var count = [Int](repeating: 0, count: 16)
        var mn = 0
        var mx = 0
        for n in lengths where n != 0 {
            if mn == 0 || n < mn { mn = n }
            if n > mx { mx = n }
            count[n] += 1
        }
        if mx == 0 { return true }

        var code = 0
        var nextcode = [Int](repeating: 0, count: 16)
        for i in mn...mx {
            code <<= 1
            nextcode[i] = code
            code += count[i]
        }
        if code != 1 << mx && !(code == 1 && mx == 1) { return false }

        min = mn
        if mx > 9 {
            let numLinks = 1 << (mx - 9)
            linkMask = UInt32(numLinks - 1)
            let link = nextcode[10] >> 1
            links = [[UInt32]](repeating: [], count: 512 - link)
            for j in link..<512 {
                let reverse = Int(GoFlate.reverse16(UInt16(j))) >> 7
                let off = j - link
                chunks[reverse] = UInt32(off << 4 | 10)
                links[off] = [UInt32](repeating: 0, count: numLinks)
            }
        }

        for (i, n) in lengths.enumerated() where n != 0 {
            let c = nextcode[n]
            nextcode[n] += 1
            let chunk = UInt32(i << 4 | n)
            var reverse = Int(GoFlate.reverse16(UInt16(truncatingIfNeeded: c))) >> (16 - n)
            if n <= 9 {
                var off = reverse
                while off < chunks.count {
                    chunks[off] = chunk
                    off += 1 << n
                }
            } else {
                let j = reverse & 511
                let value = Int(chunks[j] >> 4)
                reverse >>= 9
                var off = reverse
                while off < links[value].count {
                    links[value][off] = chunk
                    off += 1 << (n - 9)
                }
            }
        }
        return true
    }

    static let fixed: GoHuffmanDecoder = {
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0..<144 { lengths[i] = 8 }
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        for i in 280..<288 { lengths[i] = 8 }
        var h = GoHuffmanDecoder()
        _ = h.initialize(lengths[...])
        return h
    }()
}

fileprivate enum GoInflateFailure: Error, Equatable {
    case eof
    case unexpectedEOF
    case corrupt
}

/// Go's decompressor: the same steps, so that output comes out in the same pieces, each with the
/// error Go reports with it.
fileprivate final class GoInflater {
    enum Step { case nextBlock, huffmanBlock, copyData }

    let src: [UInt8]
    var rpos: Int
    var b: UInt32 = 0
    var nb: UInt32 = 0
    var h1 = GoHuffmanDecoder()
    var h2 = GoHuffmanDecoder()
    var bits = [Int](repeating: 0, count: 286 + 30)
    var codebits = [Int](repeating: 0, count: 19)

    var hist = [UInt8](repeating: 0, count: 1 << 15)
    var wrPos = 0
    var rdPos = 0
    var full = false

    var step: Step = .nextBlock
    var stepStateDict = false
    var final = false
    var err: GoInflateFailure?
    var toRead: [UInt8] = []
    var fixedTables = false
    var copyLen = 0
    var copyDist = 0

    init(_ src: [UInt8], start: Int) {
        self.src = src
        self.rpos = start
    }

    static let codeOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// The next piece of output and the error Go returns with its last byte.
    func readChunk() -> ([UInt8], GoInflateFailure?) {
        while true {
            if !toRead.isEmpty {
                let chunk = toRead
                toRead = []
                return (chunk, err)
            }
            if let e = err { return ([], e) }
            switch step {
            case .nextBlock: nextBlock()
            case .huffmanBlock: huffmanBlock()
            case .copyData: copyData()
            }
            if err != nil && toRead.isEmpty { toRead = readFlush() }
        }
    }

    // The dictionary.

    func histSize() -> Int { full ? hist.count : wrPos }

    func readFlush() -> [UInt8] {
        let out = Array(hist[rdPos..<wrPos])
        rdPos = wrPos
        if wrPos == hist.count {
            wrPos = 0
            rdPos = 0
            full = true
        }
        return out
    }

    func writeCopy(_ dist: Int, _ length: Int) -> Int {
        let dstBase = wrPos
        let endPos = Swift.min(dstBase + length, hist.count)
        var srcPos = dstBase - dist
        if srcPos < 0 { srcPos += hist.count }
        var d = dstBase
        while d < endPos {
            hist[d] = hist[srcPos]
            d += 1
            srcPos += 1
            if srcPos == hist.count { srcPos = 0 }
        }
        wrPos = endPos
        return endPos - dstBase
    }

    func tryWriteCopy(_ dist: Int, _ length: Int) -> Int {
        let dstPos = wrPos
        let endPos = dstPos + length
        if dstPos < dist || endPos > hist.count { return 0 }
        var d = dstPos
        while d < endPos {
            hist[d] = hist[d - dist]
            d += 1
        }
        wrPos = endPos
        return endPos - dstPos
    }

    // The bits.

    func moreBits() -> GoInflateFailure? {
        guard rpos < src.count else { return .unexpectedEOF }
        b |= UInt32(src[rpos]) << nb
        rpos += 1
        nb += 8
        return nil
    }

    func huffSym(_ h: GoHuffmanDecoder) -> Result<Int, GoInflateFailure> {
        var n = UInt32(h.min)
        var nbL = nb
        var bL = b
        while true {
            while nbL < n {
                guard rpos < src.count else {
                    b = bL
                    nb = nbL
                    return .failure(.unexpectedEOF)
                }
                bL |= UInt32(src[rpos]) << (nbL & 31)
                rpos += 1
                nbL += 8
            }
            var chunk = h.chunks[Int(bL & 511)]
            n = chunk & 15
            if n > 9 {
                chunk = h.links[Int(chunk >> 4)][Int((bL >> 9) & h.linkMask)]
                n = chunk & 15
            }
            if n <= nbL {
                if n == 0 {
                    b = bL
                    nb = nbL
                    return .failure(.corrupt)
                }
                b = bL >> (n & 31)
                nb = nbL - n
                return .success(Int(chunk >> 4))
            }
        }
    }

    // The blocks.

    func nextBlock() {
        while nb < 3 {
            if let e = moreBits() { err = e; return }
        }
        final = b & 1 == 1
        b >>= 1
        let typ = b & 3
        b >>= 2
        nb -= 3
        switch typ {
        case 0:
            dataBlock()
        case 1:
            fixedTables = true
            huffmanBlock()
        case 2:
            if let e = readHuffman() {
                err = e
                return
            }
            fixedTables = false
            huffmanBlock()
        default:
            err = .corrupt
        }
    }

    func readHuffman() -> GoInflateFailure? {
        while nb < 5 + 5 + 4 {
            if let e = moreBits() { return e }
        }
        let nlit = Int(b & 0x1F) + 257
        if nlit > 286 { return .corrupt }
        b >>= 5
        let ndist = Int(b & 0x1F) + 1
        if ndist > 30 { return .corrupt }
        b >>= 5
        let nclen = Int(b & 0xF) + 4
        b >>= 4
        nb -= 5 + 5 + 4

        for i in 0..<nclen {
            while nb < 3 {
                if let e = moreBits() { return e }
            }
            codebits[GoInflater.codeOrder[i]] = Int(b & 0x7)
            b >>= 3
            nb -= 3
        }
        for i in nclen..<GoInflater.codeOrder.count { codebits[GoInflater.codeOrder[i]] = 0 }
        if !h1.initialize(codebits[...]) { return .corrupt }

        var i = 0
        let n = nlit + ndist
        while i < n {
            let x: Int
            switch huffSym(h1) {
            case .success(let v): x = v
            case .failure(let e): return e
            }
            if x < 16 {
                bits[i] = x
                i += 1
                continue
            }
            var rep: Int
            let nbits: UInt32
            let value: Int
            switch x {
            case 16:
                rep = 3
                nbits = 2
                if i == 0 { return .corrupt }
                value = bits[i - 1]
            case 17:
                rep = 3
                nbits = 3
                value = 0
            case 18:
                rep = 11
                nbits = 7
                value = 0
            default:
                return .corrupt
            }
            while nb < nbits {
                if let e = moreBits() { return e }
            }
            rep += Int(b & ((1 << nbits) - 1))
            b >>= nbits
            nb -= nbits
            if i + rep > n { return .corrupt }
            for _ in 0..<rep {
                bits[i] = value
                i += 1
            }
        }

        if !h1.initialize(bits[0..<nlit]) || !h2.initialize(bits[nlit..<(nlit + ndist)]) { return .corrupt }
        if h1.min < bits[GoFlate.endBlockMarker] { h1.min = bits[GoFlate.endBlockMarker] }
        return nil
    }

    func huffmanBlock() {
        var atCopy = stepStateDict
        while true {
            if !atCopy {
                let v: Int
                switch huffSym(fixedTables ? GoHuffmanDecoder.fixed : h1) {
                case .success(let x): v = x
                case .failure(let e): err = e; return
                }
                var n: UInt32 = 0
                var length = 0
                switch v {
                case ..<256:
                    hist[wrPos] = UInt8(v)
                    wrPos += 1
                    if wrPos == hist.count {
                        toRead = readFlush()
                        step = .huffmanBlock
                        stepStateDict = false
                        return
                    }
                    continue
                case 256:
                    finishBlock()
                    return
                case ..<265:
                    length = v - (257 - 3)
                    n = 0
                case ..<269:
                    length = v * 2 - (265 * 2 - 11)
                    n = 1
                case ..<273:
                    length = v * 4 - (269 * 4 - 19)
                    n = 2
                case ..<277:
                    length = v * 8 - (273 * 8 - 35)
                    n = 3
                case ..<281:
                    length = v * 16 - (277 * 16 - 67)
                    n = 4
                case ..<285:
                    length = v * 32 - (281 * 32 - 131)
                    n = 5
                case ..<286:
                    length = 258
                    n = 0
                default:
                    err = .corrupt
                    return
                }
                if n > 0 {
                    while nb < n {
                        if let e = moreBits() { err = e; return }
                    }
                    length += Int(b & ((1 << n) - 1))
                    b >>= n
                    nb -= n
                }

                var dist: Int
                if fixedTables {
                    while nb < 5 {
                        if let e = moreBits() { err = e; return }
                    }
                    let r = UInt8(truncatingIfNeeded: (b & 0x1F) << 3)
                    dist = Int(UInt8(truncatingIfNeeded: GoFlate.reverse16(UInt16(r)) >> 8))
                    b >>= 5
                    nb -= 5
                } else {
                    switch huffSym(h2) {
                    case .success(let x): dist = x
                    case .failure(let e): err = e; return
                    }
                }

                switch dist {
                case ..<4:
                    dist += 1
                case ..<30:
                    let nbx = UInt32(dist - 2) >> 1
                    var extra = (dist & 1) << Int(nbx)
                    while nb < nbx {
                        if let e = moreBits() { err = e; return }
                    }
                    extra |= Int(b & ((1 << nbx) - 1))
                    b >>= nbx
                    nb -= nbx
                    dist = 1 << (Int(nbx) + 1) + 1 + extra
                default:
                    err = .corrupt
                    return
                }
                if dist > histSize() {
                    err = .corrupt
                    return
                }
                copyLen = length
                copyDist = dist
            }

            atCopy = false
            var cnt = tryWriteCopy(copyDist, copyLen)
            if cnt == 0 { cnt = writeCopy(copyDist, copyLen) }
            copyLen -= cnt
            if wrPos == hist.count || copyLen > 0 {
                toRead = readFlush()
                step = .huffmanBlock
                stepStateDict = true
                return
            }
        }
    }

    func dataBlock() {
        nb = 0
        b = 0
        if src.count - rpos < 4 {
            rpos = src.count
            err = .unexpectedEOF
            return
        }
        let n = Int(src[rpos]) | Int(src[rpos + 1]) << 8
        let nn = Int(src[rpos + 2]) | Int(src[rpos + 3]) << 8
        rpos += 4
        if UInt16(nn) != ~UInt16(n) {
            err = .corrupt
            return
        }
        if n == 0 {
            toRead = readFlush()
            finishBlock()
            return
        }
        copyLen = n
        copyData()
    }

    func copyData() {
        let want = Swift.min(hist.count - wrPos, copyLen)
        let cnt = Swift.min(want, src.count - rpos)
        for i in 0..<cnt { hist[wrPos + i] = src[rpos + i] }
        rpos += cnt
        copyLen -= cnt
        wrPos += cnt
        if cnt < want {
            err = .unexpectedEOF
            return
        }
        if wrPos == hist.count || copyLen > 0 {
            toRead = readFlush()
            step = .copyData
            return
        }
        finishBlock()
    }

    func finishBlock() {
        if final {
            if wrPos - rdPos > 0 { toRead = readFlush() }
            err = .eof
        }
        step = .nextBlock
    }
}

/// io.ReadAll over zlib.NewReader (through io.LimitReader when there is a limit): the bytes, or
/// nil where Go returns an error.
fileprivate func goZlibRead(_ data: [UInt8], limit: Int?) -> [UInt8]? {
    if data.count < 2 { return nil }
    let s0 = data[0]
    let s1 = data[1]
    let h = UInt16(s0) << 8 | UInt16(s1)
    if s0 & 0x0f != 8 || s0 >> 4 > 7 || h % 31 != 0 { return nil }
    var start = 2
    if s1 & 0x20 != 0 {
        // A preset dictionary: Go's reader has none, whose Adler-32 is 1.
        if data.count < 6 { return nil }
        if be32(data, 2) != 1 { return nil }
        start = 6
    }
    let f = GoInflater(data, start: start)
    var out: [UInt8] = []
    while true {
        if let limit = limit, out.count >= limit { return out }
        let (chunk, e) = f.readChunk()
        if let limit = limit, out.count + chunk.count > limit {
            out += chunk[0..<(limit - out.count)]
            return out
        }
        out += chunk
        guard let failure = e else { continue }
        if failure != .eof { return nil }
        if f.rpos + 4 > data.count { return nil }
        return be32(data, f.rpos) == adler32(out) ? out : nil
    }
}
