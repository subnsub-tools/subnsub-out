import Foundation

/// Google Gemini Live API transcription (`BidiGenerateContent` socket), for Gemini 3.5 Transcribe
/// Live, a dedicated speech-to-text model. The first message is the setup; nothing else may go out
/// before the service answers `setupComplete`. Automatic voice detection is off, so the whole
/// recording is one turn: `activityStart` goes ahead of the first audio and `activityEnd` closes it.
/// While the user speaks, `interimInputTranscription` is the segment so far; `inputTranscription`
/// is a segment's final words (verbatim mode). The turn's completion after `activityEnd` ends the session.
@MainActor
public final class GeminiLiveWire: LiveWire {
    public nonisolated static let models = ["gemini-3.5-transcribe-live"]
    public nonisolated static let keyFormat = "AIza\u{2026}"

    /// The service takes any rate named in the MIME type (it is 16 kHz inside).
    public let sampleRate = 24000
    /// Audio waits for `setupComplete`.
    public let waitsForReady = true
    /// Whether `activityStart` has gone out.
    private var started = false
    /// Whether `activityEnd` has gone out: the turn's completion after it ends the session.
    private var ending = false
    /// Whether `generationComplete` has come after `activityEnd`.
    private var generated = false
    /// Whether words are shown that no final has replaced yet.
    private var pending = false

    public init() {}

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        // The key goes in the query, as the WebSocket guide documents.
        var address = URLComponents()
        address.scheme = "wss"
        address.host = "generativelanguage.googleapis.com"
        address.path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        address.queryItems = [URLQueryItem(name: "key", value: key.trimmingCharacters(in: .whitespacesAndNewlines))]
        guard let url = address.url else { throw LiveWires.failure(.key) }
        return URLRequest(url: url)
    }

    public func opening(key: String, model: String, dictionary: [String]) throws -> [URLSessionWebSocketTask.Message] {
        let name = model.hasPrefix("models/") ? model : "models/" + model
        // Language hints bias towards Mandarin and English; detection and switching mid-sentence
        // stay on. Verbatim mode (the default) sends per-segment finals; "SMART" would resend the
        // whole text and apply spoken editing commands, which dictation does not want.
        var transcription: [String: Any] = ["languageCodes": ["cmn-Hans-CN", "en-US"]]
        let terms = Array(OpenAIWire.cleanDictionary(dictionary).prefix(1000))
        if !terms.isEmpty { transcription["customVocabulary"] = terms }
        return [try LiveWires.json(["setup": [
            "model": name,
            "generationConfig": ["responseModalities": ["TEXT"]],
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            "inputAudioTranscription": transcription,
        ]])]
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        var messages: [URLSessionWebSocketTask.Message] = []
        if !started {
            started = true
            messages.append(try LiveWires.json(["realtimeInput": ["activityStart": [String: Any]()]]))
        }
        if !pcm.isEmpty {
            messages.append(try LiveWires.json(["realtimeInput": ["audio": [
                "data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=\(sampleRate)",
            ]]]))
        }
        return messages
    }

    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        ending = true
        return [try LiveWires.json(["realtimeInput": ["activityEnd": [String: Any]()]])]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let object = LiveWires.object(message) else { return [] }
        if object["setupComplete"] != nil { return [.ready] }
        guard let content = object["serverContent"] as? [String: Any] else { return [] }
        var events: [LiveEvent] = []
        if let interim = content["interimInputTranscription"] as? [String: Any], let text = interim["text"] as? String {
            events.append(.draft(text))
            pending = !text.isEmpty
        }
        if let segment = content["inputTranscription"] as? [String: Any] {
            // A final without text is an empty segment: it only clears the draft.
            let text = segment["text"] as? String ?? ""
            events.append(text.isEmpty ? .draft("") : .settled(text))
            pending = false
        }
        guard ending else { return events }
        // The turn ends with `generationComplete`, then `turnComplete`; finals are not ordered with
        // them. The session ends at `turnComplete`, or sooner once generation is complete and no
        // draft waits for its final. Should a final still come later, the transcript keeps the draft.
        if content["generationComplete"] as? Bool == true { generated = true }
        if content["turnComplete"] as? Bool == true || (generated && !pending) {
            events.append(.done)
        }
        return events
    }
}
