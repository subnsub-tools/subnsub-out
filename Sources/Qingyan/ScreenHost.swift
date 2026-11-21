import AppKit
import AVFoundation
import CoreMedia
import IOKit.pwr_mgt
import Network
import QingyanCore
import ScreenCaptureKit
import VideoToolbox

/// This Mac's screen on the owner's Monitor page (ScreenWire has the protocol): out keeps a
/// connection or two waiting at the Monitor helper, and when the page opens the screen, the one
/// that is handed it captures the main display and the Mac's sound, encodes them, and takes the
/// pointer, the keys and the clipboard back. One page at a time.
@MainActor
final class ScreenHost: ObservableObject {
    enum State: Equatable {
        case off
        /// Waiting at the helper for a page.
        case waiting
        case viewing
        /// The helper could not be asked, and why.
        case unavailable(String)
    }
    @Published private(set) var state = State.off {
        didSet { if state != oldValue { onChange?() } }
    }
    /// Called when the state changes; set by the controller, which shows it.
    var onChange: (() -> Void)?

    private var loops: [Task<Void, Never>] = []
    private var generation = 0
    private var parked: [ObjectIdentifier: NWConnection] = [:]
    private var session: ScreenSession?

    /// Whether macOS lets out record the screen. The answer is the one from when out started:
    /// macOS asks for out to be reopened after the permission is given.
    static var recordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

    func start() {
        guard loops.isEmpty else { return }
        let generation = generation
        state = .waiting
        for _ in 0..<2 { loops.append(Task { @MainActor [weak self] in await self?.loop(generation) }) }
    }

    func stop() {
        generation += 1
        for loop in loops { loop.cancel() }
        loops.removeAll()
        for connection in parked.values { connection.cancel() }
        parked.removeAll()
        session?.end("off")
        session = nil
        state = .off
    }

    /// Ends the page's view; out goes on waiting for the next.
    func stopViewing() { session?.end("stopped") }

    private func loop(_ generation: Int) async {
        var pause: UInt64 = 1
        while !Task.isCancelled && generation == self.generation {
            do {
                let connection = try await HelperLink.parkScreen()
                guard !Task.isCancelled, generation == self.generation else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                parked[id] = connection
                if session == nil, state != .waiting { state = .waiting }
                do { try await HelperLink.screenArrival(connection) }
                catch { parked.removeValue(forKey: id); connection.cancel(); throw error }
                parked.removeValue(forKey: id)
                guard !Task.isCancelled, generation == self.generation else { connection.cancel(); return }
                pause = 1
                serve(connection)
            } catch {
                if Task.isCancelled || generation != self.generation { return }
                if session == nil {
                    let absence = error as? HelperLink.Absence
                    state = .unavailable(absence == .notInstalled
                        ? tr("The Monitor helper on this Mac is not installed, or is too old to show the screen. Install or update it from the Monitor page.")
                        : tr("The Monitor helper on this Mac is not running."))
                }
                try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
                pause = min(pause * 2, 30)
            }
        }
    }

    private func serve(_ connection: NWConnection) {
        guard session == nil else {
            // One page at a time: the second is told so and let go.
            connection.send(content: ScreenWire.status(["s": "end", "why": "busy"]), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let next = ScreenSession(connection: connection)
        session = next
        state = .viewing
        next.onEnd = { [weak self, weak next] in
            Task { @MainActor in
                guard let self, self.session === next else { return }
                self.session = nil
                if self.state == .viewing { self.state = self.loops.isEmpty ? .off : .waiting }
            }
        }
        next.start()
    }
}

/// One page's view of this Mac's screen, from its first word to its end.
final class ScreenSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onEnd: (() -> Void)?

    private let connection: NWConnection
    /// Everything the session keeps is touched on this queue.
    private let queue = DispatchQueue(label: "local.hopo.qingyan.screen")
    private var parser = ScreenWire.Parser()
    private var opened = false, live = false, ended = false

    private var stream: SCStream?
    private var displayID: CGDirectDisplayID = 0
    private var displayBounds = CGRect.zero
    private var displayPixels = (width: 0, height: 0)
    private var window: ScreenWire.Size?
    private var codecs: [ScreenWire.Codec] = [.avc]
    private var kbps = ScreenWire.kbpsDefault
    private var wantAudio = true

    private var encoder: VTCompressionSession?
    private var encoderCodec = ScreenWire.Codec.avc
    private var encoderSize = (width: 0, height: 0)
    private var forceKey = true
    private var sentConfig = Data()
    /// Bytes handed to the connection that it has not yet written.
    private var outstanding = 0
    private var skipped = 0

    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var audioSamples: UInt32 = 0
    private var audioSequence: UInt16 = 0

    private let input = ScreenInput()
    private var ticker: DispatchSourceTimer?
    private var cursorIDs: [Int: UInt32] = [:]
    private var cursorShown: UInt32 = 0
    /// Looks at the pointer that found no shape, and whether the pointer is drawn into the
    /// picture instead, as it is where the system hands none out.
    private var cursorMisses = 0
    private var cursorInPicture = false
    /// Pictures given to the encoder and taken from it since it was made, and what it said.
    private var submitted = 0, emitted = 0, encodeErrors = 0
    private var lowLatency = true
    private var encoderGeneration = 0
    /// The newest picture not encoded because the page was behind.
    private var waiting: (pixels: CVPixelBuffer, time: CMTime)?
    #if DEBUG
    /// For the self-test: what the session counted.
    var counts: [String: Int] { queue.sync { ["skipped": skipped, "encodeErrors": encodeErrors, "lowLatency": lowLatency ? 1 : 0,
                                              "cursorInPicture": cursorInPicture ? 1 : 0, "submitted": submitted, "emitted": emitted] } }
    #endif
    private var clipboardCount = 0
    private var tick = 0
    private var awake: IOPMAssertionID = 0

    init(connection: NWConnection) {
        self.connection = connection
        super.init()
    }

    func start() {
        queue.async {
            let encoders = [ScreenWire.Codec.hevc, .avc].map(\.name)
            self.send(ScreenWire.status(["s": "hello", "v": 2, "name": Host.current().localizedName ?? "", "codecs": encoders]))
            self.receive()
        }
    }

    /// Ends the session, telling the page why.
    func end(_ why: String) {
        queue.async {
            guard !self.ended else { return }
            self.send(ScreenWire.status(["s": "end", "why": why]))
            self.finish()
        }
    }

    // MARK: The connection

    private func send(_ frame: Data) {
        guard !ended else { return }
        let count = frame.count
        outstanding += count
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                guard let self else { return }
                self.outstanding -= count
                if error != nil { self.finish(); return }
                if let held = self.waiting, self.live, !self.ended, self.outstanding <= self.room / 2 {
                    self.waiting = nil
                    self.encode(held.pixels, held.time)
                }
            }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, complete, error in
            self?.queue.async {
                guard let self, !self.ended else { return }
                if let data, !data.isEmpty { self.take(data) }
                if complete || error != nil { self.finish(); return }
                if !self.ended { self.receive() }
            }
        }
    }

    private func take(_ data: Data) {
        guard let frames = parser.feed(data) else { finish(); return }
        for frame in frames {
            switch ScreenWire.FromPage(rawValue: frame.kind) {
            case .control:
                guard let command = ScreenWire.command(frame.body) else { continue }
                apply(command)
            case .pointer:
                if live, let pointer = ScreenWire.pointer(frame.body) { input.pointer(pointer) }
            case .key:
                if live, let key = ScreenWire.key(frame.body) { input.key(key) }
            case .scroll:
                if live, let scroll = ScreenWire.scroll(frame.body) { input.scroll(scroll) }
            case .none:
                break
            }
        }
    }

    private func apply(_ command: ScreenWire.Command) {
        switch command {
        case .open(let codecs, let audio, let size, let kbps):
            guard !opened else { finish(); return }
            opened = true
            self.codecs = codecs; wantAudio = audio; window = size; self.kbps = kbps
            Task { await self.begin() }
        case .size(let size):
            guard live, window != size else { return }
            window = size
            resize()
        case .kbps(let value):
            kbps = value
            if let encoder { setRate(encoder) }
        case .keyframe:
            forceKey = true
        case .clipboard(let text):
            // The clipboard is the Mac's to write only for a page that may work it.
            guard live, input.enabled else { return }
            Task { @MainActor in
                // Written only if the session that asked is still there; and through the lease,
                // so that a dictation on its way to a paste keeps the clipboard until it lands.
                guard self.queue.sync(execute: { self.live && !self.ended }) else { return }
                PasteboardLease.general.keep(text)
                let count = NSPasteboard.general.changeCount
                self.queue.async { self.clipboardCount = count }
            }
        case .text(let text):
            if live { input.type(text) }
        case .audio(let on):
            wantAudio = on
        }
    }

    // MARK: Capture

    private func begin() async {
        guard CGPreflightScreenCaptureAccess() else { end("perm-screen"); return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let main = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first else {
                end("no-display"); return
            }
            let id = display.displayID
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pixels = (width: mode?.pixelWidth ?? Int(bounds.width), height: mode?.pixelHeight ?? Int(bounds.height))
            let ready: (SCStreamConfiguration, Bool)? = queue.sync {
                // The page may have gone while the displays were being listed.
                guard !self.ended else { return nil }
                self.displayID = id; self.displayBounds = bounds; self.displayPixels = pixels
                self.input.display = bounds
                return (self.configuration(), self.wantAudio)
            }
            guard let (configuration, audio) = ready else { return }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if audio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            try await stream.startCapture()
            let trusted = AXIsProcessTrusted()
            queue.async {
                guard !self.ended else { Task { try? await stream.stopCapture() }; return }
                self.stream = stream
                self.live = true
                self.input.enabled = trusted
                self.wake()
                let size = ScreenWire.pictureSize(displayPixels: self.displayPixels, window: self.window)
                self.send(ScreenWire.status(["s": "live", "w": Int(bounds.width), "h": Int(bounds.height), "cw": size.width, "ch": size.height,
                                             "audio": audio, "input": trusted]))
                self.startTicker()
            }
        } catch {
            end("failed")
        }
    }

    private func configuration() -> SCStreamConfiguration {
        let size = ScreenWire.pictureSize(displayPixels: displayPixels, window: window)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // The pointer's shape is sent on its own and drawn by the page where its pointer is.
        configuration.showsCursor = cursorInPicture
        configuration.queueDepth = 4
        configuration.capturesAudio = wantAudio
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        return configuration
    }

    /// One change of the stream's configuration is on its way at a time; what was asked for
    /// meanwhile is applied after it, as the latest.
    private var updating = false, updateWanted = false

    private func resize() {
        guard let stream, !ended else { return }
        if updating { updateWanted = true; return }
        updating = true
        let configuration = configuration()
        Task {
            try? await stream.updateConfiguration(configuration)
            self.queue.async {
                self.updating = false
                if self.updateWanted { self.updateWanted = false; self.resize() }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        end("capture-stopped")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard live, !ended, sampleBuffer.isValid else { return }
        switch type {
        case .screen: picture(sampleBuffer)
        case .audio: if wantAudio { sound(sampleBuffer) }
        default: break
        }
    }

    // MARK: Video

    private func picture(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        // A page behind the stream is not fed more: the picture is not encoded at all, so the
        // ones that follow still build on what the page has. The newest one skipped is kept:
        // if the screen then stands still, it is what the page is owed once it has caught up.
        if outstanding > room { skipped += 1; waiting = (pixels, time); return }
        waiting = nil
        encode(pixels, time)
    }

    /// About a third of a second's worth of the stream.
    private var room: Int { max(256 << 10, kbps * 1000 / 8 / 3) }

    private func encode(_ pixels: CVPixelBuffer, _ time: CMTime) {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        if encoder == nil || encoderSize.width != width || encoderSize.height != height {
            guard makeEncoder(width: width, height: height) else { end("no-encoder"); return }
        }
        guard let encoder else { return }
        // The low-latency encoder that takes pictures and hands none back (seen where the
        // hardware has no such encoder) gives way to the plain one.
        if lowLatency, encoderCodec == .avc, emitted == 0, submitted >= 45 {
            lowLatency = false
            guard makeEncoder(width: width, height: height) else { end("no-encoder"); return }
            return
        }
        submitted += 1
        var properties: CFDictionary?
        if forceKey {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKey = false
        }
        // What an encoder that has since been replaced still hands back is not this stream's.
        let generation = encoderGeneration
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, encoded in
            self?.queue.async {
                guard let self, generation == self.encoderGeneration else { return }
                guard status == noErr, let encoded else { self.encodeErrors += 1; return }
                self.emit(encoded)
            }
        }
    }

    private func makeEncoder(width: Int, height: Int) -> Bool {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        for codec in codecs {
            let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
            // The low-latency rate control is H.264's; where a Mac has none of it, the plain encoder.
            let wanted: [CFDictionary?] = codec == .avc && lowLatency
                ? [[kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary, nil] : [nil]
            for specification in wanted {
                var made: VTCompressionSession?
                let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
                                                        encoderSpecification: specification, imageBufferAttributes: nil,
                                                        compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                        compressionSessionOut: &made)
                guard status == noErr, let made else { continue }
                VTSessionSetProperty(made, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
                VTSessionSetProperty(made, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
                VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ProfileLevel,
                                     value: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
                // Key frames are sent when one is needed (the first, a new size, the page asking),
                // and otherwise rarely.
                VTSessionSetProperty(made, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 7200 as CFNumber)
                VTSessionSetProperty(made, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
                setRate(made)
                VTCompressionSessionPrepareToEncodeFrames(made)
                encoder = made
                encoderCodec = codec
                encoderSize = (width, height)
                encoderGeneration += 1
                submitted = 0; emitted = 0
                forceKey = true
                sentConfig = Data()
                var layout = Data()
                for value in [Int(displayBounds.width), Int(displayBounds.height), width, height] {
                    layout.append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
                }
                send(ScreenWire.frame(.layout, layout))
                return true
            }
        }
        return false
    }

    private func setRate(_ encoder: VTCompressionSession) {
        let bits = kbps * 1000
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: bits as CFNumber)
        // Over any second, no more than half as much again.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_DataRateLimits, value: [bits / 8 * 3 / 2, 1] as CFArray)
    }

    private func emit(_ sample: CMSampleBuffer) {
        guard !ended, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length + 5 <= ScreenWire.frameLimit else { forceKey = true; return }
        let notSync = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let key = !notSync
        if key, let description = CMSampleBufferGetFormatDescription(sample), let record = Self.decoderRecord(description, codec: encoderCodec),
           record != sentConfig {
            sentConfig = record
            send(ScreenWire.frame(.videoConfig, Data([encoderCodec.rawValue]) + record))
        }
        guard !sentConfig.isEmpty else { forceKey = true; return }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let stamp = UInt32(truncatingIfNeeded: Int64((seconds.isFinite ? seconds : 0) * 90000))
        var body = Data(count: 5 + length)
        body[0] = key ? 1 : 0
        body[1] = UInt8(stamp >> 24 & 0xFF); body[2] = UInt8(stamp >> 16 & 0xFF); body[3] = UInt8(stamp >> 8 & 0xFF); body[4] = UInt8(stamp & 0xFF)
        let copied = body.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base + 5) == kCMBlockBufferNoErr
        }
        guard copied else { forceKey = true; return }
        emitted += 1
        send(ScreenWire.frame(.videoFrame, body))
    }

    /// The record a decoder is configured with (avcC, hvcC), as the encoder wrote it into the
    /// format description; for H.264, built from the parameter sets where it is not there.
    private static func decoderRecord(_ description: CMFormatDescription, codec: ScreenWire.Codec) -> Data? {
        let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        if let record = atoms?[codec == .hevc ? "hvcC" : "avcC"] as? Data, !record.isEmpty { return record }
        guard codec == .avc else { return nil }
        var sets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                  let pointer, size > 3 || (index == 1 && size > 0) else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        let sps = sets[0], pps = sets[1]
        var record = Data([1, sps[1], sps[2], sps[3], 0xFF, 0xE1, UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)])
        record.append(sps)
        record.append(contentsOf: [1, UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)])
        record.append(pps)
        return record
    }

    // MARK: Sound

    private func sound(_ sample: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: basic) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
        if converter == nil || converterInput != format {
            guard let output = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                        AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]),
                  let made = AVAudioConverter(from: format, to: output) else { wantAudio = false; return }
            converter = made
            converterInput = format
        }
        guard let converter else { return }
        let packets = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 16,
                                              maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
        var fed = false
        var failure: NSError?
        let status = converter.convert(to: packets, error: &failure) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true
            state.pointee = .haveData
            return pcm
        }
        guard status != .error, packets.packetCount > 0, let descriptions = packets.packetDescriptions else { return }
        // Sound waits for no one either: with the page behind, the packets are let go.
        let behind = outstanding > max(512 << 10, kbps * 1000 / 8)
        for index in 0..<Int(packets.packetCount) {
            let one = descriptions[index]
            let size = Int(one.mDataByteSize)
            defer { audioSamples &+= 1024; audioSequence &+= 1 }
            guard size > 0, size <= 8192, !behind else { continue }
            var body = Data([ScreenWire.audioAACLC,
                             UInt8(audioSamples >> 24 & 0xFF), UInt8(audioSamples >> 16 & 0xFF), UInt8(audioSamples >> 8 & 0xFF), UInt8(audioSamples & 0xFF),
                             UInt8(audioSequence >> 8), UInt8(audioSequence & 0xFF)])
            body.append(Data(bytes: packets.data + Int(one.mStartOffset), count: size))
            send(ScreenWire.frame(.audio, body))
        }
    }

    // MARK: The pointer's shape and the clipboard

    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.look() }
        timer.resume()
        ticker = timer
    }

    /// On the main queue, ten times a second: the pointer's shape; every second, the clipboard.
    private func look() {
        let shape = Self.cursor()
        var text: String?
        var count = 0
        tick += 1
        if tick % 10 == 0 {
            let board = NSPasteboard.general
            count = board.changeCount
            if let string = board.string(forType: .string), string.utf8.count <= ScreenWire.clipboardLimit { text = string }
        }
        queue.async {
            guard self.live, !self.ended else { return }
            if shape == nil, !self.cursorInPicture, self.cursorIDs.isEmpty {
                self.cursorMisses += 1
                if self.cursorMisses == 15 {
                    self.cursorInPicture = true
                    self.send(ScreenWire.status(["s": "cursor", "picture": true]))
                    self.resize()
                }
            }
            if let shape, !self.cursorInPicture {
                if let id = self.cursorIDs[shape.key] {
                    if id != self.cursorShown { self.cursorShown = id; self.send(ScreenWire.frame(.cursorSelect, Self.bytes(id))) }
                } else {
                    let id = UInt32(self.cursorIDs.count + 1)
                    self.cursorIDs[shape.key] = id
                    self.cursorShown = id
                    var body = Self.bytes(id)
                    for value in [shape.hotX, shape.hotY, shape.width, shape.height] {
                        body.append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
                    }
                    body.append(UInt8(shape.scale))
                    body.append(shape.rgba)
                    self.send(ScreenWire.frame(.cursorStore, body))
                    self.send(ScreenWire.frame(.cursorSelect, Self.bytes(id)))
                }
            }
            if count != 0, count != self.clipboardCount {
                // The first look only notes where the clipboard stands: what was on it before
                // the page came is not the page's.
                let first = self.clipboardCount == 0
                self.clipboardCount = count
                if !first, let text { self.send(ScreenWire.frame(.clipboard, Data(text.utf8))) }
            }
        }
    }

    private static func bytes(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private struct Shape { let key: Int; let hotX: Int, hotY: Int, width: Int, height: Int, scale: Int; let rgba: Data }

    /// The pointer as the system draws it now, as RGBA at its finest (two pixels to a point where
    /// it has them): drawn into a bitmap, which every kind of picture a cursor is kept as allows.
    private static func cursor() -> Shape? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let image = cursor.image
        let points = image.size
        guard points.width >= 1, points.height >= 1, points.width <= 128, points.height <= 128 else { return nil }
        let finest = image.representations.map { Double($0.pixelsWide) / Double(points.width) }.max() ?? 1
        let scale = finest >= 1.5 ? 2 : 1
        let width = Int((points.width * CGFloat(scale)).rounded(.up)), height = Int((points.height * CGFloat(scale)).rounded(.up))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        // A picture with nothing in it is no pointer to show.
        guard drawn, pixels.contains(where: { $0 != 0 }) else { return nil }
        ScreenWire.unpremultiply(&pixels)
        var hasher = Hasher()
        hasher.combine(width); hasher.combine(height); hasher.combine(pixels)
        return Shape(key: hasher.finalize(), hotX: Int(cursor.hotSpot.x * CGFloat(scale)), hotY: Int(cursor.hotSpot.y * CGFloat(scale)),
                     width: width, height: height, scale: scale, rgba: Data(pixels))
    }

    #if DEBUG
    /// For the self-test: what the system says of its pointer, step by step.
    static func cursorReport() -> [String: Any] {
        guard let cursor = NSCursor.currentSystem else { return ["system": false] }
        let image = cursor.image
        let shape = Self.cursor()
        return ["system": true, "points": [Double(image.size.width), Double(image.size.height)],
                "representations": image.representations.map { "\(type(of: $0)) \($0.pixelsWide)x\($0.pixelsHigh)" },
                "shape": shape.map { [$0.width, $0.height, $0.scale, $0.hotX, $0.hotY] } ?? []]
    }
    #endif

    // MARK: The display awake, and the end

    private func wake() {
        var once: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("out: the screen is shown on the Monitor page" as CFString, kIOPMUserActiveLocal, &once)
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "out: the screen is shown on the Monitor page" as CFString, &awake)
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        live = false
        ticker?.cancel(); ticker = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        encoderGeneration += 1
        waiting = nil
        input.releaseAll()
        if awake != 0 { IOPMAssertionRelease(awake); awake = 0 }
        // What was just said (why it ended) is let out before the connection goes.
        let connection = connection
        queue.asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
        onEnd?()
    }
}

/// The page's pointer, keys and wheel, made into this Mac's events.
final class ScreenInput {
    /// The display the picture is of, in the global coordinates events are placed in.
    var display = CGRect.zero
    /// Whether out may post events at all (Accessibility).
    var enabled = false

    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttons: UInt8 = 0
    private var held: Set<UInt16> = []
    private var place = CGPoint.zero
    private var clicks = ScreenWire.Clicks()
    private var capsLock = false

    private var flags: CGEventFlags {
        var flags = CGEventFlags()
        for code in held { if let flag = ScreenWire.modifier(code) { flags.insert(flag) } }
        if capsLock { flags.insert(.maskAlphaShift) }
        return flags
    }

    private func post(_ event: CGEvent?) {
        guard enabled, let event else { return }
        // What the event carries of its own (the keypad's and function keys' marks) is kept;
        // the modifiers are the page's, not those of whoever is at this Mac's keyboard.
        let own = event.flags.subtracting([.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskAlphaShift])
        event.flags = own.union(flags)
        event.post(tap: .cghidEventTap)
    }

    func pointer(_ pointer: ScreenWire.Pointer) {
        let x = min(max(CGFloat(pointer.x), 0), max(display.width - 1, 0)), y = min(max(CGFloat(pointer.y), 0), max(display.height - 1, 0))
        place = CGPoint(x: display.minX + x, y: display.minY + y)
        let kinds: [(bit: UInt8, button: CGMouseButton, down: CGEventType, up: CGEventType, drag: CGEventType)] = [
            (1, .left, .leftMouseDown, .leftMouseUp, .leftMouseDragged),
            (4, .right, .rightMouseDown, .rightMouseUp, .rightMouseDragged),
            (2, .center, .otherMouseDown, .otherMouseUp, .otherMouseDragged),
        ]
        var changed = false
        for kind in kinds where (pointer.buttons ^ buttons) & kind.bit != 0 {
            changed = true
            let down = pointer.buttons & kind.bit != 0
            let count = down ? clicks.press(button: kind.bit, at: ProcessInfo.processInfo.systemUptime, x: pointer.x, y: pointer.y,
                                            within: NSEvent.doubleClickInterval) : clicks.current
            let event = CGEvent(mouseEventSource: source, mouseType: down ? kind.down : kind.up, mouseCursorPosition: place, mouseButton: kind.button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            post(event)
        }
        buttons = pointer.buttons
        guard !changed else { return }
        if let kind = kinds.first(where: { buttons & $0.bit != 0 }) {
            let event = CGEvent(mouseEventSource: source, mouseType: kind.drag, mouseCursorPosition: place, mouseButton: kind.button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks.current))
            post(event)
        } else {
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: place, mouseButton: .left))
        }
    }

    func key(_ key: ScreenWire.Key) {
        if key.code == 0x39 {
            // Caps Lock is a state, changed on the way down.
            if key.down { capsLock.toggle() }
        } else if key.down { held.insert(key.code) } else { held.remove(key.code) }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.code), keyDown: key.down) else { return }
        if ScreenWire.modifier(key.code) != nil || key.code == 0x39 { event.type = .flagsChanged }
        post(event)
    }

    func scroll(_ scroll: ScreenWire.Scroll) {
        // A browser's wheel says how far the content moves; an event here says how far the wheel turned.
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(clamping: -scroll.dy), wheel2: Int32(clamping: -scroll.dx), wheel3: 0)
        // Where the frame itself says the pointer is: its own move may still be on the way.
        let x = min(max(CGFloat(scroll.x), 0), max(display.width - 1, 0)), y = min(max(CGFloat(scroll.y), 0), max(display.height - 1, 0))
        event?.location = CGPoint(x: display.minX + x, y: display.minY + y)
        post(event)
    }

    /// Text typed as it is, whatever keys it would take: a few characters to an event.
    func type(_ text: String) {
        let units = Array(text.utf16)
        var at = 0
        while at < units.count {
            var end = min(at + 16, units.count)
            // Not through the middle of a character that takes two units.
            if end < units.count, UTF16.isTrailSurrogate(units[end]) { end -= 1 }
            let piece = Array(units[at..<end])
            for down in [true, false] {
                guard enabled, let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
                event.post(tap: .cghidEventTap)
            }
            at = end
        }
    }

    /// What the page held when it went is let go.
    func releaseAll() {
        for code in held { self.key(ScreenWire.Key(down: false, code: code)) }
        if buttons != 0 { pointer(ScreenWire.Pointer(buttons: 0, x: Int(place.x - display.minX), y: Int(place.y - display.minY))) }
    }
}
