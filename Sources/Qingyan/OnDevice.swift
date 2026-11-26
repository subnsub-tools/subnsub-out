import AVFoundation
import Combine
import Foundation
import QingyanCore
import Speech

/// Recognition by the system's own speech model (macOS 26 and later): the audio never leaves
/// this Mac, and partial words show while speaking. What the platform calls a "model" is the
/// spoken language, one per recording, chosen in Settings.
@available(macOS 26, *)
@MainActor
final class OnDeviceTranscriber: Transcriber {
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var inputStream: AsyncStream<AnalyzerInput>.Continuation?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var watchdog: Task<Void, Never>?
    private var feeder: Task<Void, Error>?
    private var resultsTask: Task<String, Error>?
    private var workTask: Task<Void, Error>?
    private var finishing = false
    private var timedOut = false
    private var feedError: Error?

    init(locale: String) { self.locale = Locale(identifier: locale) }

    func run(audio: AsyncThrowingStream<Data, Error>, model: String, dictionary: [String],
             onReady: @escaping () -> Void, onPartial: @escaping (String) -> Void) async throws -> String {
        defer { cancel() }
        guard let wanted = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceError(tr("This Mac cannot recognize this language on the device. Choose another in Settings."))
        }
        let transcriber = SpeechTranscriber(locale: wanted, transcriptionOptions: [],
                                          reportingOptions: [.volatileResults], attributeOptions: [])
        await reserveLocaleSlot(for: wanted)
        // The model downloads while the recording keeps going; the input stream buffers the audio.
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw VoiceError(tr("The speech model could not be downloaded. Check the network; the recording is kept and can be retried from History."), retryable: true)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                    ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: format) else {
            throw VoiceError(tr("The audio could not be converted. Choose the input device again."))
        }
        converter.primeMethod = .none
        inputFormat = input; outputFormat = format; self.converter = converter
        let words = OpenAIWire.cleanDictionary(dictionary)
        if !words.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: words]
            try? await analyzer.setContext(context)
        }
        let (stream, sink) = AsyncStream<AnalyzerInput>.makeStream()
        inputStream = sink
        resultsTask = Task { [weak self] in
            var text = "", shown = ""
            for try await result in transcriber.results {
                guard let self else { return text }
                // A result is still arriving after the recording ended: the model is working.
                if self.finishing { self.deadline() }
                let piece = String(result.text.characters)
                if result.isFinal, !piece.isEmpty { text = OpenAIWire.joinPieces(text, piece) }
                let now = result.isFinal ? text : OpenAIWire.joinPieces(text, piece)
                if now != shown { shown = now; onPartial(now) }
            }
            return text
        }
        // Started before anything can finish it: a recording replayed from History may end at once.
        let starting = Task { try await analyzer.start(inputSequence: stream) }
        workTask = starting
        if finishing { deadline() }
        feeder = Task { [weak self] in
            do {
                var odd: UInt8?
                var bytes = 0
                for try await chunk in audio {
                    try Task.checkCancellation()
                    bytes += chunk.count
                    var data = Data()
                    if let odd { data.append(odd) }
                    data.append(chunk)
                    odd = nil
                    if data.count % 2 == 1 { odd = data.removeLast() }
                    for buffer in try self?.converted(data) ?? [] {
                        sink.yield(AnalyzerInput(buffer: buffer))
                    }
                }
                try Task.checkCancellation()
                guard bytes >= 4800 else {
                    throw VoiceError(tr("The recording is too short. Finish speaking before you stop."))
                }
                for buffer in try self?.drained() ?? [] {
                    sink.yield(AnalyzerInput(buffer: buffer))
                }
                sink.finish()
                self?.finishDeadline()
                try await starting.value
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                sink.finish()
                self?.feedError = error
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }
        onReady()
        do {
            try await feeder?.value
            let text = try await resultsTask?.value ?? ""
            try await workTask?.value
            if timedOut {
                throw VoiceError(tr("%@ did not respond in time. The recording is kept on this Mac.", Platform.thisMac.name), retryable: false)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if timedOut {
                throw VoiceError(tr("%@ did not respond in time. The recording is kept on this Mac.", Platform.thisMac.name), retryable: false)
            }
            if let feedError, feedError is VoiceError || feedError is CancellationError { throw feedError }
            if error is VoiceError { throw error }
            throw VoiceError(tr("Recognition on this Mac stopped unexpectedly. The recording is kept and can be retried from History."))
        }
    }

    /// One 24 kHz Int16 mono chunk as a buffer in the format the analyzer asked for.
    private func converted(_ data: Data) throws -> [AVAudioPCMBuffer] {
        guard let inputFormat, let outputFormat, let converter, !data.isEmpty else { return [] }
        let frames = data.count / 2
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let samples = input.int16ChannelData?[0] else { return [] }
        input.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            if let address = raw.baseAddress { memcpy(samples, address, frames * 2) }
        }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * outputFormat.sampleRate / inputFormat.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error || error != nil {
            throw VoiceError(tr("The audio could not be converted. Choose the input device again."))
        }
        return output.frameLength > 0 ? [output] : []
    }

    /// Whatever the converter still holds after the last chunk, drained with an
    /// end-of-stream input block.
    private func drained() throws -> [AVAudioPCMBuffer] {
        guard let outputFormat, let converter else { return [] }
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return [] }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            state.pointee = .endOfStream
            return nil
        }
        if status == .error || error != nil {
            throw VoiceError(tr("The audio could not be converted. Choose the input device again."))
        }
        return output.frameLength > 0 ? [output] : []
    }

    /// The recording has ended; an answer is now due within 40 seconds, moved back by every
    /// result that still arrives. If the analyzer is not up yet (the model is still
    /// downloading), the watchdog is armed when setup completes instead.
    func finishDeadline() {
        finishing = true
        if analyzer != nil { deadline() }
    }

    private func deadline() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 40 * 1_000_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.timedOut = true
            self.inputStream?.finish()
            await self.analyzer?.cancelAndFinishNow()
        }
    }

    func cancel() {
        watchdog?.cancel(); watchdog = nil
        feeder?.cancel(); feeder = nil
        resultsTask?.cancel(); resultsTask = nil
        workTask?.cancel(); workTask = nil
        inputStream?.finish(); inputStream = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        Task { await analyzer?.cancelAndFinishNow() }
    }
}

/// Free a reserved locale slot when they are all taken and this locale has none.
@available(macOS 26, *)
private func reserveLocaleSlot(for wanted: Locale) async {
    let tag = wanted.identifier(.bcp47)
    let reserved = await AssetInventory.reservedLocales
    guard !reserved.contains(where: { $0.identifier(.bcp47) == tag }),
          reserved.count >= AssetInventory.maximumReservedLocales,
          let evict = reserved.first(where: { $0.identifier(.bcp47) != tag }) else { return }
    await AssetInventory.release(reservedLocale: evict)
}

/// The system speech model's download state for the chosen language, for Settings to show.
@MainActor
final class OnDeviceModels: ObservableObject {
    static let shared = OnDeviceModels()
    private init() {}

    enum State: Equatable {
        case checking, unsupported, notInstalled, downloading(Double), installed, failed
    }

    @Published private(set) var state: State = .checking
    /// The language the state belongs to; results for any other are ignored.
    private var current: String?

    /// Whether "This Mac" can be offered: macOS 26 with a usable system speech model.
    static var available: Bool {
        guard #available(macOS 26, *) else { return false }
        return SpeechTranscriber.isAvailable
    }

    /// Re-read the model's state for a spoken language; .unsupported on older systems.
    func refresh(_ locale: String) async {
        current = locale
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else {
            state = .unsupported; return
        }
        state = .checking
        await refresh26(locale)
    }

    @available(macOS 26, *)
    private func refresh26(_ locale: String) async {
        guard let wanted = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            if current == locale { state = .unsupported }
            return
        }
        let transcriber = SpeechTranscriber(locale: wanted, transcriptionOptions: [],
                                          reportingOptions: [.volatileResults], attributeOptions: [])
        var status = await AssetInventory.status(forModules: [transcriber])
        // While the model is still coming down, keep checking until it is done.
        while status == .downloading, current == locale {
            if case .downloading = state {} else { state = .downloading(0) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            status = await AssetInventory.status(forModules: [transcriber])
        }
        guard current == locale else { return }
        switch status {
        case .installed: state = .installed
        case .downloading: state = .downloading(0)
        case .unsupported: state = .unsupported
        default: state = .notInstalled
        }
    }

    /// The model's download, its progress shown until macOS finishes it. A second tap
    /// while this language is already downloading does nothing.
    func download(_ locale: String) {
        guard #available(macOS 26, *) else { state = .unsupported; return }
        if case .downloading = state, current == locale { return }
        current = locale
        Task { [weak self] in
            do { try await self?.download26(locale) }
            catch { guard let self, self.current == locale else { return }; self.state = .failed }
        }
    }

    @available(macOS 26, *)
    private func download26(_ locale: String) async throws {
        guard let wanted = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            if current == locale { state = .unsupported }
            return
        }
        let transcriber = SpeechTranscriber(locale: wanted, transcriptionOptions: [],
                                          reportingOptions: [.volatileResults], attributeOptions: [])
        await reserveLocaleSlot(for: wanted)
        guard current == locale else { return }
        state = .downloading(0)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            await refresh26(locale)
            return
        }
        let progress = request.progress
        let poller = Task { [weak self] in
            while !Task.isCancelled, !progress.isFinished {
                guard let self, self.current == locale else { return }
                self.state = .downloading(progress.fractionCompleted)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { poller.cancel() }
        try await request.downloadAndInstall()
        guard current == locale else { return }
        await refresh26(locale)
    }
}
