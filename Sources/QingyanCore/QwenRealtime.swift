import Foundation

/// A unique id for one client event: "event_" plus a UUID without its dashes.
private func qwenEventID() -> String { "event_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }

/// Resamples put's 24 kHz recording to the 16 kHz the realtime socket accepts: polyphase, twice
/// up then a third down, 16-bit little-endian mono, fed in pieces of any size. `process` returns
/// the samples made final by what it has seen so far; the same input split differently gives the
/// same bytes.
public struct PCMResampler: Sendable {
    // The FIR prototype runs at the 48 kHz intermediate rate: 95 taps of a windowed sinc with a
    // 7 kHz cutoff and a Blackman window, multiplied by the upsampling factor. The upsampled
    // stream has zeros at odd indices, so output n — filtered sample 3n — uses only the taps
    // whose index has n's parity: two phases over input index i0 = (3n − parity) / 2.
    private static let taps: [[Double]] = {
        let cutoff = 2.0 * 7000.0 / 48000.0
        var h = [Double](repeating: 0, count: 95)
        for k in 0..<95 {
            let t = Double(k - 47)
            let sinc = t == 0 ? 1 : sin(.pi * cutoff * t) / (.pi * cutoff * t)
            let window = 0.42 - 0.5 * cos(2 * .pi * Double(k) / 94) + 0.08 * cos(4 * .pi * Double(k) / 94)
            h[k] = 2 * cutoff * sinc * window
        }
        return [[Double](stride(from: 0, through: 94, by: 2).map { h[$0] }),
                [Double](stride(from: 1, through: 94, by: 2).map { h[$0] })]
    }()

    /// Stream samples from `origin` on; only the taps' span of it is kept.
    private var history: [Int16] = []
    private var origin = 0
    /// Output samples produced so far.
    private var emitted = 0
    /// An input byte whose pair has not arrived yet.
    private var oddByte: UInt8?

    public init() {}

    public mutating func process(_ chunk: Data) -> Data {
        var raw = Data()
        if let oddByte { raw.append(oddByte); self.oddByte = nil }
        raw.append(chunk)
        if raw.count % 2 == 1 { oddByte = raw.removeLast() }
        let count = raw.count / 2
        raw.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for i in 0..<count {
                history.append(Int16(bitPattern: UInt16(base.load(fromByteOffset: 2 * i, as: UInt8.self))
                    | UInt16(base.load(fromByteOffset: 2 * i + 1, as: UInt8.self)) << 8))
            }
        }
        var out = Data()
        while true {
            let parity = emitted & 1
            let first = (3 * emitted - parity) / 2
            if first >= origin + history.count { break }
            let phase = Self.taps[parity]
            var sum = 0.0
            for (j, tap) in phase.enumerated() {
                let index = first - j - origin
                if index < 0 { break }
                sum += tap * Double(history[index])
            }
            let value = min(32767, max(-32768, Int(sum.rounded())))
            out.append(UInt8(truncatingIfNeeded: value))
            out.append(UInt8(truncatingIfNeeded: value >> 8))
            emitted += 1
        }
        let oldest = (3 * emitted - (emitted & 1)) / 2 - (Self.taps[0].count - 1)
        let drop = min(max(oldest - origin, 0), history.count)
        if drop > 0 { history.removeFirst(drop); origin += drop }
        return out
    }
}

/// Qwen-ASR-Realtime events into transcript text. Server-side silence detection splits speech
/// into items; each item shows its confirmed words plus the draft being spoken, and its final
/// transcript once completed. Items keep the order their ids were first seen in, however the
/// events arrive.
public struct QwenTranscript {
    private var order: [String] = []
    private var partial: [String: String] = [:]
    private var final: [String: String] = [:]
    /// The session said it is done: every item's final transcript has arrived.
    public private(set) var finished = false
    public init() {}

    public mutating func receive(_ event: [String: Any]) throws {
        let type = event["type"] as? String ?? ""
        if type == "error" || type == "conversation.item.input_audio_transcription.failed" {
            throw Self.error(code: (event["error"] as? [String: Any])?["code"] as? String ?? "")
        }
        if type == "session.finished" { finished = true; return }
        // Every event that names an item teaches the order it was spoken in; `conversation.item.created`
        // carries the name inside the item, the rest as `item_id`.
        let id = event["item_id"] as? String ?? (event["item"] as? [String: Any])?["id"] as? String
        guard let id else { return }
        if !order.contains(id) { order.append(id) }
        switch type {
        case "conversation.item.input_audio_transcription.text":
            if final[id] == nil { partial[id] = (event["text"] as? String ?? "") + (event["stash"] as? String ?? "") }
        case "conversation.item.input_audio_transcription.completed":
            final[id] = event["transcript"] as? String ?? ""
        default: break
        }
    }

    /// Every item seen, latest state, joined the way the pieces were spoken (see `joinPieces`).
    public var text: String {
        var text = ""
        for id in order {
            guard let piece = final[id] ?? partial[id], !piece.isEmpty else { continue }
            text = OpenAIWire.joinPieces(text, piece)
        }
        return text
    }

    /// The provider's code decides which guidance is right; its message is never shown, it can
    /// carry credentials or dictated text.
    private static func error(code: String) -> VoiceError {
        let folded = code.lowercased().replacingOccurrences(of: "_", with: "")
        if folded.contains("apikey") || folded == "unauthorized" {
            return VoiceError(tr("The API key is invalid. Update it in Settings."))
        }
        if folded.contains("modelnotfound") || folded.contains("accessdenied") {
            return VoiceError(tr("This account cannot use the selected recognition model. Choose another in Settings."))
        }
        return VoiceError(tr("Live speech recognition was interrupted. Check the network, model permissions and account balance."))
    }
}

public extension OpenAIWire {
    /// The session.update the socket answers with session.updated: text out, 16 kHz PCM in,
    /// server-side silence detection that splits speech into items without ever ending the
    /// session, and the personal dictionary as context text. No language is named: dictation
    /// mixes Chinese and English and the model detects it itself.
    static func qwenSession(dictionary: [String]) -> [String: Any] {
        var session: [String: Any] = [
            "modalities": ["text"],
            "input_audio_format": "pcm",
            "sample_rate": 16000,
            "turn_detection": ["type": "server_vad", "threshold": 0.2, "silence_duration_ms": 800],
        ]
        let words = cleanDictionary(dictionary)
        if !words.isEmpty {
            session["input_audio_transcription"] = ["corpus": ["text": words.joined(separator: ", ")]]
        }
        return ["event_id": qwenEventID(), "type": "session.update", "session": session]
    }

    /// Audio goes out in append events of at most 100 ms: 3200 bytes of 16 kHz PCM.
    static func appendChunks(_ data: Data) -> [Data] {
        var chunks: [Data] = []
        var at = data.startIndex
        while at < data.endIndex {
            let end = Swift.min(at + 3200, data.endIndex)
            chunks.append(data[at..<end])
            at = end
        }
        return chunks
    }
}

/// Recognition over Model Studio's realtime socket: the 24 kHz recording is resampled and
/// streamed while it is still being made, the words arrive as partial and final items, and the
/// session is ended by `session.finish` — the server's silence detection only splits items.
/// (The model's name is in the socket's address, so `model` is unused here.)
@MainActor
public final class QwenRealtimeTranscriber {
    private let socket: URLSessionWebSocketTask
    private var sender: Task<Void, Error>?
    private var watchdog: Task<Void, Never>?
    private var timedOut = false
    private var finishing = false
    private var sendError: Error?

    public init(key: String, endpoint: URL, session: URLSession = .shared) {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        socket = session.webSocketTask(with: request)
    }

    public func run(audio: AsyncThrowingStream<Data, Error>, model: String, dictionary: [String],
                    onReady: @escaping () -> Void, onPartial: @escaping (String) -> Void) async throws -> String {
        socket.resume()
        deadline(seconds: 12)
        defer { cancel() }
        do {
            try await send(OpenAIWire.qwenSession(dictionary: dictionary))
            var buffer = QwenTranscript()
            while true {
                let event = try await receive()
                try buffer.receive(event)
                if event["type"] as? String == "session.updated" { break }
            }
            if finishing { deadline(seconds: 40) } else { watchdog?.cancel() }
            onReady()
            sender = Task {
                do {
                    var resampler = PCMResampler()
                    var bytes = 0
                    for try await chunk in audio {
                        try Task.checkCancellation()
                        bytes += chunk.count
                        for part in OpenAIWire.appendChunks(resampler.process(chunk)) {
                            try await self.send(["event_id": qwenEventID(), "type": "input_audio_buffer.append",
                                                 "audio": part.base64EncodedString()])
                        }
                    }
                    try Task.checkCancellation()
                    guard bytes >= 4800 else { throw VoiceError(tr("The recording is too short. Finish speaking before you stop.")) }
                    self.finishDeadline()
                    try await self.send(["event_id": qwenEventID(), "type": "session.finish"])
                } catch {
                    self.sendError = error
                    self.socket.cancel(with: .goingAway, reason: nil)
                    throw error
                }
            }
            var shown = ""
            while true {
                try Task.checkCancellation()
                let event = try await receive()
                // A long recording takes a while to transcribe back; while events keep arriving
                // after it ended, the connection is alive and the deadline moves with them.
                if finishing { deadline(seconds: 40) }
                try buffer.receive(event)
                if buffer.text != shown {
                    shown = buffer.text
                    onPartial(buffer.text)
                }
                if buffer.finished {
                    try await sender?.value
                    return buffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let http = socket.response as? HTTPURLResponse, http.statusCode >= 400 {
                throw OpenAIWire.serviceError(status: http.statusCode, data: Data(), name: Platform.alibaba.name)
            }
            // The socket closing with 1007 is "model not found": a wrong model name, or the
            // service not activated on this account. The close reason is never shown.
            if socket.closeCode == .invalidFramePayloadData {
                throw VoiceError(tr("This account cannot use the selected recognition model. Choose another in Settings."))
            }
            if timedOut {
                throw VoiceError(tr("%@ did not respond in time. The recording is kept on this Mac.", Platform.alibaba.name), retryable: true)
            }
            // The watchdog's own cancel can make the sender fail first, so this comes after timedOut.
            if let sendError { throw sendError }
            if error is VoiceError { throw error }
            throw VoiceError(tr("The live connection was interrupted. The recording is kept on this Mac and will be transcribed once online."), retryable: true)
        }
    }

    /// For Verify: connect, send a session.update and wait up to 10 seconds for session.updated —
    /// proving the address and the key — then finish and close. No audio is sent.
    public static func probe(key: String, endpoint: URL, session: URLSession = .shared) async throws {
        let client = QwenRealtimeTranscriber(key: key, endpoint: endpoint, session: session)
        defer { client.cancel() }
        client.socket.resume()
        client.deadline(seconds: 10)
        do {
            try await client.send(OpenAIWire.qwenSession(dictionary: []))
            var buffer = QwenTranscript()
            while true {
                let event = try await client.receive()
                try buffer.receive(event)
                if event["type"] as? String == "session.updated" { break }
            }
            try? await client.send(["event_id": qwenEventID(), "type": "session.finish"])
        } catch {
            if let http = client.socket.response as? HTTPURLResponse, http.statusCode >= 400 {
                throw OpenAIWire.serviceError(status: http.statusCode, data: Data(), name: Platform.alibaba.name)
            }
            if client.socket.closeCode == .invalidFramePayloadData {
                throw VoiceError(tr("This account cannot use the selected recognition model. Choose another in Settings."))
            }
            if client.timedOut {
                throw VoiceError(tr("%@ did not respond in time. Check the network and the address.", Platform.alibaba.name), retryable: true)
            }
            throw error
        }
    }

    public func finishDeadline() {
        finishing = true
        deadline(seconds: 40)
    }

    public func cancel() {
        watchdog?.cancel(); watchdog = nil
        sender?.cancel(); sender = nil
        socket.cancel(with: .normalClosure, reason: nil)
    }

    private func deadline(seconds: UInt64) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self else { return }
            self.timedOut = true
            self.socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive() async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let string): data = Data(string.utf8)
        case .data(let value): data = value
        @unknown default: throw VoiceError(tr("Cannot read the live recognition response."))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceError(tr("Cannot read the live recognition response."))
        }
        return object
    }
}

extension QwenRealtimeTranscriber: Transcriber {}
