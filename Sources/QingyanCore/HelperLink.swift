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
    public static let installPage = URL(string: "https://dashboard.subnsub.com/?install=put#monitor")!

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
            guard line.count <= limit else { throw VoiceError(tr("The helper on this Mac answered in a way put does not understand.")) }
        }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw VoiceError(tr("The helper on this Mac answered in a way put does not understand."))
        }
        return object
    }

    /// Runs `body` on the connection, cancelling the connection when `seconds` pass or the task is
    /// cancelled: a helper that takes the question and never answers holds nothing up.
    static func bounded<T>(_ connection: NWConnection, _ seconds: TimeInterval, _ body: () async throws -> T) async throws -> T {
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
                      tunnel: answer["tunnel"] as? Bool == true, version: answer["version"] as? String ?? "")
    }

    /// A stream to put on the owner's Mac with this agent id, once the other side has taken it.
    static func open(agent: String, name: String) async throws -> NWConnection {
        let connection: NWConnection
        do { connection = try await connect() }
        catch let absence as Absence { throw VoiceError(sentence(absence)) }
        do {
            // The helper dials the other Mac for up to 20 seconds.
            let answer = try await bounded(connection, 25) {
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
            throw VoiceError(tr("The helper on this Mac answered in a way put does not understand."))
        }
        return (agent, String((header["name"] as? String ?? "").prefix(80)))
    }

    public static func sentence(_ absence: Absence) -> String {
        switch absence {
        case .notInstalled: return tr("The Monitor helper is not installed on this Mac, or its version is too old for put's connection between Macs. Install or update it from the Monitor page.")
        case .notRunning: return tr("The Monitor helper on this Mac is not running.")
        }
    }

    static func refusal(_ code: String, name: String) -> String {
        let who = name.isEmpty ? tr("The other Mac") : name
        switch code {
        case "put-not-running": return tr("put is not running on %@.", who)
        case "unreachable": return tr("%@ cannot be reached. Check that it is on and its Monitor helper is running.", who)
        case "unknown-peer": return tr("The helper on this Mac does not know %@ yet. Open the Monitor page once so that it can tell the Macs about each other.", who)
        case "not-allowed": return tr("%@ does not know this Mac yet. Open the Monitor page once so that it can tell the Macs about each other.", who)
        case "busy": return tr("The helper is busy. Try again.")
        default: return tr("%@ refused the connection (%@).", who, code)
        }
    }
}
