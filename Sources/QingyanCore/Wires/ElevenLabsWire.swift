import Foundation

/// ElevenLabs Scribe realtime speech to text (`wss://api.elevenlabs.io/v1/speech-to-text/realtime`).
/// Audio goes out as JSON with base64 PCM; `partial_transcript` is the segment so far and
/// `committed_transcript` a finished segment. The session uses manual commits (the service's
/// default): out commits only once, after the last audio, so the committed transcript that follows
/// that commit is the last one. The service also commits by itself after about 36 seconds of audio;
/// those segments arrive as ordinary settled text. There is no end-of-session message, so the wire
/// counts the session as over at that last committed transcript.
@MainActor
public final class ElevenLabsWire: LiveWire {
    /// Scribe v3 Live first: the successor of Scribe v2 Realtime, more accurate, and the only one
    /// with a mode that follows speech switching languages within a sentence.
    public nonisolated static let models = ["scribe_v3_live", "scribe_v2_realtime"]
    public nonisolated static let keyFormat = "sk_\u{2026}"

    public let sampleRate = 24000
    /// The service sends `session_started` as soon as the socket opens, and its examples wait for it
    /// before sending audio.
    public let waitsForReady = true
    /// Whether the last commit has gone out.
    private var committing = false

    public init() {}

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        var items = [("model_id", model), ("audio_format", "pcm_24000")]
        if model == "scribe_v3_live" {
            // Each language in its own script, following switches mid-sentence (v3 Live only; other
            // models reject it).
            items.append(("multilang_mode", "true"))
        } else {
            // Mostly Chinese, with detection limited to Chinese and English.
            items += [("language_code", "zh"), ("secondary_languages", "en")]
        }
        for term in Self.keyterms(dictionary) { items.append(("keyterms", term)) }
        guard let url = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime?" + Self.query(items)) else {
            throw LiveWires.failure(.other)
        }
        var request = URLRequest(url: url)
        request.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "xi-api-key")
        return request
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        [try chunk(pcm.base64EncodedString(), commit: false)]
    }

    /// An empty chunk that commits: the service transcribes what is left and sends it as committed.
    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        committing = true
        return [try chunk("", commit: true)]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let object = LiveWires.object(message), let type = object["message_type"] as? String else { return [] }
        let text = object["text"] as? String ?? ""
        switch type {
        case "session_started":
            return [.ready]
        case "partial_transcript":
            return [.draft(text)]
        case "committed_transcript":
            var events: [LiveEvent] = text.isEmpty ? [.draft("")] : [.settled(text)]
            if committing { events.append(.done) }
            return events
        case "auth_error":
            throw LiveWires.failure(.key)
        case "unaccepted_terms", "invalid_request":
            // Scribe's terms not accepted on the account, or the connection's settings refused
            // (an unknown model, or a feature the model does not have).
            throw LiveWires.failure(.model)
        default:
            // Every other error type (quota, rate limit, transcriber, input, session time) carries an
            // `error` field; warnings and the other events do not.
            if object["error"] != nil { throw LiveWires.failure(.other) }
            return []
        }
    }

    private func chunk(_ base64: String, commit: Bool) throws -> URLSessionWebSocketTask.Message {
        try LiveWires.json(["message_type": "input_audio_chunk", "audio_base_64": base64,
                            "commit": commit, "sample_rate": sampleRate])
    }

    /// The dictionary as keyterms, within the realtime limits: the keyterm guide allows 100 terms and
    /// 1000 characters in all, the models page 50 terms, so the smaller count is used. Terms over
    /// 50 characters (the batch limit) are left out.
    private static func keyterms(_ words: [String]) -> [String] {
        var terms: [String] = [], characters = 0
        for word in OpenAIWire.cleanDictionary(words) where word.count <= 50 {
            if terms.count == 50 { break }
            if characters + word.count > 1000 { continue }
            terms.append(word)
            characters += word.count
        }
        return terms
    }

    /// A query string with every value percent-encoded, "+" included (a server may read it as a space).
    private static func query(_ items: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
    }
}
