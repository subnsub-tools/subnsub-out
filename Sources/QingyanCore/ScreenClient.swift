//
//  ScreenClient.swift
//
//  out's own client for another Mac's Screen Sharing (user 2026-11-25: the
//  Monitor helper only gives a road and a port, and has nothing to do with
//  screen sharing). It is the client the helper ran on that Mac until
//  2026-11-25 (helper/go/applehp: client.go and stream.go), moved to the Mac
//  that shows the screen: it reaches the other Mac's Screen Sharing through
//  out there, which only carries its bytes (ScreenTunnel.swift).
//
//  A session of either kind begins the same way. The client says hello and
//  signs in (ScreenAuth.swift), says what it is and names its encodings in
//  the clear, and waits for the host's rekey (encoding 0x44f), from which the
//  record encryption of the rest of the connection is made.
//
//  A standard session then has its picture on that connection: rectangles of
//  the display in the Mac's own codec (RFB encoding 0x3f3, Adaptive Quality,
//  decoded by ScreenMVS.swift) or exact pixels, deflated. The host is asked to
//  send what changes as it changes, back to back, as the system's viewer asks
//  (auto update, 0x09, every 0 ms), and the connection is read only as fast
//  as this Mac draws, so that the host, which judges the way by how fast it
//  can write, sends what the way and this Mac can take.
//
//  A High Performance session offers its media (0x1c) with the SRTP keys of
//  both directions and is sent video (HEVC, one stream for the whole picture)
//  and sound (AAC-ELD) on UDP, which the other Mac's out carries as
//  datagrams; the host's reports and this Mac's ask for key frames.
//
//  Everything here runs with blocking reads on the session's own thread, as
//  the Go code did on its goroutines; datagrams are handled on a queue of
//  their own.
//

import Foundation
import CommonCrypto
import zlib

public final class ScreenClient: @unchecked Sendable {
    public struct Config {
        public var user: String
        public var password: String
        /// A standard session: the Mac's display as it is, on the connection itself.
        public var standard: Bool
        /// A display of the session's own (High Performance): `width` by `height` points at `scale`.
        public var ownDisplay: Bool
        public var width: Int
        public var height: Int
        public var scale: Double
        public var audio: Bool
        /// The bandwidth ceiling the media offer declares, bits a second; 0 leaves the protocol's own.
        public var maxBitrate: Int
        public var log: ((String) -> Void)?

        public init(user: String, password: String, standard: Bool, ownDisplay: Bool = false, width: Int = 1920, height: Int = 1080,
                    scale: Double = 1, audio: Bool = false, maxBitrate: Int = 0, log: ((String) -> Void)? = nil) {
            self.user = user; self.password = password; self.standard = standard; self.ownDisplay = ownDisplay
            self.width = width; self.height = height; self.scale = scale; self.audio = audio; self.maxBitrate = maxBitrate; self.log = log
        }
    }

    /// What the session hands over. Calls of one kind come one at a time, in the host's order.
    public struct Handler {
        public var hevcConfig: ((_ vps: [UInt8], _ sps: [UInt8], _ pps: [UInt8]) -> Void)?
        /// One access unit, its NAL units without start codes.
        public var videoFrame: ((_ stamp: UInt32, _ key: Bool, _ units: [[UInt8]]) -> Void)?
        public var audio: ((_ stamp: UInt32, _ sequence: UInt16, _ payloadType: UInt8, _ payload: [UInt8]) -> Void)?
        /// A cursor shape (RGBA) to keep under its id, and the one shown.
        public var cursorStore: ((_ id: UInt32, _ hotX: Int, _ hotY: Int, _ w: Int, _ h: Int, _ rgba: [UInt8]) -> Void)?
        public var cursorSelect: ((_ id: UInt32) -> Void)?
        /// The display: in points (what the pointer's coordinates are in) and in pixels.
        public var layout: ((_ scaledW: Int, _ scaledH: Int, _ backingW: Int, _ backingH: Int) -> Void)?
        public var clipboard: ((_ text: String) -> Void)?
        /// A standard session's picture: its size in pixels, a rectangle's pixels (BGRA rows) or the
        /// Mac's codec for it, and the end of an update.
        public var pictureSize: ((_ w: Int, _ h: Int) -> Void)?
        public var picture: ((_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ bgra: [UInt8]) -> Void)?
        public var pictureCoded: ((_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ body: ArraySlice<UInt8>) -> Void)?
        /// The update is all handed over; the reader waits for this to return before it reads on.
        public var pictureEnd: (() -> Void)?
        public init() {}
    }

    public struct Stats {
        public var videoPackets = 0, videoBad = 0
        public var frames = 0, keyframes = 0
        public var pictures = 0
        public var framesLost = 0
        public var audioPackets = 0, audioBad = 0
        public var bytes: Int64 = 0
        public var keyAsks = 0
    }

    public enum Failure: Error, CustomStringConvertible {
        /// The account or password was refused.
        case rejected
        case protocolError(String)
        case closed
        public var description: String {
            switch self {
            case .rejected: return "the sign-in was refused"
            case .protocolError(let s): return s
            case .closed: return "the connection closed"
            }
        }
    }

    // Limits, as the Go client had them.
    static let streamPendMax = 8 << 20
    static let picturePendMax = 160 << 20
    static let picturePixelsMax = 48 << 20
    static let pictureSideMax = 16384
    static let cursorSideMax = 512
    static let clipboardMax = 1 << 20
    static let keyAskEvery: TimeInterval = 1.5
    static let videoFrameMax = 6 << 20
    static let videoPacketsMax = 8192
    static let displaySettle: TimeInterval = 0.9

    private let link: ScreenTunnelLink
    private var config: Config
    private let lock = NSLock()
    private let sendLock = NSLock()
    private var cipher: ScreenRecordCipher?
    private var eventKeyOf: [UInt8] = []
    private var encBuffer: [UInt8] = []
    private var leftover: [[UInt8]] = []

    public private(set) var serverW = 0, serverH = 0
    private var pixels = ScreenRFB.PixelFormat()

    // High Performance media.
    private var keys = ScreenRFB.NegotiationKeys.random()
    private var videoSSRC: UInt32 = 0, audioSSRC: UInt32 = 0
    private var canvasW = 0, canvasH = 0, canvasTiles = 0
    private var videoDec: ScreenSRTPDecryptor?
    private var audioDec: ScreenSRTPDecryptor?
    private var ctrlEnc: ScreenSRTPControlEncryptor?
    private let media = DispatchQueue(label: "local.hopo.qingyan.screen.media", qos: .userInteractive)
    private var form: ScreenRFB.DisplayForm = .pointsFirst

    // The running session.
    private var running = false
    private var stopped = false
    private var stats = Stats()
    private var awaitKey = false
    private var lastKeyAsk = Date.distantPast
    private var primarySSRC: UInt32 = 0
    private var scaledW = 0, scaledH = 0, backingW = 0, backingH = 0
    private var layouts = 0
    private var resizeAsked = false
    private var askW = 0, askH = 0
    private var askLeft: [ScreenRFB.DisplayForm] = []
    private var askGen = 0
    private var askWork: DispatchWorkItem?
    private var cursorZ: ScreenInflater?
    private var clipZ: ScreenInflater?
    private var picW = 0, picH = 0
    private var picZ: ScreenInflater?
    private var picError: String?
    private var handler = Handler()
    private var feedback: DispatchSourceTimer?

    /// The form the host last made a display asked for in (a pixel a point is no form of its own).
    private static let formLock = NSLock()
    nonisolated(unsafe) private static var hostForm: ScreenRFB.DisplayForm = .pointsFirst

    public init(link: ScreenTunnelLink, config: Config) {
        self.link = link
        self.config = config
    }

    private func log(_ s: String) { config.log?(s) }

    // MARK: Signing in

    /// Screen Sharing's own client first connects once, says hello and hangs up (the warmup), then
    /// connects for the session; `reconnect` hangs the road's TCP connection up and makes another.
    public func connect(reconnect: () throws -> Void) throws {
        if !config.standard {
            link.onDatagram = { [weak self] channel, bytes in
                self?.media.async { self?.datagram(channel, bytes) }
            }
        }
        // The warmup: hello, the host's security types, and gone.
        do {
            _ = try ScreenAuth.handshake(link)
        } catch { log("warmup: \(error)") }
        // Hung up, a moment's wait (the caller's), and connected again for the session.
        try reconnect()
        // UDP: a byte from each port to the host's every 100 ms until the session is made, so the
        // host knows where to send.
        var punching: DispatchSourceTimer?
        if !config.standard {
            let timer = DispatchSource.makeTimerSource(queue: media)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                self?.link.sendDatagram(0, [0])
                self?.link.sendDatagram(1, [0])
            }
            timer.resume()
            punching = timer
        }
        defer { punching?.cancel() }

        let ecbKey = try signIn(reconnect: reconnect)
        // ClientInit (shared), ServerInit.
        try link.write([0xc1])
        let head = try link.readFull(24)
        let nameLength = Int(head.get32(20))
        guard nameLength <= 65536 else { throw Failure.protocolError("ServerInit name too long (\(nameLength))") }
        if nameLength > 0 { _ = try link.readFull(nameLength) }
        serverW = Int(head.get16(0)); serverH = Int(head.get16(2))
        pixels = ScreenRFB.PixelFormat(head[4..<20])
        log("ServerInit \(serverW)x\(serverH)")
        // A Mac with someone at it may ask whether to share that session: it is shared.
        if let peek = try link.peek(4, timeout: 1.5), peek == ScreenRFB.sessionSelectMagic {
            let prompt = try link.readFull(76)
            let user = String(decoding: prompt[0x0c...].prefix { $0 != 0 }, as: UTF8.self)
            try link.write(ScreenRFB.sessionSelectConsole(user: user))
            _ = try link.readSome(most: 64 << 10, timeout: 60)
        }
        // The prelude, in the clear.
        try link.write(ScreenRFB.viewerInfo() + ScreenRFB.setEncryptionFollowup)
        Thread.sleep(forTimeInterval: 0.1)
        if config.ownDisplay {
            form = Self.formLock.withLock { Self.hostForm }
            try link.write(ScreenRFB.displayConfig(width: config.width, height: config.height, scale: config.scale, hdr: false, form: form))
        }
        let encodings = config.standard ? ScreenRFB.codedEncodings : ScreenRFB.highPerformanceEncodings
        try link.write(ScreenRFB.setEncodings(encodings))
        try readUntilRekey(ecbKey: ecbKey)
        try link.write(ScreenRFB.postEncryptionToggle)
        Thread.sleep(forTimeInterval: 0.2)
        try drain(quiet: 0.35)
        log("encrypted")
        try sendEncrypted(ScreenRFB.setEncodings(encodings))
        if config.standard {
            if !pixels.usable {
                pixels = .bgrx
                try sendEncrypted(ScreenRFB.setPixelFormat(pixels))
            }
            return
        }
        // The media offer, and its answer: the size the host's encoder draws at.
        let offer = try ScreenOffer.createOffers(ScreenOfferOptions(codec: "hevc", tilesPerFrame: 1, audioEnabled: config.audio, ltrp: false, maxBitrate: config.maxBitrate))
        videoSSRC = offer.videoSSRC; audioSSRC = offer.audioSSRC
        keys = .random()
        let message = ScreenRFB.mediaOffer(audio: offer.audio, video: offer.video, keys: keys, noCursor: true, altSession: false)
        try sendEncrypted(message)
        try sendEncrypted(ScreenRFB.framebufferRequest(incremental: false))
        try readVideoAnswer(offer: message)
        log("media canvas \(canvasW)x\(canvasH) tiles \(canvasTiles)")
        videoDec = try ScreenSRTPDecryptor(keyBlob: keys.videoS)
        audioDec = try ScreenSRTPDecryptor(keyBlob: keys.audioS)
        ctrlEnc = try ScreenSRTPControlEncryptor(keyBlob: keys.videoV)
        sendFeedback(fir: nil)
    }

    /// Hello and the sign-in: SRP, and the older RSA sign-in on a new connection where the host
    /// asks for it.
    private func signIn(reconnect: () throws -> Void) throws -> [UInt8] {
        func hello() throws {
            let types = try ScreenAuth.handshake(link).securityTypes
            guard types.contains(ScreenAuth.securityTypeAppleRSA) else {
                throw Failure.protocolError("Screen Sharing offered no sign-in this client knows (\(types))")
            }
        }
        do {
            try hello()
            return try ScreenAuth.loginSRP(link, username: config.user, password: config.password)
        } catch ScreenAuthError.rejected {
            throw Failure.rejected
        } catch ScreenAuthError.srpFallback {
            log("SRP sign-in not taken; the older sign-in on a new connection")
            try reconnect()
            try hello()
            do { return try ScreenAuth.loginNonSRP(link, username: config.user, password: config.password) }
            catch ScreenAuthError.rejected { throw Failure.rejected }
        }
    }

    private func readUntilRekey(ecbKey: [UInt8]) throws {
        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let piece = try link.readSome(most: 64 << 10, timeout: 1)
            guard !piece.isEmpty else { continue }
            buffer += piece
            if let (blob, tail) = Self.scanForRekey(buffer) {
                let cipher = try ScreenRecordCipher(rekeyBlob: blob, wrapKey: ecbKey)
                self.cipher = cipher
                let rest = Array(buffer[tail...])
                let (_, used) = cipher.decryptStream(rest)
                encBuffer = Array(rest[used...])
                return
            }
        }
        throw Failure.protocolError("no rekey from the host in 10 s (it may be refusing connections that come too fast)")
    }

    /// The host's rekey (0x44f) in what came before it: its 36 bytes, and where what follows begins.
    static func scanForRekey(_ b: [UInt8]) -> ([UInt8], Int)? {
        var pos = 0
        while pos < b.count {
            switch b[pos] {
            case ScreenRFB.serverMiscStatus:
                guard pos + 8 <= b.count else { return nil }
                pos += 8
            case ScreenRFB.serverFramebufferUpdate:
                guard pos + 4 <= b.count else { return nil }
                let rects = Int(b.get16(pos + 2))
                var p = pos + 4
                for _ in 0..<rects {
                    guard p + 12 <= b.count else { return nil }
                    let enc = Int32(bitPattern: b.get32(p + 8))
                    p += 12
                    switch enc {
                    case ScreenRFB.encAppleRekey:
                        guard p + 36 <= b.count else { return nil }
                        return (Array(b[p..<(p + 36)]), p + 36)
                    case ScreenRFB.encAppleMediaInit, ScreenRFB.encAppleMVS:
                        guard p + 2 <= b.count else { return nil }
                        let n = Int(b.get16(p))
                        guard p + 2 + n <= b.count else { return nil }
                        p += 2 + n
                    default:
                        return nil
                    }
                }
                pos = p
            default:
                return nil
            }
        }
        return nil
    }

    /// Reads and decrypts until the host has been quiet `quiet` seconds; what it said is not needed.
    private func drain(quiet: TimeInterval) throws {
        guard let cipher else { return }
        if !encBuffer.isEmpty {
            let (_, used) = cipher.decryptStream(encBuffer)
            encBuffer.removeFirst(used)
        }
        while true {
            let piece = try link.readSome(most: 64 << 10, timeout: quiet)
            if piece.isEmpty { return }
            encBuffer += piece
            let (_, used) = cipher.decryptStream(encBuffer)
            encBuffer.removeFirst(used)
        }
    }

    private func readVideoAnswer(offer: [UInt8]) throws {
        guard let cipher else { return }
        for attempt in 0...16 {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.2)
                try sendEncrypted(offer)
                log("media offer again \(attempt)/16")
            }
            let deadline = Date().addingTimeInterval(attempt == 0 ? 3 : 1)
            while Date() < deadline {
                let piece = try link.readSome(most: 64 << 10, timeout: 0.3)
                if piece.isEmpty {
                    if canvasW > 0 && canvasH > 0 { return }
                    continue
                }
                encBuffer += piece
                let (messages, used) = cipher.decryptStream(encBuffer)
                encBuffer.removeFirst(used)
                for m in messages {
                    if canvasW == 0, let c = ScreenOffer.canvasDims(m) {
                        canvasW = c.width; canvasH = c.height; canvasTiles = c.tiles
                    } else {
                        leftover.append(m)
                    }
                }
                if canvasW > 0 && canvasH > 0 { return }
            }
        }
        throw Failure.protocolError("the host answered the media offer with no picture size")
    }

    // MARK: Sending

    private func sendEncrypted(_ message: [UInt8]) throws {
        guard let cipher else { throw Failure.closed }
        sendLock.lock()
        defer { sendLock.unlock() }
        try link.write(cipher.encrypt(message))
    }

    /// Keys and the pointer's buttons go as Apple's encrypted input event (0x10): a block encrypted
    /// with AES-128-ECB under the record key. In the block: [0] 0xff a key, [1] down, [2:6] keysym;
    /// [10] 0xff the pointer, [11] buttons and wheel (bit 0 left, 1 right, 2 middle, 3 to 6 a wheel
    /// tick up, down, left, right), [12:14] x, [14:16] y, in the display's pixels.
    private func sendEvent(_ block: [UInt8]) {
        guard let cipher, let encrypted = ScreenRFB.aesECB(Array(cipher.cbcKey.prefix(16)), block) else { return }
        try? sendEncrypted([ScreenRFB.clientEncryptedInput, 0] + encrypted)
    }

    /// The buttons as Screen Sharing counts them and where, in the display's points.
    public func sendPointer(buttons: UInt8, x: Int, y: Int) {
        var x = x, y = y
        let (sw, sh, bw, bh) = layout()
        if sw > 0, sh > 0, bw > sw, bh > sh {
            // The middle of the point, in pixels.
            x = (2 * x + 1) * bw / (2 * sw)
            y = (2 * y + 1) * bh / (2 * sh)
        }
        x = min(max(x, 0), 0xffff); y = min(max(y, 0), 0xffff)
        var p = [UInt8](repeating: 0, count: 16)
        p[10] = 0xff; p[11] = buttons
        p.set16(12, UInt16(x)); p.set16(14, UInt16(y))
        sendEvent(p)
    }

    public func sendKey(down: Bool, keysym: UInt32) {
        var p = [UInt8](repeating: 0, count: 16)
        p[0] = 0xff; p[1] = down ? 1 : 0
        p.set32(2, keysym)
        sendEvent(p)
    }

    /// Whether this Mac controls the screen or only observes it (0x0a), as the system's viewer says.
    public func setMode(control: Bool) {
        try? sendEncrypted([ScreenRFB.clientSetMode, 0, 0, control ? 1 : 0])
    }

    /// Text onto the host's clipboard: Latin-1 as RFB's ClientCutText, anything else as the system's
    /// viewer sends a clipboard (0x1f, one public.utf8-plain-text flavor, deflated). False when it
    /// is too long for one message.
    @discardableResult
    public func sendClipboard(_ text: String) -> Bool {
        if text.unicodeScalars.allSatisfy({ $0.value <= 0xff }) {
            let bytes = text.unicodeScalars.map { UInt8($0.value) }
            guard bytes.count <= 60000 else { return false }
            var m: [UInt8] = [0x06, 0, 0, 0]
            m.put32(UInt32(bytes.count))
            try? sendEncrypted(m + bytes)
            return true
        }
        let utf8 = Array(text.utf8)
        guard utf8.count <= Self.clipboardMax else { return false }
        let uti = Array("public.utf8-plain-text".utf8)
        var archive: [UInt8] = []
        archive.put32(1); archive.put32(UInt32(uti.count)); archive += uti
        archive.put32(0); archive.put32(0); archive.put32(UInt32(utf8.count)); archive += utf8
        guard let z = Self.zlibCompress(archive), z.count <= 60000 else { return false }
        var m = [UInt8](repeating: 0, count: 16)
        m[0] = ScreenRFB.clientClipboardSend
        m.set32(8, UInt32(archive.count)); m.set32(12, UInt32(z.count))
        try? sendEncrypted(m + z)
        return true
    }

    /// Asks the host to make the session's display w by h points at `scale`. Only a request: the size
    /// it settles on comes back as a layout.
    public func resize(width w: Int, height h: Int, scale: Double) {
        guard config.ownDisplay, w >= 320, h >= 200, w <= 7680, h <= 4320 else { return }
        lock.lock()
        config.width = w; config.height = h; config.scale = scale
        resizeAsked = true
        askW = w; askH = h; askLeft = Self.formsAfter(form, scale: scale)
        askGen += 1
        askWork?.cancel()
        let form = self.form
        lock.unlock()
        try? sendEncrypted(ScreenRFB.displayConfig(width: w, height: h, scale: scale, hdr: false, form: form))
    }

    static func formsAfter(_ form: ScreenRFB.DisplayForm, scale: Double) -> [ScreenRFB.DisplayForm] {
        guard scale > 1 else { return [] }
        switch form {
        case .pointsFirst: return [.pixelsFirst, .plain]
        case .pixelsFirst: return [.pointsFirst, .plain]
        case .plain: return []
        }
    }

    /// The host's answer to the display asked for, once its layouts have come to rest: the size
    /// asked for, and the form is the host's; another, and it is asked for again in the next form.
    private func askedDisplay(_ gen: Int) {
        lock.lock()
        guard gen == askGen else { lock.unlock(); return }
        let (w, h, sw, sh) = (askW, askH, scaledW, scaledH)
        func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= 2 }
        if w <= 0 || h <= 0 || (near(sw, w) && near(sh, h)) || askLeft.isEmpty {
            let done = w > 0 && h > 0 && near(sw, w) && near(sh, h)
            askLeft = []
            let form = self.form
            lock.unlock()
            if done && form != .plain { Self.formLock.withLock { Self.hostForm = form } }
            return
        }
        let next = askLeft.removeFirst()
        resizeAsked = true
        form = next
        let scale = config.scale
        lock.unlock()
        try? sendEncrypted(ScreenRFB.displayConfig(width: w, height: h, scale: scale, hdr: false, form: next))
    }

    /// Offers the media again under another bandwidth ceiling: the host starts its encoder anew.
    public func setMaxBitrate(_ bps: Int) {
        guard !config.standard, bps >= 0 else { return }
        lock.lock()
        let same = config.maxBitrate == bps
        config.maxBitrate = bps
        lock.unlock()
        if !same { reoffer() }
    }

    private func reoffer() {
        lock.lock()
        let audio = config.audio, bps = config.maxBitrate
        lock.unlock()
        guard let offer = try? ScreenOffer.createOffers(ScreenOfferOptions(codec: "hevc", tilesPerFrame: 1, audioEnabled: audio, ltrp: false, maxBitrate: bps)) else { return }
        lock.lock()
        videoSSRC = offer.videoSSRC; audioSSRC = offer.audioSSRC
        lock.unlock()
        try? sendEncrypted(ScreenRFB.mediaOffer(audio: offer.audio, video: offer.video, keys: keys, noCursor: true, altSession: false))
    }

    /// A picture that needs no other: a High Performance session asks at its next report; a
    /// standard one asks for the whole display again.
    public func requestKeyframe() {
        if config.standard { arm(); return }
        lock.lock()
        awaitKey = true
        lastKeyAsk = .distantPast
        lock.unlock()
    }

    /// The display as the host last said it: points and pixels (pixels 0 before it has said).
    public func layout() -> (Int, Int, Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return running ? (scaledW, scaledH, backingW, backingH) : (serverW, serverH, 0, 0)
    }

    public func canvas() -> (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (canvasW, canvasH)
    }

    public func currentStats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Keeps the host's cursor, layout and (standard) picture coming: auto update and one request
    /// for the whole display. A standard session has the host push what changes back to back, as
    /// the system's viewer does (every 0 ms), and names the display's own size (asked for 65535 by
    /// 65535 a Mac answers with two pixels of black). A High Performance one has it off.
    private func arm() {
        var w = 0xffff, h = 0xffff
        if config.standard {
            let (sw, sh, _, _) = layout()
            if sw > 0 && sh > 0 { w = sw; h = sh }
        }
        var m = [UInt8](repeating: 0, count: 16)
        m[0] = 0x09
        m.set16(2, 1)
        m.set32(4, config.standard ? 0 : 0xffff_ffff)
        m.set16(12, UInt16(w)); m.set16(14, UInt16(h))
        try? sendEncrypted(m)
        try? sendEncrypted(ScreenRFB.framebufferRequest(incremental: false, w: UInt16(w), h: UInt16(h)))
    }

    // MARK: Running

    /// Reads the session until the host or this side ends it; on this thread, blocking.
    public func run(_ handler: Handler) throws {
        lock.lock()
        self.handler = handler
        running = true
        awaitKey = !config.standard
        scaledW = serverW; scaledH = serverH
        if config.standard { picW = serverW; picH = serverH }
        if config.ownDisplay { askW = config.width; askH = config.height; askLeft = Self.formsAfter(form, scale: config.scale) }
        lock.unlock()
        if config.standard, picW > 0, picH > 0 { handler.pictureSize?(picW, picH) }
        arm()
        try? sendEncrypted([ScreenRFB.clientAutoPasteboard, 0, 0, 1, 0, 0, 0, 0])
        let timer = DispatchSource.makeTimerSource(queue: media)
        var ticks = 0
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            ticks += 1
            if self.config.standard {
                // No picture yet: asked for again every other second.
                if self.currentStats().pictures == 0 && ticks % 2 == 0 { self.arm() }
                return
            }
            self.lock.lock()
            var fir: UInt32?
            if self.awaitKey && self.primarySSRC != 0 && Date().timeIntervalSince(self.lastKeyAsk) >= Self.keyAskEvery {
                fir = self.primarySSRC
                self.lastKeyAsk = Date()
                self.stats.keyAsks += 1
            }
            self.lock.unlock()
            self.sendFeedback(fir: fir)
            self.flushVideoIfStale()
        }
        timer.resume()
        feedback = timer
        defer { timer.cancel() }
        try readControl()
    }

    public func close() {
        lock.lock()
        stopped = true
        lock.unlock()
        feedback?.cancel()
        link.close()
    }

    // MARK: The control stream

    private var pend: [UInt8] = []

    private func readControl() throws {
        guard let cipher else { throw Failure.closed }
        let pendMax = config.standard ? Self.picturePendMax : Self.streamPendMax
        var lostPlace = false
        func feed(_ body: [UInt8]) {
            pend += body
            var at = 0
            while at < pend.count {
                let (n, status) = parseServer(pend, from: at)
                if status == .more {
                    if pend.count - at > pendMax { pend = []; at = 0; if config.standard { lostPlace = true } }
                    break
                }
                if status == .lost || n <= 0 {
                    pend = []; at = 0
                    if config.standard { lostPlace = true }
                    break
                }
                at += n
            }
            if at > 0 { pend.removeFirst(at) }
        }
        for m in leftover { feed(m) }
        leftover = []
        var enc = encBuffer
        encBuffer = []
        while true {
            let (messages, used) = cipher.decryptStream(enc)
            enc.removeFirst(used)
            for m in messages { feed(m) }
            lock.lock()
            let failed = picError
            lock.unlock()
            if let failed { throw Failure.protocolError(failed) }
            if lostPlace { throw Failure.protocolError("the standard session's stream cannot be followed") }
            if enc.count >= 2 {
                let n = Int(enc.get16(0))
                if n == 0 || n % 16 != 0 { throw Failure.protocolError("the control stream is out of step") }
            }
            let piece: [UInt8]
            do { piece = try link.readSome(most: 64 << 10) } catch {
                lock.lock(); let ended = stopped; lock.unlock()
                if ended { return }
                throw Failure.closed
            }
            enc += piece
        }
    }

    enum ParseStatus { case ok, more, lost }

    /// One message of the host's from `b[at...]`: how much it took.
    private func parseServer(_ b: [UInt8], from at: Int) -> (Int, ParseStatus) {
        let left = b.count - at
        switch b[at] {
        case ScreenRFB.serverFramebufferUpdate:
            guard left >= 4 else { return (0, .more) }
            if b[at + 1] == 0x1c {
                // The answer to a media offer, all of its record.
                if let c = ScreenOffer.canvasDims(Array(b[at...])) {
                    lock.lock(); canvasW = c.width; canvasH = c.height; canvasTiles = c.tiles; lock.unlock()
                }
                return (left, .ok)
            }
            return parseUpdate(b, from: at)
        case ScreenRFB.serverBell:
            return (1, .ok)
        case ScreenRFB.serverCutText:
            guard left >= 8 else { return (0, .more) }
            let n = Int(b.get32(at + 4))
            guard n <= Self.clipboardMax else { return (0, .lost) }
            guard left >= 8 + n else { return (0, .more) }
            let text = String(String.UnicodeScalarView(b[(at + 8)..<(at + 8 + n)].map { Unicode.Scalar($0) }))
            handler.clipboard?(text)
            return (8 + n, .ok)
        case ScreenRFB.serverMiscStatus:
            return left >= 8 ? (8, .ok) : (0, .more)
        case ScreenRFB.serverClipboardSend:
            guard left >= 16 else { return (0, .more) }
            let raw = Int(b.get32(at + 8)), zn = Int(b.get32(at + 12))
            guard raw <= Self.clipboardMax, zn <= Self.clipboardMax else { return (0, .lost) }
            guard left >= 16 + zn else { return (0, .more) }
            if handler.clipboard != nil, raw > 0 {
                let z = clipZ ?? ScreenInflater()
                clipZ = z
                if let archive = z.inflate(b[(at + 16)..<(at + 16 + zn)], want: raw), let text = Self.pasteboardText(archive) {
                    handler.clipboard?(text)
                }
            }
            return (16 + zn, .ok)
        default:
            return (0, .lost)
        }
    }

    /// A framebuffer update: nothing is handed over until all of it is read, so an update that has to
    /// wait for its next record is not acted on twice.
    private func parseUpdate(_ b: [UInt8], from start: Int) -> (Int, ParseStatus) {
        let rects = Int(b.get16(start + 2))
        var pos = start + 4
        var events: [() -> Void] = []
        var pictures = false, wire = 0
        func done(_ status: ParseStatus) -> (Int, ParseStatus) {
            if status != .more {
                for e in events { e() }
                if pictures {
                    lock.lock()
                    stats.frames += 1
                    stats.bytes += Int64(wire)
                    lock.unlock()
                    handler.pictureEnd?()
                }
            }
            return (pos - start, status)
        }
        for _ in 0..<rects {
            guard pos + 12 <= b.count else { return (0, .more) }
            let x = Int(b.get16(pos)), y = Int(b.get16(pos + 2)), w = Int(b.get16(pos + 4)), h = Int(b.get16(pos + 6))
            let enc = Int32(bitPattern: b.get32(pos + 8))
            let p = pos + 12
            if config.standard {
                var taken = true
                switch enc {
                case ScreenRFB.encRaw:
                    guard w * h <= Self.picturePixelsMax else { return done(.lost) }
                    let n = w * h * pixels.bytes
                    guard p + n <= b.count else { return (0, .more) }
                    if n > 0 {
                        let raw = b[p..<(p + n)]
                        events.append { [unowned self] in self.onPixels(x, y, w, h, raw) }
                        pictures = true; wire += n
                    }
                    pos = p + n
                case ScreenRFB.encZlib:
                    guard p + 4 <= b.count else { return (0, .more) }
                    let zn = Int(b.get32(p))
                    guard zn <= Self.picturePendMax, w * h <= Self.picturePixelsMax else { return done(.lost) }
                    guard p + 4 + zn <= b.count else { return (0, .more) }
                    let z = b[(p + 4)..<(p + 4 + zn)]
                    events.append { [unowned self] in
                        let inflater = self.picZ ?? ScreenInflater(most: Self.picturePixelsMax * 4, strict: true)
                        self.picZ = inflater
                        if w == 0 || h == 0 { inflater.feed(z); return }
                        guard let raw = inflater.inflate(z, want: w * h * self.pixels.bytes) else {
                            self.lock.lock()
                            if self.picError == nil { self.picError = "a picture rectangle \(w)x\(h) at \(x),\(y) (\(zn) bytes deflated) could not be inflated" }
                            self.lock.unlock()
                            return
                        }
                        self.onPixels(x, y, w, h, raw[...])
                    }
                    pictures = true; wire += zn
                    pos = p + 4 + zn
                case ScreenRFB.encAppleMVS:
                    guard p + 4 <= b.count else { return (0, .more) }
                    let zn = Int(b.get32(p))
                    guard zn <= Self.picturePendMax else { return done(.lost) }
                    guard p + 4 + zn <= b.count else { return (0, .more) }
                    let coded = b[(p + 4)..<(p + 4 + zn)]
                    events.append { [unowned self] in self.onCoded(x, y, w, h, coded) }
                    pictures = true; wire += zn
                    pos = p + 4 + zn
                case ScreenRFB.encApplePointer, ScreenRFB.encAppleSelector:
                    pos = p
                case ScreenRFB.encDesktopSize:
                    events.append { [unowned self] in self.onPictureSize(w, h) }
                    pos = p
                default:
                    taken = false
                }
                if taken { continue }
            }
            switch enc {
            case ScreenRFB.encAppleCursor:
                guard p + 8 <= b.count else { return (0, .more) }
                let id = b.get32(p)
                let zn = Int(b.get32(p + 4))
                guard zn <= 4 << 20 else { return done(.lost) }
                guard p + 8 + zn <= b.count else { return (0, .more) }
                if zn == 0 {
                    events.append { [unowned self] in self.handler.cursorSelect?(id) }
                } else if w > 0, h > 0, w <= Self.cursorSideMax, h <= Self.cursorSideMax {
                    let z = b[(p + 8)..<(p + 8 + zn)]
                    events.append { [unowned self] in
                        let inflater = self.cursorZ ?? ScreenInflater()
                        self.cursorZ = inflater
                        // Read even with nobody to hand it to: the next shape rides the same stream.
                        guard let raw = inflater.inflate(z, want: w * h * 5) else { return }
                        self.handler.cursorStore?(id, x, y, w, h, Self.cursorRGBA(raw, w, h))
                        self.handler.cursorSelect?(id)
                    }
                }
                pos = p + 8 + zn
            case ScreenRFB.encAppleLayout:
                guard p + 2 <= b.count else { return (0, .more) }
                let n = 2 + Int(b.get16(p))
                guard p + n <= b.count else { return (0, .more) }
                let body = Array(b[(p + 2)..<(p + n)])
                if body.count >= 10 {
                    let sw = Int(body.get16(2)), sh = Int(body.get16(4)), bw = Int(body.get16(6)), bh = Int(body.get16(8))
                    events.append { [unowned self] in self.onLayout(sw, sh, bw, bh) }
                }
                pos = p + n
            case ScreenRFB.encAppleKeysyms:
                guard p + 22 <= b.count else { return (0, .more) }
                pos = p + 22
            case ScreenRFB.encAppleMediaInit:
                guard p + 2 <= b.count else { return (0, .more) }
                let n = 2 + Int(b.get16(p))
                guard p + n <= b.count else { return (0, .more) }
                if let c = ScreenOffer.answerMediaBlobs(Array(b[p..<(p + n)])).lazy.compactMap({ ScreenOffer.canvas(fromBlob: $0) }).first {
                    events.append { [unowned self] in
                        self.lock.lock(); self.canvasW = c.width; self.canvasH = c.height; self.canvasTiles = c.tiles; self.lock.unlock()
                    }
                }
                pos = p + n
            case ScreenRFB.encAppleInputSource, ScreenRFB.encAppleDevice:
                guard p + 2 <= b.count else { return (0, .more) }
                let n = 2 + Int(b.get16(p))
                guard p + n <= b.count else {
                    // Metadata nothing here reads: a length that does not close inside the record
                    // ends the update with the record.
                    pos = b.count
                    return done(.ok)
                }
                pos = p + n
            case ScreenRFB.encAppleRekey:
                // A second key for the stream: how its counters carry over is not known.
                return done(.lost)
            default:
                if config.standard { log("a rectangle of encoding \(enc) (\(w)x\(h) at \(x),\(y)) is not read") }
                return done(.lost)
            }
        }
        return done(.ok)
    }

    private func onPictureSize(_ w: Int, _ h: Int) {
        guard w > 0, h > 0 else { return }
        lock.lock()
        guard w <= Self.pictureSideMax, h <= Self.pictureSideMax, w * h <= Self.picturePixelsMax else {
            if picError == nil { picError = "a picture of \(w)x\(h) is more than is shown" }
            lock.unlock()
            return
        }
        let same = picW == w && picH == h
        picW = w; picH = h
        lock.unlock()
        if !same { handler.pictureSize?(w, h) }
    }

    /// Makes the picture as large as a rectangle that lies past its edge (the host said its size in
    /// points and draws in pixels); whether the rectangle fits it.
    private func grow(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        lock.lock()
        var pw = max(picW, x + w), ph = max(picH, y + h)
        if pw > picW || ph > picH { pw = max(pw, backingW); ph = max(ph, backingH) }
        lock.unlock()
        onPictureSize(pw, ph)
        lock.lock()
        let fits = picError == nil && x + w <= picW && y + h <= picH
        if fits { stats.pictures += 1 }
        lock.unlock()
        return fits
    }

    private func onPixels(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ raw: ArraySlice<UInt8>) {
        guard grow(x, y, w, h) else { return }
        handler.picture?(x, y, w, h, pixels.bgra(raw, count: w * h))
    }

    private func onCoded(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ body: ArraySlice<UInt8>) {
        if w > 0 && h > 0 {
            guard grow(x, y, w, h) else { return }
        } else {
            lock.lock(); stats.pictures += 1; lock.unlock()
        }
        handler.pictureCoded?(x, y, w, h, body)
    }

    private func onLayout(_ sw: Int, _ sh: Int, _ bw: Int, _ bh: Int) {
        guard sw > 0, sh > 0 else { return }
        lock.lock()
        let changed = !config.standard && (resizeAsked || (layouts > 0 && (bw != backingW || bh != backingH)))
        resizeAsked = false
        layouts += 1
        scaledW = sw; scaledH = sh; backingW = bw; backingH = bh
        if changed { awaitKey = true }
        if askW > 0 && !askLeft.isEmpty {
            askWork?.cancel()
            let gen = askGen
            let work = DispatchWorkItem { [weak self] in self?.askedDisplay(gen) }
            askWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.displaySettle, execute: work)
        }
        lock.unlock()
        // Every layout drops the host's arming; a changed size also needs the offer again.
        arm()
        if changed { reoffer() }
        handler.layout?(sw, sh, bw, bh)
    }

    /// The host's cursor (BGRA with nothing in its fourth byte, then the alpha as a plane) as RGBA.
    static func cursorRGBA(_ raw: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        let n = w * h
        var out = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            out[i * 4] = raw[i * 4 + 2]; out[i * 4 + 1] = raw[i * 4 + 1]; out[i * 4 + 2] = raw[i * 4]; out[i * 4 + 3] = raw[n * 4 + i]
        }
        return out
    }

    /// Plain text in the host's clipboard archive: UTF-8 where there is some, else UTF-16.
    static func pasteboardText(_ arc: [UInt8]) -> String? {
        func u32(_ p: Int) -> Int? {
            guard p + 4 <= arc.count else { return nil }
            let v = Int(arc.get32(p))
            return v <= arc.count ? v : nil
        }
        func take(_ p: inout Int) -> ArraySlice<UInt8>? {
            guard let n = u32(p), p + 4 + n <= arc.count else { return nil }
            defer { p += 4 + n }
            return arc[(p + 4)..<(p + 4 + n)]
        }
        guard let items = u32(0) else { return nil }
        var p = 4
        var utf16: ArraySlice<UInt8>?
        for _ in 0..<items {
            guard let uti = take(&p) else { break }
            p += 4
            guard let aliases = u32(p) else { break }
            p += 4
            var bad = false
            for _ in 0..<aliases where take(&p) == nil || take(&p) == nil { bad = true; break }
            if bad { break }
            guard let data = take(&p) else { break }
            switch String(decoding: uti, as: UTF8.self) {
            case "public.utf8-plain-text": return String(decoding: data, as: UTF8.self)
            case "public.utf16-plain-text": utf16 = data
            default: break
            }
        }
        if let utf16, utf16.count >= 2 {
            let a = Array(utf16)
            var units: [UInt16] = []
            var i = 0
            while i + 1 < a.count { units.append(UInt16(a[i]) << 8 | UInt16(a[i + 1])); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }
        return nil
    }

    static func zlibCompress(_ data: [UInt8]) -> [UInt8]? {
        var size = compressBound(uLong(data.count))
        var out = [UInt8](repeating: 0, count: Int(size))
        let status = compress2(&out, &size, data, uLong(data.count), Z_DEFAULT_COMPRESSION)
        return status == Z_OK ? Array(out.prefix(Int(size))) : nil
    }

    // MARK: Media (High Performance)

    private struct VideoGroup {
        var ssrc: UInt32
        var ts: UInt32
        var packets: [(seq: UInt16, payload: [UInt8])] = []
        var bytes = 0
        var over = false
        var lastAt = Date()
    }
    private var group: VideoGroup?
    private var nextSeq: [UInt32: UInt16] = [:]
    private var vps: [UInt8] = [], sps: [UInt8] = [], pps: [UInt8] = []
    private var setsSent = false

    /// On the media queue.
    private func datagram(_ channel: Int, _ bytes: [UInt8]) {
        guard bytes.count > 1 else { return }
        if channel == 1 { video(bytes) } else { control(bytes) }
    }

    private func video(_ packet: [UInt8]) {
        guard let videoDec else { return }
        let opened = packet.withUnsafeBytes { videoDec.decrypt($0) }
        lock.lock()
        stats.videoPackets += 1
        guard let p = opened else { stats.videoBad += 1; lock.unlock(); return }
        let payload = [UInt8](p.payload)
        stats.bytes += Int64(payload.count)
        if primarySSRC != p.ssrc {
            // A new stream (the encoder started again at a new size): nothing of the old one helps.
            if primarySSRC != 0 { awaitKey = true }
            primarySSRC = p.ssrc
        }
        lock.unlock()
        if let g = group, g.ssrc != p.ssrc || g.ts != p.timestamp { flushVideo() }
        if group == nil { group = VideoGroup(ssrc: p.ssrc, ts: p.timestamp) }
        if group!.over || group!.bytes + payload.count > Self.videoFrameMax || group!.packets.count >= Self.videoPacketsMax {
            // Kept as a group so that its end is still seen; its packets are not.
            group!.over = true
            group!.packets = [(p.sequence, [])]
        } else {
            group!.bytes += payload.count
            group!.packets.append((p.sequence, payload))
        }
        group!.lastAt = Date()
        if p.marker { flushVideo() }
    }

    /// A frame whose last packet carried no marker is not held back for ever.
    private func flushVideoIfStale() {
        media.async {
            if let g = self.group, Date().timeIntervalSince(g.lastAt) > 0.5 { self.flushVideo() }
        }
    }

    private func flushVideo() {
        guard var g = group else { return }
        group = nil
        guard !g.packets.isEmpty else { return }
        g.packets.sort { Int16(bitPattern: $0.seq &- $1.seq) < 0 }
        // Whole: it follows the last packet handed over, and has no hole.
        var whole = true
        if let expected = nextSeq[g.ssrc], g.packets[0].seq != expected { whole = false }
        for i in 1..<g.packets.count where g.packets[i].seq != g.packets[i - 1].seq &+ 1 { whole = false }
        nextSeq[g.ssrc] = g.packets[g.packets.count - 1].seq &+ 1
        if g.over {
            lock.lock(); stats.framesLost += 1; awaitKey = true; lock.unlock()
            return
        }
        let units = ScreenHEVC.reassemble(g.packets.map { $0.payload })
        guard !units.isEmpty else { return }
        var key = false
        for u in units {
            let t = ScreenHEVC.type(u[0])
            switch t {
            case ScreenHEVC.vps: if u != vps { vps = u; setsSent = false }
            case ScreenHEVC.sps: if u != sps { sps = u; setsSent = false }
            case ScreenHEVC.pps: if u != pps { pps = u; setsSent = false }
            default: if ScreenHEVC.isKey(t) { key = true }
            }
        }
        lock.lock()
        if !whole {
            stats.framesLost += 1; awaitKey = true
            lock.unlock(); return
        }
        if awaitKey && !key { lock.unlock(); return }
        if key && (vps.isEmpty || sps.isEmpty || pps.isEmpty) { lock.unlock(); return }
        awaitKey = false
        stats.frames += 1
        if key { stats.keyframes += 1 }
        lock.unlock()
        if key && !setsSent {
            setsSent = true
            handler.hevcConfig?(vps, sps, pps)
        }
        handler.videoFrame?(g.ts, key, units)
    }

    private func control(_ packet: [UInt8]) {
        // RTCP shares the port: packet types 192 and 200 to 207.
        let pt = packet[1]
        if pt == 192 || (pt >= 200 && pt <= 207) { return }
        guard let audioDec else { return }
        let opened = packet.withUnsafeBytes { audioDec.decrypt($0) }
        lock.lock()
        stats.audioPackets += 1
        if opened == nil { stats.audioBad += 1 }
        lock.unlock()
        guard let p = opened, !p.payload.isEmpty else { return }
        handler.audio?(p.timestamp, p.sequence, pt & 0x7f, [UInt8](p.payload))
    }

    /// A report to the host's control port (sender and receiver report), with an ask for a key frame
    /// when one is due.
    private func sendFeedback(fir: UInt32?) {
        guard let ctrlEnc, let videoDec else { return }
        lock.lock()
        let own = videoSSRC
        lock.unlock()
        // The sender and receiver reports, and with an ask for a key frame the three ways a host
        // may read one (AVPF's FIR, a picture loss, the old FIR).
        let states = videoDec.stateSnapshot()
        var packet = ScreenSRTPControlPacket.emptySenderReport(senderSSRC: own)
        packet += ScreenSRTPControlPacket.receiverReport(senderSSRC: own, sources: states.keys.sorted(), states: states)
        if let fir, fir != 0 {
            packet += ScreenSRTPControlPacket.fullIntraRequest(senderSSRC: own, targetSSRC: fir, sequenceNumber: 1)
            packet += ScreenSRTPControlPacket.pictureLossIndication(senderSSRC: own, mediaSSRC: fir)
            packet += ScreenSRTPControlPacket.legacyFullIntraRequest(targetSSRC: fir)
        }
        if let protected = try? ctrlEnc.protect(packet) { link.sendDatagram(0, [UInt8](protected)) }
    }
}

// MARK: - Inflating the host's zlib streams

/// Pieces of a zlib stream the host flushes after each message. Whether the host keeps one stream
/// for the session or starts one per message is not established, so it follows whichever the bytes
/// are: a piece that cannot be read as the running stream's next is tried as a stream of its own.
final class ScreenInflater {
    private var stream = z_stream()
    private var live = false
    private var dead = false
    private var held: [UInt8] = []
    private let most: Int
    private let strict: Bool

    init(most: Int = 16 << 20, strict: Bool = false) {
        self.most = max(most, 16 << 20)
        self.strict = strict
    }

    deinit { if live { inflateEnd(&stream) } }

    /// Adds a piece nothing is read from now to the running stream.
    func feed(_ piece: ArraySlice<UInt8>) {
        guard !dead, !piece.isEmpty else { return }
        _ = run(Array(piece), want: 0)
    }

    func inflate(_ piece: ArraySlice<UInt8>, want: Int) -> [UInt8]? {
        guard want > 0, want <= most else { return nil }
        if !dead {
            if let out = run(Array(piece), want: want) {
                if strict && held.count > 16 {
                    dead = true
                    return nil
                }
                return out
            }
            dead = true
        }
        // Each piece on its own.
        var fresh = z_stream()
        guard inflateInit_(&fresh, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&fresh) }
        var input = Array(piece)
        var out = [UInt8](repeating: 0, count: want)
        let status: Int32 = input.withUnsafeMutableBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                fresh.next_in = inBuf.baseAddress; fresh.avail_in = uInt(inBuf.count)
                fresh.next_out = outBuf.baseAddress; fresh.avail_out = uInt(outBuf.count)
                return zlib.inflate(&fresh, Z_SYNC_FLUSH)
            }
        }
        guard status == Z_OK || status == Z_STREAM_END, fresh.avail_out == 0 else { return nil }
        return out
    }

    /// The running stream: the piece after whatever was left over, `want` bytes out (none for a feed).
    private func run(_ piece: [UInt8], want: Int) -> [UInt8]? {
        if !live {
            guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            live = true
        }
        var input = held + piece
        var out = [UInt8](repeating: 0, count: max(want, 1))
        var produced = 0
        var status: Int32 = Z_OK
        input.withUnsafeMutableBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = inBuf.baseAddress; stream.avail_in = uInt(inBuf.count)
                if want == 0 {
                    // Fed only: inflate into a scratch buffer and drop it.
                    var scratch = [UInt8](repeating: 0, count: 64 << 10)
                    repeat {
                        scratch.withUnsafeMutableBufferPointer { s in
                            stream.next_out = s.baseAddress; stream.avail_out = uInt(s.count)
                            status = zlib.inflate(&stream, Z_SYNC_FLUSH)
                        }
                    } while status == Z_OK && stream.avail_in > 0 && stream.avail_out == 0
                } else {
                    stream.next_out = outBuf.baseAddress; stream.avail_out = uInt(want)
                    status = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    produced = want - Int(stream.avail_out)
                }
                let left = Int(stream.avail_in)
                held = left > 0 ? Array(inBuf.suffix(left)) : []
            }
        }
        if want == 0 { return status == Z_OK || status == Z_BUF_ERROR || status == Z_STREAM_END ? [] : nil }
        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR, produced == want else { return nil }
        return out
    }
}

// MARK: - HEVC as Screen Sharing sends it

/// RTP as RFC 7798 has it, with no decoding order numbers: a NAL unit alone, an aggregation packet
/// (48) holding several (the parameter sets before each key frame), or a fragmentation unit (49).
/// Range Extensions, 4:4:4. One stream for the whole picture (one tile a picture).
public enum ScreenHEVC {
    public static let vps: UInt8 = 32, sps: UInt8 = 33, pps: UInt8 = 34, aud: UInt8 = 35, ap: UInt8 = 48, fu: UInt8 = 49

    public static func type(_ b0: UInt8) -> UInt8 { (b0 >> 1) & 0x3f }
    /// A picture that stands alone (BLA, IDR or CRA).
    public static func isKey(_ t: UInt8) -> Bool { t >= 16 && t <= 21 }

    public static func reassemble(_ payloads: [[UInt8]]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var unit: [UInt8] = []
        var active = false
        for pay in payloads where pay.count >= 3 {
            let t = type(pay[0])
            if t == fu {
                let fh = pay[2]
                if fh & 0x80 != 0 {
                    unit = [pay[0] & 0x81 | (fh & 0x3f) << 1, pay[1]]
                    active = true
                } else if !active { continue }
                unit += pay[3...]
                if fh & 0x40 != 0 { out.append(unit); unit = []; active = false }
            } else if t == ap {
                var p = 2
                while p + 2 <= pay.count {
                    let n = Int(pay[p]) << 8 | Int(pay[p + 1])
                    p += 2
                    guard n >= 2, p + n <= pay.count else { break }
                    out.append(Array(pay[p..<(p + n)]))
                    p += n
                }
            } else if t < ap {
                out.append(pay)
            }
        }
        return out
    }

    /// The decoder configuration (hvcC) for these parameter sets, four bytes of length a unit; nil
    /// when they are not whole.
    public static func decoderRecord(vps: [UInt8], sps: [UInt8], pps: [UInt8]) -> [UInt8]? {
        guard vps.count >= 3, sps.count >= 3, pps.count >= 3 else { return nil }
        let r = removeEmulationPrevention(Array(sps[2...]))
        guard r.count >= 13 else { return nil }
        let (chroma, depthY, depthC) = format(r) ?? (1, 0, 0)
        var b: [UInt8] = [1]
        b += r[1..<13]
        b += [0xf0, 0x00, 0xfc, 0xfc | UInt8(chroma), 0xf8 | UInt8(depthY), 0xf8 | UInt8(depthC), 0, 0]
        let layers = (r[0] >> 1) & 7 + 1
        b.append(layers << 3 | (r[0] & 1) << 2 | 3)
        b.append(3)
        for u in [vps, sps, pps] {
            b.append(0x80 | type(u[0]))
            b.put16(1)
            b.put16(UInt16(u.count))
            b += u
        }
        return b
    }

    static func removeEmulationPrevention(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var zeros = 0
        for v in b {
            if zeros >= 2 && v == 3 { zeros = 0; continue }
            out.append(v)
            zeros = v == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// A sequence parameter set (no header, no emulation prevention) as far as its chroma format and
    /// bit depths.
    static func format(_ r: [UInt8]) -> (Int, Int, Int)? {
        var bits = BitReader(r)
        guard let first = bits.read(8) else { return nil }
        let sub = Int(first >> 1) & 7
        for _ in 0..<12 { guard bits.read(8) != nil else { return nil } }
        var profile = [Bool](repeating: false, count: sub), level = [Bool](repeating: false, count: sub)
        for i in 0..<sub {
            guard let p = bits.read(1), let l = bits.read(1) else { return nil }
            profile[i] = p == 1; level[i] = l == 1
        }
        if sub > 0 { for _ in sub..<8 { guard bits.read(2) != nil else { return nil } } }
        for i in 0..<sub {
            var skip = (profile[i] ? 88 : 0) + (level[i] ? 8 : 0)
            while skip > 0 { guard bits.read(8) != nil else { return nil }; skip -= 8 }
        }
        guard bits.ue() != nil, let chroma = bits.ue(), chroma <= 3 else { return nil }
        if chroma == 3 { guard bits.read(1) != nil else { return nil } }
        guard bits.ue() != nil, bits.ue() != nil, let window = bits.read(1) else { return nil }
        if window == 1 { for _ in 0..<4 { guard bits.ue() != nil else { return nil } } }
        guard let dy = bits.ue(), dy <= 7, let dc = bits.ue(), dc <= 7 else { return nil }
        return (Int(chroma), Int(dy), Int(dc))
    }

    struct BitReader {
        let data: [UInt8]
        var pos = 0
        init(_ data: [UInt8]) { self.data = data }
        mutating func read(_ n: Int) -> UInt32? {
            guard n <= 32, pos + n <= data.count * 8 else { return nil }
            var v: UInt32 = 0
            for _ in 0..<n {
                v = v << 1 | UInt32((data[pos >> 3] >> (7 - UInt8(pos & 7))) & 1)
                pos += 1
            }
            return v
        }
        mutating func ue() -> UInt32? {
            var zeros = 0
            while true {
                guard let b = read(1) else { return nil }
                if b == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard zeros > 0 else { return 0 }
            guard let rest = read(zeros) else { return nil }
            return (1 << UInt32(zeros)) - 1 + rest
        }
    }
}
