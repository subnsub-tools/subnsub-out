import Foundation

/// Where recognition or tidying is sent. OpenAI is spoken to in its own way (audio streamed while
/// you speak, text through the Responses API), Alibaba Cloud Model Studio through its realtime
/// socket and `/chat/completions`. Every other platform is spoken to in the common
/// "OpenAI-compatible" way: the finished recording is uploaded to `/audio/transcriptions`, text
/// goes through `/chat/completions`.
public struct Platform: Equatable, Identifiable, Sendable {
    /// How a platform is spoken to.
    public enum Wire: Sendable, Equatable {
        /// OpenAI's realtime socket and the Responses API.
        case openAI
        /// The common way: one upload of the finished recording, and `/chat/completions`.
        case generic
        /// The Qwen-ASR-Realtime socket for recognition, `/chat/completions` for text.
        case alibaba
    }

    public let id: String
    /// The name in English: a brand, or what the service whose address the user types in is called.
    public let englishName: String
    /// Empty for the platform whose address the user types in.
    public let base: String
    /// Suggestions only, the first one being the default. The user may type any other model.
    public let speechModels: [String]
    public let textModels: [String]
    /// How this platform is spoken to.
    public let wire: Wire
    /// OpenAI itself: recognition streams over the realtime socket, text uses the Responses API.
    public var live: Bool { wire == .openAI }
    /// Whether the vocabulary may be sent along with the audio as a `prompt`.
    public let hints: Bool
    /// What a key looks like, or a note in English for a service that may need none.
    public let englishKeyHint: String

    /// The name as the user reads it, in the language chosen in Settings.
    public var name: String { tr(englishName) }
    /// Shown in the empty key field, in the language chosen in Settings.
    public var keyHint: String { tr(englishKeyHint) }

    public static let openAI = Platform(id: "openai", englishName: "OpenAI", base: "https://api.openai.com/v1",
        speechModels: ["gpt-live-transcribe", "gpt-transcribe", "gpt-4o-mini-transcribe"],
        textModels: ["gpt-4.1-mini", "gpt-4.1"], wire: .openAI, hints: true, englishKeyHint: "sk-…")
    /// Alibaba Cloud Model Studio: by default the Singapore region; the address can name another
    /// region or a workspace's own domain.
    public static let alibaba = Platform(id: "alibaba", englishName: "Alibaba Cloud Model Studio",
        base: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        speechModels: ["qwen3-asr-flash-realtime"], textModels: ["qwen3.8-flash", "qwen-plus"],
        wire: .alibaba, hints: true, englishKeyHint: "sk-…")
    public static let groq = Platform(id: "groq", englishName: "Groq", base: "https://api.groq.com/openai/v1",
        speechModels: ["whisper-large-v3-turbo", "whisper-large-v3"],
        textModels: ["openai/gpt-oss-120b", "llama-3.3-70b-versatile"], wire: .generic, hints: true, englishKeyHint: "gsk_…")
    public static let siliconFlow = Platform(id: "siliconflow", englishName: "SiliconFlow", base: "https://api.siliconflow.cn/v1",
        speechModels: ["FunAudioLLM/SenseVoiceSmall", "TeleAI/TeleSpeechASR"],
        textModels: ["deepseek-ai/DeepSeek-V4-Flash"], wire: .generic, hints: false, englishKeyHint: "sk-…")
    /// Any other service with the same interface: another cloud, a gateway, a model on this network.
    public static let custom = Platform(id: "custom", englishName: "Custom", base: "", speechModels: [], textModels: [],
        wire: .generic, hints: true, englishKeyHint: "leave empty if none is needed")

    public static let all = [openAI, alibaba, groq, siliconFlow, custom]

    /// OpenAI's model for finished recordings. It is sent the whole file rather than a stream:
    /// that is the call OpenAI documents for telling it which languages and words to expect.
    public static let fileModel = "gpt-transcribe"
    /// Whether this model is sent the recording while it is still being made.
    public func streams(model: String) -> Bool {
        switch wire {
        case .openAI: return model != Platform.fileModel
        case .alibaba: return true
        case .generic: return false
        }
    }

    /// A dictation saved before platforms existed names none; it was made for OpenAI.
    public static func named(_ id: String?) -> Platform { all.first { $0.id == id } ?? openAI }

    /// An address as people paste it: with a trailing slash, or with the full path of one call.
    /// Nil when it is not an https address with a host. Plain http is taken only for this Mac and
    /// machines named the way a private network names them — an IP address, a bare name, `.local` —
    /// which is also all that macOS lets an app reach without encryption.
    public static func normalized(base text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        for tail in ["/chat/completions", "/audio/transcriptions", "/responses", "/models"] where value.hasSuffix(tail) {
            value.removeLast(tail.count)
        }
        while value.hasSuffix("/") { value.removeLast() }
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = parts.host, !host.isEmpty,
              parts.query == nil, parts.fragment == nil, parts.user == nil, parts.password == nil else { return nil }
        if scheme == "http" && !isPrivateName(host) { return nil }
        return parts.url
    }

    static func isPrivateName(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".local") || name.contains(":") || !name.contains(".") { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in UInt8(part) != nil }
    }

    /// Whether what is sent to this address travels unencrypted beyond this Mac.
    public static func isPlain(_ base: URL) -> Bool {
        guard base.scheme?.lowercased() == "http" else { return false }
        let host = base.host?.lowercased() ?? ""
        return !(host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]")
    }

    /// Model Studio's address as people type or paste it: a bare host name, or an https address
    /// whose path and query are ignored — both calls live at fixed paths on the host. Empty is
    /// the Singapore region. Anything but https is refused: the key works only where it was made.
    public static func alibabaBase(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1") }
        let address = value.contains("://") ? value : "https://" + value
        guard let parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        var base = URLComponents()
        base.scheme = "https"
        base.host = host
        base.port = parts.port
        base.path = "/compatible-mode/v1"
        return base.url
    }

    /// The realtime socket for a model on this address: `wss://<host>/api-ws/v1/realtime`.
    public static func realtimeURL(base: URL, model: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "wss"
        parts.host = base.host
        parts.port = base.port
        parts.path = "/api-ws/v1/realtime"
        parts.queryItems = [URLQueryItem(name: "model", value: model)]
        return parts.url ?? base
    }

    public func baseURL(custom: String, alibaba: String = "") -> URL? {
        if wire == .alibaba { return Platform.alibabaBase(alibaba) }
        return base.isEmpty ? Platform.normalized(base: custom) : URL(string: base)
    }
}

/// A platform together with what it takes to call it now.
public struct Service: Sendable {
    public let platform: Platform
    public let base: URL
    /// May be empty for a custom service that asks for none.
    public let key: String
    public init(platform: Platform, base: URL, key: String) { self.platform = platform; self.base = base; self.key = key }

    func request(_ path: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = timeout
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// The models the platform lists for this key, or nil when it has no such list.
    public func models(session: URLSession = .shared) async throws -> [String]? {
        let (data, response) = try await session.data(for: request("models", timeout: 15))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 405 { return nil }
        guard status == 200 else { throw OpenAIWire.serviceError(status: status, data: data, name: platform.name) }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let list = object?["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["id"] as? String }
    }
}

/// Turns a recording into text. Two ways exist: while it is being made, or after it is finished.
@MainActor
public protocol Transcriber: AnyObject {
    func run(audio: AsyncThrowingStream<Data, Error>, model: String, dictionary: [String],
             onReady: @escaping () -> Void, onPartial: @escaping (String) -> Void) async throws -> String
    /// The recording has ended; an answer is now due within a bounded time.
    func finishDeadline()
    func cancel()
}

extension RealtimeTranscriber: Transcriber {}

/// For platforms that take a whole file: waits for the recording to end, uploads it once, and
/// returns the text. Nothing leaves this Mac while the recording is still being made.
@MainActor
public final class UploadTranscriber: Transcriber {
    private let service: Service
    private let session: URLSession

    public init(service: Service, session: URLSession = .shared) { self.service = service; self.session = session }

    public func run(audio: AsyncThrowingStream<Data, Error>, model: String, dictionary: [String],
                    onReady: @escaping () -> Void, onPartial: @escaping (String) -> Void) async throws -> String {
        var pcm = Data()
        for try await chunk in audio {
            try Task.checkCancellation()
            pcm.append(chunk)
        }
        try Task.checkCancellation()
        guard pcm.count >= 4800 else { throw VoiceError(tr("The recording is too short. Finish speaking before you stop.")) }
        let wav = OpenAIWire.wav(pcm: pcm)
        // OpenAI's file model is told the languages to expect and the user's words, each in a
        // field of its own. Every other model gets the words as a short prompt, where it takes one.
        var told = service.platform == .openAI && model == Platform.fileModel
        let prompt = told || !service.platform.hints ? "" : OpenAIWire.vocabularyPrompt(dictionary)
        while true {
            let boundary = "input-\(UUID().uuidString)"
            var request = service.request("audio/transcriptions", timeout: 120)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let body = OpenAIWire.transcriptionForm(wav: wav, model: model, prompt: prompt,
                languages: told ? OpenAIWire.spokenLanguages : [], keywords: told ? OpenAIWire.cleanDictionary(dictionary) : [],
                boundary: boundary)
            let data: Data, response: URLResponse
            do { (data, response) = try await session.upload(for: request, from: body) }
            catch {
                if Task.isCancelled { throw CancellationError() }
                if (error as? URLError)?.code == .timedOut {
                    throw VoiceError(tr("%@ did not respond in time. The recording is kept on this Mac.", service.platform.name), retryable: true)
                }
                throw error
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw VoiceError(tr("The recognition response is invalid.")) }
            // What it was told must never cost the dictation: refused with it, the recording is
            // sent once more without.
            if http.statusCode == 400, told { told = false; continue }
            guard http.statusCode == 200 else {
                throw OpenAIWire.serviceError(status: http.statusCode, data: data, name: service.platform.name)
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let text = object["text"] as? String else { throw VoiceError(tr("Cannot read the recognition result.")) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // The upload is one request with its own time limit, and ends when the task around it is cancelled.
    public func finishDeadline() {}
    public func cancel() {}
}

public extension OpenAIWire {
    /// The recording as a WAV file: 16-bit mono PCM at the rate it was captured.
    static func wav(pcm: Data, rate: UInt32 = 24000) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var data = Data("RIFF".utf8)
        data += le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
        data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(rate) + le(rate * 2) + le(UInt16(2)) + le(UInt16(16))
        data += Data("data".utf8) + le(UInt32(pcm.count))
        return data + pcm
    }

    /// The vocabulary as a recognition hint. Whisper-style models read only a short prompt (Groq:
    /// 224 tokens), so words are taken in order while a cautious estimate of their size fits:
    /// a third of a token for a Latin letter, two tokens for any other character.
    static func vocabularyPrompt(_ dictionary: [String], budget: Int = 180) -> String {
        var kept: [String] = [], cost = 0
        for word in cleanDictionary(dictionary) {
            let size = word.unicodeScalars.reduce(2) { $0 + ($1.isASCII ? 1 : 6) }
            let tokens = (size + 2) / 3
            if cost + tokens > budget { break }
            cost += tokens; kept.append(word)
        }
        return kept.joined(separator: ", ")
    }

    /// What dictation here is spoken in: Chinese with English terms mixed in.
    static let spokenLanguages = ["zh", "en"]

    static func transcriptionForm(wav: Data, model: String, prompt: String, languages: [String] = [],
                                  keywords: [String] = [], boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        field("model", model)
        if !prompt.isEmpty { field("prompt", prompt) }
        for language in languages { field("languages[]", language) }
        for keyword in keywords { field("keywords[]", keyword) }
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body += wav
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        return body
    }

    /// The same request as `responseBody`/`revisionBody` builds, in the shape `/chat/completions` takes.
    static func chatBody(_ body: [String: Any], platform: Platform) -> [String: Any] {
        var chat: [String: Any] = ["model": body["model"] ?? "", "stream": false, "max_tokens": 8192, "messages": [
            ["role": "system", "content": body["instructions"] ?? ""],
            ["role": "user", "content": body["input"] ?? ""]
        ]]
        // Model Studio's models think by default; the answer itself is all that is wanted.
        if platform.wire == .alibaba { chat["enable_thinking"] = false }
        return chat
    }

    /// Some Model Studio models refuse the `enable_thinking` parameter itself (400, "The model …
    /// does not support enable_thinking"); the caller asks the same question once more without it.
    static func rejectsThinkingSwitch(status: Int, data: Data) -> Bool {
        status == 400 && String(decoding: data, as: UTF8.self).lowercased().contains("enable_thinking")
    }

    static func chatText(_ object: [String: Any]) throws -> String {
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { throw VoiceError(tr("Cannot read the text polishing result.")) }
        // A reply cut off at the length limit must never be pasted as if it were whole.
        if choice["finish_reason"] as? String == "length" {
            throw VoiceError(tr("Text polishing did not return a complete result. The original transcript is kept."))
        }
        var text = (choice["message"] as? [String: Any])?["content"] as? String ?? ""
        // Some models write their reasoning into the answer itself.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>"), let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw VoiceError(tr("The model returned no usable text. The original transcript is kept.")) }
        return text
    }
}
