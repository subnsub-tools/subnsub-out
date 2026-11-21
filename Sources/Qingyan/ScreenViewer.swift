import AppKit
import AVFoundation
import CoreMedia
import Network
import QingyanCore
import VideoToolbox

/// Another Mac's screen in a window of out's own (user 2026-11-21: a screen button after each Mac
/// in Multiple Macs opens it; the Macs there can be worked from each other's out without a switch).
/// That Mac's out captures and encodes its screen (ScreenHost) as it does for the Monitor page; this
/// window is the page's viewer in out: the picture, the sound, the pointer's shape, the clipboard
/// both ways, and the pointer, the keys and the wheel sent back. One window a Mac.
@MainActor
final class ScreenViewer: NSObject, NSWindowDelegate {
    private static var open: [String: ScreenViewer] = [:]

    /// The Mac whose screen is in the window in front: out is the app in front, and the window is
    /// its key window. Dictation goes to that Mac, as it goes behind a remote desktop.
    static var frontKey: String? {
        guard NSApp.isActive else { return nil }
        return open.values.first { $0.window.isKeyWindow && $0.live }?.device.key
    }

    static func show(_ device: TrustedDevice, controller: DictationController) {
        NSApp.activate(ignoringOtherApps: true)
        if let viewer = open[device.key] {
            viewer.window.makeKeyAndOrderFront(nil)
            if viewer.ended { viewer.connect() }
            return
        }
        let viewer = ScreenViewer(device: device, controller: controller)
        open[device.key] = viewer
        viewer.window.makeKeyAndOrderFront(nil)
        viewer.connect()
    }

    let device: TrustedDevice
    private weak var controller: DictationController?
    let window: NSWindow
    private let view: ScreenView
    private var link: ScreenLink?
    private var ended = true
    /// The screen is shown: a window still connecting, or one that says why it is not, takes no dictation.
    private(set) var live = false
    private var sized = false
    private var resizeWork: DispatchWorkItem?
    private var clipboardSeen = 0
    private var clipboardTimer: Timer?

    private init(device: TrustedDevice, controller: DictationController) {
        self.device = device
        self.controller = controller
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1024, visible.width * 0.8), height: min(640, visible.height * 0.8))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        view = ScreenView(frame: NSRect(origin: .zero, size: size))
        super.init()
        window.title = tr("%@ — Screen", device.label)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.contentMinSize = NSSize(width: 320, height: 200)
        window.center()
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        view.onReconnect = { [weak self] in self?.connect() }
        view.send = { [weak self] frame in self?.link?.send(frame) }
    }

    // MARK: The session

    private func connect() {
        guard let controller, let identity = controller.identity else {
            view.say(tr("This Mac has no identity for working with other Macs yet. Open Multiple Macs on the panel first."), again: false)
            return
        }
        link?.close()
        ended = false
        live = false
        sized = false
        view.reset()
        view.say(tr("Connecting to %@…", device.label), again: false)
        let device = device, name = controller.deviceName, listening = controller.settings.preferences.remotePort
        let next = ScreenLink(name: device.label)
        link = next
        next.onStatus = { [weak self, weak next] status in
            guard let self, let next, self.link === next else { return }
            self.status(status)
        }
        next.onLayout = { [weak self, weak next] layout in
            guard let self, let next, self.link === next else { return }
            self.view.remoteLayout = layout
            self.fitWindow(to: layout)
        }
        next.onClipboard = { [weak self, weak next] text in
            guard let self, let next, self.link === next else { return }
            // Only the window in front: another one's text would be sent on to the Mac in front.
            guard NSApp.isActive, self.window.isKeyWindow else { return }
            // Through the lease, so that a dictation on its way to a paste keeps the clipboard until it lands.
            PasteboardLease.general.keep(text)
            self.clipboardSeen = NSPasteboard.general.changeCount
        }
        next.onCursor = { [weak self, weak next] cursor in
            guard let self, let next, self.link === next else { return }
            self.view.remoteCursor = cursor
        }
        next.onEnd = { [weak self, weak next] why in
            guard let self, let next, self.link === next else { return }
            self.end(why)
        }
        view.displayLayer = next.displayLayer
        Task { @MainActor [weak self] in
            do {
                let connection = try await RemoteSender.openScreen(device, identity: identity, name: name, listening: listening)
                guard let self, self.link === next, !self.ended else { connection.cancel(); return }
                next.start(connection, scale: self.window.backingScaleFactor)
            } catch {
                guard let self, self.link === next else { return }
                self.ended = true
                self.view.say(error.localizedDescription, again: true)
            }
        }
    }

    private func status(_ status: [String: Any]) {
        guard let state = status["s"] as? String else { return }
        switch state {
        case "live":
            live = true
            view.say(nil, again: false)
            view.canControl = status["input"] as? Bool != false
            view.banner = view.canControl ? nil
                : tr("View only: out on %@ has no Accessibility permission, so the pointer and keys do not reach it.", device.label)
            clipboardSeen = 0
            sendClipboard()
            startClipboardWatch()
        case "cursor":
            if status["picture"] as? Bool == true { view.cursorInPicture = true }
        default:
            break
        }
    }

    private func end(_ why: String) {
        guard !ended else { return }
        ended = true
        live = false
        stopClipboardWatch()
        view.releaseAll()
        let name = device.label
        let words: String
        switch why {
        case "busy": words = tr("%@’s screen is being shown elsewhere. Try again once that has ended.", name)
        case "perm-screen": words = tr("out on %@ may not record its screen. On that Mac, turn out on in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen out there.", name)
        case "stopped", "off": words = tr("%@ stopped showing its screen.", name)
        case "no-display", "capture-stopped", "failed": words = tr("%@’s screen could not be captured.", name)
        default: words = tr("The connection to %@ was lost.", name)
        }
        view.say(words, again: true)
    }

    /// The window in the proportions of that Mac's display, as large as fits most of this screen
    /// the first time; later only its proportions follow.
    private func fitWindow(to layout: ScreenWire.Layout) {
        window.contentAspectRatio = NSSize(width: layout.width, height: layout.height)
        guard !sized else { return }
        sized = true
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let fitted = ScreenWire.fit((layout.width, layout.height), in: CGRect(origin: .zero, size: CGSize(width: visible.width * 0.85, height: visible.height * 0.85)))
        let size = NSSize(width: min(fitted.width, CGFloat(layout.width)), height: min(fitted.height, CGFloat(layout.height)))
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        window.setFrame(NSRect(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2, width: frame.width, height: frame.height), display: true)
        askSize()
    }

    /// The picture is sent at the window's size (the other Mac's display stays as it is).
    private func askSize() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ended else { return }
            let size = self.view.bounds.size
            guard size.width >= 160, size.height >= 120 else { return }
            self.link?.send(ScreenWire.control(["t": "size", "w": Int(size.width), "h": Int(size.height), "scale": Double(self.window.backingScaleFactor)]))
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: The clipboard: this Mac's text goes over while the window is in front

    private func startClipboardWatch() {
        stopClipboardWatch()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window.isKeyWindow == true { self?.sendClipboard() } }
        }
        timer.tolerance = 0.3
        clipboardTimer = timer
    }

    private func stopClipboardWatch() { clipboardTimer?.invalidate(); clipboardTimer = nil }

    private func sendClipboard() {
        guard !ended, live, view.canControl, NSApp.isActive, window.isKeyWindow else { return }
        let board = NSPasteboard.general
        guard board.changeCount != clipboardSeen else { return }
        clipboardSeen = board.changeCount
        guard let text = board.string(forType: .string), !text.isEmpty, text.utf8.count <= ScreenWire.clipboardLimit else { return }
        let frame = ScreenWire.control(["t": "clip", "text": text])
        // Its JSON, quotes and line breaks escaped, must still be a frame the other Mac takes, or the session ends.
        guard frame.count - 4 <= ScreenWire.controlLimit else { return }
        link?.send(frame)
    }

    // MARK: The window

    func windowDidBecomeKey(_ notification: Notification) { sendClipboard() }

    func windowDidResignKey(_ notification: Notification) {
        // Keys and buttons held here are let go there: this window no longer hears them go up.
        view.releaseAll()
    }

    func windowDidEndLiveResize(_ notification: Notification) { askSize() }
    func windowDidExitFullScreen(_ notification: Notification) { askSize() }
    func windowDidEnterFullScreen(_ notification: Notification) { askSize() }

    func windowWillClose(_ notification: Notification) {
        ended = true
        live = false
        stopClipboardWatch()
        view.releaseAll()
        link?.close()
        link = nil
        Self.open.removeValue(forKey: device.key)
    }
}

/// The connection of one session: frames in and out, the picture decoded into a display layer and
/// the sound into a player. Frames are read on a queue of its own.
final class ScreenLink: @unchecked Sendable {
    var onStatus: (@MainActor ([String: Any]) -> Void)?
    var onLayout: (@MainActor (ScreenWire.Layout) -> Void)?
    var onClipboard: (@MainActor (String) -> Void)?
    var onCursor: (@MainActor (RemoteCursor) -> Void)?
    var onEnd: (@MainActor (String) -> Void)?

    let displayLayer = AVSampleBufferDisplayLayer()
    private let name: String
    private let queue = DispatchQueue(label: "local.hopo.qingyan.screen.viewer")
    private var connection: NWConnection?
    private var parser = ScreenWire.Parser(limit: ScreenWire.frameLimit + 8)
    private var closed = false
    private var opened = false
    private var scale: CGFloat = 2

    private var format: CMVideoFormatDescription?
    private var awaitingKey = true
    private var cursors: [UInt32: RemoteCursor.Shape] = [:]
    private let sound = ScreenSound()

    init(name: String) {
        self.name = name
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    func start(_ connection: NWConnection, scale: CGFloat) {
        queue.async {
            self.connection = connection
            self.scale = scale
            self.receive()
        }
    }

    func send(_ frame: Data) {
        queue.async {
            guard !self.closed, let connection = self.connection else { return }
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.queue.async { self?.finish("lost") } }
            })
        }
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.connection?.cancel()
            self.sound.stop()
        }
    }

    private func receive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] data, _, complete, error in
            self?.queue.async {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.take(data) }
                if complete || error != nil { self.finish("lost"); return }
                if !self.closed { self.receive() }
            }
        }
    }

    private func finish(_ why: String) {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        sound.stop()
        let onEnd = onEnd
        DispatchQueue.main.async { MainActor.assumeIsolated { onEnd?(why) } }
    }

    private func main(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    private func take(_ data: Data) {
        guard let frames = parser.feed(data) else { finish("failed"); return }
        for frame in frames {
            guard !closed else { return }
            switch ScreenWire.ToPage(rawValue: frame.kind) {
            case .status:
                guard let status = (try? JSONSerialization.jsonObject(with: frame.body)) as? [String: Any], let state = status["s"] as? String else { continue }
                switch state {
                case "hello":
                    guard !opened else { continue }
                    opened = true
                    let theirs = status["codecs"] as? [String] ?? ["avc"]
                    var codecs: [String] = []
                    var hevc = theirs.contains("hevc") && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
                    #if DEBUG
                    if preferAVC { hevc = false }
                    #endif
                    if hevc { codecs.append("hevc") }
                    if theirs.contains("avc") || theirs.isEmpty { codecs.append("avc") }
                    connection?.send(content: ScreenWire.control(["t": "open", "codecs": codecs, "audio": true, "kbps": ScreenWire.kbpsDefault]),
                                     completion: .contentProcessed { _ in })
                case "live":
                    count("live")
                    if status["audio"] as? Bool == true { sound.start() }
                    if let w = status["w"] as? Int, let h = status["h"] as? Int, let cw = status["cw"] as? Int, let ch = status["ch"] as? Int,
                       w > 0, h > 0, cw > 0, ch > 0 {
                        let layout = ScreenWire.Layout(width: w, height: h, pictureWidth: cw, pictureHeight: ch)
                        let onLayout = onLayout
                        main { onLayout?(layout) }
                    }
                    let onStatus = onStatus
                    main { onStatus?(status) }
                case "end":
                    finish(status["why"] as? String ?? "stopped")
                default:
                    let onStatus = onStatus
                    main { onStatus?(status) }
                }
            case .videoConfig:
                configure(frame.body)
            case .videoFrame:
                picture(frame.body)
            case .audio:
                if let packet = ScreenWire.audioPacket(frame.body), packet.codec == ScreenWire.audioAACLC { count("soundPackets"); sound.play(packet.bytes) }
            case .layout:
                if let layout = ScreenWire.layout(frame.body) {
                    count("layouts")
                    let onLayout = onLayout
                    main { onLayout?(layout) }
                }
            case .cursorStore:
                if let shape = ScreenWire.cursorShape(frame.body) {
                    count("cursorShapes")
                    cursors[shape.id] = RemoteCursor.Shape(shape)
                    if cursors.count > 64, let oldest = cursors.keys.min() { cursors.removeValue(forKey: oldest) }
                }
            case .cursorSelect:
                if let id = ScreenWire.cursorID(frame.body), let shape = cursors[id] {
                    let onCursor = onCursor
                    main { onCursor?(RemoteCursor(shape: shape)) }
                }
            case .clipboard:
                if let text = String(data: frame.body, encoding: .utf8) {
                    let onClipboard = onClipboard
                    main { onClipboard?(text) }
                }
            case .none:
                break
            }
        }
    }

    // MARK: The picture

    #if DEBUG
    /// For the self-test: each picture made for the display layer, and what the session counted.
    var onSample: ((CMSampleBuffer) -> Void)?
    var preferAVC = false
    private(set) var counted: [String: Int] = [:]
    private func count(_ what: String) { counted[what, default: 0] += 1 }
    var counts: [String: Int] { queue.sync { counted.merging(["soundBuffers": sound.played]) { a, _ in a } } }
    #else
    private func count(_ what: String) {}
    #endif

    /// The format a decoder reads the pictures with, from the decoder record the other Mac sent.
    static func format(codec: ScreenWire.Codec, record: Data) -> CMVideoFormatDescription? {
        guard let sets = codec == .hevc ? ScreenWire.hevcParameterSets(record) : ScreenWire.avcParameterSets(record) else { return nil }
        let pointers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let unsafe = pointers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var made: CMFormatDescription?
        let status: OSStatus = unsafe.withUnsafeBufferPointer { sp in
            sizes.withUnsafeBufferPointer { zp in
                codec == .hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                         parameterSetPointers: sp.baseAddress!, parameterSetSizes: zp.baseAddress!,
                                                                         nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &made)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                         parameterSetPointers: sp.baseAddress!, parameterSetSizes: zp.baseAddress!,
                                                                         nalUnitHeaderLength: 4, formatDescriptionOut: &made)
            }
        }
        return status == noErr ? made : nil
    }

    /// One picture as a sample for the display layer: shown as soon as it is decoded.
    static func sample(units: Data, stamp: UInt32, key: Bool, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let count = units.count
        var block: CMBlockBuffer?
        guard count > 0, CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count, blockAllocator: kCFAllocatorDefault,
                                                            customBlockSource: nil, offsetToData: 0, dataLength: count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                            blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = units.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) == kCMBlockBufferNoErr
        }
        guard copied else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(stamp), timescale: 90000), decodeTimeStamp: .invalid)
        var size = count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !key {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    private func configure(_ body: Data) {
        guard body.count > 1, let codec = ScreenWire.Codec(rawValue: body[body.startIndex]),
              let made = Self.format(codec: codec, record: Data(body.dropFirst())) else { count("badConfig"); return }
        count(codec == .hevc ? "configHEVC" : "configAVC")
        format = made
        awaitingKey = true
    }

    private func picture(_ body: Data) {
        guard let format, let frame = ScreenWire.videoFrame(body), !frame.units.isEmpty else { return }
        count("frames")
        if awaitingKey {
            // A picture that builds on one this window never had cannot be shown: wait for a whole one.
            guard frame.key else { count("waitedForKey"); askKey(); return }
            awaitingKey = false
        }
        guard let sample = Self.sample(units: frame.units, stamp: frame.stamp, key: frame.key, format: format) else { count("badSample"); return }
        #if DEBUG
        onSample?(sample)
        #endif
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            // The decoder gave up: start again from a whole picture.
            count("rendererFailed")
            renderer.flush()
            awaitingKey = true
            askKey()
            return
        }
        renderer.enqueue(sample)
        count("enqueued")
    }

    private var keyAsked = Date.distantPast
    private func askKey() {
        guard Date().timeIntervalSince(keyAsked) > 0.5 else { return }
        keyAsked = Date()
        connection?.send(content: ScreenWire.control(["t": "key"]), completion: .contentProcessed { _ in })
    }
}

/// The other Mac's sound: AAC-LC, 48 kHz, stereo, decoded and played as it comes, never more than
/// a fifth of a second behind.
final class ScreenSound: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
    private let pcm = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
    private let lock = NSLock()
    private var pending = 0
    private var running = false
    /// Buffers decoded and handed to the player (for the self-test).
    private(set) var played = 0

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running, let aac, let pcm, let made = AVAudioConverter(from: aac, to: pcm) else { return }
        // AAC-LC, 48 kHz, two channels: the decoder's configuration, as the encoder on the other Mac makes it.
        made.magicCookie = Data([0x11, 0x90])
        converter = made
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcm)
        do { try engine.start(); player.play(); running = true } catch { converter = nil }
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        // Stopping calls the handlers of the buffers not yet played, which take the lock.
        player.stop()
        engine.stop()
    }

    func play(_ bytes: Data) {
        lock.lock()
        guard running, let converter, let aac, let pcm, pending < 10, bytes.count > 0, bytes.count <= 8192 else { lock.unlock(); return }
        lock.unlock()
        let packet = AVAudioCompressedBuffer(format: aac, packetCapacity: 1, maximumPacketSize: bytes.count)
        bytes.withUnsafeBytes { raw in if let base = raw.baseAddress { packet.data.copyMemory(from: base, byteCount: bytes.count) } }
        packet.byteLength = UInt32(bytes.count)
        packet.packetCount = 1
        packet.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 2048) else { return }
        var given = false
        var failure: NSError?
        let status = converter.convert(to: out, error: &failure) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return packet
        }
        guard status != .error, out.frameLength > 0 else { return }
        lock.lock(); pending += 1; played += 1; lock.unlock()
        player.scheduleBuffer(out) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
        }
    }
}

/// The other Mac's pointer shape, as a cursor for the window at its scale.
struct RemoteCursor {
    struct Shape {
        let hotX: Int, hotY: Int, width: Int, height: Int, scale: Int
        let image: NSImage?
        init(_ shape: ScreenWire.CursorShape) {
            hotX = shape.hotX; hotY = shape.hotY; width = shape.width; height = shape.height; scale = shape.scale
            var pixels = [UInt8](shape.rgba)
            let rep = pixels.withUnsafeMutableBufferPointer { buffer -> NSBitmapImageRep? in
                var planes: UnsafeMutablePointer<UInt8>? = buffer.baseAddress
                return NSBitmapImageRep(bitmapDataPlanes: &planes, pixelsWide: shape.width, pixelsHigh: shape.height, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bitmapFormat: .alphaNonpremultiplied, bytesPerRow: shape.width * 4, bitsPerPixel: 32)?.copy() as? NSBitmapImageRep
            }
            if let rep {
                let image = NSImage(size: NSSize(width: shape.width, height: shape.height))
                image.addRepresentation(rep)
                self.image = image
            } else { image = nil }
        }
    }
    let shape: Shape

    /// The cursor for a window that shows a point of that display as `pointsPerPoint` of its own.
    func cursor(pointsPerPoint k: CGFloat) -> NSCursor? {
        guard let source = shape.image else { return nil }
        let size = NSSize(width: CGFloat(shape.width) / CGFloat(shape.scale) * k, height: CGFloat(shape.height) / CGFloat(shape.scale) * k)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let image = NSImage(size: size)
        image.addRepresentations(source.representations)
        return NSCursor(image: image, hotSpot: NSPoint(x: CGFloat(shape.hotX) / CGFloat(shape.scale) * k, y: CGFloat(shape.hotY) / CGFloat(shape.scale) * k))
    }
}

/// The window's content: the picture, what the window says over it, and the pointer, keys and
/// wheel, sent as the page sends them.
final class ScreenView: NSView {
    var send: ((Data) -> Void)?
    var onReconnect: (() -> Void)?
    var remoteLayout: ScreenWire.Layout? { didSet { needsLayout = true; window?.invalidateCursorRects(for: self) } }
    var canControl = true
    var cursorInPicture = false { didSet { window?.invalidateCursorRects(for: self) } }
    var remoteCursor: RemoteCursor? { didSet { applyCursor() } }
    var banner: String? { didSet { bannerLabel.stringValue = banner ?? ""; bannerLabel.isHidden = banner == nil } }
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let displayLayer { layer?.addSublayer(displayLayer); needsLayout = true }
        }
    }

    private let label = NSTextField(wrappingLabelWithString: "")
    private let bannerLabel = NSTextField(labelWithString: "")
    private let again = NSButton(title: tr("Connect Again"), target: nil, action: nil)
    private var buttons: UInt8 = 0
    private var keysDown: Set<UInt16> = []
    private var pending: (x: Int, y: Int)?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 14)
        label.maximumNumberOfLines = 6
        bannerLabel.textColor = .white
        bannerLabel.font = .systemFont(ofSize: 11)
        bannerLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        bannerLabel.drawsBackground = true
        bannerLabel.isHidden = true
        again.bezelStyle = .rounded
        again.target = self
        again.action = #selector(reconnect)
        again.isHidden = true
        for sub in [label, bannerLabel, again] { addSubview(sub) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func reconnect() { onReconnect?() }

    func reset() {
        remoteLayout = nil; remoteCursor = nil; cursorInPicture = false; canControl = true; banner = nil
        buttons = 0; keysDown = []
    }

    /// Words over the picture (nil: none), and whether Connect Again is offered under them.
    func say(_ words: String?, again offered: Bool) {
        label.stringValue = words ?? ""
        label.isHidden = words == nil
        again.isHidden = !offered
        needsLayout = true
    }

    /// Where the picture is drawn: as large as fits, in that display's proportions.
    private var picture: CGRect {
        guard let layout = remoteLayout else { return bounds }
        return ScreenWire.fit((layout.width, layout.height), in: bounds)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        displayLayer?.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        let width = min(bounds.width - 40, 520)
        let fitted = label.sizeThatFits(NSSize(width: width, height: 400))
        label.frame = NSRect(x: bounds.midX - width / 2, y: bounds.midY - fitted.height / 2 - 18, width: width, height: fitted.height)
        again.sizeToFit()
        again.frame.origin = NSPoint(x: bounds.midX - again.frame.width / 2, y: label.frame.maxY + 12)
        bannerLabel.sizeToFit()
        bannerLabel.frame = NSRect(x: 8, y: 8, width: min(bannerLabel.frame.width + 8, bounds.width - 16), height: bannerLabel.frame.height + 4)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: The pointer's shape

    private var cursor: NSCursor {
        guard !cursorInPicture, let remoteCursor, let layout = remoteLayout else { return .arrow }
        let k = picture.width / CGFloat(layout.width)
        return remoteCursor.cursor(pointsPerPoint: k) ?? .arrow
    }

    override func resetCursorRects() { addCursorRect(picture, cursor: cursor) }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    private func applyCursor() {
        window?.invalidateCursorRects(for: self)
        guard let window, window.isKeyWindow else { return }
        let inside = picture.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if inside { cursor.set() }
    }

    // MARK: The pointer

    /// Where the event is on that display; `edge`: outside the picture, at its nearest edge (a button
    /// let go out there, a drag that left it).
    private func place(_ event: NSEvent, edge: Bool = false) -> (x: Int, y: Int)? {
        guard let layout = remoteLayout else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        let shown = picture
        if edge {
            point.x = min(max(point.x, shown.minX), shown.maxX - 0.01)
            point.y = min(max(point.y, shown.minY), shown.maxY - 0.01)
        }
        return ScreenWire.remotePoint(point, picture: shown, display: (layout.width, layout.height), flipped: true)
    }

    private func pointer(_ event: NSEvent, bit: UInt8? = nil, down: Bool = false) {
        // A press starts only in the picture; a release, or a drag, is taken wherever it is.
        let held = buttons != 0 || (bit != nil && !down)
        guard canControl, let at = place(event, edge: held) else { return }
        if let bit {
            buttons = down ? buttons | bit : buttons & ~bit
            pending = nil
            send?(ScreenWire.pointerFrame(buttons: buttons, x: at.x, y: at.y))
            return
        }
        // One position a turn of the run loop: a mouse says where it is more often than that.
        let first = pending == nil
        pending = at
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let at = self.pending else { return }
            self.pending = nil
            self.send?(ScreenWire.pointerFrame(buttons: self.buttons, x: at.x, y: at.y))
        }
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, bit: 1, down: true) }
    override func mouseUp(with event: NSEvent) { pointer(event, bit: 1, down: false) }
    override func rightMouseDown(with event: NSEvent) { pointer(event, bit: 4, down: true) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, bit: 4, down: false) }
    override func otherMouseDown(with event: NSEvent) { pointer(event, bit: 2, down: true) }
    override func otherMouseUp(with event: NSEvent) { pointer(event, bit: 2, down: false) }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }

    override func scrollWheel(with event: NSEvent) {
        guard canControl, let at = place(event) else { return }
        let wheel = ScreenWire.wheel(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        guard wheel.dx != 0 || wheel.dy != 0 else { return }
        send?(ScreenWire.scrollFrame(dx: wheel.dx, dy: wheel.dy, x: at.x, y: at.y))
    }

    // MARK: The keys, by their place on the keyboard: that Mac's own input method makes the words

    private func key(_ code: UInt16, down: Bool) {
        guard canControl, code <= 0x7E else { return }
        if down { keysDown.insert(code) } else { keysDown.remove(code) }
        send?(ScreenWire.keyFrame(down: down, code: code))
    }

    override func keyDown(with event: NSEvent) { key(event.keyCode, down: true) }
    override func keyUp(with event: NSEvent) { key(event.keyCode, down: false) }

    /// Command shortcuts are that Mac's too (⌘Q quits an app there, not out here): they are taken
    /// before this Mac's menus see them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        key(event.keyCode, down: true)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        if code == 0x39 {
            // Caps Lock is a state there, changed on its way down.
            key(code, down: true); key(code, down: false)
            return
        }
        guard let bit = Shortcut.modifierBits[Int(code)], code != 63 else { return }
        key(code, down: UInt64(event.modifierFlags.rawValue) & bit != 0)
    }

    /// What is held here is let go there: the window went to the back, or the session ended.
    func releaseAll() {
        for code in keysDown { send?(ScreenWire.keyFrame(down: false, code: code)) }
        keysDown = []
        if buttons != 0 {
            buttons = 0
            if let layout = remoteLayout, let window {
                let at = ScreenWire.remotePoint(convert(window.mouseLocationOutsideOfEventStream, from: nil), picture: picture,
                                                display: (layout.width, layout.height), flipped: true) ?? (0, 0)
                send?(ScreenWire.pointerFrame(buttons: 0, x: at.x, y: at.y))
            }
        }
    }
}
