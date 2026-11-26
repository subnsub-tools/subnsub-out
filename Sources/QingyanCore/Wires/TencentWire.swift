import CryptoKit
import Foundation

/// Tencent Cloud real-time speech recognition over WebSocket:
/// https://cloud.tencent.com/document/product/1093/48982 (engines 16k_zh_en, 16k_zh, Hy-ASR-3.0-preview)
/// https://cloud.tencent.com/document/product/1093/131127 (V2, same address: 16k_zh_en_2.0)
///
/// Flow: signed address -> {"code":0,"message":"success","voice_id":…} -> binary PCM, 16 kHz,
/// 200 ms pieces -> {"type":"end"} -> results until one has "final": 1, then the service closes.
/// Each result is the current sentence: slice_type 0 (started) and 1 (in progress) replace the draft,
/// 2 is its final text. The 2.0 engines may answer in sentence lists instead; both shapes are read.
@MainActor
public final class TencentWire: LiveWire {
    /// engine_model_type. 16k_zh_en: Chinese, English and dialects, large model 1.0 (no stated session
    /// limit). 16k_zh_en_2.0: the same in large model 2.0 (billed on the 2.0 price list). 16k_zh: the
    /// general Mandarin engine. Hy-ASR-3.0-preview: newest, but a preview capped at 5 minutes of audio.
    public nonisolated static let models = ["16k_zh_en", "16k_zh_en_2.0", "16k_zh", "Hy-ASR-3.0-preview"]
    /// APPID from the account centre, SecretId and SecretKey from API key management.
    public nonisolated static let keyFormat = "APP_ID:SECRET_ID:SECRET_KEY"

    public let sampleRate = 16000
    /// 200 ms at 16 kHz, as the docs recommend (sent at 1:1 real time).
    public let chunkBytes = 6400
    /// The handshake answer (code 0) is documented; a bad signature answers with code 4002 instead.
    public let waitsForReady = true

    private nonisolated static let host = "asr.cloud.tencent.com/asr/v2/"
    private var ready = false
    /// The last sentence_id taken as final in sentence lists.
    private var settledSentence = -1

    public init() {}

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        guard let parts = LiveWires.parts(key, count: 3), UInt64(parts[0]) != nil else { throw LiveWires.failure(.key) }
        let now = Int(Date().timeIntervalSince1970)
        var query = [
            "secretid": parts[1],
            "timestamp": String(now),
            "expired": String(now + 24 * 3600),
            "nonce": String(Int.random(in: 1...999_999_999)),
            "engine_model_type": model.isEmpty ? Self.models[0] : model,
            // A new voice_id for every connection, as required.
            "voice_id": UUID().uuidString.lowercased(),
            "voice_format": "1",  // PCM
            // Voice activity detection splits long speech into sentences (otherwise cut at 60 s).
            "needvad": "1",
            // Filter some filler words (hesitation sounds).
            "filter_modal": "1",
        ]
        let hotwords = Self.hotwords(dictionary)
        if !hotwords.isEmpty { query["hotword_list"] = hotwords }
        guard let url = URL(string: Self.address(appID: parts[0], query: query, secretKey: parts[2])) else {
            throw LiveWires.failure(.key)
        }
        return URLRequest(url: url)
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] { [.data(pcm)] }

    public func closing() throws -> [URLSessionWebSocketTask.Message] { [try LiveWires.json(["type": "end"])] }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let root = LiveWires.object(message) else { return [] }
        let code = Self.number(root["code"]) ?? 0
        if code != 0 { throw LiveWires.failure(Self.failure(code)) }
        var events: [LiveEvent] = []
        if let result = root["result"] as? [String: Any] {
            let text = result["voice_text_str"] as? String ?? ""
            if Self.number(result["slice_type"]) == 2 {
                events.append(text.isEmpty ? .draft("") : .settled(text))
            } else {
                events.append(.draft(text))
            }
        }
        if let sentences = root["sentences"] { events += sentenceEvents(sentences) }
        if Self.number(root["final"]) == 1 { events.append(.done) }
        // The first answer with code 0 is the handshake's (audio waits for it, so no result comes first).
        if !ready {
            ready = true
            return events + [.ready]
        }
        return events
    }

    /// The 2.0 engines' results, as the official Python SDK reads them:
    /// {"sentences": {"sentence_list": [{"sentence", "sentence_type" (0 in progress, 1 final), "sentence_id"}]}}.
    /// A list may repeat sentences already settled; those are skipped by sentence_id.
    private func sentenceEvents(_ value: Any) -> [LiveEvent] {
        let list: [[String: Any]]
        if let object = value as? [String: Any] {
            list = object["sentence_list"] as? [[String: Any]] ?? [object]
        } else {
            list = value as? [[String: Any]] ?? []
        }
        var events: [LiveEvent] = []
        var draft: String?
        for item in list {
            let text = item["sentence"] as? String ?? ""
            let id = Self.number(item["sentence_id"]) ?? settledSentence + 1
            guard id > settledSentence else { continue }
            if Self.number(item["sentence_type"]) == 1 {
                settledSentence = id
                events.append(text.isEmpty ? .draft("") : .settled(text))
                draft = nil
            } else {
                draft = text
            }
        }
        if let draft { events.append(.draft(draft)) }
        return events
    }

    // MARK: - Signing

    /// The signed address: wss:// + host/path/APPID + "?" + parameters sorted by name with
    /// percent-encoded values, and the percent-encoded signature last.
    nonisolated static func address(appID: String, query: [String: String], secretKey: String) -> String {
        let pairs = query.sorted { $0.key < $1.key }.map { "\($0.key)=\(encode($0.value))" }.joined(separator: "&")
        return "wss://\(host)\(appID)?\(pairs)&signature=\(encode(signature(appID: appID, query: query, secretKey: secretKey)))"
    }

    /// Base64(HMAC-SHA1(SecretKey, host/path/APPID + "?" + parameters sorted by name, values unencoded)).
    /// The documented example (48982, the signature section), with its masked values as given:
    /// "asr.cloud.tencent.com/asr/v2/125922***?engine_model_type=16k_zh&expired=1673494772&needvad=1
    /// &nonce=1673408372&secretid=*****Qq1zhZMN8dv0******&timestamp=1673408372&voice_format=1
    /// &voice_id=c64385ee-3e5c-4fc5-bbfd-7c71addb35b0" with SecretKey "*****SkqpeHgqmSz*****"
    /// -> "G8jDQBRg1JfeBi/YnTjyjekxfDA=" (verified with a scratch script).
    nonisolated static func signature(appID: String, query: [String: String], secretKey: String) -> String {
        let original = host + appID + "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(original.utf8), using: SymmetricKey(data: Data(secretKey.utf8)))
        return Data(mac).base64EncodedString()
    }

    /// Percent-encoding of everything but letters, digits and "-._~" (as the SDK's quote(safe='')),
    /// so "+", "/" and "=" in the signature are encoded, as the docs require.
    private nonisolated static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private nonisolated static let unreserved =
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: - Helpers

    /// The personal dictionary as a temporary hotword list, "word|10,word|10": at most 128 words, each
    /// without spaces, commas or bars and at most 30 bytes (10 Chinese characters). Words that do not
    /// fit are left out rather than changed.
    static func hotwords(_ words: [String]) -> String {
        OpenAIWire.cleanDictionary(words)
            .filter { word in
                !word.isEmpty && word.utf8.count <= 30
                    && !word.contains { $0.isWhitespace || $0 == "," || $0 == "|" }
            }
            .prefix(128)
            .map { "\($0)|10" }
            .joined(separator: ",")
    }

    /// Which guidance a service code gets.
    private nonisolated static func failure(_ code: Int) -> LiveWires.Failure {
        switch code {
        case 4002: return .key  // authentication failed (signature, SecretId, expiry)
        case 4001, 4003: return .model  // invalid parameter (such as the engine), service not enabled
        default: return .other  // balance, concurrency, audio timing, server load, region
        }
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return (value as? String).flatMap { Int($0) }
    }
}
