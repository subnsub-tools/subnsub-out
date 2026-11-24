import Foundation
import Compression
import CoreGraphics
import Network

/// Another Mac's screen as out's window takes it, and worked from there.
///
/// The picture, the sound and the input are that Mac's own Screen Sharing. out's own client signs
/// in to it with the account the window gives and speaks these frames to the window in this process
/// (ScreenSession.swift); until 2026-11-25 the Monitor helper on that Mac did, and they crossed the
/// road between the Macs. A window may ask for Screen Sharing's standard mode ("standard" in its
/// first word): the Mac's display as it is, with no sound, sent where it changes and not at all while
/// it does not (user 2026-11-23: a Mac showing the High Performance video runs hot, and the system's
/// own standard mode does not). The frames, each way, [kind: 1 byte][length: 3 bytes][body]:
///
///     to the page    1 status (JSON): hello {v, name, user, codecs, signin}, connecting,
///                      live {w h (points), cw ch (pixels), own, audio, input}, end {why}
///                    2 video configuration: codec (2, HEVC), then hvcC
///                    3 video frame: flags (1 = key), timestamp (90 kHz), then
///                      [length: 4 bytes][NAL unit] for each unit
///                    4 audio packet: codec (2 = AAC-LC, 3 = AAC-ELD), timestamp (samples), sequence, bytes
///                    5 cursor shape: id, hot spot x y, size w h (pixels), pixels per point, RGBA
///                    6 cursor shown: id          7 clipboard (UTF-8)
///                    8 layout: the display in points w h, the picture in pixels w h
///                    9 picture (standard): x y w h (pixels), flags, then the rectangle's BGRA rows,
///                      deflated, or with flag 2 the rectangle as a JPEG (to a viewer whose open
///                      said jpeg; smaller than the rectangle to one that said scaled). Flag 1 =
///                      the update is whole: no rectangle, and for such a viewer x and y are the
///                      update's number, which it says back (shown). With flag 4 (to a viewer whose
///                      open said mvs) the rectangle as that Mac's Screen Sharing sent it in its own
///                      codec (ScreenMVS); flag 8 with it = the first of a session, flag 16 with it =
///                      the next piece holds more of the same rectangle's bytes
///     from the page  1 control (JSON): open {codecs, audio, kbps, user, password, own, standard, jpeg, scaled, mvs, w, h, scale},
///                      shown {n}, …
///                    2 pointer: buttons, x y (points)
///                    3 key: down, virtual key code
///                    4 scroll: dx dy (pixels, as a browser's wheel says them), x y
public enum ScreenWire {
    public enum ToPage: UInt8 { case status = 1, videoConfig, videoFrame, audio, cursorStore, cursorSelect, clipboard, layout, picture }
    public enum FromPage: UInt8 { case control = 1, pointer, key, scroll }
    public enum Codec: UInt8, Sendable {
        case avc = 1, hevc = 2
        public var name: String { self == .avc ? "avc" : "hevc" }
    }
    /// The audio codec byte for AAC-LC, raw access units.
    public static let audioAACLC: UInt8 = 2
    /// AAC-ELD as Screen Sharing sends it: 48 kHz, two channels, 480 samples a packet, raw access
    /// units (decoder configuration f8e65000).
    public static let audioAACELD: UInt8 = 3

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

    /// What arrives, cut into frames as it comes in pieces of any size: what the page sends (no
    /// frame over `controlLimit`), or, for out showing another Mac's screen, what that Mac sends.
    public struct Parser {
        private var held = Data()
        private let limit: Int
        public init(limit: Int = ScreenWire.controlLimit) { self.limit = limit }

        /// The whole frames in what has arrived so far; nil when a frame is longer than the other
        /// end may send, which ends the session.
        public mutating func feed(_ piece: Data) -> [(kind: UInt8, body: Data)]? {
            held.append(piece)
            var frames: [(kind: UInt8, body: Data)] = []
            var at = held.startIndex
            while held.endIndex - at >= 4 {
                let n = Int(held[at + 1]) << 16 | Int(held[at + 2]) << 8 | Int(held[at + 3])
                guard n <= limit else { return nil }
                guard held.endIndex - at >= 4 + n else { break }
                frames.append((held[at], Data(held[(at + 4)..<(at + 4 + n)])))
                at += 4 + n
            }
            // Only what was read is let go: a picture arriving in many pieces is not copied once a piece.
            if at > held.startIndex { held.removeSubrange(held.startIndex..<at) }
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

/// The other end of a session, for out showing another Mac's screen in a window of its own (user
/// 2026-11-21: a screen button after each Mac in Multiple Macs). What it sends is what the page
/// sends, and what it reads is what the page reads.
public extension ScreenWire {
    static func frame(from kind: FromPage, _ body: Data) -> Data {
        var out = Data(capacity: 4 + body.count)
        let n = min(body.count, 0xFF_FFFF)
        out.append(contentsOf: [kind.rawValue, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        out.append(body.prefix(n))
        return out
    }

    static func control(_ fields: [String: Any]) -> Data {
        frame(from: .control, (try? JSONSerialization.data(withJSONObject: fields)) ?? Data("{}".utf8))
    }

    /// Buttons as the page counts them: 1 the left, 2 the middle, 4 the right.
    static func pointerFrame(buttons: UInt8, x: Int, y: Int) -> Data {
        let x = UInt16(clamping: max(x, 0)), y = UInt16(clamping: max(y, 0))
        return frame(from: .pointer, Data([buttons & 7, UInt8(x >> 8), UInt8(x & 0xFF), UInt8(y >> 8), UInt8(y & 0xFF)]))
    }

    static func keyFrame(down: Bool, code: UInt16) -> Data {
        frame(from: .key, Data([down ? 1 : 0, UInt8(code >> 8), UInt8(code & 0xFF)]))
    }

    /// `dx` `dy`: how far the content moves, in pixels, as a browser's wheel says it.
    static func scrollFrame(dx: Int, dy: Int, x: Int, y: Int) -> Data {
        func bytes(_ v: Int) -> [UInt8] { let u = UInt16(bitPattern: Int16(clamping: v)); return [UInt8(u >> 8), UInt8(u & 0xFF)] }
        let x = UInt16(clamping: max(x, 0)), y = UInt16(clamping: max(y, 0))
        return frame(from: .scroll, Data(bytes(dx) + bytes(dy) + [UInt8(x >> 8), UInt8(x & 0xFF), UInt8(y >> 8), UInt8(y & 0xFF)]))
    }

    /// A Mac's wheel or trackpad, as the page's wheel would say it: AppKit counts the other way,
    /// and in lines where the device has no finer steps.
    static func wheel(deltaX: Double, deltaY: Double, precise: Bool) -> (dx: Int, dy: Int) {
        let unit = precise ? 1.0 : 16.0
        func one(_ v: Double) -> Int { Int((-v * unit).rounded()).clamped(-32000, 32000) }
        return (one(deltaX), one(deltaY))
    }

    struct Layout: Equatable, Sendable {
        /// The display in points, and the picture in pixels.
        public let width: Int, height: Int, pictureWidth: Int, pictureHeight: Int
        public init(width: Int, height: Int, pictureWidth: Int, pictureHeight: Int) {
            self.width = width; self.height = height; self.pictureWidth = pictureWidth; self.pictureHeight = pictureHeight
        }
    }

    static func layout(_ body: Data) -> Layout? {
        guard body.count >= 8 else { return nil }
        let b = [UInt8](body.prefix(8))
        func u(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        let layout = Layout(width: u(0), height: u(2), pictureWidth: u(4), pictureHeight: u(6))
        return layout.width > 0 && layout.height > 0 && layout.pictureWidth > 0 && layout.pictureHeight > 0 ? layout : nil
    }

    /// A piece of a standard session's picture: where it lies in the picture, in pixels, and its BGRA
    /// rows, deflated, or the same rectangle as a JPEG (`jpeg`: an adaptive session sends what
    /// changes that way, and the same pixels deflated once that place rests); or the rectangle in
    /// that Mac's own codec, as its Screen Sharing sent it (`coded`: `first` for the first of a
    /// session, `more` when the next piece holds more of its bytes); or, with no pixels, the word
    /// that the pieces of one update have all come.
    struct PicturePiece: Equatable, Sendable {
        public let x: Int, y: Int, width: Int, height: Int
        public let whole: Bool
        public let jpeg: Bool
        public let coded: Bool
        public let first: Bool
        public let more: Bool
        public let deflated: Data
        /// Of the word that an update is whole: the update's number in an adaptive session, which
        /// the helper waits to hear back before it asks that Mac what changed next; 0 otherwise.
        public var serial: Int { whole ? x << 16 | y : 0 }
    }

    static func picturePiece(_ body: Data) -> PicturePiece? {
        guard body.count >= 9 else { return nil }
        let b = [UInt8](body.prefix(9))
        func u(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        return PicturePiece(x: u(0), y: u(2), width: u(4), height: u(6), whole: b[8] & 1 == 1, jpeg: b[8] & 2 == 2,
                            coded: b[8] & 4 == 4, first: b[8] & 8 == 8, more: b[8] & 16 == 16, deflated: Data(body.dropFirst(9)))
    }

    /// The most pixels a picture has, its longest side, and the most bytes of pixels in one piece:
    /// what the helper sends is well inside each.
    static let pictureAreaLimit = 48 << 20
    static let pictureSideLimit = 16384
    static let pieceLimit = 8 << 20

    /// A piece's pixels inflated into `room`, which holds `capacity` bytes: how many came, and never
    /// more than `capacity`. A piece of `n` bytes is read into room for one more, so that one that
    /// holds more than it says is told from one that holds exactly that.
    static func inflate(_ deflated: Data, into room: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        guard capacity > 0, !deflated.isEmpty else { return 0 }
        return deflated.withUnsafeBytes { raw -> Int in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(room, capacity, source, deflated.count, nil, COMPRESSION_ZLIB)
        }
    }

    /// A picture: whether it is a key frame, its time (90 kHz), and its units, each after four bytes of length.
    static func videoFrame(_ body: Data) -> (key: Bool, stamp: UInt32, units: Data)? {
        guard body.count > 5 else { return nil }
        let b = body.startIndex
        let stamp = UInt32(body[b + 1]) << 24 | UInt32(body[b + 2]) << 16 | UInt32(body[b + 3]) << 8 | UInt32(body[b + 4])
        return (body[b] & 1 == 1, stamp, Data(body[(b + 5)...]))
    }

    /// A sound packet: its codec, its first sample, its sequence and its bytes.
    static func audioPacket(_ body: Data) -> (codec: UInt8, samples: UInt32, sequence: UInt16, bytes: Data)? {
        guard body.count > 7 else { return nil }
        let b = body.startIndex
        let samples = UInt32(body[b + 1]) << 24 | UInt32(body[b + 2]) << 16 | UInt32(body[b + 3]) << 8 | UInt32(body[b + 4])
        return (body[b], samples, UInt16(body[b + 5]) << 8 | UInt16(body[b + 6]), Data(body[(b + 7)...]))
    }

    struct CursorShape: Equatable, Sendable {
        public let id: UInt32
        /// The hot spot and the size in pixels, and the pixels to a point.
        public let hotX: Int, hotY: Int, width: Int, height: Int, scale: Int
        public let rgba: Data
    }

    static func cursorShape(_ body: Data) -> CursorShape? {
        guard body.count >= 13 else { return nil }
        let b = [UInt8](body.prefix(13))
        func u(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        let width = u(8), height = u(10)
        guard width > 0, height > 0, width <= 512, height <= 512, body.count >= 13 + width * height * 4 else { return nil }
        let start = body.startIndex + 13
        return CursorShape(id: cursorID(body) ?? 0, hotX: u(4), hotY: u(6), width: width, height: height, scale: max(1, Int(b[12])),
                           rgba: Data(body[start..<(start + width * height * 4)]))
    }

    /// What a pointer shape looks like, whatever its size: the Mac shown sends its pointer as a
    /// picture at a pixel a point, which is soft on a display of two; a shape that is one of this
    /// Mac's own pointers can be shown as that pointer instead, which the system draws sharp. The
    /// shape's box is cut into a grid: how opaque each cell is, and how light where it is solid.
    struct CursorSignature: Sendable {
        public static let side = 12
        public private(set) var opaque = [Float](repeating: 0, count: side * side)
        public private(set) var light = [Float](repeating: 0, count: side * side)
        public private(set) var solid = [Float](repeating: 0, count: side * side)
        /// The shape's width over its height, and the hot spot within its box (0 to 1 across it).
        public private(set) var aspect: Float = 1
        public private(set) var hotX: Float = 0, hotY: Float = 0

        /// From RGBA rows, top row first, and the hot spot in pixels from the top left.
        public init?(rgba: [UInt8], width: Int, height: Int, hotX hx: Double, hotY hy: Double) {
            guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
            var x0 = width, y0 = height, x1 = -1, y1 = -1
            for y in 0..<height {
                for x in 0..<width where rgba[(y * width + x) * 4 + 3] >= 96 {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
            guard x1 >= x0, y1 >= y0 else { return nil }
            let boxWidth = x1 - x0 + 1, boxHeight = y1 - y0 + 1
            guard boxWidth >= 3 || boxHeight >= 3 else { return nil }
            aspect = Float(boxWidth) / Float(boxHeight)
            hotX = Float((hx - Double(x0)) / Double(boxWidth)); hotY = Float((hy - Double(y0)) / Double(boxHeight))
            let n = Self.side
            var weight = [Float](repeating: 0, count: n * n)
            // Each pixel of the box goes to the cells it lies over, by its share in each.
            for y in 0..<boxHeight {
                let top = Float(y) * Float(n) / Float(boxHeight), bottom = Float(y + 1) * Float(n) / Float(boxHeight)
                for x in 0..<boxWidth {
                    let i = ((y + y0) * width + x + x0) * 4
                    let alpha = Float(rgba[i + 3]) / 255
                    let lightness = (0.299 * Float(rgba[i]) + 0.587 * Float(rgba[i + 1]) + 0.114 * Float(rgba[i + 2])) / 255
                    let left = Float(x) * Float(n) / Float(boxWidth), right = Float(x + 1) * Float(n) / Float(boxWidth)
                    var row = Int(top)
                    while row < n, Float(row) < bottom {
                        let tall = min(bottom, Float(row + 1)) - max(top, Float(row))
                        var column = Int(left)
                        while column < n, Float(column) < right {
                            let share = (min(right, Float(column + 1)) - max(left, Float(column))) * tall
                            if share > 0 {
                                let cell = row * n + column
                                weight[cell] += share; opaque[cell] += alpha * share
                                // Only where the shape is solid: its edges are the same whether or not
                                // the colors were multiplied by their alpha.
                                if alpha >= 0.9 { solid[cell] += share; light[cell] += lightness * share }
                            }
                            column += 1
                        }
                        row += 1
                    }
                }
            }
            for cell in 0..<(n * n) {
                if solid[cell] > 0 { light[cell] /= solid[cell] }
                if weight[cell] > 0 { opaque[cell] /= weight[cell]; solid[cell] /= weight[cell] }
            }
        }

        /// How far this shape is from another, when it could be the same pointer at another size
        /// (the same proportions, the hot spot at the same place, the same outline and lightness
        /// within what drawing a pointer at another size changes); nil when it is not.
        public func nearness(to other: CursorSignature) -> Float? {
            guard abs(log(aspect / other.aspect)) <= 0.14, abs(hotX - other.hotX) <= 0.14, abs(hotY - other.hotY) <= 0.14 else { return nil }
            var outline: Float = 0, lightness: Float = 0, both: Float = 0
            for cell in 0..<opaque.count {
                outline += abs(opaque[cell] - other.opaque[cell])
                let shared = min(solid[cell], other.solid[cell])
                lightness += abs(light[cell] - other.light[cell]) * shared; both += shared
            }
            outline /= Float(opaque.count)
            lightness = both > 0 ? lightness / both : 1
            guard outline <= 0.09, lightness <= 0.17 else { return nil }
            return outline + lightness / 2
        }
    }

    /// The one of `known` a shape is, each known by how it looks at a few sizes: the nearest, unless
    /// another is nearly as near (two pointers that differ by a small mark are not told apart).
    static func cursor<Known>(like shape: CursorSignature, among known: [(Known, [CursorSignature])]) -> Known? {
        var best: (index: Int, nearness: Float)?, second: Float?
        for (index, entry) in known.enumerated() {
            guard let nearness = entry.1.compactMap({ shape.nearness(to: $0) }).min() else { continue }
            if best == nil || nearness < best!.nearness {
                second = best?.nearness; best = (index, nearness)
            } else if second == nil || nearness < second! {
                second = nearness
            }
        }
        guard let best else { return nil }
        if let second, second - best.nearness < 0.03 { return nil }
        return known[best.index].0
    }

    static func cursorID(_ body: Data) -> UInt32? {
        guard body.count >= 4 else { return nil }
        let b = body.startIndex
        return UInt32(body[b]) << 24 | UInt32(body[b + 1]) << 16 | UInt32(body[b + 2]) << 8 | UInt32(body[b + 3])
    }

    /// The parameter sets in an H.264 decoder record (avcC): its sequence and picture sets.
    static func avcParameterSets(_ record: Data) -> [Data]? {
        let b = [UInt8](record)
        guard b.count >= 7, b[0] == 1 else { return nil }
        var at = 5, sets: [Data] = []
        for group in 0..<2 {
            guard at < b.count else { return nil }
            let count = group == 0 ? Int(b[at] & 0x1F) : Int(b[at])
            at += 1
            for _ in 0..<count {
                guard at + 2 <= b.count else { return nil }
                let n = Int(b[at]) << 8 | Int(b[at + 1]); at += 2
                guard n > 0, at + n <= b.count else { return nil }
                sets.append(Data(b[at..<(at + n)])); at += n
            }
        }
        return sets.count >= 2 ? sets : nil
    }

    /// The parameter sets in an HEVC decoder record (hvcC): video, sequence and picture sets.
    static func hevcParameterSets(_ record: Data) -> [Data]? {
        let b = [UInt8](record)
        guard b.count >= 23, b[0] == 1 else { return nil }
        var at = 22
        let arrays = Int(b[at]); at += 1
        var sets: [Data] = []
        for _ in 0..<arrays {
            guard at + 3 <= b.count else { return nil }
            let count = Int(b[at + 1]) << 8 | Int(b[at + 2]); at += 3
            for _ in 0..<count {
                guard at + 2 <= b.count else { return nil }
                let n = Int(b[at]) << 8 | Int(b[at + 1]); at += 2
                guard n > 0, at + n <= b.count else { return nil }
                sets.append(Data(b[at..<(at + n)])); at += n
            }
        }
        return sets.count >= 3 ? sets : nil
    }

    /// Where a place in the window's picture is on the other Mac's display, in its points; nil
    /// outside the picture. `picture`: where the picture is drawn in the window.
    static func remotePoint(_ point: CGPoint, picture: CGRect, display: (width: Int, height: Int), flipped: Bool) -> (x: Int, y: Int)? {
        guard picture.width > 0, picture.height > 0, display.width > 0, display.height > 0, picture.contains(point) else { return nil }
        let fx = (point.x - picture.minX) / picture.width
        let fy = flipped ? (point.y - picture.minY) / picture.height : (picture.maxY - point.y) / picture.height
        return (Int((fx * Double(display.width)).rounded(.down)).clamped(0, display.width - 1),
                Int((fy * Double(display.height)).rounded(.down)).clamped(0, display.height - 1))
    }

    /// Where a picture of these proportions is drawn in a window of this size: as large as fits, centered.
    static func fit(_ size: (width: Int, height: Int), in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let k = min(bounds.width / CGFloat(size.width), bounds.height / CGFloat(size.height))
        let w = CGFloat(size.width) * k, h = CGFloat(size.height) * k
        return CGRect(x: bounds.minX + (bounds.width - w) / 2, y: bounds.minY + (bounds.height - h) / 2, width: w, height: h)
    }
}

extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}
