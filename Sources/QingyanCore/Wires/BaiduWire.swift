import Foundation

/// Baidu AI Cloud real-time speech recognition over WebSocket.
///
/// qianfan-asr-v1, the large model (the real-time large model, current, updated 2026-11-19):
/// https://cloud.baidu.com/doc/SPEECH/s/rmwdj6ina
/// wss://aip.baidubce.com/ws/2.0/speech/publiccloudspeech/v1/asr, the API key in
/// "Authorization: Bearer bce-v3/ALTAK-…", START {"model", "format", "sample"}.
///
/// The numbered models are the older dev_pid engines (the real-time WebSocket API):
/// https://cloud.baidu.com/doc/SPEECH/s/jlbxejt2i
/// wss://vop.baidu.com/realtime_asr, the app's AppID and API Key inside START with the dev_pid.
///
/// Both: START (text) -> binary PCM, 16 kHz, 160 ms pieces -> FINISH (text). MID_TEXT is the sentence
/// so far, FIN_TEXT its final text (or a per-sentence error); the service closes when all is sent.
/// There is no signature to compute: the key goes in a header or in START.
@MainActor
public final class BaiduWire: LiveWire {
    /// qianfan-asr-v1: the large model, Chinese, English, dialects and other languages.
    /// 15372: Mandarin with full punctuation. 1537: Mandarin, light punctuation. 15376: Chinese dialects
    /// (Mandarin, Cantonese, Sichuanese, Northeastern). 17372: English with punctuation.
    public nonisolated static let models = ["qianfan-asr-v1", "15372", "1537", "15376", "17372"]
    /// The large model takes an API key (API Key management); the dev_pid models take AppID:API Key.
    public nonisolated static let keyFormat = "bce-v3/ALTAK-\u{2026} | APP_ID:API_KEY"

    public let sampleRate = 16000
    /// 160 ms at 16 kHz, the size the docs call best (each piece 20-200 ms).
    public let chunkBytes = 5120
    /// After FINISH the service sends the remaining results and closes; it sends no end message.
    public let closeEnds = true

    public init() {}

    /// The large model's key goes with the connection; a dev_pid model's is read from START, after it.
    public func provesKey(model: String) -> Bool { model == "qianfan-asr-v1" }

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        // The dictionary is not used: custom vocabulary needs a model trained on Baidu's
        // self-training platform (lm_id), not inline words.
        let sn = UUID().uuidString.lowercased()
        if Int(model) != nil {
            guard Self.appCredentials(key) != nil, let url = URL(string: "wss://vop.baidu.com/realtime_asr?sn=\(sn)") else {
                throw LiveWires.failure(.key)
            }
            return URLRequest(url: url)
        }
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // AppID:API Key works only with the dev_pid models.
        guard !token.isEmpty, !token.contains(where: \.isWhitespace), Self.appCredentials(token) == nil,
              let url = URL(string: "wss://aip.baidubce.com/ws/2.0/speech/publiccloudspeech/v1/asr?sn=\(sn)") else {
            throw LiveWires.failure(.key)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    public func opening(key: String, model: String, dictionary: [String]) throws -> [URLSessionWebSocketTask.Message] {
        var data: [String: Any] = ["format": "pcm", "sample": 16000]
        if let pid = Int(model) {
            guard let (appID, appKey) = Self.appCredentials(key) else { throw LiveWires.failure(.key) }
            data["appid"] = appID
            data["appkey"] = appKey
            data["dev_pid"] = pid
            // Only counted for statistics; a fixed value says nothing about the Mac.
            data["cuid"] = "out"
            // The dialect model requires a user field; any value does.
            if pid == 15376 { data["user"] = "out" }
        } else {
            data["model"] = model.isEmpty ? Self.models[0] : model
        }
        return [try LiveWires.json(["type": "START", "data": data])]
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] { [.data(pcm)] }

    public func closing() throws -> [URLSessionWebSocketTask.Message] { [try LiveWires.json(["type": "FINISH"])] }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let root = LiveWires.object(message) else { return [] }
        switch Self.number(root["err_no"]) ?? 0 {
        case 0: break
        // One sentence failed (no valid speech, a backend error); the rest is still recognized.
        case -3003, -3005, -3013: return [.draft("")]
        // Cancelled: only after a CANCEL frame, which is never sent.
        case -3014: return []
        // Authentication failed (wrong AppID or API Key, or no permission).
        case -3004: throw LiveWires.failure(.key)
        // A wrong START parameter, such as the model.
        case -3008: throw LiveWires.failure(.model)
        // Server VAD error, stream setup failure, no audio for too long.
        default: throw LiveWires.failure(.other)
        }
        let text = (root["result"] as? String) ?? (root["result"] as? [String])?.first ?? ""
        switch root["type"] as? String {
        case "MID_TEXT": return [.draft(text)]
        case "FIN_TEXT": return [text.isEmpty ? .draft("") : .settled(text)]
        default: return []  // HEARTBEAT, every 5 s
        }
    }

    /// "APP_ID:API_KEY" with a numeric AppID, as the dev_pid START frame needs; nil otherwise.
    private static func appCredentials(_ key: String) -> (Int, String)? {
        guard let parts = LiveWires.parts(key, count: 2), let appID = Int(parts[0]) else { return nil }
        return (appID, parts[1])
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return (value as? String).flatMap { Int($0) }
    }
}
