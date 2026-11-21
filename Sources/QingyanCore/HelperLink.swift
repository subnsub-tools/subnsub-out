import Foundation
import Network

/// put on this Mac reaching put on the owner's other Macs through the Monitor helper (the
/// helper's put.go): the helper on each Mac knows which Macs are the owner's, because the
/// owner's Monitor page told it, signed by the key it has pinned, and carries the bytes through
/// its tunnel, directly where a path forms and through DERP where none does. put pairs nothing,
/// scans nothing and needs no Tailscale. Its own encrypted channel (Channel) runs inside.
///
/// The helper answers on a unix socket, put.sock in its config directory: one JSON line asks and
/// one JSON line answers; for open and accept the socket then is the stream.
public enum HelperLink {
    /// The Monitor page's Install window with put's switch on (monitor.js, ?install=put): the line
    /// there installs the helper for this account, with direct connections, and put after it.
    public static let installPage = URL(string: "https://dashboard.subnsub.com/?install=out#monitor")!

    /// A device reached through the helper is called this, followed by its agent id.
    public static let prefix = "helper:"

    public static func id(_ agent: String) -> String { prefix + agent }
    public static func agent(of host: String) -> String? {
        host.hasPrefix(prefix) ? String(host.dropFirst(prefix.count)) : nil
    }

    public struct Peer: Equatable, Sendable {
        public let agent: String
        public let name: String
        public init(agent: String, name: String) { self.agent = agent; self.name = name }
    }

    /// What the helper on this Mac says: who this Mac is, the owner's other Macs, and whether its
    /// tunnel is up.
    public struct Roster: Equatable, Sendable {
        public let agent: String
        public let name: String
        public let peers: [Peer]
        public let tunnel: Bool
        public let version: String
        /// Whether a Shelf item can be given a link: the helper is the owner's primary helper, or
        /// knows where that is. False from a helper too old to say.
        public let host: Bool
    }

    /// Why the helper could not be asked.
    public enum Absence: Error, Equatable, Sendable {
        /// No put.sock: no helper, or one older than put's channel.
        case notInstalled
        /// put.sock is there and nobody answers: the helper is not running.
        case notRunning
    }

    /// The directories the helper keeps its config in, under either of its names.
    public static var socketOverride: String?

    public static func socketPath() -> String? {
        if let socketOverride { return socketOverride }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for name in ["subnsub-helper", "subnsub-monitor"] {
            let path = "\(home)/.config/\(name)/put.sock"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    static func connect(timeout: TimeInterval = 3) async throws -> NWConnection {
        guard let path = socketPath() else { throw Absence.notInstalled }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            connection.cancel()
        }
        defer { deadline.cancel() }
        do { try await RemoteIO.ready(connection, queue: .main) }
        catch { connection.cancel(); throw Absence.notRunning }
        return connection
    }

    static func ask(_ connection: NWConnection, _ question: [String: Any]) async throws {
        var line = try JSONSerialization.data(withJSONObject: question)
        line.append(0x0A)
        try await RemoteIO.write(connection, line)
    }

    /// One line from the helper, at most `limit` bytes, and not a byte past it: what follows is the
    /// stream.
    static func readLine(_ connection: NWConnection, limit: Int = 4096) async throws -> [String: Any] {
        var line = Data()
        while true {
            let byte = try await RemoteIO.read(connection, count: 1)
            if byte.first == 0x0A { break }
            line.append(byte)
            guard line.count <= limit else { throw VoiceError(tr("The helper on this Mac answered in a way out does not understand.")) }
        }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw VoiceError(tr("The helper on this Mac answered in a way out does not understand."))
        }
        return object
    }

    /// Set when a wait ran out, read after it.
    final class Expiry: @unchecked Sendable {
        private let lock = NSLock()
        private var hit = false
        func set() { lock.lock(); hit = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return hit }
    }

    /// Runs `body` on the connection, cancelling the connection when `seconds` pass or the task is
    /// cancelled: a helper that takes the question and never answers holds nothing up. `expiry` is
    /// set when it was the time that ran out.
    static func bounded<T>(_ connection: NWConnection, _ seconds: TimeInterval, expiry: Expiry? = nil,
                           _ body: () async throws -> T) async throws -> T {
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            expiry?.set()
            connection.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler { try await body() } onCancel: { connection.cancel() }
    }

    public static func roster() async throws -> Roster {
        let connection = try await connect()
        defer { connection.cancel() }
        let answer: [String: Any]
        do {
            answer = try await bounded(connection, 5) {
                try await ask(connection, ["op": "peers"])
                // The list of the owner's Macs, with no stream after it: it may be long.
                return try await readLine(connection, limit: 1 << 20)
            }
        } catch { throw Absence.notRunning }
        let me = answer["self"] as? [String: Any] ?? [:]
        let peers = (answer["peers"] as? [[String: Any]] ?? []).compactMap { entry -> Peer? in
            guard let agent = entry["agent"] as? String, !agent.isEmpty else { return nil }
            return Peer(agent: agent, name: String((entry["name"] as? String ?? "").prefix(80)))
        }
        return Roster(agent: me["agent"] as? String ?? "", name: me["name"] as? String ?? "", peers: peers,
                      tunnel: answer["tunnel"] as? Bool == true, version: answer["version"] as? String ?? "",
                      host: answer["host"] as? Bool == true)
    }

    // MARK: Links

    /// Has the owner's primary helper keep a Shelf item, and answers the link it opens at on the
    /// tailnet (the helper's host.go). The helper on this Mac asks the primary first, and the bytes
    /// go only when it has none. file is nil where this Mac holds only the item's card: the link
    /// is then given only if the item was hosted from another Mac before.
    public static func host(id: UUID, name: String, size: Int, file: URL?,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let connection: NWConnection
        do { connection = try await connect() }
        catch let absence as Absence { throw VoiceError(sentence(absence)) }
        defer { connection.cancel() }
        do {
            // The helper dials its primary before it answers.
            var answer = try await bounded(connection, 60) {
                try await ask(connection, ["op": "host", "id": id.uuidString.lowercased(), "name": name, "size": size, "have": file != nil])
                return try await readLine(connection)
            }
            if answer["ok"] as? Bool == true, answer["send"] as? Bool == true {
                guard let file else { throw VoiceError(hostRefusal("not-hosted")) }
                try await withTaskCancellationHandler {
                    try await send(file, size: size, over: connection, progress: progress)
                } onCancel: { connection.cancel() }
                // It answers once its primary has the last byte, which through a relay takes a while.
                answer = try await bounded(connection, 300) { try await readLine(connection) }
            }
            guard answer["ok"] as? Bool == true, let link = answer["url"] as? String,
                  link.hasPrefix("http://") || link.hasPrefix("https://") else {
                throw VoiceError(hostRefusal(answer["error"] as? String ?? ""))
            }
            return link
        } catch let error as VoiceError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw VoiceError(tr("The helper on this Mac stopped answering. Check that it is running."))
        }
    }

    /// Takes a Shelf item's link down: the primary helper lets its copy go. One that was not hosted
    /// is down already.
    public static func unhost(id: UUID) async throws {
        let connection: NWConnection
        do { connection = try await connect() }
        catch let absence as Absence { throw VoiceError(sentence(absence)) }
        defer { connection.cancel() }
        let answer: [String: Any]
        do {
            answer = try await bounded(connection, 40) {
                try await ask(connection, ["op": "unhost", "id": id.uuidString.lowercased()])
                return try await readLine(connection)
            }
        } catch { throw VoiceError(tr("The helper on this Mac stopped answering. Check that it is running.")) }
        guard answer["ok"] as? Bool == true else { throw VoiceError(hostRefusal(answer["error"] as? String ?? "")) }
    }

    /// The file's bytes, exactly size of them, in pieces the socket takes one at a time.
    private static func send(_ file: URL, size: Int, over connection: NWConnection,
                             progress: (@Sendable (Double) -> Void)?) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sent = 0
        while sent < size {
            try Task.checkCancellation()
            guard let piece = try handle.read(upToCount: min(256 << 10, size - sent)), !piece.isEmpty else {
                throw VoiceError(tr("The file changed while it was being sent. Try again."))
            }
            try await RemoteIO.write(connection, piece)
            sent += piece.count
            progress?(Double(sent) / Double(max(size, 1)))
        }
    }

    static func hostRefusal(_ code: String) -> String {
        switch code {
        case "no-primary", "not-primary":
            return tr("This Mac has no primary helper to keep the file on. Choose one on the Monitor page: open a machine's Settings and click Make primary.")
        case "unreachable": return tr("The primary helper cannot be reached. Check that its machine is on and its helper is running.")
        case "no-tailnet": return tr("The primary helper is not on a tailnet, so it has no address to give a link.")
        case "full": return tr("The primary helper has no room for this file. Remove links that are no longer needed, then try again.")
        case "not-hosted": return tr("This file is not on this Mac yet. Fetch it first, then copy its link.")
        case "not-allowed": return tr("The primary helper does not know this Mac yet. It asks every Mac within ten minutes. Try again then.")
        case "off": return tr("Links are turned off on the helper.")
        case "unknown-op": return tr("The Monitor helper on this Mac is too old for links. Update it from the Monitor page.")
        default: return tr("The link could not be made (%@).", code)
        }
    }

    /// The longest the helper itself dials another Mac, and a little more for its answer.
    public static let longestDial: TimeInterval = 25

    /// A stream to put on the owner's Mac with this agent id, once the other side has taken it.
    /// `within`: how long to wait for it; the helper dials for up to 20 seconds, and a caller that
    /// cannot wait that long (finding the Mac behind a remote desktop) gives up sooner, with the
    /// other Mac counted as out of reach.
    static func open(agent: String, name: String, within seconds: TimeInterval = longestDial) async throws -> NWConnection {
        let connection: NWConnection
        do { connection = try await connect() }
        catch let absence as Absence { throw VoiceError(sentence(absence)) }
        let expiry = Expiry()
        do {
            let answer = try await bounded(connection, min(seconds, longestDial), expiry: expiry) {
                try await ask(connection, ["op": "open", "agent": agent])
                return try await readLine(connection)
            }
            guard answer["ok"] as? Bool == true else {
                connection.cancel()
                throw VoiceError(refusal(answer["error"] as? String ?? "", name: name))
            }
            return connection
        } catch let error as VoiceError { throw error }
        catch {
            connection.cancel()
            // The helper was still dialing when the caller's wait ran out.
            if expiry.isSet && seconds < longestDial { throw VoiceError(refusal("unreachable", name: name)) }
            throw VoiceError(tr("The helper on this Mac stopped answering. Check that it is running."))
        }
    }

    /// Leaves a connection waiting at the helper for a stream from one of the owner's other Macs.
    static func park() async throws -> NWConnection {
        let connection = try await connect()
        do { try await bounded(connection, 5) { try await ask(connection, ["op": "accept"]) } }
        catch { connection.cancel(); throw Absence.notRunning }
        return connection
    }

    /// The stream on a parked connection, once one comes: who it is from.
    static func arrival(_ connection: NWConnection) async throws -> (agent: String, name: String) {
        let header = try await readLine(connection)
        guard let agent = header["from"] as? String, !agent.isEmpty else {
            throw VoiceError(tr("The helper on this Mac answered in a way out does not understand."))
        }
        return (agent, String((header["name"] as? String ?? "").prefix(80)))
    }

    public static func sentence(_ absence: Absence) -> String {
        switch absence {
        case .notInstalled: return tr("The Monitor helper is not installed on this Mac, or its version is too old for out's connection between Macs. Install or update it from the Monitor page.")
        case .notRunning: return tr("The Monitor helper on this Mac is not running.")
        }
    }

    static func refusal(_ code: String, name: String) -> String {
        let who = name.isEmpty ? tr("The other Mac") : name
        switch code {
        case "put-not-running": return tr("out is not running on %@.", who)
        case "unreachable": return tr("%@ cannot be reached. Check that it is on and its Monitor helper is running.", who)
        case "unknown-peer": return tr("The helper on this Mac does not know %@ yet. Open the Monitor page once so that it can tell the Macs about each other.", who)
        case "not-allowed": return tr("%@ does not know this Mac yet. Open the Monitor page once so that it can tell the Macs about each other.", who)
        case "busy": return tr("The helper is busy. Try again.")
        default: return tr("%@ refused the connection (%@).", who, code)
        }
    }
}
