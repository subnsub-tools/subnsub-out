import Foundation

/// Deepgram live transcription (`wss://api.deepgram.com/v1/listen`), for Nova-3. Audio goes out as
/// binary frames of raw PCM. With interim results on, a `Results` message with `is_final` false is
/// the segment so far and one with `is_final` true is the segment's final words. `CloseStream` makes
/// the service transcribe what is left, send its final results and a `Metadata` summary, and close
/// the socket.
@MainActor
public final class DeepgramWire: LiveWire {
    /// Nova-3 only: its multilingual mode covers Mandarin and English with switches mid-sentence,
    /// and keyterms are a Nova-3 feature. (Flux, on `/v2/listen`, has no Chinese.)
    public nonisolated static let models = ["nova-3"]
    public nonisolated static let keyFormat = "\u{2026}"

    public let sampleRate = 24000
    /// The socket closes by itself after the summary; should the summary go missing, the close
    /// still ends the session.
    public let closeEnds = true
    /// Whether `CloseStream` has gone out: the summary after it ends the session.
    private var ending = false

    public init() {}

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        var items = [("model", model), ("encoding", "linear16"), ("sample_rate", String(sampleRate)),
                     ("channels", "1"), ("interim_results", "true"), ("smart_format", "true"), ("punctuate", "true")]
        if model == "nova-3" || model == "nova-3-general" {
            // Multilingual, leaning towards Mandarin and English; the hints bias detection and do
            // not restrict it.
            items += [("language", "multi"), ("language_hint", "zh"), ("language_hint", "en")]
        } else {
            // Other models have no Chinese in their multilingual mode: Mandarin alone.
            items.append(("language", "zh"))
        }
        if model.hasPrefix("nova-3") {
            for term in Self.keyterms(dictionary) { items.append(("keyterm", term)) }
        }
        guard let url = URL(string: "wss://api.deepgram.com/v1/listen?" + Self.query(items)) else {
            throw LiveWires.failure(.other)
        }
        var request = URLRequest(url: url)
        request.setValue("Token " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        return request
    }

    /// An empty binary frame would close the stream, so none is sent.
    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        pcm.isEmpty ? [] : [.data(pcm)]
    }

    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        ending = true
        return [try LiveWires.json(["type": "CloseStream"])]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let object = LiveWires.object(message), let type = object["type"] as? String else { return [] }
        switch type {
        case "Results":
            let channel = object["channel"] as? [String: Any]
            let best = (channel?["alternatives"] as? [[String: Any]])?.first
            let text = Self.tidy(best?["transcript"] as? String ?? "")
            guard object["is_final"] as? Bool == true else { return [.draft(text)] }
            return text.isEmpty ? [.draft("")] : [.settled(text)]
        case "Metadata":
            return ending ? [.done] : []
        case "Error":
            // A key or model the service refuses fails the handshake with an HTTP status instead;
            // what arrives here is a fault in the stream.
            throw LiveWires.failure(.other)
        default:
            // SpeechStarted, UtteranceEnd and Configure replies.
            return []
        }
    }

    /// Chinese is written without spaces; any the transcript has between Chinese characters (or
    /// Chinese punctuation) are taken out. Spaces next to Latin words stay.
    private static let gap = try? NSRegularExpression(
        pattern: "(?<=[\\p{Han}\\u3000-\\u303F\\uFF00-\\uFFEF])\\s+(?=[\\p{Han}\\u3000-\\u303F\\uFF00-\\uFFEF])")
    private static func tidy(_ text: String) -> String {
        guard let gap else { return text }
        return gap.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// The dictionary as keyterms: up to 100 terms, and under the 500-token limit for all of them
    /// together. The tokenizer is not published, so the count is a cautious estimate: a token per
    /// three ASCII characters, two per other character, one more per term.
    private static func keyterms(_ words: [String]) -> [String] {
        var terms: [String] = [], tokens = 0
        for word in OpenAIWire.cleanDictionary(words) {
            if terms.count == 100 { break }
            let ascii = word.unicodeScalars.filter(\.isASCII).count
            let cost = (ascii + 2) / 3 + (word.unicodeScalars.count - ascii) * 2 + 1
            if tokens + cost > 450 { continue }
            terms.append(word)
            tokens += cost
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
