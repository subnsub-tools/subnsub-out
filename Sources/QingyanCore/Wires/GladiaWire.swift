import Foundation

/// Gladia live transcription, v2. A POST to `https://api.gladia.io/v2/live` (key in `x-gladia-key`)
/// sets the session up and answers with the socket's address, which carries a token of its own.
/// Audio goes out as binary frames of raw PCM. A `transcript` message with `is_final` false is the
/// utterance so far, with `is_final` true its final words. `stop_recording` makes the service finish
/// the audio; `end_session` comes last and the socket closes with code 1000.
@MainActor
public final class GladiaWire: LiveWire {
    /// Solaria-1 is the only model for live sessions (Solaria-3 is for files and five European
    /// languages).
    public nonisolated static let models = ["solaria-1"]
    public nonisolated static let keyFormat = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

    /// Live sessions take 8, 16, 32, 44.1 or 48 kHz, not 24 kHz: the engine resamples to 16 kHz.
    public let sampleRate = 16000
    /// Should `end_session` go missing, the socket closing after the stop still ends the session.
    public let closeEnds = true

    public init() {}

    /// The session is set up first; without a `region` the service picks where it runs (it also
    /// takes `us-west` and `eu-west`).
    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        var body: [String: Any] = [
            "encoding": "wav/pcm", "bit_depth": 16, "sample_rate": sampleRate, "channels": 1, "model": model,
            // Language detected anew on each utterance, between Mandarin and English only.
            "language_config": ["languages": ["zh", "en"], "code_switching": true],
            // Partial and final transcripts, errors, and the session's end; no acknowledgments for
            // every chunk, no speech or processing events.
            "messages_config": [
                "receive_partial_transcripts": true, "receive_final_transcripts": true,
                "receive_speech_events": false, "receive_pre_processing_events": false,
                "receive_realtime_processing_events": false, "receive_post_processing_events": false,
                "receive_acknowledgments": false, "receive_errors": true, "receive_lifecycle_events": true,
            ],
        ]
        let vocabulary = Self.vocabulary(dictionary)
        if !vocabulary.isEmpty {
            // Replacement by sound after recognition; 0.4 is the starting intensity the docs advise.
            body["realtime_processing"] = [
                "custom_vocabulary": true,
                "custom_vocabulary_config": ["vocabulary": vocabulary, "default_intensity": 0.4],
            ]
        }
        var post = URLRequest(url: URL(string: "https://api.gladia.io/v2/live")!, timeoutInterval: 10)
        post.httpMethod = "POST"
        post.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-gladia-key")
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: post)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 { throw LiveWires.failure(.key) }
            // Invalid settings; the body is only looked at to tell a refused model from the rest.
            let model = (status == 400 || status == 422) && String(decoding: data, as: UTF8.self).contains("model")
            let service = status == 402 || status == 429 || status >= 500
            throw LiveWires.failure(model ? .model : service ? .other : .refused)
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let address = answer["url"] as? String, let url = URL(string: address) else {
            throw LiveWires.failure(.other)
        }
        return URLRequest(url: url)
    }

    /// Chunks of about 100 ms are advised, which is the engine's default.
    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        [.data(pcm)]
    }

    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        [try LiveWires.json(["type": "stop_recording"])]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let object = LiveWires.object(message) else { return [] }
        // Messages carry `error` as null, or as an object with a status code when something failed.
        if let error = object["error"] as? [String: Any] {
            let status = "\(error["status_code"] ?? "")"
            throw LiveWires.failure(status == "401" || status == "403" ? .key : .other)
        }
        switch object["type"] as? String {
        case "transcript":
            // Partials and the final of one utterance share its id; each replaces the one before.
            let data = object["data"] as? [String: Any]
            let utterance = data?["utterance"] as? [String: Any]
            let text = (utterance?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard data?["is_final"] as? Bool == true else { return [.draft(text)] }
            return text.isEmpty ? [.draft("")] : [.settled(text)]
        case "end_session":
            return [.draft(""), .done]
        case "error":
            throw LiveWires.failure(.other)
        default:
            // start_session, start_recording, end_recording.
            return []
        }
    }

    /// The dictionary as custom vocabulary. No limit is published, but every word is compared with
    /// every entry, so a long list brings false replacements: 100 entries at most. Each entry is
    /// compared by sound in its own language, Chinese for terms with Han characters, English otherwise.
    private static func vocabulary(_ words: [String]) -> [[String: String]] {
        OpenAIWire.cleanDictionary(words).prefix(100).map { word in
            let han = word.unicodeScalars.contains {
                (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x2FFFF).contains($0.value)
            }
            return ["value": word, "language": han ? "zh" : "en"]
        }
    }
}
