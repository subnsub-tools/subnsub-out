//
//  ScreenRFB.swift
//
//  The messages of Apple's Screen Sharing that this Mac's client writes, and
//  the few it reads before a session's own parsing takes over. Screen Sharing
//  speaks RFB (the VNC protocol) with Apple's extensions: after the sign-in
//  (ScreenAuth.swift) the viewer says what it is (ViewerInfo, 0x21), asks for
//  the record encryption (0x12), names the encodings it reads (0x02), offers
//  its media (0x1c, with the SRTP keys of both directions) and asks for a
//  display of its own (0x1d): a session is High Performance alone.
//
//  Every message here is written byte for byte as the Go client the helper
//  ran until 2026-11-25 wrote it (helper/go/applehp/rfb.go), which matched
//  the system's own viewer.
//

import Foundation
import CommonCrypto

public enum ScreenRFB {
    // Messages the viewer sends.
    public static let clientSetEncodings: UInt8 = 0x02
    public static let clientFramebufferRequest: UInt8 = 0x03
    public static let clientKeyEvent: UInt8 = 0x04
    public static let clientPointerEvent: UInt8 = 0x05
    public static let clientSetMode: UInt8 = 0x0a
    public static let clientEncryptedInput: UInt8 = 0x10
    public static let clientSetEncryption: UInt8 = 0x12
    public static let clientAutoPasteboard: UInt8 = 0x15
    public static let clientMediaNegotiation: UInt8 = 0x1c
    public static let clientVirtualDisplay: UInt8 = 0x1d
    public static let clientClipboardSend: UInt8 = 0x1f
    public static let clientViewerInfo: UInt8 = 0x21

    // Messages the host sends.
    public static let serverFramebufferUpdate: UInt8 = 0x00
    public static let serverSetColorMap: UInt8 = 0x01
    public static let serverBell: UInt8 = 0x02
    public static let serverCutText: UInt8 = 0x03
    public static let serverMiscStatus: UInt8 = 0x14
    public static let serverClipboardSend: UInt8 = 0x1f

    // Encodings.
    public static let encRaw: Int32 = 0
    public static let encZlib: Int32 = 6
    public static let encDesktopSize: Int32 = -223
    public static let encApplePointer: Int32 = 1100
    public static let encAppleSelector: Int32 = 1101
    public static let encAppleMediaInit: Int32 = 1010
    public static let encAppleMVS: Int32 = 1011
    public static let encAppleHighQuality: Int32 = 1002
    public static let encAppleRekey: Int32 = 1103
    public static let encAppleCursor: Int32 = 1104
    public static let encAppleLayout: Int32 = 1105
    public static let encAppleKeysyms: Int32 = 1107
    public static let encAppleInputSource: Int32 = 1109
    public static let encAppleDevice: Int32 = 1110

    /// What a High Performance session names, before and after the rekey.
    public static let highPerformanceEncodings: [Int32] = [1010, 1011, 1002, 6, 16, 1104, 1100, -223, 1101, 1105, 1107, 1109, 1110]

    /// A stable macOS release, so hosts of every supported version take their usual path.
    public static let viewerOSVersion: (UInt32, UInt32, UInt32) = (15, 3, 0)

    /// The capability bitmap of ViewerInfo, as the system's viewer sends it.
    public static func viewerCommandMask() -> [UInt8] {
        var m = [UInt8](repeating: 0, count: 32)
        m[0] = 0xb0; m[2] = 0x0c; m[3] = 0x03; m[4] = 0x90; m[10] = 0x40
        return m
    }

    /// ViewerInfo (0x21), the first message after the sign-in.
    public static func viewerInfo(os: (UInt32, UInt32, UInt32) = viewerOSVersion) -> [UInt8] {
        var b: [UInt8] = [clientViewerInfo, 0]
        b.put16(0x3e); b.put16(1); b.put32(2); b.put32(6); b.put32(1); b.put32(0)
        b.put32(os.0); b.put32(os.1); b.put32(os.2)
        b += viewerCommandMask()
        return b
    }

    /// SetEncryption, command 1: sent in the clear right after ViewerInfo.
    public static let setEncryptionFollowup: [UInt8] = [0x12, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01]
    /// SetEncryption, command 2: after the rekey, before the media offer.
    public static let postEncryptionToggle: [UInt8] = [0x12, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00]

    public static func setEncodings(_ encodings: [Int32]) -> [UInt8] {
        var b: [UInt8] = [clientSetEncodings, 0]
        b.put16(UInt16(encodings.count))
        for e in encodings { b.put32(UInt32(bitPattern: e)) }
        return b
    }

    public static func framebufferRequest(incremental: Bool, x: UInt16 = 0, y: UInt16 = 0, w: UInt16 = 0xffff, h: UInt16 = 0xffff) -> [UInt8] {
        var b: [UInt8] = [clientFramebufferRequest, incremental ? 1 : 0]
        b.put16(x); b.put16(y); b.put16(w); b.put16(h)
        return b
    }

    public static func keyEvent(down: Bool, keysym: UInt32) -> [UInt8] {
        var b: [UInt8] = [clientKeyEvent, down ? 1 : 0, 0, 0]
        b.put32(keysym)
        return b
    }

    public static func pointerEvent(buttons: UInt8, x: UInt16, y: UInt16) -> [UInt8] {
        var b: [UInt8] = [clientPointerEvent, buttons]
        b.put16(x); b.put16(y)
        return b
    }

    /// SetDisplayConfiguration (0x1d): a display of the session's own (a virtual display), of
    /// `width` by `height` as the modes are written (see `displayConfig`), following the window.
    /// `maxWidth` by `maxHeight` is the largest picture in pixels the display may be made at: the
    /// host makes none larger, and answers a bigger one with another size.
    public static func virtualDisplay(width: Int, height: Int, scale: Double, hdr: Bool, name: String,
                                      maxWidth: Int = 3840, maxHeight: Int = 2160) -> [UInt8] {
        let width = width <= 0 ? 1920 : width, height = height <= 0 ? 1080 : height
        let scale = scale <= 0 ? 1 : scale
        let name = name.isEmpty ? "subnsub Virtual Display" : name
        let modeCount = 5
        let diSize = 0x9c + 28 * modeCount
        var di = [UInt8](repeating: 0, count: diSize)
        di.set16(0x00, UInt16(diSize))
        let nameBytes = Array(name.utf8.prefix(119))
        di.replaceSubrange(0x02..<(0x02 + nameBytes.count), with: nameBytes)
        di.set32(0x7a, 1) // dynamic resolution
        di.set32(0x7e, 4) // a virtual display
        di.set32(0x82, Float32(369.45456).bitPattern)
        di.set32(0x86, Float32(207.81818).bitPattern)
        di.set32(0x8a, UInt32(max(1, maxWidth)))
        di.set32(0x8e, UInt32(max(1, maxHeight)))
        di.set16(0x92, 0)
        di.set16(0x94, 0)
        di.set32(0x96, 7)
        di.set16(0x9a, UInt16(modeCount))
        let native: [(Int, Int)] = [(1920, 1080), (1440, 900), (1920, 1080), (1440, 810), (1312, 848)]
        let sx = Double(width) / 1920, sy = Double(height) / 1080
        let flags: UInt32 = hdr ? 1 : 0
        for (i, mode) in native.enumerated() {
            let msw = max(1, Int(Double(mode.0) * sx + 0.5)), msh = max(1, Int(Double(mode.1) * sy + 0.5))
            // macOS reads a mode as its size in points, then that size divided by the pixel scale.
            let lw = max(1, Int(Double(msw) / scale + 0.5)), lh = max(1, Int(Double(msh) / scale + 0.5))
            let m = 0x9c + 28 * i
            di.set32(m, UInt32(msw)); di.set32(m + 4, UInt32(msh))
            di.set32(m + 8, UInt32(lw)); di.set32(m + 12, UInt32(lh))
            di.set64(m + 16, Double(60).bitPattern)
            di.set32(m + 24, flags)
        }
        let msgSize = 8 + diSize
        var out: [UInt8] = [clientVirtualDisplay, 0]
        out.put16(UInt16(msgSize)); out.put16(1); out.put16(1); out.put32(0)
        out += di
        return out
    }

    /// How a display of w by h points at a pixel scale is written: Macs read a mode's two pairs
    /// differently (one takes the first pair as the points, another as the pixels), and nothing
    /// before the display is made tells which; a session asks one way, reads the size the host made
    /// (0x451) and asks the other way when it is not the one asked for; a pixel a point, read the
    /// same by both, is what is left.
    public enum DisplayForm: Int { case pointsFirst, pixelsFirst, plain }

    /// `room` is the largest display the session may be asked for later, in pixels: the host reads
    /// the display's bounds only when it makes the display (ScreensharingAgent's initVirtualDisplay,
    /// read 2026-11-26); a later config is applied within them. So the first config of a session
    /// must already allow the largest screen its window may go full screen on.
    public static func displayConfig(width w: Int, height h: Int, scale: Double, hdr: Bool, form: DisplayForm,
                                     room: (width: Int, height: Int) = (0, 0)) -> [UInt8] {
        let name = "subnsub Virtual Display"
        // Room for the whole picture asked for, w by h points at `scale`, however the host reads
        // the modes, and for the room given. A window in full screen on a Retina screen needs more
        // than 3840 × 2160 pixels (1800 × 1130 points: 3600 × 2260), and a host bound to that made
        // it a pixel a point, the picture enlarged twice and blurred; 3840 × 2160 stays the least.
        let even = { (n: Int) -> Int in (n + 1) & ~1 }
        let k = max(scale, 1)
        let maxW = max(3840, even(Int((Double(w) * k).rounded(.up))), even(min(max(room.width, 0), 7680)))
        let maxH = max(2160, even(Int((Double(h) * k).rounded(.up))), even(min(max(room.height, 0), 4320)))
        if form == .plain || scale <= 1 {
            // An even number of pixels each way: an odd one was made and never sent.
            return virtualDisplay(width: w & ~1, height: h & ~1, scale: 1, hdr: hdr, name: name, maxWidth: maxW, maxHeight: maxH)
        }
        if form == .pixelsFirst {
            return virtualDisplay(width: Int(Double(w) * scale + 0.5), height: Int(Double(h) * scale + 0.5), scale: scale, hdr: hdr, name: name,
                                  maxWidth: maxW, maxHeight: maxH)
        }
        return virtualDisplay(width: w, height: h, scale: scale, hdr: hdr, name: name, maxWidth: maxW, maxHeight: maxH)
    }

    /// The four SRTP master key and salt blobs a media offer carries: audio and video, the
    /// viewer's and the host's.
    public struct NegotiationKeys {
        public static let blobLength = 46
        public var audioV: [UInt8], audioS: [UInt8], videoV: [UInt8], videoS: [UInt8]

        public init(audioV: [UInt8], audioS: [UInt8], videoV: [UInt8], videoS: [UInt8]) {
            self.audioV = audioV; self.audioS = audioS; self.videoV = videoV; self.videoS = videoS
        }

        public static func random() -> NegotiationKeys {
            NegotiationKeys(audioV: randomBytes(blobLength), audioS: randomBytes(blobLength),
                            videoV: randomBytes(blobLength), videoS: randomBytes(blobLength))
        }
    }

    /// MediaStreamConfiguration (0x1c): the media offer with its keys.
    public static func mediaOffer(audio: [UInt8], video: [UInt8], keys: NegotiationKeys, noCursor: Bool, altSession: Bool,
                                  callID: [UInt8] = randomBytes(16)) -> [UInt8] {
        let ms = audio.count + video.count + 0xd8
        var b = [UInt8](repeating: 0, count: ms + 4)
        b[0] = clientMediaNegotiation
        b.set16(2, UInt16(ms))
        b.set16(4, 3)
        var flags: UInt32 = 3
        if altSession { flags = (flags & ~2) | 4 } else if noCursor { flags |= 4 }
        b.set32(6, flags)
        b.set16(10, UInt16(audio.count))
        b.set16(12, UInt16(video.count))
        var id = callID
        id[6] = (id[6] & 0x0f) | 0x40
        id[8] = (id[8] & 0x3f) | 0x80
        b.replaceSubrange(0x14..<0x24, with: id)
        b.replaceSubrange(0x24..<0x52, with: keys.audioV)
        b.replaceSubrange(0x52..<0x80, with: keys.audioS)
        b.replaceSubrange(0x80..<(0x80 + audio.count), with: audio)
        let vo = 0x80 + audio.count
        b.replaceSubrange(vo..<(vo + 0x2e), with: keys.videoV)
        b.replaceSubrange((vo + 0x2e)..<(vo + 0x5c), with: keys.videoS)
        b.replaceSubrange((vo + 0x5c)..<(vo + 0x5c + video.count), with: video)
        return b
    }

    /// SessionSelect, command 0: share the console's session.
    public static func sessionSelectConsole(user: String) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 72)
        body.set16(0, 2)
        body[6] = 0
        let u = Array(user.utf8.prefix(body.count - 8 - 2))
        body.replaceSubrange(8..<(8 + u.count), with: u)
        var out: [UInt8] = []
        out.put16(UInt16(body.count))
        return out + body
    }

    /// SessionSelect, command 2: a session of its own for the account, its name and password
    /// encrypted with the session's ECB key.
    public static func sessionSelectOwn(user: String, password: String, ecbKey: [UInt8]) -> [UInt8]? {
        guard ecbKey.count >= 16 else { return nil }
        var userBuf = [UInt8](repeating: 0, count: 64), passBuf = [UInt8](repeating: 0, count: 64)
        let u = Array(user.utf8.prefix(63)), p = Array(password.utf8.prefix(63))
        userBuf.replaceSubrange(0..<u.count, with: u)
        passBuf.replaceSubrange(0..<p.count, with: p)
        var body = [UInt8](repeating: 0, count: 200)
        body.set16(0, 2)
        body[6] = 2
        guard let eu = aesECB(Array(ecbKey.prefix(16)), userBuf), let ep = aesECB(Array(ecbKey.prefix(16)), passBuf) else { return nil }
        body.replaceSubrange(0x48..<(0x48 + 64), with: eu)
        body.replaceSubrange(0x88..<(0x88 + 64), with: ep)
        var out: [UInt8] = []
        out.put16(UInt16(body.count))
        return out + body
    }

    public static let sessionSelectMagic: [UInt8] = [0x00, 0x4a, 0x00, 0x01]

    /// One of the host's displays in the layout (0x451), in backing pixels.
    public struct DisplayRect: Equatable {
        public var id: UInt32
        public var x, y, w, h: Int
    }

    /// The host's display layout (0x451): the backing size and its displays.
    public static func displayLayout(_ p: ArraySlice<UInt8>) -> (backingW: Int, backingH: Int, rects: [DisplayRect])? {
        let p = Array(p)
        guard p.count >= 20 else { return nil }
        let bw = Int(p.get16(6)), bh = Int(p.get16(8))
        let count = Int(p.get16(18))
        var rects: [DisplayRect] = []
        var off = 20
        var i = 0
        while i < count && off + 56 <= p.count {
            let id = p.get32(off + 16)
            let y0 = Int(p.get16(off + 28)), x0 = Int(p.get16(off + 30)), y1 = Int(p.get16(off + 32)), x1 = Int(p.get16(off + 34))
            if x1 > x0 && y1 > y0 { rects.append(DisplayRect(id: id, x: x0, y: y0, w: x1 - x0, h: y1 - y0)) }
            off += 56
            i += 1
        }
        return rects.isEmpty ? nil : (bw, bh, rects)
    }

    public static func randomBytes(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b
    }

    /// AES-128 in ECB over whole blocks.
    static func aesECB(_ key: [UInt8], _ data: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess, moved == data.count else { return nil }
        return Array(out.prefix(moved))
    }
}

// Big-endian helpers for building and reading messages.
extension Array where Element == UInt8 {
    mutating func put16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func put32(_ v: UInt32) { put16(UInt16(v >> 16)); put16(UInt16(v & 0xffff)) }
    mutating func put64(_ v: UInt64) { put32(UInt32(v >> 32)); put32(UInt32(v & 0xffff_ffff)) }
    mutating func set16(_ at: Int, _ v: UInt16) { self[at] = UInt8(v >> 8); self[at + 1] = UInt8(v & 0xff) }
    mutating func set32(_ at: Int, _ v: UInt32) { set16(at, UInt16(v >> 16)); set16(at + 2, UInt16(v & 0xffff)) }
    mutating func set64(_ at: Int, _ v: UInt64) { set32(at, UInt32(v >> 32)); set32(at + 4, UInt32(v & 0xffff_ffff)) }
    func get16(_ at: Int) -> UInt16 { UInt16(self[at]) << 8 | UInt16(self[at + 1]) }
    func get32(_ at: Int) -> UInt32 { UInt32(get16(at)) << 16 | UInt32(get16(at + 2)) }
}
