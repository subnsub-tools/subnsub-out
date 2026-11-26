import Foundation

/// Doubao streaming speech recognition (Volcengine "bigmodel" / Seed-ASR) over its binary WebSocket
/// protocol, on the optimized bidirectional endpoint (`bigmodel_async`) with two-pass recognition:
/// live text while speaking, and each finished sentence recognized again by the non-streaming model.
/// Protocol: https://www.volcengine.com/docs/6561/1354869
/// Parameters: https://www.volcengine.com/docs/6561/2630027
@MainActor
public final class VolcengineWire: LiveWire {
    /// `X-Api-Resource-Id` values: Seed-ASR 2.0 (recommended for new users), then 1.0; hourly plan
    /// first, concurrent plan second. The account must have bought the one chosen.
    public nonisolated static let models = ["volc.seedasr.sauc.duration", "volc.seedasr.sauc.concurrent",
                                "volc.bigasr.sauc.duration", "volc.bigasr.sauc.concurrent"]
    /// Old console: App ID and Access Token. A new-console API Key on its own (no colon) works too.
    public nonisolated static let keyFormat = "APP_ID:ACCESS_TOKEN"

    /// The service takes 16 kHz only.
    public let sampleRate = 16000
    /// 200 ms: the docs' best packet size for bidirectional streaming.
    public let chunkBytes = 6400
    /// The server answers the full client request (an empty result) before any audio.
    public let waitsForReady = true

    private static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    /// The next frame's sequence number: 1 is the full client request, audio follows from 2.
    private var sequence: Int32 = 1
    private var ready = false

    public init() {}

    public func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parts = LiveWires.parts(key, count: 2) {
            request.setValue(parts[0], forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(parts[1], forHTTPHeaderField: "X-Api-Access-Key")
        } else if !key.isEmpty, !key.contains(":") {
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        } else {
            throw LiveWires.failure(.key)
        }
        request.setValue(model.isEmpty ? Self.models[0] : model, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Api-Connect-Id")
        return request
    }

    /// The full client request: audio format and recognition options, as uncompressed JSON.
    public func opening(key: String, model: String, dictionary: [String]) throws -> [URLSessionWebSocketTask.Message] {
        sequence = 1
        ready = false
        var options: [String: Any] = [
            "model_name": "bigmodel",
            "enable_punc": true,
            "enable_itn": true,          // spoken numbers, dates and amounts as digits
            "enable_nonstream": true,    // second pass; only its sentences come back as definite
            "show_utterances": true,     // sentences, each with `definite`
            "result_type": "full",       // every result carries the whole transcript so far
        ]
        // No `language`: the endpoint has none; its default model covers Chinese, English and mixes.
        if let context = Self.hotwords(dictionary) { options["corpus"] = ["context": context] }
        let body: [String: Any] = [
            "user": ["uid": "out"],
            "audio": ["format": "pcm", "codec": "raw", "rate": sampleRate, "bits": 16, "channel": 1],
            "request": options,
        ]
        let json = try JSONSerialization.data(withJSONObject: body)
        return [.data(frame(type: 0b0001, serialization: 0b0001, payload: json))]
    }

    public func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message] {
        [.data(frame(type: 0b0010, serialization: 0, payload: pcm))]
    }

    /// The last packet must be marked as such. The audio has all gone by now, so it is 20 ms of
    /// silence: the docs never show an empty last packet.
    public func closing() throws -> [URLSessionWebSocketTask.Message] {
        [.data(frame(type: 0b0010, serialization: 0, payload: Data(count: 640), last: true))]
    }

    public func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent] {
        guard case .data(let data) = message, let frame = Self.parse(data) else { return [] }
        // Error frame: a 4-byte code (45000001 bad parameters, 45000081 waited too long for audio,
        // 550xxxxx service side); key and plan problems fail the handshake itself instead.
        if frame.type == 0b1111 { throw LiveWires.failure(.other) }
        guard frame.type == 0b1001 else { return [] }
        var events: [LiveEvent] = []
        if let payload = frame.payload,
           let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
           let result = (object["result"] as? [String: Any]) ?? (object["result"] as? [[String: Any]])?.first {
            events += Self.events(result)
        }
        // The first response answers the full client request; anything after `.ready` would be
        // dropped while waiting for it, so it goes last.
        if !ready {
            ready = true
            events.append(.ready)
        }
        if frame.last { events.append(.done) }
        return events
    }

    // MARK: Protocol

    /// One client frame, all integers big-endian: header (version 1, 4-byte header; message type and
    /// flags; serialization and compression, here none; reserved), sequence number, payload size,
    /// payload. The last audio frame has flags 0b0011 and the sequence number negated.
    func frame(type: UInt8, serialization: UInt8, payload: Data, last: Bool = false) -> Data {
        let number = last ? -sequence : sequence
        sequence += 1
        var data = Data([0x11, type << 4 | (last ? 0b0011 : 0b0001), serialization << 4, 0x00])
        withUnsafeBytes(of: number.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    struct Frame {
        var type: UInt8
        /// Flags bit 1: the final response.
        var last: Bool
        /// Error frames only.
        var code: UInt32
        /// Decompressed; nil when gzip did not inflate.
        var payload: Data?
    }

    /// A server frame: header, sequence number (when flagged), event number (when flagged), the
    /// error code for error frames, payload size, payload. Nil when it is too short to be one.
    static func parse(_ data: Data) -> Frame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let type = bytes[1] >> 4, flags = bytes[1] & 0x0F
        var at = Int(bytes[0] & 0x0F) * 4
        func word() -> UInt32? {
            guard at >= 4, at + 4 <= bytes.count else { return nil }
            defer { at += 4 }
            return bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        if flags & 0b0001 != 0, word() == nil { return nil }
        if flags & 0b0100 != 0, word() == nil { return nil }
        var code: UInt32 = 0
        if type == 0b1111 {
            guard let value = word() else { return nil }
            code = value
        }
        guard let size = word() else { return nil }
        var payload: Data? = Data(bytes[at..<min(bytes.count, at + Int(size))])
        // The server answers in the client's compression (none), but takes gzip in its stride.
        if bytes[2] & 0x0F == 0b0001, let packed = payload { payload = gunzip(packed) }
        return Frame(type: type, last: flags & 0b0010 != 0, code: code, payload: payload)
    }

    /// A gzip member's contents (RFC 1952), inflated by Foundation's raw DEFLATE decoder; nil when
    /// it is not one.
    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        var at = 10
        if b[3] & 0x04 != 0 { at += 2 + (Int(b[10]) | Int(b[11]) << 8) }   // extra field
        for flag: UInt8 in [0x08, 0x10] where b[3] & flag != 0 {           // name, comment
            while at < b.count, b[at] != 0 { at += 1 }
            at += 1
        }
        if b[3] & 0x02 != 0 { at += 2 }                                     // header checksum
        guard at < b.count - 8 else { return nil }
        return try? (Data(b[at..<b.count - 8]) as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: Results and dictionary

    /// The transcript in a result: the leading definite sentences as settled text, the rest as the
    /// draft. Without sentences, the whole text.
    static func events(_ result: [String: Any]) -> [LiveEvent] {
        let utterances = result["utterances"] as? [[String: Any]] ?? []
        guard !utterances.isEmpty else {
            guard let text = result["text"] as? String else { return [] }
            return [.whole(text)]
        }
        var settled = "", draft = "", open = false
        for utterance in utterances {
            guard let text = utterance["text"] as? String, !text.isEmpty else { continue }
            if !open, utterance["definite"] as? Bool == true {
                settled = OpenAIWire.joinPieces(settled, text)
            } else {
                open = true
                draft = OpenAIWire.joinPieces(draft, text)
            }
        }
        return [.whole(settled), .draft(draft)]
    }

    /// The personal dictionary as `corpus.context`, a JSON string {"hotwords":[{"word":...}]}, kept
    /// within the bidirectional limit of 100 tokens (hotwords and context together; the service
    /// cuts the excess from the end); nil when empty.
    static func hotwords(_ dictionary: [String]) -> String? {
        var budget = 100
        var words: [[String: String]] = []
        for word in OpenAIWire.cleanDictionary(dictionary) {
            let cost = tokens(word)
            guard cost <= budget else { continue }
            budget -= cost
            words.append(["word": word])
        }
        guard !words.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["hotwords": words]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A generous token estimate, as the tokenizer is not published: one per CJK character or
    /// symbol, one per started 3 letters or digits of a Latin word.
    static func tokens(_ word: String) -> Int {
        var count = 0, run = 0
        for scalar in word.unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
                run += 1
                continue
            }
            count += (run + 2) / 3
            run = 0
            if !scalar.properties.isWhitespace { count += 1 }
        }
        return count + (run + 2) / 3
    }
}
