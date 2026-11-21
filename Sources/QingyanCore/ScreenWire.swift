import Foundation
import CoreGraphics
import Network

/// This Mac's screen shown on the owner's Monitor page, and worked from there.
///
/// The page reaches the Monitor helper on this Mac through its tunnel, signed by a key the
/// helper has pinned, and the helper hands the two streams of that screen session to out over
/// its socket (HelperLink.parkScreen), as it hands a stream from another Mac's out. The helper
/// reads none of it. What travels is frames each way, [kind: 1 byte][length: 3 bytes][body]:
///
///     to the page    1 status (JSON)             2 video configuration: codec, then avcC / hvcC
///                    3 video frame: flags (1 = key), timestamp (90 kHz), then
///                      [length: 4 bytes][NAL unit] for each unit
///                    4 audio packet: codec (2 = AAC-LC), timestamp (samples), sequence, bytes
///                    5 cursor shape: id, hot spot x y, size w h (pixels), pixels per point, RGBA
///                    6 cursor shown: id          7 clipboard (UTF-8)
///                    8 layout: the display in points w h, the picture in pixels w h
///     from the page  1 control (JSON)            2 pointer: buttons, x y (points)
///                    3 key: down, virtual key code
///                    4 scroll: dx dy (pixels, as a browser's wheel says them), x y
///
/// The page's viewer is screen-hp.js; the helper's side is screen.go and put.go.
public enum ScreenWire {
    public enum ToPage: UInt8 { case status = 1, videoConfig, videoFrame, audio, cursorStore, cursorSelect, clipboard, layout }
    public enum FromPage: UInt8 { case control = 1, pointer, key, scroll }
    public enum Codec: UInt8, Sendable {
        case avc = 1, hevc = 2
        public var name: String { self == .avc ? "avc" : "hevc" }
    }
    /// The audio codec byte for AAC-LC, raw access units.
    public static let audioAACLC: UInt8 = 2

    /// The most one frame carries either way: a control message is small, a picture is not, and
    /// neither reaches what three bytes of length can say.
    public static let controlLimit = 300 << 10
    public static let frameLimit = 8 << 20
    public static let clipboardLimit = 256 << 10

    public static func frame(_ kind: ToPage, _ body: Data) -> Data {
        var out = Data(capacity: 4 + body.count)
        let n = min(body.count, 0xFF_FFFF)
        out.append(contentsOf: [kind.rawValue, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        out.append(body.prefix(n))
        return out
    }

    public static func status(_ fields: [String: Any]) -> Data {
        frame(.status, (try? JSONSerialization.data(withJSONObject: fields)) ?? Data("{}".utf8))
    }

    /// What the page sends, cut into frames as it arrives in pieces of any size.
    public struct Parser {
        private var held = Data()
        public init() {}

        /// The whole frames in what has arrived so far; nil when a frame is longer than a page
        /// may send, which ends the session.
        public mutating func feed(_ piece: Data) -> [(kind: UInt8, body: Data)]? {
            held.append(piece)
            var frames: [(kind: UInt8, body: Data)] = []
            var at = held.startIndex
            while held.endIndex - at >= 4 {
                let n = Int(held[at + 1]) << 16 | Int(held[at + 2]) << 8 | Int(held[at + 3])
                guard n <= ScreenWire.controlLimit else { return nil }
                guard held.endIndex - at >= 4 + n else { break }
                frames.append((held[at], Data(held[(at + 4)..<(at + 4 + n)])))
                at += 4 + n
            }
            held = Data(held[at...])
            return frames
        }
    }

    public enum Command: Equatable {
        /// The page's first word: the codecs its decoder takes, in its order of preference, whether
        /// it wants the sound, and its settings.
        case open(codecs: [Codec], audio: Bool, size: Size?, kbps: Int)
        /// The size the picture is sent at: the window's, or nil for the display's own.
        case size(Size?)
        case kbps(Int)
        case keyframe
        case clipboard(String)
        /// Text to type as it is: an input method's word, an on-screen keyboard's.
        case text(String)
        case audio(Bool)
    }

    /// A window's size in points and its pixels per point.
    public struct Size: Equatable, Sendable {
        public let width: Int, height: Int
        public let scale: Double
        public init(width: Int, height: Int, scale: Double) { self.width = width; self.height = height; self.scale = scale }
    }

    public static let kbpsRange = 500...80_000
    public static let kbpsDefault = 12_000

    public static func command(_ body: Data) -> Command? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let kind = object["t"] as? String else { return nil }
        func size() -> Size? {
            guard let w = object["w"] as? Int, let h = object["h"] as? Int, w >= 160, h >= 120, w <= 16384, h <= 16384 else { return nil }
            let scale = (object["scale"] as? Double) ?? Double(object["scale"] as? Int ?? 1)
            return Size(width: w, height: h, scale: min(max(scale, 1), 3))
        }
        func rate() -> Int {
            let asked = object["kbps"] as? Int ?? kbpsDefault
            return asked <= 0 ? kbpsDefault : min(max(asked, kbpsRange.lowerBound), kbpsRange.upperBound)
        }
        switch kind {
        case "open":
            let names = object["codecs"] as? [String] ?? ["avc"]
            var codecs = names.compactMap { $0 == "avc" ? Codec.avc : $0 == "hevc" ? Codec.hevc : nil }
            if codecs.isEmpty { codecs = [.avc] }
            return .open(codecs: codecs, audio: object["audio"] as? Bool ?? true, size: size(), kbps: rate())
        case "size": return .size(size())
        case "kbps": return .kbps(rate())
        case "key": return .keyframe
        case "clip":
            guard let text = object["text"] as? String, text.utf8.count <= clipboardLimit else { return nil }
            return .clipboard(text)
        case "text":
            guard let text = object["text"] as? String, text.utf16.count <= 4096 else { return nil }
            return .text(text)
        case "audio": return .audio(object["on"] as? Bool ?? true)
        default: return nil
        }
    }

    public struct Pointer: Equatable {
        public let buttons: UInt8
        public let x: Int, y: Int
        public init(buttons: UInt8, x: Int, y: Int) { self.buttons = buttons; self.x = x; self.y = y }
    }
    public static func pointer(_ body: Data) -> Pointer? {
        guard body.count == 5 else { return nil }
        let b = [UInt8](body)
        return Pointer(buttons: b[0] & 7, x: Int(b[1]) << 8 | Int(b[2]), y: Int(b[3]) << 8 | Int(b[4]))
    }

    public struct Key: Equatable {
        public let down: Bool
        public let code: UInt16
        public init(down: Bool, code: UInt16) { self.down = down; self.code = code }
    }
    public static func key(_ body: Data) -> Key? {
        guard body.count == 3 else { return nil }
        let b = [UInt8](body)
        let code = UInt16(b[1]) << 8 | UInt16(b[2])
        // The Mac's virtual key codes end at 0x7E.
        return code <= 0x7E ? Key(down: b[0] != 0, code: code) : nil
    }

    public struct Scroll: Equatable { public let dx: Int, dy: Int, x: Int, y: Int }
    public static func scroll(_ body: Data) -> Scroll? {
        guard body.count == 8 else { return nil }
        let b = [UInt8](body)
        func signed(_ hi: UInt8, _ lo: UInt8) -> Int { Int(Int16(bitPattern: UInt16(hi) << 8 | UInt16(lo))) }
        return Scroll(dx: signed(b[0], b[1]), dy: signed(b[2], b[3]), x: Int(b[4]) << 8 | Int(b[5]), y: Int(b[6]) << 8 | Int(b[7]))
    }

    /// The pixels a picture is sent at: the display's own, or what fits the page's window at its
    /// pixel density, in the display's proportions, never larger than the display and with even
    /// sides (a video picture's are).
    public static func pictureSize(displayPixels: (width: Int, height: Int), window: Size?) -> (width: Int, height: Int) {
        let dw = max(displayPixels.width, 2), dh = max(displayPixels.height, 2)
        func even(_ value: Double) -> Int { max(2, Int(value.rounded()) & ~1) }
        guard let window else { return (dw & ~1, dh & ~1) }
        let ww = Double(window.width) * window.scale, wh = Double(window.height) * window.scale
        let factor = min(ww / Double(dw), wh / Double(dh), 1)
        // Not smaller than can be read: a quarter of the display, or 640 across.
        let least = max(0.25, min(1, 640 / Double(dw)))
        let used = max(factor, least)
        return (even(Double(dw) * used), even(Double(dh) * used))
    }

    /// The modifier keys among the virtual key codes, and the flag each stands for.
    public static func modifier(_ code: UInt16) -> CGEventFlags? {
        switch code {
        case 0x37, 0x36: return .maskCommand
        case 0x38, 0x3C: return .maskShift
        case 0x3A, 0x3D: return .maskAlternate
        case 0x3B, 0x3E: return .maskControl
        default: return nil
        }
    }

    /// How many presses in a row a press is: the second of a double click, the third of a triple.
    public struct Clicks {
        private var last: (button: UInt8, at: TimeInterval, x: Int, y: Int, count: Int)?
        public init() {}
        public mutating func press(button: UInt8, at time: TimeInterval, x: Int, y: Int, within interval: TimeInterval) -> Int {
            var count = 1
            if let last, last.button == button, time - last.at <= interval, abs(x - last.x) <= 4, abs(y - last.y) <= 4 {
                count = last.count + 1
            }
            last = (button, time, x, y, count)
            return count
        }
        public var current: Int { last?.count ?? 1 }
    }

    /// A cursor's pixels, drawn premultiplied, as plain RGBA.
    public static func unpremultiply(_ pixels: inout [UInt8]) {
        var i = 0
        while i + 3 < pixels.count {
            let a = Int(pixels[i + 3])
            if a > 0 && a < 255 {
                pixels[i] = UInt8(min(255, Int(pixels[i]) * 255 / a))
                pixels[i + 1] = UInt8(min(255, Int(pixels[i + 1]) * 255 / a))
                pixels[i + 2] = UInt8(min(255, Int(pixels[i + 2]) * 255 / a))
            }
            i += 4
        }
    }
}

extension HelperLink {
    /// Leaves a connection waiting at the helper for a screen session from the Monitor page.
    public static func parkScreen() async throws -> NWConnection {
        let connection = try await connect()
        do { try await bounded(connection, 5) { try await ask(connection, ["op": "screen"]) } }
        catch { connection.cancel(); throw Absence.notRunning }
        return connection
    }

    /// The session on a parked connection, once the page opens one. A helper too old to know
    /// the question answers it with a refusal instead.
    public static func screenArrival(_ connection: NWConnection) async throws {
        let header = try await readLine(connection)
        if header["ok"] as? Bool == false { throw Absence.notInstalled }
        guard header["from"] as? String == "page" else {
            throw VoiceError(tr("The helper on this Mac answered in a way out does not understand."))
        }
    }
}
