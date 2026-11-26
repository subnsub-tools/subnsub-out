import CryptoKit
import Foundation

/// iFlytek real-time transcription, large-model edition:
/// https://www.xfyun.cn/doc/spark/asr_llm/rtasr_llm.html
///
/// Chosen over dictation (iat and its large-model edition), which stops at 60 seconds of audio.
/// This API takes up to 8 hours in one session, recognizes Chinese and English (and 202 dialects)
/// without switching, and is the edition the standard real-time page now points to.
///
/// Flow: signed address -> {"msg_type":"action","data":{"action":"started","sessionId":…}} -> binary
/// PCM, 16 kHz, 40 ms pieces -> {"end":true,"sessionId":…} -> results until one has "ls": true, then the
/// service closes. Each result holds one sentence: type "1" is the sentence so far (it replaces the
/// previous one), type "0" is its final form. This API has no word-range correction (wpgs).
@MainActor
public final class IFlytekWire: LiveWire {
    /// The `lang` parameter: Chinese, English and 202 dialects; or 37 languages (enabled by a support ticket).
    public nonisolated static let models = ["autodialect", "autominor"]
    /// APPID, APIKey (sent as accessKeyId) and APISecret (the signing secret) from the console.
    public nonisolated static let keyFormat = "APP_ID:API_KEY:API_SECRET"

    public let sampleRate = 16000
    /// 40 ms at 16 kHz, as the docs recommend.
    public let chunkBytes = 1280
    /// The "started" action carries the session id the end frame needs.
    public let waitsForReady = true
    /// The service closes once the last result is out; with no speech there may be no "ls" result.
    public let closeEnds = true

    private static let endpoint = "wss://office-api-ast-dx.iflyaisol.com/ast/communicate/v1"
    private var sessionID = ""
    /// The last seg_id taken as final; repeats of it (or older ones) are ignored.
    private var settledSegment = -1

    public init() {}

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        // The dictionary is not used: hotwords can only be uploaded in the console.
        guard let parts = LiveWires.parts(key, count: 3) else { throw LiveWires.failure(.key) }
        let lang = model.isEmpty ? Self.models[0] : model
        var parameters = [
            "appId": parts[0],
            "accessKeyId": parts[1],
            // A new uuid for every connection: the same uuid and second would be a repeated signature (35030).
            "uuid": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "utc": Self.beijingTime(Date()),
            "lang": lang,
            "audio_encode": "pcm_s16le",
            "samplerate": "16000",
        ]
        // With the 37-language model, say which languages to expect.
        if lang == "autominor" { parameters["recognized_language"] = "cn,en" }
        guard let url = URL(string: Self.endpoint + "?" + Self.signedQuery(parameters, secret: parts[2])) else {
            throw LiveWires.failure(.key)
        }
        return URLRequest(url: url)
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] { [.data(pcm)] }

    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        var end: [String: Any] = ["end": true]
        if !sessionID.isEmpty { end["sessionId"] = sessionID }
        return [try LiveWires.json(end)]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let root = LiveWires.object(message) else { return [] }
        // The page's field table (action, code, sid; data as a JSON string) is the standard edition's;
        // the large model sends msg_type/res_type with data as an object. Both shapes are read.
        let data = Self.object(root["data"]) ?? [:]
        let action = (data["action"] as? String) ?? (root["action"] as? String) ?? ""
        let code = Self.text(data["code"]) ?? Self.text(root["code"]) ?? "0"
        if action == "error" || code != "0" || root["msg_type"] as? String == "error"
            || (data["normal"] as? Bool) == false {
            // 37009: the last result was already sent.
            if code == "37009" { return [.done] }
            throw LiveWires.failure(Self.failure(code))
        }
        if action == "started" {
            sessionID = (data["sessionId"] as? String) ?? (root["sid"] as? String) ?? ""
            return [.ready]
        }
        guard root["msg_type"] as? String == "result" || action == "result" else { return [] }
        if let kind = root["res_type"] as? String, kind != "asr" { return [] }

        var events: [LiveEvent] = []
        if let sentence = Self.object(data["cn"]).flatMap({ Self.object($0["st"]) }),
           let results = sentence["rt"] as? [[String: Any]] {
            let segment = Self.number(data["seg_id"])
            if let segment, segment <= settledSegment {
                // A copy of a sentence that is already settled.
            } else {
                let text = Self.join(results.flatMap { ($0["ws"] as? [[String: Any]]) ?? [] }.compactMap(Self.word))
                if Self.text(sentence["type"]) == "0" {
                    if let segment { settledSegment = segment }
                    events.append(text.isEmpty ? .draft("") : .settled(text))
                } else {
                    events.append(.draft(text))
                }
            }
        }
        if (data["ls"] as? Bool) == true || Self.text(data["ls"]) == "true" { events.append(.done) }
        return events
    }

    // MARK: - Signing

    /// The signed query: parameters (signature aside) sorted by name, names and values percent-encoded,
    /// joined as name=value with "&"; signature = Base64(HMAC-SHA1(APISecret, that string)), appended
    /// percent-encoded. The page's example signature is a leftover from the standard edition (it is
    /// HMAC-SHA1 of the old MD5 example), so this was checked against iFlytek's own Python demo instead:
    /// accessKeyId=fixture-key, appId=fixture-app, audio_encode=pcm_s16le, lang=autodialect,
    /// role_type=2, samplerate=16000, utc=2026-09-25T14:50:00+0800, uuid=fixture-uuid, secret
    /// "fixture-secret" -> signature "pQib7904f134VI+xgEsXtVYhvqY=" (verified with a scratch script).
    nonisolated static func signedQuery(_ parameters: [String: String], secret: String) -> String {
        let base = parameters.sorted { $0.key < $1.key }
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(base.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return base + "&signature=" + encode(Data(mac).base64EncodedString())
    }

    /// Beijing time as the service wants it: "2025-09-04T15:38:07+0800".
    nonisolated static func beijingTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }

    /// Percent-encoding of everything but letters, digits and "-._~" (as Python's quote(safe='')).
    private nonisolated static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private nonisolated static let unreserved =
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: - Results

    /// One word's text: its first candidate, leaving out fillers ("s", a hesitation sound) and paragraph marks ("g").
    private static func word(_ entry: [String: Any]) -> String? {
        guard let best = (entry["cw"] as? [[String: Any]])?.first, let text = best["w"] as? String else { return nil }
        let kind = best["wp"] as? String ?? "n"
        return kind == "s" || kind == "g" ? nil : text
    }

    /// The words of a sentence as text: Chinese and punctuation run together; two Latin words get a space.
    nonisolated static func join(_ words: [String]) -> String {
        var text = ""
        for word in words where !word.isEmpty {
            if let last = text.unicodeScalars.last, let first = word.unicodeScalars.first,
               isLatin(last), isLatin(first) {
                text += " "
            }
            text += word
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
    }

    /// Which guidance a service code gets.
    private nonisolated static func failure(_ code: String) -> LiveWires.Failure {
        switch code {
        // Authentication, unknown or disabled app/key, key mismatch, bad or repeated signature.
        case "35001", "35004", "35005", "35010", "35017", "35019", "35030",
             "100002", "100013", "100016", "100020": return .key
        // The language is not supported or not enabled for this account.
        case "35020", "100018", "100019": return .model
        default: return .other
        }
    }

    /// An object, or a JSON object written as a string (the standard edition's "data").
    private static func object(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let string = value as? String, let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A string or number field as text; nil when missing or empty.
    private nonisolated static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return (value as? String).flatMap { Int($0) }
    }
}
