import Foundation

/// What a recognition service sends back, as `LiveSocketTranscriber` needs it.
public enum LiveEvent: Sendable, Equatable {
    /// The session is set up: audio may be sent (only for wires whose `waitsForReady` is true).
    case ready
    /// The words of the segment being spoken so far; replaces the previous draft.
    case draft(String)
    /// A segment's final words: added to what is settled, and the draft is cleared.
    case settled(String)
    /// The whole transcript so far, settled and draft together (for services that send all of it each time).
    case whole(String)
    /// Every final result has arrived: the session is over.
    case done
}

/// One recognition service's live socket: how to connect, how audio goes out, what comes back.
/// A class, so that a wire may keep what its protocol needs (a sequence number, a session id).
/// One wire serves one session.
@MainActor
public protocol LiveWire: AnyObject {
    /// The rate the PCM is sent at: 16-bit little-endian mono, 16000 or 24000 Hz. out records at
    /// 24000 Hz; for 16000 it is resampled first.
    var sampleRate: Int { get }
    /// Bytes of audio per piece handed to `audio(_:)`: 100 ms at the rate unless the service wants other.
    var chunkBytes: Int { get }
    /// Whether audio waits for `.ready`; otherwise it goes as soon as `opening` has been sent.
    var waitsForReady: Bool { get }
    /// Whether the socket closing by itself (normal closure) after `closing()` ends the session
    /// as `.done` would: for services that send no end event of their own.
    var closeEnds: Bool { get }
    /// The socket's request: its address, and the key in a header or in the query. May call the
    /// service first (a service that hands out a session address).
    func request(key: String, model: String, dictionary: [String]) async throws -> URLRequest
    /// Sent first, once the socket is open (a configuration); empty for none.
    func opening(key: String, model: String, dictionary: [String]) throws -> [URLSessionWebSocketTask.Message]
    /// One piece of audio, `chunkBytes` long (the last may be shorter).
    func audio(_ pcm: Data) throws -> [URLSessionWebSocketTask.Message]
    /// Sent after the last audio: asks for the final results and the end of the session.
    func closing() throws -> [URLSessionWebSocketTask.Message]
    /// What one message from the service means. An error the service reports is thrown as a
    /// `VoiceError` (see `LiveWires.failure`); a message that means nothing here gives `[]`.
    func read(_ message: URLSessionWebSocketTask.Message) throws -> [LiveEvent]
    /// Whether a probe that connects (and is answered `.ready` where the wire waits for it) proves
    /// the key: false where the key is only checked once audio or a later message has been sent.
    func provesKey(model: String) -> Bool
}

public extension LiveWire {
    var chunkBytes: Int { sampleRate / 10 * 2 }
    var waitsForReady: Bool { false }
    var closeEnds: Bool { false }
    func opening(key: String, model: String, dictionary: [String]) throws -> [URLSessionWebSocketTask.Message] { [] }
    func provesKey(model: String) -> Bool { true }
}

/// A service that takes the finished recording in a request of its own shape (not `/audio/transcriptions`).
@MainActor
public protocol FileWire: AnyObject {
    /// The whole request, body included. `wav` is 16-bit mono PCM at 24000 Hz in a WAV file.
    func request(key: String, model: String, dictionary: [String], wav: Data) async throws -> URLRequest
    /// The text from a 200 answer's body.
    func text(_ data: Data) throws -> String
}

/// The transcript as the events build it.
public struct LiveTranscript: Sendable {
    private var settled = ""
    private var draft = ""
    public private(set) var finished = false
    public init() {}

    public mutating func apply(_ event: LiveEvent) {
        switch event {
        case .ready: break
        case .draft(let text): draft = text
        case .settled(let text): settled = OpenAIWire.joinPieces(settled, text); draft = ""
        case .whole(let text): settled = text; draft = ""
        case .done: finished = true
        }
    }

    public var text: String { OpenAIWire.joinPieces(settled, draft).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Helpers the wires share.
public enum LiveWires {
    /// A key made of several parts, written with colons between them ("APP_ID:ACCESS_TOKEN"): the
    /// parts, or nil when there are not exactly `count` non-empty ones. The last part keeps any
    /// further colons.
    public static func parts(_ key: String, count: Int) -> [String]? {
        let pieces = key.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: count - 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard pieces.count == count, pieces.allSatisfy({ !$0.isEmpty }) else { return nil }
        return pieces
    }

    /// The guidance for an error a service reports. Its own message is never shown: it can carry
    /// credentials or dictated text.
    public enum Failure { case key, model, other }
    public static func failure(_ kind: Failure) -> VoiceError {
        switch kind {
        case .key: return VoiceError(tr("The API key is invalid. Update it in Settings."))
        case .model: return VoiceError(tr("This account cannot use the selected recognition model. Choose another in Settings."))
        case .other: return VoiceError(tr("Live speech recognition was interrupted. Check the network, model permissions and account balance."))
        }
    }

    /// A message's text, from a text or a data frame.
    public static func string(_ message: URLSessionWebSocketTask.Message) -> String {
        switch message {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    /// A message as a JSON object; nil when it is not one.
    public static func object(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A JSON object as a text frame.
    public static func json(_ object: [String: Any]) throws -> URLSessionWebSocketTask.Message {
        let data = try JSONSerialization.data(withJSONObject: object)
        return .string(String(decoding: data, as: UTF8.self))
    }
}

/// Recognition over a service's own live socket: the recording is streamed while it is being
/// made, the words arrive as drafts and settled segments, and `closing()` ends the session.
@MainActor
public final class LiveSocketTranscriber {
    private let wire: any LiveWire
    private let key: String
    /// The service's name, for messages.
    private let name: String
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var sender: Task<Void, Error>?
    private var watchdog: Task<Void, Never>?
    private var timedOut = false
    private var finishing = false
    private var sendError: Error?

    public init(wire: any LiveWire, key: String, name: String, session: URLSession = .shared) {
        self.wire = wire; self.key = key; self.name = name; self.session = session
    }

    public func run(audio: AsyncThrowingStream<Data, Error>, model: String, dictionary: [String],
                    onReady: @escaping () -> Void, onPartial: @escaping (String) -> Void) async throws -> String {
        deadline(seconds: 12)
        defer { cancel() }
        do {
            let socket = try await open(model: model, dictionary: dictionary)
            var transcript = LiveTranscript()
            if wire.waitsForReady {
                waiting: while true {
                    for event in try wire.read(try await socket.receive()) {
                        if event == .ready { break waiting }
                        transcript.apply(event)
                    }
                }
            }
            if finishing { deadline(seconds: 40) } else { watchdog?.cancel() }
            onReady()
            let wire = self.wire
            sender = Task {
                do {
                    var resampler = PCMResampler()
                    var pending = Data()
                    var bytes = 0
                    for try await chunk in audio {
                        try Task.checkCancellation()
                        bytes += chunk.count
                        pending.append(wire.sampleRate == 16000 ? resampler.process(chunk) : chunk)
                        while pending.count >= wire.chunkBytes {
                            let piece = pending.prefix(wire.chunkBytes)
                            pending.removeFirst(wire.chunkBytes)
                            for message in try wire.audio(Data(piece)) { try await socket.send(message) }
                        }
                    }
                    try Task.checkCancellation()
                    guard bytes >= 4800 else { throw VoiceError(tr("The recording is too short. Finish speaking before you stop.")) }
                    if !pending.isEmpty { for message in try wire.audio(pending) { try await socket.send(message) } }
                    self.finishDeadline()
                    for message in try wire.closing() { try await socket.send(message) }
                } catch {
                    self.sendError = error
                    socket.cancel(with: .goingAway, reason: nil)
                    throw error
                }
            }
            var shown = ""
            while true {
                try Task.checkCancellation()
                let message: URLSessionWebSocketTask.Message
                do { message = try await socket.receive() } catch {
                    // A service that ends by closing: what arrived before the close is the result.
                    if finishing, wire.closeEnds, !timedOut, sendError == nil, socket.closeCode == .normalClosure {
                        try await sender?.value
                        return transcript.text
                    }
                    throw error
                }
                // A long recording takes a while to come back; while messages keep arriving after
                // it ended, the connection is alive and the deadline moves with them.
                if finishing { deadline(seconds: 40) }
                for event in try wire.read(message) { transcript.apply(event) }
                if transcript.text != shown {
                    shown = transcript.text
                    onPartial(shown)
                }
                if transcript.finished {
                    try await sender?.value
                    return transcript.text
                }
            }
        } catch {
            throw failure(error, waiting: tr("%@ did not respond in time. The recording is kept on this Mac.", name))
        }
    }

    /// For Verify: connect and, where the service answers a configuration, wait up to 10 seconds
    /// for it to be accepted; otherwise a ping proves the connection (and the key, where it goes
    /// with the connection). No audio is sent.
    public static func probe(wire: any LiveWire, key: String, model: String, name: String,
                             session: URLSession = .shared) async throws {
        let client = LiveSocketTranscriber(wire: wire, key: key, name: name, session: session)
        defer { client.cancel() }
        client.deadline(seconds: 10)
        do {
            let socket = try await client.open(model: model, dictionary: [])
            if wire.waitsForReady {
                waiting: while true {
                    for event in try wire.read(try await socket.receive()) where event == .ready { break waiting }
                }
            } else {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                    socket.sendPing { error in
                        if let error { done.resume(throwing: error) } else { done.resume() }
                    }
                }
            }
        } catch {
            throw client.failure(error, waiting: tr("%@ did not respond in time. Check the network and the address.", name))
        }
    }

    public func finishDeadline() {
        finishing = true
        deadline(seconds: 40)
    }

    public func cancel() {
        watchdog?.cancel(); watchdog = nil
        sender?.cancel(); sender = nil
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    private func open(model: String, dictionary: [String]) async throws -> URLSessionWebSocketTask {
        let request = try await wire.request(key: key, model: model, dictionary: dictionary)
        try Task.checkCancellation()
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        if timedOut { socket.cancel(with: .goingAway, reason: nil) }
        for message in try wire.opening(key: key, model: model, dictionary: dictionary) { try await socket.send(message) }
        return socket
    }

    private func failure(_ error: Error, waiting: String) -> Error {
        if Task.isCancelled { return CancellationError() }
        if let http = socket?.response as? HTTPURLResponse, http.statusCode >= 400 {
            return OpenAIWire.serviceError(status: http.statusCode, data: Data(), name: name)
        }
        if timedOut { return VoiceError(waiting, retryable: true) }
        // The watchdog's own cancel can make the sender fail first, so this comes after timedOut.
        if let sendError { return sendError }
        if error is VoiceError { return error }
        return VoiceError(tr("The live connection was interrupted. The recording is kept on this Mac and will be transcribed once online."), retryable: true)
    }

    private func deadline(seconds: UInt64) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self else { return }
            self.timedOut = true
            self.socket?.cancel(with: .goingAway, reason: nil)
        }
    }
}

extension LiveSocketTranscriber: Transcriber {}

/// For services that take the finished recording their own way: waits for the recording to end,
/// sends it once, and returns the text.
@MainActor
public final class FileTranscriber: Transcriber {
    private let wire: any FileWire
    private let key: String
    private let name: String
    private let session: URLSession

    public init(wire: any FileWire, key: String, name: String, session: URLSession = .shared) {
        self.wire = wire; self.key = key; self.name = name; self.session = session
    }

    public var live: Bool { false }

    public func run(audio: AsyncThrowingStream<Data, Error>, model: String, dictionary: [String],
                    onReady: @escaping () -> Void, onPartial: @escaping (String) -> Void) async throws -> String {
        var pcm = Data()
        for try await chunk in audio {
            try Task.checkCancellation()
            pcm.append(chunk)
        }
        try Task.checkCancellation()
        guard pcm.count >= 4800 else { throw VoiceError(tr("The recording is too short. Finish speaking before you stop.")) }
        let request = try await wire.request(key: key, model: model, dictionary: dictionary, wav: OpenAIWire.wav(pcm: pcm))
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut {
                throw VoiceError(tr("%@ did not respond in time. The recording is kept on this Mac.", name), retryable: true)
            }
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw VoiceError(tr("The recognition response is invalid.")) }
        guard http.statusCode == 200 else { throw OpenAIWire.serviceError(status: http.statusCode, data: data, name: name) }
        return try wire.text(data).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func finishDeadline() {}
    public func cancel() {}
}
