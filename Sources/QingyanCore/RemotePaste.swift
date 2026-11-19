import Foundation
import Network

/// Several Macs running the same app: one records and recognises, another pastes.
/// A frame is a 4-byte big-endian length and a body. The first frame each way is a hello in the
/// clear that proves who is calling (see `Channel`); every frame after it is sealed. A sealed
/// body is a JSON object, or raw bytes of a shelf item.
public enum RemoteWire {
    public static let defaultPort = 18765
    public static let limit = 1 << 20

    public static func frame(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object)
        guard body.count <= limit else { throw VoiceError(tr("The text is too long to send to the other Mac.")) }
        var size = UInt32(body.count).bigEndian
        return Data(bytes: &size, count: 4) + body
    }

    /// A frame of raw bytes belonging to one shelf item: a zero byte, the item's id, the bytes.
    /// JSON frames start with a brace, so the two cannot be mistaken for each other.
    public static func rawFrame(id: UUID, _ data: Data) throws -> Data {
        guard data.count + 17 <= limit else { throw VoiceError(tr("The data block is too large.")) }
        var size = UInt32(data.count + 17).bigEndian
        return Data(bytes: &size, count: 4) + [0] + withUnsafeBytes(of: id.uuid) { Data($0) } + data
    }

    /// The same without the length, for a channel that seals and frames it itself.
    public static func rawBody(id: UUID, _ data: Data) -> Data {
        [0] + withUnsafeBytes(of: id.uuid) { Data($0) } + data
    }

    public static func raw(_ body: Data) -> (id: UUID, data: Data)? {
        guard body.count >= 17, body.first == 0 else { return nil }
        let bytes = [UInt8](body.dropFirst().prefix(16))
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return (id, Data(body.dropFirst(17)))
    }

    public static func bodyLength(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw VoiceError(tr("The other Mac's response was incomplete.")) }
        let size = header.reduce(0) { $0 << 8 | Int($1) }
        guard size > 0, size <= limit else { throw VoiceError(tr("The other Mac's response is in an incompatible format. Make sure both Macs run the same version of put.")) }
        return size
    }

    public static func object(_ body: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw VoiceError(tr("The other Mac's response is in an incompatible format. Make sure both Macs run the same version of put."))
        }
        return object
    }

    public static func validPort(_ port: Int) -> Bool { (1024...65535).contains(port) }

    /// Compares every byte so the time taken does not reveal how much of a guess was right.
    public static func sameCode(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard !x.isEmpty, x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func newCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return (0..<3).map { _ in String((0..<4).map { _ in alphabet.randomElement(using: &generator)! }) }
            .joined(separator: "-")
    }

    /// True when the frontmost app is a window onto another computer's screen:
    /// Apple Screen Sharing, or any Jump Desktop viewer build (App Store, direct, Setapp).
    /// Jump Desktop Connect is the hosting agent on this Mac, not a viewer.
    public static func showsAnotherScreen(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        if id == "com.apple.screensharing" { return true }
        return id.hasPrefix("com.p5sys.jump") && !id.hasPrefix("com.p5sys.jump.connect")
    }

    /// Tailscale's 100.64.0.0/10 and fd7a:115c:a1e0::/48, plus loopback for local checks.
    public static func isTrustedPeer(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return trusted(v4: Array(address.rawValue))
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return false }
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return trusted(v4: Array(bytes[12...]))
            }
            if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
            return Array(bytes[0..<6]) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        default: return false
        }
    }

    private static func trusted(v4 bytes: [UInt8]) -> Bool {
        bytes.count == 4 && (bytes[0] == 127 || (bytes[0] == 100 && bytes[1] & 0xc0 == 64))
    }

    /// This Mac's Tailscale IPv4 address and the interface it is on.
    private static func tailnet() -> (address: String, interface: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let bytes = withUnsafeBytes(of: raw) { Array($0) }
            if bytes[0] == 100 && bytes[1] & 0xc0 == 64 {
                return (bytes.map(String.init).joined(separator: "."), String(cString: item.pointee.ifa_name))
            }
        }
        return nil
    }

    /// This Mac's Tailscale IPv4 address, shown so another Mac can be pointed at it.
    public static func localTailnetAddress() -> String? { tailnet()?.address }
    /// The network interface Tailscale runs on, when it is running.
    public static func tailnetInterface() -> String? { tailnet()?.interface }
}

/// The knock: a keystroke pattern the sending Mac types into whatever window is in front.
/// A remote-desktop window forwards it to exactly the Mac the user is operating, and that Mac's
/// input recognises it. Only modifier keys are used, so no application ever sees a character.
/// Option stays held throughout, so the taps are never a bare double-tap of Shift or Control.
public enum Knock {
    public static let bits = 6
    public enum Key: Equatable, Sendable { case option, shift, control }
    public struct Step: Equatable, Sendable {
        public let key: Key
        public let down: Bool
        public init(_ key: Key, down: Bool) { self.key = key; self.down = down }
    }

    public static func validNonce(_ nonce: Int) -> Bool { (0..<(1 << bits)).contains(nonce) }
    public static func newNonce() -> Int { Int.random(in: 0..<(1 << bits)) }

    /// Option down, one tap per bit from the highest (Shift = 0, Control = 1), Option up.
    public static func steps(for nonce: Int) -> [Step] {
        var steps = [Step(.option, down: true)]
        for bit in (0..<bits).reversed() {
            let key: Key = nonce >> bit & 1 == 1 ? .control : .shift
            steps += [Step(key, down: true), Step(key, down: false)]
        }
        return steps + [Step(.option, down: false)]
    }
}

/// Fed every modifier change the event tap sees; reports a nonce when a whole knock went by.
public struct KnockDecoder {
    private var started: TimeInterval?
    private var held: Knock.Key?
    private var value = 0
    private var count = 0
    /// Far longer than a posted knock takes even over a slow link, far shorter than typing by hand.
    public static let window: TimeInterval = 2

    public init() {}

    public mutating func reset() { started = nil; held = nil; value = 0; count = 0 }

    public mutating func feed(_ step: Knock.Step, at time: TimeInterval) -> Int? {
        if let begun = started, time - begun > Self.window || time < begun { reset() }
        guard started != nil else {
            if step.key == .option && step.down { started = time }
            return nil
        }
        switch (step.key, step.down) {
        case (.option, false):
            let nonce = held == nil && count == Knock.bits ? value : nil
            reset()
            return nonce
        case (.option, true):
            reset(); started = time
        case (let key, true):
            guard held == nil, count < Knock.bits else { reset(); return nil }
            held = key
        case (let key, false):
            guard held == key else { reset(); return nil }
            held = nil; value = value << 1 | (key == .control ? 1 : 0); count += 1
        }
        return nil
    }
}

/// Network callbacks may arrive on another queue; a continuation may only be resumed once.
final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func resume(_ result: Result<Value, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}

enum RemoteIO {
    static func endpoint(host: String, port: Int) throws -> (NWEndpoint.Host, NWEndpoint.Port, String) {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, RemoteWire.validPort(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw VoiceError(tr("Enter the other Mac's address and port first."))
        }
        return (NWEndpoint.Host(name), endpointPort, name)
    }

    static func ready(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(()))
                case .failed(let error), .waiting(let error): once.resume(.failure(error))
                case .cancelled: once.resume(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    static func write(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                once.resume(error.map { .failure($0) } ?? .success(()))
            })
        }
    }

    static func read(_ connection: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let once = Once(continuation)
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count { once.resume(.success(data)) }
                else { once.resume(.failure(error ?? URLError(.networkConnectionLost))) }
            }
        }
    }

    /// One frame sent in the clear: only the hello that starts a channel.
    static func readFrame(_ connection: NWConnection) async throws -> [String: Any] {
        let size = try RemoteWire.bodyLength(try await read(connection, count: 4))
        return try RemoteWire.object(try await read(connection, count: size))
    }

    static func unreachable(_ name: String, _ port: Int) -> VoiceError {
        VoiceError(tr("Cannot reach %@:%ld. Make sure put is running on the other Mac and the two Macs can reach each other.", name, port))
    }
}

/// Single calls to another Mac: who are you, are you ready, will you trust me.
public enum RemoteSender {
    public struct Reply {
        public let ok: Bool
        public let message: String
        public let name: String
        /// Whether that Mac trusts this one.
        public let paired: Bool
    }

    /// A Mac that answered at an address: who it says it is, proven by its key.
    public struct Found: Equatable, Identifiable, Sendable {
        public let key: String
        public let name: String
        public let host: String
        public let port: Int
        public var id: String { key }
        public init(key: String, name: String, host: String, port: Int) { self.key = key; self.name = name; self.host = host; self.port = port }
    }

    /// Asks the Mac at an address who it is. Any Mac running the app answers, paired or not.
    public static func identify(host: String, port: Int, identity: DeviceIdentity, name: String, listening: Int,
                                timeout: TimeInterval = 2.5) async throws -> Found {
        let channel = try await Channel.open(host: host, port: port, identity: identity, name: name, listening: listening,
                                             queue: DispatchQueue(label: "local.hopo.qingyan.remote.identify"), timeout: timeout)
        channel.close()
        return Found(key: channel.peerKey, name: channel.peerName, host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
    }

    /// Checks that a trusted Mac is where it was, is still the same Mac, and can paste. Nothing is pasted.
    public static func ping(_ device: TrustedDevice, identity: DeviceIdentity, name: String, listening: Int,
                            timeout: TimeInterval = 6) async throws -> Reply {
        let channel = try await Channel.open(host: device.host, port: device.port, identity: identity, name: name, listening: listening,
                                             queue: DispatchQueue(label: "local.hopo.qingyan.remote.ping"), timeout: timeout)
        defer { channel.close() }
        guard channel.peerKey == device.key else { throw VoiceError(tr("A different Mac answers at this address, not the paired “%@”.", device.label)) }
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            channel.close()
        }
        defer { deadline.cancel() }
        do {
            try await channel.write(["ping": true])
            let reply = try await channel.readObject()
            return Reply(ok: reply["ok"] as? Bool == true, message: reply["message"] as? String ?? "",
                         name: reply["name"] as? String ?? channel.peerName, paired: reply["paired"] as? Bool == true)
        } catch let error as VoiceError { throw error }
        catch { throw RemoteIO.unreachable(device.label, device.port) }
    }

    /// Asks the Mac at an address to trust this one, and waits for its user to answer.
    /// `legacyCode` is the pairing code of the version before device keys; a Mac that still
    /// remembers that code agrees without asking.
    public static func pair(host: String, port: Int, identity: DeviceIdentity, name: String, listening: Int,
                            legacyCode: String? = nil, timeout: TimeInterval = 120,
                            onCode: @Sendable @escaping (String) -> Void = { _ in }) async throws -> TrustedDevice {
        let channel = try await Channel.open(host: host, port: port, identity: identity, name: name, listening: listening,
                                             queue: DispatchQueue(label: "local.hopo.qingyan.remote.pair"))
        defer { channel.close() }
        onCode(DeviceIdentity.checkCode(identity.publicKey, channel.peerKey))
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            channel.close()
        }
        defer { deadline.cancel() }
        do {
            var request: [String: Any] = ["pair": true]
            if let legacyCode, !legacyCode.isEmpty { request["code"] = legacyCode }
            try await channel.write(request)
            let reply = try await channel.readObject()
            guard reply["ok"] as? Bool == true else { throw VoiceError(reply["message"] as? String ?? tr("The other Mac did not allow pairing.")) }
            return TrustedDevice(key: channel.peerKey, name: channel.peerName, host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
        } catch let error as VoiceError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw VoiceError(tr("The other Mac did not answer the pairing request."))
        }
    }
}

/// One dictation's link to every trusted Mac. Armed while the recording is being transcribed;
/// a knock typed into the front window then tells which of them the user is operating.
@MainActor
public final class RemoteSession {
    private final class Link {
        let device: TrustedDevice
        var channel: Channel?
        var armed = false
        var name = ""
        var problem = ""
        var seen: Date?
        var elapsed: TimeInterval = 0
        var reply: Once<[String: Any]>?
        init(_ device: TrustedDevice) { self.device = device }
    }

    public let nonce = Knock.newNonce()
    private let links: [Link]
    private let identity: DeviceIdentity
    private let name: String
    private let listening: Int
    private var closed = false

    public init(devices: [TrustedDevice], identity: DeviceIdentity, name: String, listening: Int) {
        links = devices.filter(\.reachable).map(Link.init)
        self.identity = identity; self.name = name; self.listening = listening
    }

    public var armedCount: Int { links.filter(\.armed).count }
    public func name(_ index: Int) -> String { links[index].name.isEmpty ? links[index].device.label : links[index].name }
    public func key(_ index: Int) -> String { links[index].device.key }
    /// Names learnt while arming, for the list in the panel.
    public var names: [String: String] {
        Dictionary(links.filter { !$0.name.isEmpty }.map { ($0.device.key, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
    /// After arming: which trusted Macs answered.
    public var reachable: [String: Bool] { Dictionary(links.map { ($0.device.key, $0.armed) }, uniquingKeysWith: { first, _ in first }) }
    /// Why each unreachable Mac could not be armed.
    public var problems: [String] { links.filter { !$0.armed && !$0.problem.isEmpty }.map { tr("%@: %@", $0.device.label, $0.problem) } }
    /// How long to wait for a claim after the knock: the slowest armed link's round trip plus the
    /// time a remote-desktop session needs to carry the keys.
    public var patience: TimeInterval {
        let slowest = links.filter(\.armed).map(\.elapsed).max() ?? 0
        return min(0.9, max(0.25, slowest / 3 + 0.2))
    }

    /// Connects to every Mac at once. Unreachable ones are simply left out.
    public func arm(timeout: TimeInterval = 3) async {
        let tasks = links.map { link in Task { @MainActor [weak self] in await self?.arm(link, timeout: timeout) } }
        for task in tasks { await task.value }
    }

    private func arm(_ link: Link, timeout: TimeInterval) async {
        guard !closed else { return }
        let started = Date()
        do {
            let channel = try await Channel.open(host: link.device.host, port: link.device.port, identity: identity, name: name,
                                                 listening: listening, timeout: timeout)
            link.channel = channel
            guard channel.peerKey == link.device.key else { throw VoiceError(tr("A different Mac is at this address now. Pair again.")) }
            let deadline = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                channel.close()
            }
            defer { deadline.cancel() }
            do {
                try await channel.write(["arm": nonce])
                let reply = try await channel.readObject()
                guard reply["ok"] as? Bool == true else { throw VoiceError(reply["message"] as? String ?? tr("Not ready.")) }
                link.name = reply["name"] as? String ?? channel.peerName
            } catch let error as VoiceError { throw error }
            catch { throw RemoteIO.unreachable(link.device.label, link.device.port) }
            guard !closed else { channel.close(); return }
            link.elapsed = Date().timeIntervalSince(started)
            link.armed = true
            listen(link, channel)
        } catch {
            link.problem = error.localizedDescription
            link.channel?.close()
        }
    }

    /// One reader per link: claims and the replies to requests both arrive here.
    private func listen(_ link: Link, _ channel: Channel) {
        Task { @MainActor in
            while let frame = try? await channel.readObject() {
                if frame["seen"] as? Bool == true { link.seen = Date() }
                else { link.reply?.resume(.success(frame)); link.reply = nil }
            }
            link.armed = false
            link.reply?.resume(.failure(URLError(.networkConnectionLost))); link.reply = nil
        }
    }

    /// Types the knock (through `knock`) and waits for one armed Mac to say it saw it.
    /// Nil means the front window belongs to this Mac, or to a Mac that is not trusted.
    public func locate(knock: @MainActor () async -> Void) async -> Int? {
        guard !closed, armedCount > 0 else { return nil }
        let started = Date()
        await knock()
        let deadline = Date().addingTimeInterval(patience)
        while true {
            if let index = links.firstIndex(where: { $0.armed && ($0.seen ?? .distantPast) >= started }) { return index }
            if closed || Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// One request and its reply on an armed link.
    private func exchange(_ index: Int, _ request: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let link = links[index]
        guard link.armed, let channel = link.channel else { throw RemoteIO.unreachable(link.device.label, link.device.port) }
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            channel.close()
        }
        defer { deadline.cancel() }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let once = Once(continuation)
                link.reply = once
                channel.send(request) { once.resume(.failure($0)) }
            }
        } catch let error as VoiceError { throw error }
        catch { throw RemoteIO.unreachable(link.device.label, link.device.port) }
    }

    /// Hands the text to the Mac that claimed the knock and returns what happened there.
    /// `replace`: the text this Mac sent there last, which the new text takes the place of.
    /// `field`: the whole content of that Mac's text field as it was read; `text` is its new content.
    public func send(to index: Int, text: String, mode: WritingMode, seconds: Double, replace: String? = nil,
                     field: String? = nil, timeout: TimeInterval = 8) async throws -> String {
        var request: [String: Any] = ["text": text, "mode": mode.rawValue, "seconds": seconds]
        if let replace { request["replace"] = replace }
        if let field { request["field"] = field }
        let reply = try await exchange(index, request, timeout: timeout)
        let message = reply["message"] as? String ?? ""
        guard reply["ok"] as? Bool == true else { throw VoiceError(tr("%@: %@", name(index), message)) }
        return message
    }

    /// The text of the field that has the keyboard on the Mac that claimed the knock, split at
    /// its cursor. Nil when that Mac cannot read it or does not allow it.
    public func context(of index: Int, timeout: TimeInterval = 4) async -> (before: String, after: String)? {
        guard let reply = try? await exchange(index, ["context": true], timeout: timeout), reply["ok"] as? Bool == true,
              let before = reply["before"] as? String, let after = reply["after"] as? String else { return nil }
        return (before, after)
    }

    public func close() {
        closed = true
        for link in links { link.channel?.close() }
    }
}

/// Answers other Macs. Every connection first proves who is calling; what the caller may then
/// do depends on whether this Mac trusts it and what it was allowed.
@MainActor
public final class RemoteReceiver {
    public struct Request {
        public let text: String
        public let mode: WritingMode
        public let seconds: Double
        /// Text pasted here earlier that `text` replaces; `text` may then be empty, meaning delete.
        public let replace: String?
        /// The whole content of the focused field as the sender read it; `text` is its new content.
        public let field: String?
    }

    /// Another Mac asks to be trusted. Shown to the user, who calls `answer` once.
    public struct PairRequest: Identifiable {
        public let id = UUID()
        public let device: TrustedDevice
        /// The same six digits show on the asking Mac.
        public let code: String
        public let answer: (Bool) -> Void
        public init(device: TrustedDevice, code: String, answer: @escaping (Bool) -> Void) { self.device = device; self.code = code; self.answer = answer }
    }

    private final class Decision {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func settle(_ value: Bool) { continuation?.resume(returning: value); continuation = nil }
    }

    public private(set) var listening = false
    public private(set) var status = ""
    public var onChange: (() -> Void)?
    public var identity = DeviceIdentity()
    /// What this Mac calls itself.
    public var name = ""
    /// Looks a calling Mac up among the trusted ones.
    public var trusted: (String) -> TrustedDevice? = { _ in nil }
    public var onPairRequest: ((PairRequest) -> Void)?
    /// A request went away unanswered: the caller gave up or time ran out.
    public var onPairEnded: ((UUID) -> Void)?
    /// A Mac is to be added to the trusted ones. The flag says how it got in: true when it knew the
    /// earlier version's pairing code, false when the user agreed.
    public var onPaired: ((TrustedDevice, Bool) -> Void)?
    /// The pairing code this Mac showed before device keys. A Mac that sends it is trusted without asking.
    public var legacyCode = ""
    /// Only take calls that come from a Tailscale address or arrive on Tailscale's interface.
    public var tailscaleOnly = true
    /// Connections that say a shelf hello are handed over to this, and no longer read here.
    public weak var shelf: ShelfSync?

    private var listener: NWListener?
    private var port = 0
    private var probe: (() -> (Bool, String))?
    private var deliver: ((Request) throws -> String)?
    private var context: (() -> (before: String, after: String)?)?
    private var armed: [Int: Channel] = [:]
    private var deadlines: [ObjectIdentifier: DispatchWorkItem] = [:]
    /// A dictation may be transcribed for a while before its text arrives.
    private static let armedLifetime: TimeInterval = 300
    private enum Next { case close, keep, handOver }

    public init() {}

    /// Safe to call repeatedly; only a changed port or a dead listener causes a restart.
    /// `context` reads the text field that has the keyboard, for a Mac whose user spoke an editing command.
    public func start(port: Int, probe: @escaping () -> (Bool, String),
                      context: @escaping () -> (before: String, after: String)? = { nil },
                      deliver: @escaping (Request) throws -> String) {
        self.probe = probe; self.deliver = deliver; self.context = context
        if listener != nil && self.port == port { return }
        // Replace quietly: the new listener reports its own state, so a retry does not blink the status.
        listener?.cancel(); listener = nil
        self.port = port
        guard RemoteWire.validPort(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            update(false, tr("Invalid port. Enter a number from 1024 to 65535.")); return
        }
        do {
            let parameters = ShelfSync.parameters
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: endpointPort)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.update(true, tr("Listening on port %ld · Ready", port))
                    case .failed, .waiting:
                        listener.cancel(); self.listener = nil
                        self.update(false, tr("Cannot listen on port %ld, which may be in use. put will try again automatically.", port))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self else { connection.cancel(); return }
                    Task { @MainActor in await self.serve(connection) }
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch { update(false, tr("Cannot listen on port %ld, which may be in use. put will try again automatically.", port)) }
    }

    public func stop() {
        listener?.cancel(); listener = nil; port = 0
        for channel in armed.values { channel.close() }
        armed.removeAll()
        update(false, "")
    }

    /// The event tap saw a complete knock. Tell the Mac that armed it, if there is one.
    public func knocked(_ nonce: Int) { armed[nonce]?.post(["seen": true]) }

    private func update(_ listening: Bool, _ status: String) {
        guard self.listening != listening || self.status != status else { return }
        self.listening = listening; self.status = status
        onChange?()
    }

    private func expire(_ connection: NWConnection, after seconds: TimeInterval?) {
        let item = seconds.map { _ in DispatchWorkItem { connection.cancel() } }
        if let item { deadlines.updateValue(item, forKey: ObjectIdentifier(connection))?.cancel() }
        else { deadlines.removeValue(forKey: ObjectIdentifier(connection))?.cancel() }
        if let item, let seconds { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item) }
    }

    private static func address(_ connection: NWConnection) -> String {
        guard case let .hostPort(host, _) = connection.endpoint else { return "" }
        return String("\(host)".split(separator: "%").first ?? "")
    }

    /// With the restriction on: from a Tailscale address, or — when a router forwards a Mac on its
    /// own network into the tailnet without rewriting the address — at least over Tailscale's interface.
    private func admissible(_ connection: NWConnection) -> Bool {
        guard tailscaleOnly else { return true }
        if case let .hostPort(host, _) = connection.endpoint, RemoteWire.isTrustedPeer(host) { return true }
        guard let interface = RemoteWire.tailnetInterface() else { return false }
        return connection.currentPath?.availableInterfaces.first?.name == interface
    }

    private func serve(_ connection: NWConnection) async {
        // A caller that never finishes its hello must not hold a connection open.
        expire(connection, after: 8)
        defer {
            expire(connection, after: nil)
            armed = armed.filter { $0.value.connection !== connection }
        }
        guard (try? await RemoteIO.ready(connection, queue: .main)) != nil, admissible(connection) else { connection.cancel(); return }
        guard let first = try? await RemoteIO.readFrame(connection) else { connection.cancel(); return }
        guard first["v"] as? Int == 2, let hello = first["hello"] as? [String: Any],
              let (reply, channel) = Channel.answer(connection, hello: hello, identity: identity, name: name, listening: port) else {
            let refusal: [String: Any] = ["ok": false, "message": tr("The two Macs run different versions of put. Update both to the same version.")]
            if let frame = try? RemoteWire.frame(refusal) { try? await RemoteIO.write(connection, frame) }
            connection.cancel(); return
        }
        guard let frame = try? RemoteWire.frame(reply), (try? await RemoteIO.write(connection, frame)) != nil else { connection.cancel(); return }
        while let request = try? await channel.readObject() {
            let (reply, next) = await answer(request, on: channel)
            guard (try? await channel.write(reply)) != nil else { break }
            switch next {
            case .keep: continue
            case .close: connection.cancel(); return
            // The shelf reads this connection from now on, for as long as it lives.
            case .handOver: return
            }
        }
        connection.cancel()
    }

    private func answer(_ object: [String: Any], on channel: Channel) async -> ([String: Any], Next) {
        func refuse(_ message: String) -> ([String: Any], Next) { (["ok": false, "message": message], .close) }
        let device = trusted(channel.peerKey)
        if object["ping"] as? Bool == true {
            guard device != nil else { return (["ok": false, "message": tr("The other Mac has not added this Mac to its trusted list."), "name": name, "paired": false], .close) }
            let (ok, message) = probe?() ?? (false, tr("put on the other Mac is not ready."))
            return (["ok": ok, "message": message, "name": name, "paired": true], .close)
        }
        if object["pair"] as? Bool == true { return await pair(object, on: channel, known: device) }
        guard let device else { return refuse(tr("The other Mac has not added this Mac to its trusted list. Pair the two Macs first.")) }
        if object["shelf"] as? String == "hello" {
            guard device.canShelf, let shelf else { return refuse(tr("The other Mac has not allowed Shelf sharing.")) }
            expire(channel.connection, after: nil)
            return (shelf.adopt(channel, hello: object), .handOver)
        }
        guard device.canWrite else { return refuse(tr("The other Mac does not allow this Mac to type text there.")) }
        if let nonce = object["arm"] as? Int {
            guard Knock.validNonce(nonce) else { return refuse(tr("The two Macs run different versions of put. Update both to the same version.")) }
            let (ok, message) = probe?() ?? (false, tr("put on the other Mac is not ready."))
            guard ok else { return refuse(message) }
            guard armed[nonce] == nil || armed[nonce] === channel else { return refuse(tr("The signal channel is busy. Try again.")) }
            armed[nonce] = channel
            expire(channel.connection, after: Self.armedLifetime)
            return (["ok": true, "message": "armed", "name": name], .keep)
        }
        let stays: Next = armed.values.contains(where: { $0 === channel }) ? .keep : .close
        if object["context"] as? Bool == true {
            guard device.canRead else { return (["ok": false, "message": tr("The other Mac does not allow reading its text field.")], stays) }
            guard let field = context?() else { return (["ok": false, "message": tr("Could not read the text field on the other Mac.")], stays) }
            return (["ok": true, "before": field.before, "after": field.after], stays)
        }
        let replace = (object["replace"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let field = object["field"] as? String
        guard let text = object["text"] as? String, !text.isEmpty || replace != nil || field != nil else { return refuse(tr("No text was received.")) }
        guard field == nil || device.canRead else { return refuse(tr("The other Mac does not allow changing its text field.")) }
        let request = Request(text: text, mode: WritingMode(rawValue: object["mode"] as? String ?? "") ?? .dictate,
                              seconds: object["seconds"] as? Double ?? 0, replace: replace, field: field)
        do { return (["ok": true, "message": try deliver?(request) ?? ""], .close) }
        catch { return refuse(error.localizedDescription) }
    }

    private func pair(_ object: [String: Any], on channel: Channel, known: TrustedDevice?) async -> ([String: Any], Next) {
        if known != nil { return (["ok": true, "message": tr("Already paired.")], .close) }
        let device = TrustedDevice(key: channel.peerKey, name: channel.peerName, host: Self.address(channel.connection), port: channel.peerPort)
        if !legacyCode.isEmpty, RemoteWire.sameCode(object["code"] as? String ?? "", legacyCode) {
            onPaired?(device, true)
            return (["ok": true, "message": tr("Connected using the earlier pairing.")], .close)
        }
        guard let onPairRequest else { return (["ok": false, "message": tr("That Mac is not accepting pairing requests now.")], .close) }
        // The other Mac's user needs time to look and decide.
        expire(channel.connection, after: 130)
        var requestID: UUID?
        let agreed: Bool = await withCheckedContinuation { continuation in
            let decision = Decision(continuation)
            let request = PairRequest(device: device, code: DeviceIdentity.checkCode(identity.publicKey, channel.peerKey)) { decision.settle($0) }
            requestID = request.id
            onPairRequest(request)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                decision.settle(false)
            }
        }
        if let requestID { onPairEnded?(requestID) }
        guard agreed else { return (["ok": false, "message": tr("The other Mac did not allow pairing.")], .close) }
        onPaired?(device, false)
        return (["ok": true, "message": tr("Paired.")], .close)
    }
}
