import Foundation

/// Mistral realtime transcription (`wss://api.mistral.ai/v1/audio/transcriptions/realtime`), for
/// Voxtral Mini Transcribe Realtime 3. The service opens with `session.created`; nothing may be sent
/// before it. The settings (`session.update`) must arrive before the first audio and are fixed from
/// then on, so they go out just ahead of the first audio piece. Audio is base64 PCM in
/// `input_audio.append`. Each `transcription.text.delta` is final, carries its own spaces and only
/// ever adds to the end; `input_audio.end` asks for the rest, and `transcription.done` brings the
/// transcript of record and ends the session.
@MainActor
public final class MistralWire: LiveWire {
    /// Voxtral 3 realtime; the `-3` alias first, then the pinned version.
    public nonisolated static let models = ["voxtral-mini-transcribe-realtime-3", "voxtral-mini-transcribe-realtime-3-0"]
    public nonisolated static let keyFormat = "\u{2026}"

    /// `audio_format` declares the rate, and 24000 is the documented example.
    public let sampleRate = 24000
    /// Audio waits for `session.created`.
    public let waitsForReady = true
    /// The settings, sent once, just before the first audio piece.
    private var settings: URLSessionWebSocketTask.Message?
    /// The deltas so far, joined exactly as they came (they bring their own spaces).
    private var text = ""

    public init() {}

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        var address = URLComponents()
        address.scheme = "wss"
        address.host = "api.mistral.ai"
        address.path = "/v1/audio/transcriptions/realtime"
        address.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = address.url else { throw LiveWires.failure(.model) }
        // No `language`: left out, the model follows the language it hears, which suits Mandarin
        // with English terms (pinned to "zh", English dictation could come back in Chinese).
        // 480 ms is the documented balance of speed and accuracy; deltas are never revised.
        var session: [String: Any] = [
            "audio_format": ["encoding": "pcm_s16le", "sample_rate": sampleRate],
            "target_streaming_delay_ms": 480,
        ]
        // Keyphrases share the context window with the audio, so the list is kept short.
        let terms = Array(OpenAIWire.cleanDictionary(dictionary).prefix(100))
        if !terms.isEmpty { session["context_bias"] = terms }
        settings = try LiveWires.json(["type": "session.update", "session": session])
        var request = URLRequest(url: url)
        request.setValue("Bearer " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        return request
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        var messages: [URLSessionWebSocketTask.Message] = []
        if let settings {
            messages.append(settings)
            self.settings = nil
        }
        if !pcm.isEmpty {
            messages.append(try LiveWires.json(["type": "input_audio.append", "audio": pcm.base64EncodedString()]))
        }
        return messages
    }

    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        [try LiveWires.json(["type": "input_audio.end"])]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let object = LiveWires.object(message), let type = object["type"] as? String else { return [] }
        switch type {
        case "session.created":
            return [.ready]
        case "transcription.text.delta":
            guard let delta = object["text"] as? String, !delta.isEmpty else { return [] }
            text += delta
            return [.whole(text)]
        case "transcription.done":
            // The full transcript of record; the joined deltas stand in should it be missing.
            let final = (object["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text
            return [.whole(final), .done]
        case "error":
            throw LiveWires.failure(Self.kind(object["error"]))
        default:
            // session.updated (the settings echoed), turn.* and anything new.
            return []
        }
    }

    /// Which guidance an `error` event calls for. Its message is read only to choose; it is never shown.
    private static func kind(_ error: Any?) -> LiveWires.Failure {
        let detail = ((error as? [String: Any])?["message"] as? String ?? error as? String ?? "").lowercased()
        if detail.contains("unauthori") || detail.contains("api key") || detail.contains("authenticat") { return .key }
        if detail.contains("model") { return .model }
        return .other
    }
}
