import Foundation

/// AssemblyAI streaming speech-to-text, v3 (`wss://streaming.assemblyai.com/v3/ws`, the global
/// endpoint; `streaming.us.` and `streaming.eu.` pin data residency). The key goes in the
/// Authorization header and the settings in the query. `Begin` opens the session; audio goes out as
/// binary frames of raw PCM; each `Turn` message replaces the one before for the same turn, and the
/// last one for a turn (ended and formatted) holds its final words. `Terminate` makes the service
/// send what is left, then `Termination`, and close the socket.
@MainActor
public final class AssemblyAIWire: LiveWire {
    /// 3.7 Realtime is the model for transcription and captions (its turn detection segments text
    /// rather than waiting for a voice agent's turn); 3.7 Realtime Agent is tuned for voice agents;
    /// universal-3-6-pro is the previous model. All of them code-switch across 32 languages,
    /// Mandarin and English among them, and format their turns.
    public nonisolated static let models = ["assemblyai-stt-3-7-realtime", "assemblyai-stt-3-7-realtime-agent", "universal-3-6-pro"]
    public nonisolated static let keyFormat = "\u{2026}"

    public let sampleRate = 24000
    /// `Begin` comes before the service takes audio; waiting for it also lets Verify see a refused
    /// key, which arrives as an `Error` message after the handshake rather than as an HTTP status.
    public let waitsForReady = true

    public init() {}

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        // List values go in the query as JSON arrays. The language codes steer the model towards
        // Mandarin and English while it still switches between them mid-sentence.
        var items = [("speech_model", model), ("encoding", "pcm_s16le"), ("sample_rate", String(sampleRate)),
                     ("language_codes", #"["zh","en"]"#)]
        let terms = Self.keyterms(dictionary)
        if !terms.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: terms)
            items.append(("keyterms_prompt", String(decoding: data, as: UTF8.self)))
        }
        guard let url = URL(string: "wss://streaming.assemblyai.com/v3/ws?" + Self.query(items)) else {
            throw LiveWires.failure(.other)
        }
        var request = URLRequest(url: url)
        // The bare key, without "Bearer".
        request.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        return request
    }

    /// Each frame must hold 20 to 1000 ms of audio, or the session ends with an error; a last piece
    /// shorter than 20 ms is padded with silence.
    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        let least = sampleRate / 50 * 2
        return [.data(pcm.count >= least ? pcm : pcm + Data(count: least - pcm.count))]
    }

    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        [try LiveWires.json(["type": "Terminate"])]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let object = LiveWires.object(message), let type = object["type"] as? String else { return [] }
        switch type {
        case "Begin":
            return [.ready]
        case "Turn":
            let text = (object["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A turn is complete on the message that is both ended and formatted.
            let complete = object["end_of_turn"] as? Bool == true && object["turn_is_formatted"] as? Bool != false
            guard complete else { return [.draft(text)] }
            return text.isEmpty ? [.draft("")] : [.settled(text)]
        case "Termination":
            // Every turn has been sent: nothing is left in progress.
            return [.draft(""), .done]
        case "Error":
            throw Self.failure(code: (object["error_code"] as? NSNumber)?.intValue ?? 0,
                               text: object["error"] as? String ?? "")
        default:
            // SpeechStarted and Heartbeat.
            return []
        }
    }

    /// Code 1008 covers a missing, invalid or disabled key, and also the rate limit and an empty
    /// balance; only the text tells them apart. The text is read here and never shown.
    private static func failure(code: Int, text: String) -> VoiceError {
        let text = text.lowercased()
        if code == 1008, text.contains("api key") || text.contains("authorization header") {
            return LiveWires.failure(.key)
        }
        if text.contains("model") { return LiveWires.failure(.model) }
        return LiveWires.failure(.other)
    }

    /// The dictionary as key terms: at most 100 (more fail the session) of at most 50 characters
    /// each (longer ones would be ignored).
    private static func keyterms(_ words: [String]) -> [String] {
        Array(OpenAIWire.cleanDictionary(words).filter { $0.count <= 50 }.prefix(100))
    }

    /// A query string with every value percent-encoded, "+" included (a server may read it as a space).
    private static func query(_ items: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
    }
}
