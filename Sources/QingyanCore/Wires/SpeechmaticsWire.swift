import Foundation

/// Speechmatics real-time transcription (`wss://global.rt.speechmatics.com/v2`, which routes to the
/// nearest region; `eu.`, `us.` and `au.rt.speechmatics.com` pin one). The key goes in the
/// Authorization header. `StartRecognition` carries the audio format and the transcription settings;
/// audio may go out once `RecognitionStarted` has come back, as binary frames of raw PCM. An
/// `AddPartialTranscript` holds the words not yet final, an `AddTranscript` a run of final words.
/// `EndOfStream` (with the number of audio frames sent) makes the service finish, and
/// `EndOfTranscript` comes after the last final words.
@MainActor
public final class SpeechmaticsWire: LiveWire {
    /// Enhanced is the most accurate and Standard the faster model; with them the Mandarin & English
    /// bilingual pack is used, which follows speakers switching between the two. Melia 1 detects
    /// 55+ languages by itself, but has no custom dictionary yet.
    public nonisolated static let models = ["enhanced", "standard", "melia-1"]
    public nonisolated static let keyFormat = "\u{2026}"

    /// Raw PCM is accepted at any rate given in `StartRecognition`.
    public let sampleRate = 24000
    public let waitsForReady = true
    /// Audio frames sent so far: `EndOfStream` names the last one.
    private var sent = 0

    public init() {}

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://global.rt.speechmatics.com/v2")!)
        request.setValue("Bearer " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        return request
    }

    public func opening(key: String, model: String, dictionary: [String]) throws -> [URLSessionWebSocketTask.Message] {
        // Punctuation and smart formatting are on by default.
        var config: [String: Any] = ["model": model, "enable_partials": true]
        if model.hasPrefix("melia") || model.hasPrefix("oak") {
            // The multilingual models take "multi" and hints, and refuse what they do not support yet
            // (custom dictionary, max_delay, punctuation overrides).
            config["language"] = "multi"
            config["language_hints"] = ["cmn", "en"]
        } else {
            config["language"] = "cmn_en"
            // Up to 20,000 items are accepted, but no more than 1000 are advised; items longer than
            // six words are dropped by the service.
            let words = OpenAIWire.cleanDictionary(dictionary).prefix(1000)
            if !words.isEmpty { config["additional_vocab"] = words.map { ["content": $0] } }
        }
        return [try LiveWires.json([
            "message": "StartRecognition",
            "audio_format": ["type": "raw", "encoding": "pcm_s16le", "sample_rate": sampleRate],
            "transcription_config": config,
        ])]
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        sent += 1
        return [.data(pcm)]
    }

    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        [try LiveWires.json(["message": "EndOfStream", "last_seq_no": sent])]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let object = LiveWires.object(message), let type = object["message"] as? String else { return [] }
        switch type {
        case "RecognitionStarted":
            return [.ready]
        case "AddPartialTranscript":
            return [.draft(Self.transcript(object))]
        case "AddTranscript":
            // A partial with the words still in progress follows every final at once.
            let text = Self.transcript(object)
            return text.isEmpty ? [] : [.settled(text)]
        case "EndOfTranscript":
            return [.draft(""), .done]
        case "Error":
            switch object["type"] as? String {
            case "not_authorised": throw LiveWires.failure(.key)
            case "invalid_model", "invalid_language", "not_allowed": throw LiveWires.failure(.model)
            default: throw LiveWires.failure(.other)
            }
        default:
            // AudioAdded, Info, Warning, LanguageInfo, EndOfUtterance.
            return []
        }
    }

    /// A transcript message's text, formatted for display by the service.
    private static func transcript(_ object: [String: Any]) -> String {
        let metadata = object["metadata"] as? [String: Any]
        return (metadata?["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
