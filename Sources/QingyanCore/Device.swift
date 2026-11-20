import CryptoKit
import Foundation
import Network

/// What makes this copy of the app this Mac and no other: a key pair made on first launch.
/// The public half is the Mac's identity to every other Mac; the private half never leaves it.
public struct DeviceIdentity: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

    /// From the bytes `saved` returned earlier.
    public init?(saved: Data) {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: saved) else { return nil }
        privateKey = key
    }

    public var saved: Data { privateKey.rawRepresentation }
    public var publicKey: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    /// Six digits both people can compare when two Macs pair: the same on both screens only if
    /// nobody stands in between pretending to be the other Mac.
    public static func checkCode(_ a: String, _ b: String) -> String {
        let digest = SHA256.hash(data: Data(([a, b].sorted().joined(separator: "|")).utf8))
        let number = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06d", number)
        return digits.prefix(3) + " " + digits.suffix(3)
    }
}

/// A Mac this one trusts, known by its key. What it may do here is set per Mac.
public struct TrustedDevice: Codable, Equatable, Identifiable, Sendable {
    /// The other Mac's public key. This, not its name or address, is who it is.
    public var key: String
    public var id: String { key }
    public var name: String
    /// Where it was last reached. Empty when it has only ever called this Mac.
    public var host: String
    public var port: Int
    /// It may put text at this Mac's cursor.
    public var canWrite = true
    /// It shares the shelf with this Mac.
    public var canShelf = true
    /// It may read the text field at this Mac's cursor, for spoken editing.
    public var canRead = true

    public init(key: String, name: String, host: String, port: Int) {
        self.key = key; self.name = name; self.host = host; self.port = port
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? RemoteWire.defaultPort
        canWrite = try values.decodeIfPresent(Bool.self, forKey: .canWrite) ?? true
        canShelf = try values.decodeIfPresent(Bool.self, forKey: .canShelf) ?? true
        canRead = try values.decodeIfPresent(Bool.self, forKey: .canRead) ?? true
    }

    public var reachable: Bool { !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && RemoteWire.validPort(port) }
    public var label: String { name.isEmpty ? (host.isEmpty ? tr("Unnamed Mac") : host) : name }
}

/// An encrypted connection between two copies of the app that have proved who they are.
///
/// Each side sends its identity key and a fresh one-time key in the clear. The session keys are
/// derived from three Diffie-Hellman results — one-time with one-time, and each side's identity
/// with the other's one-time key — so only the holders of both identity keys can read or write
/// the frames that follow, and a recording of the traffic stays unreadable even if an identity
/// key leaks later. Every frame after the hello is sealed and numbered; one changed, replayed,
/// dropped or reordered frame ends the connection.
final class Channel: @unchecked Sendable {
    let connection: NWConnection
    /// The other Mac's identity, proven by the handshake.
    let peerKey: String
    let peerName: String
    /// The port the other Mac listens on, as it said; for calling it back.
    let peerPort: Int
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private let lock = NSLock()

    private init(connection: NWConnection, peerKey: String, peerName: String, peerPort: Int, sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.connection = connection; self.peerKey = peerKey; self.peerName = peerName; self.peerPort = peerPort
        self.sendKey = sendKey; self.receiveKey = receiveKey
    }

    private static func keys(identity: DeviceIdentity, oneTime: Curve25519.KeyAgreement.PrivateKey, peerIdentity: Data, peerOneTime: Data,
                             initiator: Bool) throws -> (toResponder: SymmetricKey, toInitiator: SymmetricKey) {
        let theirIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerIdentity)
        let theirOneTime = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerOneTime)
        let both = try oneTime.sharedSecretFromKeyAgreement(with: theirOneTime)
        // The initiator's identity with the responder's one-time key, and the other way round.
        let mine = try identity.privateKey.sharedSecretFromKeyAgreement(with: theirOneTime)
        let theirs = try oneTime.sharedSecretFromKeyAgreement(with: theirIdentity)
        var material = Data()
        both.withUnsafeBytes { material.append(contentsOf: $0) }
        (initiator ? mine : theirs).withUnsafeBytes { material.append(contentsOf: $0) }
        (initiator ? theirs : mine).withUnsafeBytes { material.append(contentsOf: $0) }
        let myIdentity = identity.privateKey.publicKey.rawRepresentation, myOneTime = oneTime.publicKey.rawRepresentation
        var transcript = Data("input channel v2".utf8)
        transcript.append(initiator ? myIdentity : peerIdentity); transcript.append(initiator ? peerIdentity : myIdentity)
        transcript.append(initiator ? myOneTime : peerOneTime); transcript.append(initiator ? peerOneTime : myOneTime)
        let salt = Data(SHA256.hash(data: transcript))
        let output = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: salt, info: Data("frames".utf8), outputByteCount: 64)
        let bytes = output.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }

    private static func greeting(identity: DeviceIdentity, oneTime: Curve25519.KeyAgreement.PrivateKey, name: String, port: Int) -> [String: Any] {
        ["key": identity.publicKey, "once": oneTime.publicKey.rawRepresentation.base64EncodedString(), "name": name, "port": port]
    }

    private static func parse(_ hello: [String: Any]) -> (key: Data, once: Data, name: String, port: Int)? {
        guard let key = (hello["key"] as? String).flatMap({ Data(base64Encoded: $0) }), key.count == 32,
              let once = (hello["once"] as? String).flatMap({ Data(base64Encoded: $0) }), once.count == 32 else { return nil }
        return (key, once, String((hello["name"] as? String ?? "").prefix(80)), hello["port"] as? Int ?? RemoteWire.defaultPort)
    }

    /// Calls another Mac and shakes hands. `port` is the port this Mac itself listens on.
    /// A host of the form helper:<agent id> is one of the owner's Macs reached through the
    /// Monitor helper (HelperLink); the channel then goes by that name rather than by its key,
    /// since the helpers vouch for the Mac and put's own key may change with a reinstall.
    /// `dial`: how long the helper may take to reach the other Mac, before `timeout` for the
    /// handshake starts; the helper's own limit when not given.
    static func open(host: String, port: Int, identity: DeviceIdentity, name: String, listening: Int,
                     queue: DispatchQueue = .main, timeout: TimeInterval = 4,
                     dial: TimeInterval = HelperLink.longestDial) async throws -> Channel {
        let helperAgent = HelperLink.agent(of: host)
        let connection: NWConnection
        let label: String
        if let helperAgent {
            // The helper's own dial can take a few seconds the first time; it is bounded there.
            connection = try await HelperLink.open(agent: helperAgent, name: "", within: dial)
            label = host
        } else {
            let (endpointHost, endpointPort, endpointLabel) = try RemoteIO.endpoint(host: host, port: port)
            connection = NWConnection(host: endpointHost, port: endpointPort, using: ShelfSync.parameters)
            label = endpointLabel
        }
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            connection.cancel()
        }
        defer { deadline.cancel() }
        do {
            if helperAgent == nil { try await RemoteIO.ready(connection, queue: queue) }
            let oneTime = Curve25519.KeyAgreement.PrivateKey()
            try await RemoteIO.write(connection, try RemoteWire.frame(["v": 2, "hello": greeting(identity: identity, oneTime: oneTime, name: name, port: listening)]))
            let reply = try await RemoteIO.readFrame(connection)
            guard reply["ok"] as? Bool == true, let theirs = parse(reply) else {
                throw VoiceError(reply["message"] as? String ?? tr("The other Mac runs a different version of out. Update both to the same version."))
            }
            let keys = try keys(identity: identity, oneTime: oneTime, peerIdentity: theirs.key, peerOneTime: theirs.once, initiator: true)
            return Channel(connection: connection, peerKey: helperAgent.map(HelperLink.id) ?? theirs.key.base64EncodedString(),
                           peerName: theirs.name, peerPort: theirs.port, sendKey: keys.toResponder, receiveKey: keys.toInitiator)
        } catch {
            connection.cancel()
            if Task.isCancelled { throw CancellationError() }
            if error is VoiceError { throw error }
            if helperAgent != nil { throw VoiceError(tr("The connection to the other Mac through the Monitor helper was lost.")) }
            throw RemoteIO.unreachable(label, port)
        }
    }

    /// The answering side: given the caller's hello, the reply to send in the clear and the channel.
    /// `helperAgent`: the caller came through the Monitor helper, which says who it is.
    static func answer(_ connection: NWConnection, hello: [String: Any], identity: DeviceIdentity, name: String,
                       listening: Int, helperAgent: String? = nil) -> (reply: [String: Any], channel: Channel)? {
        guard let theirs = parse(hello) else { return nil }
        let oneTime = Curve25519.KeyAgreement.PrivateKey()
        guard let keys = try? keys(identity: identity, oneTime: oneTime, peerIdentity: theirs.key, peerOneTime: theirs.once, initiator: false) else { return nil }
        var reply = greeting(identity: identity, oneTime: oneTime, name: name, port: listening)
        reply["ok"] = true
        return (reply, Channel(connection: connection, peerKey: helperAgent.map(HelperLink.id) ?? theirs.key.base64EncodedString(),
                               peerName: theirs.name, peerPort: theirs.port, sendKey: keys.toInitiator, receiveKey: keys.toResponder))
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Seals one frame and hands it to the connection. Sealing and queueing happen in one step,
    /// so frames go out in the order they were numbered.
    private func enqueue(_ body: Data, completion: @escaping @Sendable (NWError?) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard body.count + 16 <= RemoteWire.limit else { throw VoiceError(tr("The content is too long to send to the other Mac.")) }
        let box = try ChaChaPoly.seal(body, using: sendKey, nonce: Self.nonce(sent))
        sent += 1
        var size = UInt32(box.ciphertext.count + box.tag.count).bigEndian
        connection.send(content: Data(bytes: &size, count: 4) + box.ciphertext + box.tag, completion: .contentProcessed(completion))
    }

    func write(_ body: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            do { try enqueue(body) { error in once.resume(error.map { .failure($0) } ?? .success(())) } }
            catch { once.resume(.failure(error)) }
        }
    }

    func write(_ object: [String: Any]) async throws { try await write(try JSONSerialization.data(withJSONObject: object)) }

    /// Sends without waiting for it to leave; `failed` is called if it could not.
    /// `sent` is called once the frame has gone out, `failed` when it could not.
    func send(_ object: [String: Any], sent: (@Sendable () -> Void)? = nil, failed: @escaping @Sendable (Error) -> Void) {
        do { try enqueue(try JSONSerialization.data(withJSONObject: object)) { error in if let error { failed(error) } else { sent?() } } }
        catch { failed(error) }
    }

    /// Sends without waiting; for a notice that needs no answer.
    func post(_ object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? enqueue(body) { _ in }
    }

    /// One frame's content, opened. Only one reader per channel.
    func readBody() async throws -> Data {
        let size = try RemoteWire.bodyLength(try await RemoteIO.read(connection, count: 4))
        let sealed = try await RemoteIO.read(connection, count: size)
        guard sealed.count >= 16 else { throw VoiceError(tr("The other Mac's reply was incomplete.")) }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(received), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        guard let body = try? ChaChaPoly.open(box, using: receiveKey) else {
            connection.cancel()
            throw VoiceError(tr("The encrypted connection to the other Mac failed verification and was closed."))
        }
        received += 1
        return body
    }

    func readObject() async throws -> [String: Any] { try RemoteWire.object(try await readBody()) }

    func close() { connection.cancel() }

    /// For the checks only: the first frame this channel sent, sealed again exactly as it was.
    func resealFirstFrame(_ body: Data) throws -> Data {
        let box = try ChaChaPoly.seal(body, using: sendKey, nonce: Self.nonce(0))
        var size = UInt32(box.ciphertext.count + box.tag.count).bigEndian
        return Data(bytes: &size, count: 4) + box.ciphertext + box.tag
    }
}
