import Foundation

/// Azure AI Speech fast transcription (`POST /speechtotext/transcriptions:transcribe`,
/// api-version 2025-10-15): synchronous, multipart, the finished recording in `audio` and the
/// options as JSON in `definition`. The answer's `combinedPhrases` holds the whole transcript.
/// The model names pick the engine: Azure Transcribe (the default engine, every region), Azure
/// LLM Speech or MAI-Transcribe through `enhancedMode` (only some regions).
@MainActor
public final class AzureWire: FileWire {
    public nonisolated static let models = ["transcribe", "llm-speech", "MAI-Transcribe-2"]
    /// The region of the Speech resource (such as eastus) and one of its keys. A resource host
    /// (name.cognitiveservices.azure.com) also works in place of the region.
    public nonisolated static let keyFormat = "REGION:KEY"

    public init() {}

    public func request(key: String, model: String, dictionary: [String], wav: Data) async throws -> URLRequest {
        guard let parts = LiveWires.parts(key, count: 2) else { throw LiveWires.failure(.key) }
        let place = parts[0].lowercased()
        guard place.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else {
            throw LiveWires.failure(.key)
        }
        let host = place.contains(".") ? place : place + ".api.cognitive.microsoft.com"
        guard let url = URL(string: "https://\(host)/speechtotext/transcriptions:transcribe?api-version=2025-10-15") else {
            throw LiveWires.failure(.key)
        }

        // No `locales`: a list of candidates picks one language for the whole file (and fails when
        // none dominates), while no locale at all means the multilingual model, which transcribes
        // Mandarin and English mixed together continuously. Dictated words are never masked.
        var definition: [String: Any] = ["profanityFilterMode": "None"]
        switch model {
        case "transcribe": break
        case "llm-speech": definition["enhancedMode"] = ["enabled": true, "task": "transcribe"]
        default: definition["enhancedMode"] = ["enabled": true, "model": model]   // MAI-Transcribe-2 and its successors
        }
        let phrases = Self.phrases(dictionary)
        if !phrases.isEmpty { definition["phraseList"] = ["phrases": phrases] }

        let boundary = "out-" + UUID().uuidString
        var body = Data()
        func part(_ head: String, _ content: Data) {
            body.append(Data("--\(boundary)\r\n\(head)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n".utf8))
        }
        part("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav", wav)
        part("Content-Disposition: form-data; name=\"definition\"", try JSONSerialization.data(withJSONObject: definition))
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(parts[1], forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    public func text(_ data: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw VoiceError(tr("The recognition response is invalid."))
        }
        // Mono audio: one channel, one combined transcript. Silence gives none.
        if let combined = (object["combinedPhrases"] as? [[String: Any]])?.first?["text"] as? String { return combined }
        let phrases = (object["phrases"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return phrases.reduce("") { OpenAIWire.joinPieces($0, $1) }
    }

    /// The dictionary as a phrase list, within the stricter documented limit (200 phrases and 3,200
    /// characters in all, for the multilingual model).
    private static func phrases(_ dictionary: [String]) -> [String] {
        var kept: [String] = []
        var characters = 0
        for word in OpenAIWire.cleanDictionary(dictionary) where kept.count < 200 {
            guard characters + word.count <= 3200 else { break }
            kept.append(word)
            characters += word.count
        }
        return kept
    }
}
