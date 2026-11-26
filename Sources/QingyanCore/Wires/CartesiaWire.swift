import Foundation

/// Cartesia Ink realtime speech to text, the manual endpoint (`wss://api.cartesia.ai/stt/websocket`):
/// out decides when speech ends (Cartesia recommends it for push-to-talk). Audio goes out as binary
/// frames of raw PCM. Each `transcript` message is a delta: with `is_final` false, the text since
/// the last final one; with `is_final` true, final text to append exactly as received (its own
/// spaces, none added or trimmed). So the wire keeps the transcript itself and hands it on whole.
/// `close` makes the service transcribe what is left and answer `done`, then it closes the socket.
@MainActor
public final class CartesiaWire: LiveWire {
    /// Ink Preview first: its 44 languages include Mandarin, it follows language switches within a
    /// sentence and takes language hints, but Cartesia says it can change without notice. Ink Whisper
    /// is the stable model with Chinese. (Ink 2 has English, French, Hindi, Japanese and Spanish only.)
    public nonisolated static let models = ["ink-preview", "ink-whisper"]
    public nonisolated static let keyFormat = "sk_car_\u{2026}"
    /// The API version the messages below follow, sent with every connection.
    private static let version = "2026-08-14"

    public let sampleRate = 24000
    /// The socket closes by itself after `done`; should `done` go missing, the close still ends the
    /// session.
    public let closeEnds = true
    /// The final text so far, joined exactly as it came.
    private var settled = ""

    public init() {}

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        var items = [("model", model), ("encoding", "pcm_s16le"), ("sample_rate", String(sampleRate)),
                     ("cartesia_version", Self.version)]
        if model.hasPrefix("ink-whisper") {
            // Without it Ink Whisper assumes English and may translate Chinese speech into English.
            items.append(("language", "zh"))
        } else if model == "ink-2" {
            // Ink 2 takes no hints, and its keyterms only in the address.
            for term in Self.keyterms(dictionary, count: 100, characters: 1200, inAddress: true) {
                items.append(("keyterm", term))
            }
        } else {
            // Ink Preview detects the language itself; hints lean it towards Mandarin and English.
            items += [("language_hint", "zh"), ("language_hint", "en")]
        }
        guard let url = URL(string: "wss://api.cartesia.ai/stt/websocket?" + Self.query(items)) else {
            throw LiveWires.failure(.other)
        }
        var request = URLRequest(url: url)
        request.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-API-Key")
        return request
    }

    /// Ink Preview's keyterms go in a `config` message right after connecting, as Cartesia advises
    /// for long lists (an address over about 8 KB is refused).
    public func opening(key: String, model: String, dictionary: [String]) throws -> [URLSessionWebSocketTask.Message] {
        guard !model.hasPrefix("ink-whisper"), model != "ink-2" else { return [] }
        let terms = Self.keyterms(dictionary, count: 500, characters: 5000, inAddress: false)
        return terms.isEmpty ? [] : [try LiveWires.json(["type": "config", "keyterms": terms])]
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        pcm.isEmpty ? [] : [.data(pcm)]
    }

    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        [.string("close")]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let object = LiveWires.object(message), let type = object["type"] as? String else { return [] }
        switch type {
        case "transcript":
            let text = object["text"] as? String ?? ""
            guard object["is_final"] as? Bool == true else { return [.whole(settled + text)] }
            settled += text
            return [.whole(settled)]
        case "done":
            return [.done]
        case "error":
            let status = object["status_code"] as? Int ?? 0
            let code = object["error_code"] as? String ?? ""
            if status == 401 { throw LiveWires.failure(.key) }
            if status == 403 || status == 404 || code.contains("model") { throw LiveWires.failure(.model) }
            throw LiveWires.failure(.other)
        default:
            // `flush_done` answers a `finalize`, which out does not send.
            return []
        }
    }

    /// The dictionary as keyterms within a model's limits. In the address, the encoded terms are also
    /// kept under 6000 bytes so the whole address stays below the 8 KB the service accepts.
    private static func keyterms(_ words: [String], count: Int, characters: Int, inAddress: Bool) -> [String] {
        var terms: [String] = [], total = 0, bytes = 0
        for word in OpenAIWire.cleanDictionary(words) {
            if terms.count == count { break }
            let encoded = inAddress ? query([("keyterm", word)]).utf8.count + 1 : 0
            if total + word.count > characters || bytes + encoded > 6000 { continue }
            terms.append(word)
            total += word.count
            bytes += encoded
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
