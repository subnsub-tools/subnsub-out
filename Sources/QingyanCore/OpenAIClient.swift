import Foundation

@MainActor
public final class RealtimeTranscriber {
    private let socket: URLSessionWebSocketTask
    private var sender: Task<Void, Error>?
    private var watchdog: Task<Void, Never>?
    private var timedOut = false
    private var finishing = false
    private var sendError: Error?

    public init(key: String, session: URLSession = .shared,
                endpoint: URL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!) {
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
            try await send(OpenAIWire.session(model: model, dictionary: dictionary))
            var buffer = TranscriptBuffer()
            while true {
                let event = try await receive()
                try buffer.receive(event)
                if event["type"] as? String == "session.updated" { break }
            }
            if finishing { deadline(seconds: 40) } else { watchdog?.cancel() }
            onReady()
            sender = Task {
                do {
                    var bytes = 0
                    for try await chunk in audio {
                        try Task.checkCancellation()
                        bytes += chunk.count
                        try await self.send(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()])
                    }
                    try Task.checkCancellation()
                    guard bytes >= 4800 else { throw VoiceError(tr("The recording is too short. Finish speaking before you stop.")) }
                    self.finishDeadline()
                    try await self.send(["type": "input_audio_buffer.commit"])
                } catch {
                    self.sendError = error
                    self.socket.cancel(with: .goingAway, reason: nil)
                    throw error
                }
            }
            while true {
                try Task.checkCancellation()
                let event = try await receive()
                try buffer.receive(event)
                if !buffer.text.isEmpty { onPartial(buffer.text) }
                if buffer.isComplete {
                    try await sender?.value
                    return buffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let http = socket.response as? HTTPURLResponse, http.statusCode >= 400 {
                throw OpenAIWire.serviceError(status: http.statusCode, data: Data())
            }
            if let sendError { throw sendError }
            if timedOut { throw VoiceError(tr("OpenAI did not respond in time. The original recording is kept on this Mac."), retryable: true) }
            if error is VoiceError { throw error }
            throw VoiceError(tr("The live connection was interrupted. The recording is kept on this Mac and will be transcribed once online."), retryable: true)
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

/// Tidies, translates and edits text on whichever platform was chosen for it: OpenAI through its
/// Responses API, any other through `/chat/completions`. The instructions are the same.
public struct TextClient {
    private let service: Service
    private let session: URLSession
    public init(service: Service, session: URLSession = .shared) { self.service = service; self.session = session }

    public func edit(transcript: String, mode: WritingMode, targetLanguage: String,
                     selection: String, model: String, screening: Bool = false) async throws -> String {
        try await send(OpenAIWire.responseBody(transcript: transcript, mode: mode, targetLanguage: targetLanguage,
                                               selection: selection, model: model, screening: screening))
    }

    /// The second step for a dictation that may be an editing command. See `OpenAIWire.revisionBody`.
    public func revise(transcript: String, before: String, after: String, previous: String,
                       model: String) async throws -> String {
        try await send(OpenAIWire.revisionBody(transcript: transcript, before: before, after: after,
                                               previous: previous, model: model))
    }

    private func send(_ body: [String: Any]) async throws -> String {
        let live = service.platform.live
        var (data, http) = try await post(live ? "responses" : "chat/completions",
            body: live ? body : OpenAIWire.chatBody(body, platform: service.platform), timeout: live ? 45 : 60)
        // Some Model Studio models refuse the thinking switch itself; ask once more without it.
        if service.platform.wire == .alibaba, OpenAIWire.rejectsThinkingSwitch(status: http.statusCode, data: data) {
            var again = OpenAIWire.chatBody(body, platform: service.platform)
            again.removeValue(forKey: "enable_thinking")
            (data, http) = try await post("chat/completions", body: again, timeout: 60)
        }
        guard http.statusCode == 200 else {
            throw OpenAIWire.serviceError(status: http.statusCode, data: data, name: service.platform.name)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceError(tr("Cannot read the text polishing result."))
        }
        return try live ? OpenAIWire.responseText(object) : OpenAIWire.chatText(object)
    }

    private func post(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var request = service.request(path, timeout: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw VoiceError(tr("Invalid response from %@.", service.platform.name)) }
        return (data, http)
    }
}
