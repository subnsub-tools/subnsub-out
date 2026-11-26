import Foundation

/// Fun-ASR real-time recognition on Alibaba Cloud Model Studio, over DashScope's inference
/// WebSocket: run-task, binary audio, finish-task; task-started, result-generated, task-finished,
/// task-failed.
/// https://help.aliyun.com/en/model-studio/fun-asr-realtime-websocket-api
/// https://help.aliyun.com/en/model-studio/fun-asr-client-events
/// https://help.aliyun.com/en/model-studio/fun-asr-server-events
@MainActor
public final class FunASRWire: LiveWire {
    /// The stable model, then the newest snapshot (Beijing only; it takes no context, so no
    /// dictionary). Singapore offers `fun-asr-realtime` alone.
    public nonisolated static let models = ["fun-asr-realtime", "fun-asr-realtime-2026-02-28"]
    /// A Model Studio API key for the region of `host`.
    public nonisolated static let keyFormat = "sk-\u{2026}"

    /// Any rate is taken except by the 8 kHz models, so the recording goes as it is.
    public let sampleRate = 24000
    /// 100 ms, the docs' chunk and send interval.
    public let chunkBytes = 4800
    /// Audio may go only after task-started.
    public let waitsForReady = true

    /// e.g. "dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com" or a workspace domain such as
    /// "<WorkspaceId>.cn-beijing.maas.aliyuncs.com".
    private let host: String
    private var taskID = ""

    /// `host` may also be a whole base URL ("https://dashscope.aliyuncs.com/compatible-mode/v1"):
    /// only its host is kept, as the docs' own examples do.
    public init(host: String) {
        let text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = URLComponents(string: text.contains("://") ? text : "wss://" + text)?.host ?? ""
    }

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LiveWires.failure(.key) }
        guard !host.isEmpty, let url = URL(string: "wss://\(host)/api-ws/v1/inference") else {
            throw LiveWires.failure(.other)
        }
        var request = URLRequest(url: url)
        // Checked in the handshake: a bad key fails it with HTTP 401 or 403.
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func opening(key: String, model: String, dictionary: [String]) throws -> [URLSessionWebSocketTask.Message] {
        taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let model = model.isEmpty ? Self.models[0] : model
        // Punctuation and number formatting are built in. No `language_hints`: unset, the model
        // detects the language itself, which suits Chinese with English terms.
        let parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": sampleRate,
            "heartbeat": true,   // keeps the task alive through long silences
        ]
        // Hotwords proper need a vocabulary created beforehand (vocabulary_id), so they are not
        // used; the documented inline alternative is context, which may be a word list.
        var input: [String: Any] = [:]
        if model == "fun-asr-realtime", let words = Self.context(dictionary) {
            input["context"] = [["role": "user", "content": [["type": "input_text", "text": words]]]]
        }
        return [try LiveWires.json([
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio", "task": "asr", "function": "recognition", "model": model,
                "parameters": parameters, "input": input,
            ] as [String: Any],
        ])]
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        [.data(pcm)]
    }

    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        [try LiveWires.json([
            "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["input": [String: Any]()],
        ])]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard let object = LiveWires.object(message), let header = object["header"] as? [String: Any] else { return [] }
        switch header["event"] as? String {
        case "task-started":
            return [.ready]
        case "task-finished":
            return [.done]
        case "task-failed":
            throw LiveWires.failure(Self.failure(header["error_code"] as? String ?? ""))
        case "result-generated":
            guard let payload = object["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  sentence["heartbeat"] as? Bool != true,
                  let text = sentence["text"] as? String else { return [] }
            // Each result is the current sentence so far; sentence_end marks its final words.
            guard sentence["sentence_end"] as? Bool == true, !text.isEmpty else { return [.draft(text)] }
            return [.settled(text)]
        default:
            return []
        }
    }

    /// The dictionary as one context text, within the 400 characters a turn may hold (the service
    /// cuts the rest from the end); nil when empty.
    static func context(_ dictionary: [String]) -> String? {
        var text = ""
        for word in OpenAIWire.cleanDictionary(dictionary) {
            let next = text.isEmpty ? word : text + ", " + word
            if next.count > 400 { continue }
            text = next
        }
        return text.isEmpty ? nil : text
    }

    /// Model Studio's error codes (https://help.aliyun.com/zh/model-studio/error-code) as guidance.
    static func failure(_ code: String) -> LiveWires.Failure {
        let code = code.lowercased()
        if code.contains("apikey") || code.contains("api_key") { return .key }   // InvalidApiKey
        // Model.AccessDenied, AccessDenied.Unpurchased, Workspace.AccessDenied, ModelNotFound, ModelUnavailable
        if ["accessdenied", "access_denied", "notfound", "not_found", "modelunavailable"].contains(where: code.contains) {
            return .model
        }
        return .other   // Arrearage, Throttling.*, InvalidParameter, CLIENT_ERROR (timeout) ...
    }
}
