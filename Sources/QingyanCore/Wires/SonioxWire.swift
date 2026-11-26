import Foundation

/// Soniox real-time speech-to-text (`wss://stt-rt.soniox.com/transcribe-websocket`, the US region;
/// `stt-rt.eu.`, `.jp.` and `.in.soniox.com` serve keys made in those regions). The key goes in the
/// Authorization header and the settings in a first JSON message; audio goes out as binary frames
/// of raw PCM. Each answer carries tokens: final ones are sent once and never change, non-final ones
/// are replaced by the next answer. An empty text frame ends the stream; the answer with
/// `finished` comes last, and the service closes the socket.
@MainActor
public final class SonioxWire: LiveWire {
    /// One model covers 60+ languages and switches between them within a sentence.
    public nonisolated static let models = ["stt-rt-v6"]
    public nonisolated static let keyFormat = "\u{2026}"

    public let sampleRate = 24000
    /// The final text so far. Tokens are pieces of words (spaces are tokens of their own), so the
    /// wire joins them itself and hands over the whole transcript each time.
    private var settled = ""

    public init() {}

    /// The key is checked only after the configuration is sent, so connecting proves nothing about it.
    public func provesKey(model: String) -> Bool { false }

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
        request.setValue("Bearer " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        return request
    }

    public func opening(key: String, model: String, dictionary: [String]) throws -> [URLSessionWebSocketTask.Message] {
        // The hints bias recognition towards Mandarin and English without excluding other languages.
        var config: [String: Any] = ["model": model, "audio_format": "pcm_s16le", "sample_rate": sampleRate,
                                     "num_channels": 1, "language_hints": ["zh", "en"]]
        let terms = Self.terms(dictionary)
        if !terms.isEmpty { config["context"] = ["terms": terms] }
        return [try LiveWires.json(config)]
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        [.data(pcm)]
    }

    /// An empty text frame ends the stream (an empty binary frame would only be empty audio).
    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        [.string("")]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let object = LiveWires.object(message) else { return [] }
        if object["error_code"] != nil || object["error_type"] != nil { throw Self.failure(object) }
        guard let tokens = object["tokens"] as? [[String: Any]] else { return [] }
        var draft = ""
        for token in tokens {
            // Endpoint and finalization markers are not words.
            guard let text = token["text"] as? String, text != "<end>", text != "<fin>" else { continue }
            if token["is_final"] as? Bool == true { settled += text } else { draft += text }
        }
        if object["finished"] as? Bool == true { return [.whole(settled), .done] }
        return tokens.isEmpty ? [] : [.whole(settled + draft)]
    }

    /// The error's type names the cause; its message is never read.
    private static func failure(_ object: [String: Any]) -> VoiceError {
        switch object["error_type"] as? String {
        case "unauthenticated", "temp_api_key_session_expired": return LiveWires.failure(.key)
        case "model_not_available", "permission_denied": return LiveWires.failure(.model)
        default:
            switch (object["error_code"] as? NSNumber)?.intValue {
            case 401: return LiveWires.failure(.key)
            case 403: return LiveWires.failure(.model)
            default: return LiveWires.failure(.other)
            }
        }
    }

    /// The dictionary as context terms. The whole context must stay under 8000 tokens (about
    /// 10,000 characters of English); the terms are kept to 4000 characters, as Chinese takes
    /// more tokens per character.
    private static func terms(_ words: [String]) -> [String] {
        var terms: [String] = [], characters = 0
        for word in OpenAIWire.cleanDictionary(words) where characters + word.count <= 4000 {
            terms.append(word)
            characters += word.count
        }
        return terms
    }
}
