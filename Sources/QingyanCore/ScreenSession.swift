//
//  ScreenSession.swift
//
//  Another Mac's screen as out's window takes it: ScreenWire's frames (status,
//  video, sound, cursor, layout, clipboard, picture), made here from out's own
//  Screen Sharing client (ScreenClient.swift), and the window's frames
//  (control words, pointer, keys, wheel) turned into what Screen Sharing
//  takes. Until 2026-11-25 the Monitor helper on the other Mac did this
//  (helper/go/screenhp.go) and the frames crossed the road between the Macs;
//  now only Screen Sharing's own bytes cross it (ScreenTunnel.swift), and the
//  frames go from here to the window in this process.
//
//  The window's side is as it was: a hello that asks for an account, the
//  window's open with it, live once the first picture (standard) or the
//  first media packet (High Performance) has come, stats every two seconds,
//  and an end with its reason. High Performance is HEVC or nothing (user
//  2026-11-25), on a Mac with Apple silicon.
//
//  A standard session's picture: each rectangle in the Mac's own codec goes
//  to the window as it came, and exact pixels deflated; each update ends with
//  a numbered word that the window says back once it is on its screen. The
//  client's reader waits while more than a few updates are not yet shown, so
//  Screen Sharing, which writes as fast as the road and this Mac take, sends
//  what both can show.
//

import Foundation
import Compression

public final class ScreenSession: @unchecked Sendable {
    /// What the other Mac's out said with its yes.
    public struct Host {
        public var name: String
        public var user: String
        /// Apple silicon: a display of the session's own, and HEVC.
        public var appleSilicon: Bool
        public init(name: String, user: String, appleSilicon: Bool) { self.name = name; self.user = user; self.appleSilicon = appleSilicon }
    }

    /// Frames for the window, in order; called on the session's threads, one at a time.
    private let deliver: (Data) -> Void
    private let host: Host
    /// Opens another road to the other Mac (for the next route), blocking; nil when it could not.
    private let reopen: () -> ScreenTunnelLink?
    private var first: ScreenTunnelLink?

    private let queue = DispatchQueue(label: "local.hopo.qingyan.screen.session")
    private let lock = NSLock()
    private let deliverLock = NSLock()
    private var opened = false
    private var ended = false
    private var client: ScreenClient?
    private var link: ScreenTunnelLink?
    private var own = false, audio = false, standard = false
    private var want: (w: Int, h: Int, scale: Double)?
    private var buttons: UInt8 = 0
    private var wheelX = 0, wheelY = 0
    private var scale = 1
    private var conf: Data?
    private var codedFirst = true
    private var picW = 0, picH = 0
    // Updates sent whole, and the last the window said it has shown.
    private var serial: UInt32 = 0
    private var shown: UInt32 = 0
    private let shownCame = NSCondition()
    private var sentAt = [Date](repeating: .distantPast, count: 64)
    private var tookLast: TimeInterval = 0, tookLeast: TimeInterval = 0
    private var picBytes: Int64 = 0, wholes: Int64 = 0

    static let kbpsDefault = 12000, kbpsMin = 1000, kbpsMax = 60000
    static let scrollStep = 4, scrollMost = 64
    /// The reader waits while this many updates are not yet on the window's screen.
    static let shownAhead: UInt32 = 3
    static let codedPiece = 4 << 20
    static let pictureBand = 1 << 20
    static let firstPicture: TimeInterval = 5
    static let routeGap: TimeInterval = 3

    public init(first: ScreenTunnelLink, host: Host, reopen: @escaping () -> ScreenTunnelLink?, deliver: @escaping (Data) -> Void) {
        self.first = first
        self.host = host
        self.reopen = reopen
        self.deliver = deliver
    }

    /// Says hello: the window asks for an account and opens.
    public func start() {
        status(["s": "hello", "v": 3, "name": host.name, "user": host.user,
                "codecs": host.appleSilicon ? ["hevc"] : [String](), "signin": true, "standard": true, "own": host.appleSilicon])
    }

    public func close() {
        lock.lock()
        ended = true
        let client = self.client, link = self.link, first = self.first
        self.first = nil
        lock.unlock()
        client?.close()
        link?.close()
        first?.close()
        shownCame.lock(); shownCame.broadcast(); shownCame.unlock()
    }

    // MARK: To the window

    private func send(_ kind: UInt8, _ body: Data) {
        var frame = Data(capacity: 4 + body.count)
        frame.append(contentsOf: [kind, UInt8((body.count >> 16) & 0xff), UInt8((body.count >> 8) & 0xff), UInt8(body.count & 0xff)])
        frame.append(body)
        deliverLock.lock()
        defer { deliverLock.unlock() }
        lock.lock(); let gone = ended; lock.unlock()
        if !gone { deliver(frame) }
    }

    private func status(_ object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(ScreenWire.ToPage.status.rawValue, body)
    }

    private func layoutFrame(_ sw: Int, _ sh: Int, _ bw: Int, _ bh: Int) {
        var b: [UInt8] = []
        b.put16(UInt16(clamping: sw)); b.put16(UInt16(clamping: sh)); b.put16(UInt16(clamping: bw)); b.put16(UInt16(clamping: bh))
        send(ScreenWire.ToPage.layout.rawValue, Data(b))
    }

    private func piece(_ x: Int, _ y: Int, _ w: Int, _ h: Int, flags: UInt8, _ bytes: some Collection<UInt8>) {
        var b: [UInt8] = []
        b.reserveCapacity(9 + bytes.count)
        b.put16(UInt16(clamping: x)); b.put16(UInt16(clamping: y)); b.put16(UInt16(clamping: w)); b.put16(UInt16(clamping: h))
        b.append(flags)
        b += bytes
        lock.lock(); picBytes += Int64(b.count); lock.unlock()
        send(ScreenWire.ToPage.picture.rawValue, Data(b))
    }

    // MARK: From the window

    /// One of the window's frames.
    public func take(kind: UInt8, body: Data) {
        queue.async { self.act(kind, [UInt8](body)) }
    }

    private func act(_ kind: UInt8, _ body: [UInt8]) {
        lock.lock()
        let client = self.client
        lock.unlock()
        switch kind {
        case 2: // pointer: buttons (1 left, 2 middle, 4 right), x, y in points
            guard body.count == 5 else { return }
            let b = body[0]
            // Screen Sharing has middle and right the other way round.
            let buttons = b & 1 | (b & 2) << 1 | (b & 4) >> 1
            lock.lock(); self.buttons = buttons; lock.unlock()
            client?.sendPointer(buttons: buttons, x: Int(body.get16(1)), y: Int(body.get16(3)))
        case 3: // key: down, the Mac's virtual key code
            guard body.count == 3, let client else { return }
            let ks = ScreenKeys.keysym(forMacKey: body.get16(1))
            if ks != 0 { client.sendKey(down: body[0] != 0, keysym: ks) }
        case 4: // wheel: dx dy in pixels, x y
            guard body.count == 8, let client else { return }
            scroll(client, Int(Int16(bitPattern: body.get16(0))), Int(Int16(bitPattern: body.get16(2))), Int(body.get16(4)), Int(body.get16(6)))
        case 1:
            guard let o = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] else { return }
            command(o, client)
        default:
            break
        }
    }

    private func command(_ o: [String: Any], _ client: ScreenClient?) {
        func int(_ k: String) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }
        switch o["t"] as? String {
        case "open":
            lock.lock()
            let again = opened
            opened = true
            lock.unlock()
            guard !again else { return }
            let thread = Thread { [weak self] in self?.run(o) }
            thread.name = "local.hopo.qingyan.screen.session"
            thread.qualityOfService = .userInteractive
            thread.start()
        case "size":
            let w = int("w"), h = int("h")
            guard w >= 320, h >= 200, w <= 7680, h <= 4320 else { return }
            var sc = (o["scale"] as? NSNumber)?.doubleValue ?? 1
            if sc < 1 || sc > 3 { sc = 1 }
            lock.lock()
            want = (w, h, sc)
            let own = self.own
            lock.unlock()
            if own { client?.resize(width: w, height: h, scale: sc) }
        case "key":
            client?.requestKeyframe()
        case "shown":
            shownCame.lock()
            let n = UInt32(truncatingIfNeeded: int("n"))
            if n &- shown < 1 << 31 { shown = n }
            let at = sentAt[Int(n % 64)]
            shownCame.broadcast()
            shownCame.unlock()
            let took = Date().timeIntervalSince(at)
            if took >= 0 && took < 60 {
                lock.lock()
                tookLast = took
                if tookLeast == 0 || took < tookLeast { tookLeast = took }
                lock.unlock()
            }
        case "mode":
            client?.setMode(control: !(o["observe"] as? Bool ?? false))
        case "kbps":
            let k = int("kbps")
            if k > 0 { client?.setMaxBitrate(min(max(k, Self.kbpsMin), Self.kbpsMax) * 1000) }
        case "clip":
            if let text = o["text"] as? String, text.utf8.count <= 256 << 10, let client {
                if !client.sendClipboard(text) { status(["s": "clip", "ok": false]) }
            }
        case "text":
            if let text = o["text"] as? String, text.utf8.count <= 16 << 10, let client {
                for scalar in text.unicodeScalars {
                    let ks = ScreenKeys.keysym(for: scalar)
                    if ks == 0 { continue }
                    client.sendKey(down: true, keysym: ks)
                    client.sendKey(down: false, keysym: ks)
                }
            }
        default:
            break
        }
    }

    /// The window's wheel in pixels as the Mac's ticks: each a press and release of a wheel button
    /// where the pointer is, an axis at a time.
    private func scroll(_ client: ScreenClient, _ dx: Int, _ dy: Int, _ x: Int, _ y: Int) {
        lock.lock()
        let buttons = self.buttons
        wheelX += dx; wheelY += dy
        var ticks: [UInt8] = []
        while ticks.count < Self.scrollMost && abs(wheelY) >= Self.scrollStep {
            if wheelY > 0 { ticks.append(0x10); wheelY -= Self.scrollStep } else { ticks.append(0x08); wheelY += Self.scrollStep }
        }
        while ticks.count < Self.scrollMost && abs(wheelX) >= Self.scrollStep {
            if wheelX > 0 { ticks.append(0x40); wheelX -= Self.scrollStep } else { ticks.append(0x20); wheelX += Self.scrollStep }
        }
        if ticks.count == Self.scrollMost { wheelX = 0; wheelY = 0 }
        lock.unlock()
        for t in ticks {
            client.sendPointer(buttons: buttons | t, x: x, y: y)
            client.sendPointer(buttons: buttons, x: x, y: y)
        }
    }

    // MARK: The session

    private func run(_ o: [String: Any]) {
        let user = (o["user"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let password = o["password"] as? String ?? ""
        guard !user.isEmpty, !password.isEmpty else { status(["s": "end", "why": "auth"]); return }
        let standard = o["standard"] as? Bool ?? false
        let codecs = o["codecs"] as? [String] ?? []
        // High Performance is HEVC or nothing.
        guard standard || (codecs.contains("hevc") && host.appleSilicon) else { status(["s": "end", "why": "no-hp"]); return }
        var kbps = (o["kbps"] as? NSNumber)?.intValue ?? 0
        if kbps <= 0 { kbps = Self.kbpsDefault }
        kbps = min(max(kbps, Self.kbpsMin), Self.kbpsMax)
        let audio = (o["audio"] as? Bool ?? true) && !standard
        let own = (o["own"] as? Bool ?? false) && !standard && host.appleSilicon
        var config = ScreenClient.Config(user: user, password: password, standard: standard, ownDisplay: own,
                                         audio: audio, maxBitrate: kbps * 1000)
        config.log = { [weak self] text in self?.note(text) }
        let w = (o["w"] as? NSNumber)?.intValue ?? 0, h = (o["h"] as? NSNumber)?.intValue ?? 0
        if own && w >= 320 && h >= 200 && w <= 7680 && h <= 4320 {
            config.width = w; config.height = h
            if let sc = (o["scale"] as? NSNumber)?.doubleValue, sc >= 1, sc <= 3 { config.scale = sc }
        }
        lock.lock()
        self.own = own; self.audio = audio; self.standard = standard
        if let want, own { config.width = want.w; config.height = want.h; config.scale = want.scale }
        lock.unlock()
        status(["s": "connecting"])
        var why = "failed"
        var route = 0, routes = 1
        while route < routes {
            lock.lock()
            if ended { lock.unlock(); return }
            var link = first
            first = nil
            lock.unlock()
            if link == nil {
                Thread.sleep(forTimeInterval: Self.routeGap)
                link = reopen()
            }
            guard let link else { break }
            lock.lock(); self.link = link; lock.unlock()
            link.start()
            link.say(["t": "connect", "route": route, "udp": !standard])
            guard let answer = link.nextWord(timeout: 15) else { link.close(); why = "failed"; route += 1; continue }
            routes = (answer["routes"] as? Int) ?? routes
            if answer["t"] as? String == "failed" {
                link.close()
                switch answer["why"] as? String {
                case "no-vnc": status(["s": "end", "why": "no-vnc"]); return
                case "busy": status(["s": "end", "why": "busy"]); return
                case "no-route": route = routes
                default: route += 1
                }
                continue
            }
            note("route \(answer["route"] as? String ?? "\(route)")")
            let client = ScreenClient(link: link, config: config)
            do {
                try client.connect(reconnect: {
                    link.say(["t": "hangup"])
                    Thread.sleep(forTimeInterval: 1.4)
                    link.forgetIncoming()
                    link.say(["t": "connect", "route": route, "udp": !standard])
                    guard let again = link.nextWord(timeout: 15), again["t"] as? String == "connected" else {
                        throw ScreenClient.Failure.protocolError("Screen Sharing did not take a second connection")
                    }
                })
            } catch ScreenClient.Failure.rejected {
                link.close()
                status(["s": "end", "why": "auth"])
                return
            } catch {
                note("route \(route): \(error)")
                link.close()
                why = standard ? "failed" : "no-media"
                if standard { break }
                route += 1
                continue
            }
            lock.lock()
            self.client = client
            codedFirst = true
            let late = want
            lock.unlock()
            if own, let late, late.w != config.width || late.h != config.height || late.scale != config.scale {
                client.resize(width: late.w, height: late.h, scale: late.scale)
            }
            // Signed in is not yet a picture: the media has to find its way here.
            let ran = DispatchSemaphore(value: 0)
            var failure: Error?
            let reader = Thread { [weak self] in
                guard let self else { return }
                do { try client.run(self.handler(standard: standard)) } catch { failure = error }
                ran.signal()
            }
            reader.qualityOfService = .userInteractive
            reader.start()
            var live = false
            let deadline = Date().addingTimeInterval(Self.firstPicture)
            while Date() < deadline {
                if ran.wait(timeout: .now() + 0.1) == .success { ran.signal(); break }
                let st = client.currentStats()
                if st.videoPackets - st.videoBad > 0 || (standard && st.pictures > 0) { live = true; break }
            }
            if !live {
                client.close()
                ran.wait()
                lock.lock(); self.client = nil; lock.unlock()
                why = standard ? "no-picture" : "no-media"
                if let failure { note("route \(route): \(failure)") }
                if standard { break }
                route += 1
                continue
            }
            let (sw, sh, _, _) = client.layout()
            let (cw, ch) = standard ? (picW, picH) : client.canvas()
            status(["s": "live", "w": sw, "h": sh, "cw": cw, "ch": ch, "own": own, "audio": audio, "input": true,
                    "codec": standard ? "pixels" : "hevc", "standard": standard, "adaptive": standard, "mvs": standard])
            let stats = DispatchSource.makeTimerSource(queue: queue)
            stats.schedule(deadline: .now() + 2, repeating: 2)
            var last = client.currentStats()
            var lastBytes: Int64 = 0, lastWholes: Int64 = 0
            stats.setEventHandler { [weak self] in
                guard let self else { return }
                let st = client.currentStats()
                self.lock.lock()
                let bytes = self.picBytes, wholes = self.wholes, least = self.tookLeast, took = self.tookLast
                self.lock.unlock()
                var fps = Double(st.frames - last.frames) / 2, kbps = Double(st.bytes - last.bytes) * 8 / 1000 / 2
                if standard {
                    fps = Double(wholes - lastWholes) / 2
                    kbps = Double(bytes - lastBytes) * 8 / 1000 / 2
                    if wholes != lastWholes {
                        self.status(["s": "note", "text": String(format: "adaptive, the Mac's own codec: an update shown in %.0f ms at the least, %.0f ms the last; %.1f a second, %.0f KB a second",
                                                                 least * 1000, took * 1000, fps, Double(bytes - lastBytes) / 1024 / 2)])
                    }
                    lastBytes = bytes; lastWholes = wholes
                }
                self.status(["s": "stats", "fps": fps, "kbps": kbps, "audio": Double(st.audioPackets - last.audioPackets) / 2,
                             "lost": st.framesLost, "keyframes": st.keyframes, "bad": st.videoBad, "dropped": 0, "asks": st.keyAsks])
                last = st
            }
            stats.resume()
            ran.wait()
            stats.cancel()
            client.close()
            lock.lock(); self.client = nil; lock.unlock()
            if let failure { note("ended: \(failure)") }
            status(["s": "end", "why": "closed"])
            return
        }
        status(["s": "end", "why": why])
    }

    private func note(_ text: String) {
        status(["s": "note", "text": text])
    }

    private func handler(standard: Bool) -> ScreenClient.Handler {
        var h = ScreenClient.Handler()
        h.hevcConfig = { [weak self] vps, sps, pps in
            guard let self, let record = ScreenHEVC.decoderRecord(vps: vps, sps: sps, pps: pps) else { return }
            self.lock.lock(); self.conf = Data([ScreenWire.Codec.hevc.rawValue] + record); self.lock.unlock()
        }
        h.videoFrame = { [weak self] stamp, key, units in
            guard let self else { return }
            var b: [UInt8] = [key ? 1 : 0]
            b.put32(stamp)
            for u in units where !u.isEmpty {
                let t = ScreenHEVC.type(u[0])
                // Parameter sets travel in the configuration; a delimiter is nothing a decoder needs.
                if t >= ScreenHEVC.vps && t <= ScreenHEVC.aud { continue }
                b.put32(UInt32(u.count)); b += u
            }
            guard b.count > 5 else { return }
            self.lock.lock()
            let conf = key ? self.conf : nil
            if key { self.conf = nil }
            self.lock.unlock()
            if let conf { self.send(ScreenWire.ToPage.videoConfig.rawValue, conf) }
            self.send(ScreenWire.ToPage.videoFrame.rawValue, Data(b))
        }
        h.audio = { [weak self] stamp, sequence, _, payload in
            guard let self else { return }
            var b: [UInt8] = [3]
            b.put32(stamp); b.put16(sequence)
            self.send(ScreenWire.ToPage.audio.rawValue, Data(b + payload))
        }
        h.cursorStore = { [weak self] id, hx, hy, w, hh, rgba in
            guard let self else { return }
            self.lock.lock(); let scale = self.scale; self.lock.unlock()
            var b: [UInt8] = []
            b.put32(id); b.put16(UInt16(clamping: hx)); b.put16(UInt16(clamping: hy)); b.put16(UInt16(clamping: w)); b.put16(UInt16(clamping: hh))
            b.append(UInt8(scale))
            self.send(ScreenWire.ToPage.cursorStore.rawValue, Data(b + rgba))
        }
        h.cursorSelect = { [weak self] id in
            var b: [UInt8] = []
            b.put32(id)
            self?.send(ScreenWire.ToPage.cursorSelect.rawValue, Data(b))
        }
        h.layout = { [weak self] sw, sh, bw, bh in
            guard let self else { return }
            self.lock.lock()
            if sw > 0 && bw > 0 { self.scale = min(max((bw + sw / 2) / sw, 1), 4) }
            var (pw, ph) = (bw, bh)
            // The picture is the size its rectangles are drawn in.
            if self.standard && self.picW > 0 { pw = self.picW; ph = self.picH }
            self.lock.unlock()
            self.layoutFrame(sw, sh, pw, ph)
        }
        h.clipboard = { [weak self] text in
            guard text.utf8.count <= 256 << 10 else { return }
            self?.send(ScreenWire.ToPage.clipboard.rawValue, Data(text.utf8))
        }
        h.pictureSize = { [weak self] w, hh in
            guard let self else { return }
            self.lock.lock()
            self.picW = w; self.picH = hh
            let client = self.client
            self.lock.unlock()
            // The layout again, with the picture's new size.
            if let client {
                let (sw, sh, _, _) = client.layout()
                self.layoutFrame(sw, sh, w, hh)
            }
        }
        h.picture = { [weak self] x, y, w, hh, bgra in
            guard let self, w > 0, hh > 0, bgra.count >= w * hh * 4 else { return }
            let rows = max(1, Self.pictureBand / (w * 4))
            var top = 0
            while top < hh {
                let n = min(rows, hh - top)
                let band = bgra[(top * w * 4)..<((top + n) * w * 4)]
                if let deflated = Self.deflate(band) { self.piece(x, y + top, w, n, flags: 0, deflated) }
                top += n
            }
        }
        h.pictureCoded = { [weak self] x, y, w, hh, body in
            guard let self else { return }
            self.lock.lock()
            var flags: UInt8 = 4
            if self.codedFirst { self.codedFirst = false; flags |= 8 }
            self.lock.unlock()
            var rest = body
            while rest.count > Self.codedPiece {
                self.piece(x, y, w, hh, flags: flags | 16, rest.prefix(Self.codedPiece))
                rest = rest.dropFirst(Self.codedPiece)
                flags = 4
            }
            self.piece(x, y, w, hh, flags: flags, rest)
        }
        h.pictureEnd = { [weak self] in self?.whole() }
        return h
    }

    /// The update is all sent: a numbered word that it is whole, and, while more than a few are not
    /// yet on the window's screen, a wait (the reader's, so Screen Sharing waits too).
    private func whole() {
        shownCame.lock()
        serial &+= 1
        if serial == 0 { serial = 1 }
        let n = serial
        sentAt[Int(n % 64)] = Date()
        shownCame.unlock()
        lock.lock(); wholes += 1; lock.unlock()
        piece(Int(n >> 16), Int(n & 0xffff), 0, 0, flags: 1, [UInt8]())
        let deadline = Date().addingTimeInterval(1)
        shownCame.lock()
        while n &- shown >= Self.shownAhead, Date() < deadline {
            lock.lock(); let gone = ended; lock.unlock()
            if gone { break }
            shownCame.wait(until: deadline)
        }
        shownCame.unlock()
    }

    /// Raw deflate, as the window inflates a piece (no zlib header).
    static func deflate(_ bytes: ArraySlice<UInt8>) -> [UInt8]? {
        let capacity = bytes.count + bytes.count / 8 + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let n = bytes.withUnsafeBufferPointer { src in
            compression_encode_buffer(&out, capacity, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Array(out.prefix(n)) : nil
    }
}

// MARK: - Keys

/// The Mac's virtual key codes as the X11 keysyms Screen Sharing takes. A key is sent by what it is
/// on a US keyboard: the other Mac turns it back into its key with its own layout. Screen Sharing
/// reads the modifiers its own way: Super is Command, Meta is Option, Control is Control.
public enum ScreenKeys {
    static let commandL: UInt32 = 0xffeb, commandR: UInt32 = 0xffec, optionL: UInt32 = 0xffe7, optionR: UInt32 = 0xffe8

    static let table: [UInt16: UInt32] = {
        var t: [UInt16: UInt32] = [:]
        let letters: [(UInt16, Character)] = [
            (0x00, "a"), (0x01, "s"), (0x02, "d"), (0x03, "f"), (0x04, "h"), (0x05, "g"), (0x06, "z"), (0x07, "x"),
            (0x08, "c"), (0x09, "v"), (0x0B, "b"), (0x0C, "q"), (0x0D, "w"), (0x0E, "e"), (0x0F, "r"),
            (0x10, "y"), (0x11, "t"), (0x12, "1"), (0x13, "2"), (0x14, "3"), (0x15, "4"), (0x16, "6"), (0x17, "5"),
            (0x18, "="), (0x19, "9"), (0x1A, "7"), (0x1B, "-"), (0x1C, "8"), (0x1D, "0"), (0x1E, "]"), (0x1F, "o"),
            (0x20, "u"), (0x21, "["), (0x22, "i"), (0x23, "p"), (0x25, "l"), (0x26, "j"), (0x27, "'"), (0x28, "k"),
            (0x29, ";"), (0x2A, "\\"), (0x2B, ","), (0x2C, "/"), (0x2D, "n"), (0x2E, "m"), (0x2F, "."), (0x31, " "),
            (0x32, "`"), (0x5E, "_")
        ]
        for (code, c) in letters { t[code] = c.unicodeScalars.first!.value }
        let named: [(UInt16, UInt32)] = [
            (0x0A, 0xa7), (0x24, 0xff0d), (0x30, 0xff09), (0x33, 0xff08), (0x34, 0xff8d), (0x35, 0xff1b),
            (0x38, 0xffe1), (0x39, 0xffe5), (0x3A, optionL), (0x3B, 0xffe3), (0x3C, 0xffe2), (0x3D, optionR), (0x3E, 0xffe4),
            (0x40, 0xffce), (0x41, 0xffae), (0x43, 0xffaa), (0x45, 0xffab), (0x47, 0xff7f),
            (0x48, 0x1008ff13), (0x49, 0x1008ff11), (0x4A, 0x1008ff12), (0x4B, 0xffaf), (0x4C, 0xff8d), (0x4E, 0xffad),
            (0x4F, 0xffcf), (0x50, 0xffd0), (0x51, 0xffbd),
            (0x52, 0xffb0), (0x53, 0xffb1), (0x54, 0xffb2), (0x55, 0xffb3), (0x56, 0xffb4), (0x57, 0xffb5), (0x58, 0xffb6), (0x59, 0xffb7),
            (0x5A, 0xffd1), (0x5B, 0xffb8), (0x5C, 0xffb9), (0x5D, 0xa5), (0x5F, 0xffac),
            (0x60, 0xffc2), (0x61, 0xffc3), (0x62, 0xffc4), (0x63, 0xffc0), (0x64, 0xffc5), (0x65, 0xffc6),
            (0x66, 0xff30), (0x67, 0xffc8), (0x68, 0xff2e), (0x69, 0xffca), (0x6A, 0xffcd), (0x6B, 0xffcb),
            (0x6D, 0xffc7), (0x6F, 0xffc9), (0x71, 0xffcc), (0x72, 0xff63), (0x73, 0xff50), (0x74, 0xff55),
            (0x75, 0xffff), (0x76, 0xffc1), (0x77, 0xff57), (0x78, 0xffbf), (0x79, 0xff56), (0x7A, 0xffbe),
            (0x7B, 0xff51), (0x7C, 0xff53), (0x7D, 0xff54), (0x7E, 0xff52)
        ]
        for (code, ks) in named { t[code] = ks }
        return t
    }()

    /// The keysym for one of the Mac's virtual key codes; 0 for a key that has none (Fn).
    public static func keysym(forMacKey code: UInt16) -> UInt32 {
        switch code {
        case 0x37: return commandL
        case 0x36: return commandR
        default: return table[code] ?? 0
        }
    }

    /// The keysym that types one character: Latin-1 as itself, the rest as 0x01000000 plus its code
    /// point; 0 for what types nothing.
    public static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
        let r = scalar.value
        switch r {
        case 0x0a, 0x0d: return 0xff0d
        case 0x09: return 0xff09
        case 0..<0x20, 0x7f, 0x80..<0xa0: return 0
        case ...0xff: return r
        default: return 0x0100_0000 | r
        }
    }
}
