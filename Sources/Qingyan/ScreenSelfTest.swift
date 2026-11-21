#if DEBUG
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import Network
import QingyanCore
import VideoToolbox

/// A run of the screen session with nobody at the other end but this: a socket where the helper's
/// would be, the page's first words, a window whose picture keeps changing so that there is
/// something to send, and what comes back written into a directory to be looked at afterwards
/// (the video as an elementary stream, the sound, and report.json). For a machine that builds
/// out and has no page: `Qingyan --screen-selftest <dir> [avc|hevc]`.
enum ScreenSelfTest {
    @MainActor private static var keep: [AnyObject] = []

    @MainActor static func run(to directory: String, codec: String) async throws {
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let path = NSTemporaryDirectory() + "out-screen-\(getpid()).sock"
        unlink(path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            let session = ScreenSession(connection: connection)
            Task { @MainActor in keep.append(session) }
            session.start()
        }
        listener.start(queue: .main)
        keep.append(listener)

        // Something on the screen that moves: a picture that does not change is sent once.
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "0")
        label.font = .monospacedDigitSystemFont(ofSize: 120, weight: .bold)
        label.frame = NSRect(x: 20, y: 100, width: 480, height: 160)
        window.contentView?.addSubview(label)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        var count = 0
        let animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            count += 1
            label.stringValue = String(count)
            window.backgroundColor = NSColor(hue: CGFloat(count % 90) / 90, saturation: 0.6, brightness: 0.9, alpha: 1)
        }
        keep.append(window); keep.append(animation)

        try await Task.sleep(nanoseconds: 300_000_000)
        let client = NWConnection(to: .unix(path: path), using: .tcp)
        var report: [String: Any] = ["screenRecording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted(), "asked": codec]
        var statuses: [[String: Any]] = [], layouts: [[Int]] = []
        var frames = 0, keys = 0, videoBytes = 0, audioPackets = 0, audioBytes = 0, cursors = 0, selects = 0, clips = 0
        var record = Data(), videoCodec: UInt8 = 0, firstFrameAt = 0.0
        var video = Data(), audio = Data(), held = Data()
        let started = Date()
        func lengthPrefixedToAnnexB(_ body: Data) -> Data {
            var result = Data(), at = body.startIndex
            while body.endIndex - at >= 4 {
                let n = Int(body[at]) << 24 | Int(body[at + 1]) << 16 | Int(body[at + 2]) << 8 | Int(body[at + 3])
                guard n > 0, body.endIndex - at - 4 >= n else { break }
                result.append(contentsOf: [0, 0, 0, 1]); result.append(body[(at + 4)..<(at + 4 + n)])
                at += 4 + n
            }
            return result
        }
        func parameterSets() -> Data {
            var result = Data()
            let b = [UInt8](record)
            func add(_ at: inout Int) -> Bool {
                guard at + 2 <= b.count else { return false }
                let n = Int(b[at]) << 8 | Int(b[at + 1]); at += 2
                guard n > 0, at + n <= b.count else { return false }
                result.append(contentsOf: [0, 0, 0, 1]); result.append(contentsOf: b[at..<(at + n)]); at += n
                return true
            }
            if videoCodec == ScreenWire.Codec.avc.rawValue, b.count > 7 {
                var at = 6
                for _ in 0..<Int(b[5] & 0x1F) { if !add(&at) { return result } }
                guard at < b.count else { return result }
                let pps = Int(b[at]); at += 1
                for _ in 0..<pps { if !add(&at) { return result } }
            } else if b.count > 23 {
                var at = 23
                for _ in 0..<Int(b[22]) {
                    guard at + 3 <= b.count else { break }
                    let units = Int(b[at + 1]) << 8 | Int(b[at + 2]); at += 3
                    for _ in 0..<units { if !add(&at) { return result } }
                }
            }
            return result
        }
        func take(_ kind: UInt8, _ body: Data) {
            switch ScreenWire.ToPage(rawValue: kind) {
            case .status:
                if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] { statuses.append(object) }
            case .videoConfig:
                videoCodec = body.first ?? 0; record = Data(body.dropFirst())
            case .videoFrame:
                guard body.count > 5 else { return }
                if frames == 0 { firstFrameAt = Date().timeIntervalSince(started) }
                frames += 1; videoBytes += body.count
                if body[body.startIndex] & 1 == 1 { keys += 1; video.append(parameterSets()) }
                video.append(lengthPrefixedToAnnexB(Data(body.dropFirst(5))))
            case .audio:
                guard body.count > 7 else { return }
                audioPackets += 1; audioBytes += body.count - 7
                // An ADTS header in front of each access unit, so that a player reads the file: LC, 48 kHz, two channels.
                let n = body.count - 7 + 7
                audio.append(contentsOf: [0xFF, 0xF1, 0x4C, UInt8(0x80 | (n >> 11 & 3)), UInt8(n >> 3 & 0xFF), UInt8((n & 7) << 5 | 0x1F), 0xFC])
                audio.append(body.dropFirst(7))
            case .cursorStore: cursors += 1
            case .cursorSelect: selects += 1
            case .clipboard: clips += 1
            case .layout:
                let b = [UInt8](body)
                if b.count == 8 { layouts.append([Int(b[0]) << 8 | Int(b[1]), Int(b[2]) << 8 | Int(b[3]), Int(b[4]) << 8 | Int(b[5]), Int(b[6]) << 8 | Int(b[7])]) }
            case .none: break
            }
        }
        func receive() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let data { held.append(data) }
                var at = held.startIndex
                while held.endIndex - at >= 4 {
                    let n = Int(held[at + 1]) << 16 | Int(held[at + 2]) << 8 | Int(held[at + 3])
                    guard held.endIndex - at >= 4 + n else { break }
                    take(held[at], Data(held[(at + 4)..<(at + 4 + n)]))
                    at += 4 + n
                }
                held = Data(held[at...])
                if !complete && error == nil { receive() }
            }
        }
        func say(_ kind: ScreenWire.FromPage, _ body: Data) {
            var frame = Data([kind.rawValue, UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
            frame.append(body)
            client.send(content: frame, completion: .contentProcessed { _ in })
        }
        func control(_ object: [String: Any]) { say(.control, (try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
        client.start(queue: .main)
        receive()
        try await Task.sleep(nanoseconds: 300_000_000)
        control(["t": "open", "codecs": [codec], "audio": true, "kbps": 6000])
        // Another program's sound, since out's own is left out of what it sends.
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Submarine.aiff"]
        try? player.run()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        say(.pointer, Data([0, 0, 200, 0, 150])); say(.pointer, Data([1, 0, 200, 0, 150])); say(.pointer, Data([0, 0, 200, 0, 150]))
        say(.scroll, Data([0, 0, 0, 30, 0, 200, 0, 150]))
        control(["t": "text", "text": "ok"])
        control(["t": "clip", "text": "from the self-test"])
        let beforeResize = frames
        control(["t": "size", "w": 800, "h": 500, "scale": 1])
        control(["t": "kbps", "kbps": 3000])
        try await Task.sleep(nanoseconds: 3_000_000_000)
        report["framesBeforeResize"] = beforeResize
        report["clipboardNow"] = NSPasteboard.general.string(forType: .string) ?? ""
        report["cursor"] = ScreenSession.cursorReport()
        if let session = keep.compactMap({ $0 as? ScreenSession }).first { report["session"] = session.counts }
        client.cancel()
        try await Task.sleep(nanoseconds: 600_000_000)
        report["statuses"] = statuses; report["layouts"] = layouts
        report["frames"] = frames; report["keyFrames"] = keys; report["videoBytes"] = videoBytes; report["firstFrameAt"] = firstFrameAt
        report["audioPackets"] = audioPackets; report["audioBytes"] = audioBytes
        report["cursorShapes"] = cursors; report["cursorSelects"] = selects; report["clipboardFrames"] = clips
        report["codec"] = Int(videoCodec); report["recordBytes"] = record.count
        try video.write(to: out.appendingPathComponent(videoCodec == ScreenWire.Codec.hevc.rawValue ? "video.hevc" : "video.h264"))
        try audio.write(to: out.appendingPathComponent("audio.aac"))
        try record.write(to: out.appendingPathComponent("record.bin"))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("report.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8) ?? "")
    }
}
#endif

#if DEBUG
/// Another Mac's screen in out, with this Mac on both ends: the session (ScreenHost) at a socket of
/// its own, and out's own viewer (ScreenLink, the window's view) at the other end. Each picture the
/// viewer makes for its display layer is also decoded here, so that a format or sample it gets wrong
/// shows as a count of zero rather than as a black window nobody looks at. For a machine that builds
/// out: `Qingyan --screen-viewer-selftest <dir> [avc|hevc]`; it exits 1 when nothing was decoded.
enum ScreenViewerSelfTest {
    @MainActor private static var keep: [AnyObject] = []

    @MainActor static func run(to directory: String, codec: String) async throws -> Bool {
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let path = NSTemporaryDirectory() + "out-viewer-\(getpid()).sock"
        unlink(path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            let session = ScreenSession(connection: connection)
            Task { @MainActor in keep.append(session) }
            session.start()
        }
        listener.start(queue: .main)
        keep.append(listener)

        // Something on the screen that moves, as the session's own self-test has.
        let moving = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "0")
        label.font = .monospacedDigitSystemFont(ofSize: 120, weight: .bold)
        label.frame = NSRect(x: 20, y: 100, width: 480, height: 160)
        moving.contentView?.addSubview(label)
        moving.level = .floating
        moving.makeKeyAndOrderFront(nil)
        var tick = 0
        let animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            tick += 1
            label.stringValue = String(tick)
            moving.backgroundColor = NSColor(hue: CGFloat(tick % 90) / 90, saturation: 0.6, brightness: 0.9, alpha: 1)
        }
        keep.append(moving); keep.append(animation)

        // The viewer, in a window of its own as out shows it.
        let viewerWindow = NSWindow(contentRect: NSRect(x: 640, y: 80, width: 640, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = ScreenView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        viewerWindow.contentView = view
        viewerWindow.orderFrontRegardless()
        keep.append(viewerWindow)

        let link = ScreenLink(name: "self")
        link.preferAVC = codec != "hevc"
        view.displayLayer = link.displayLayer
        var statuses: [String] = [], layouts: [[Int]] = [], clipboard: [String] = [], cursors = 0
        link.onStatus = { status in statuses.append(status["s"] as? String ?? "?") }
        link.onLayout = { layout in view.remoteLayout = layout; layouts.append([layout.width, layout.height, layout.pictureWidth, layout.pictureHeight]) }
        link.onClipboard = { text in clipboard.append(text) }
        link.onCursor = { cursor in view.remoteCursor = cursor; cursors += 1 }
        var ended: String?
        link.onEnd = { why in ended = why }

        // Each picture the viewer makes, decoded here too.
        let decoder = SampleDecoder()
        link.onSample = { sample in decoder.decode(sample) }

        try await Task.sleep(nanoseconds: 300_000_000)
        let client = NWConnection(to: .unix(path: path), using: .tcp)
        client.start(queue: .main)
        link.start(client, scale: 2)
        try await Task.sleep(nanoseconds: 4_000_000_000)
        // The window's own words: a smaller picture, a key, the pointer, the wheel, the clipboard.
        link.send(ScreenWire.control(["t": "size", "w": 640, "h": 400, "scale": 1]))
        link.send(ScreenWire.pointerFrame(buttons: 0, x: 200, y: 150))
        link.send(ScreenWire.scrollFrame(dx: 0, dy: 30, x: 200, y: 150))
        link.send(ScreenWire.control(["t": "clip", "text": "from the viewer self-test"]))
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let counts = link.counts
        let renderer = link.displayLayer.sampleBufferRenderer
        var report: [String: Any] = ["screenRecording": CGPreflightScreenCaptureAccess(), "asked": codec, "viewer": counts,
                                     "decoded": decoder.decoded, "decodeErrors": decoder.errors, "decodedSize": decoder.size,
                                     "renderer": renderer.status == .failed ? "failed" : renderer.status == .rendering ? "rendering" : "unknown",
                                     "rendererError": renderer.error.map { "\($0)" } ?? "", "statuses": statuses, "layouts": layouts,
                                     "clipboardFrames": clipboard.count, "cursorsShown": cursors, "ended": ended ?? "",
                                     // Whether the window's clipboard text landed, and not what else is on the clipboard.
                                     "clipboardLanded": NSPasteboard.general.string(forType: .string) == "from the viewer self-test"]
        if let session = keep.compactMap({ $0 as? ScreenSession }).first { report["session"] = session.counts }
        link.close()
        try await Task.sleep(nanoseconds: 400_000_000)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("viewer-report.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8) ?? "")
        return decoder.decoded > 0 && renderer.status != .failed
    }
}

/// Decodes the viewer's samples with VideoToolbox, counting what comes out.
final class SampleDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var described: CMFormatDescription?
    private let lock = NSLock()
    private(set) var decoded = 0, errors = 0
    private(set) var size: [Int] = []

    func decode(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if session == nil || described.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
            if let session { VTDecompressionSessionInvalidate(session) }
            var made: VTDecompressionSession?
            let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
            guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                               imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &made) == noErr else {
                lock.lock(); errors += 1; lock.unlock(); return
            }
            session = made; described = format
        }
        guard let session else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if status == noErr, let image { self.decoded += 1; self.size = [CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)] }
            else { self.errors += 1 }
        }
        if status != noErr { lock.lock(); errors += 1; lock.unlock() }
    }
}
#endif
