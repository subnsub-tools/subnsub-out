//
//  ScreenTunnel.swift
//
//  How another Mac's screen reaches this out: this Mac's out is the Screen
//  Sharing client, and out on the other Mac only carries bytes between this
//  Mac and its own Screen Sharing, as the Monitor helper does for the Monitor
//  page's VNC (user 2026-11-25: the helper only gives a road and a port; it
//  has nothing to do with screen sharing). The road between the two outs is
//  the one the helpers keep between the owner's Macs (RemotePaste.openScreen).
//
//  On that road, after the other Mac's yes, one stream carries everything, in
//  frames of [kind u8][length u24][body]:
//
//    1  a word (JSON), each way: this Mac asks the other to connect, the
//       other says it has, or why not, and when Screen Sharing hung up
//    2  bytes of the TCP connection to Screen Sharing, each way
//    3  a datagram of the UDP control port, each way
//    4  a datagram of the UDP video port, each way
//
//  A session (High Performance, the only kind) has its video, sound and
//  their reports on UDP: Screen Sharing sends them
//  to the address the session's TCP connection comes from, at the ports a
//  client punches from (the server's own port and the next), so the other
//  Mac connects from one of its own addresses (a route) and binds its UDP
//  there. Which route works differs between Macs: this Mac asks for one by
//  number and, when no media comes, opens the road again for the next.
//
//  The other Mac reads nothing it carries: no frame of Screen Sharing's is
//  parsed there. What goes to this Mac waits for the road (TCP), so Screen
//  Sharing sees how fast this Mac takes its picture; datagrams are let go
//  when the road is that far behind, as a network would.
//

import Foundation
import Network
import Darwin

public enum ScreenTunnel {
    public static let word: UInt8 = 1
    public static let tcp: UInt8 = 2
    public static let udpControl: UInt8 = 3
    public static let udpVideo: UInt8 = 4
    /// Screen Sharing's port on every Mac; its UDP ports are this one and the next.
    public static let port: UInt16 = 5900
    /// The most a frame's body may hold.
    public static let largest = (1 << 24) - 1

    /// This Mac has Apple silicon: its Screen Sharing makes a display for a session and sends HEVC.
    public static let appleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    public static func frame(_ kind: UInt8, _ body: [UInt8]) -> Data {
        var d = Data(capacity: 4 + body.count)
        d.append(contentsOf: [kind, UInt8((body.count >> 16) & 0xff), UInt8((body.count >> 8) & 0xff), UInt8(body.count & 0xff)])
        d.append(contentsOf: body)
        return d
    }

    public static func word(_ object: [String: Any]) -> Data {
        frame(word, Array((try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)))
    }

    /// Cuts frames out of what arrives, in pieces of any size.
    public struct Parser {
        private var buffer: [UInt8] = []
        public init() {}

        /// The whole frames so far; nil when a frame says it is larger than any may be.
        public mutating func feed(_ data: Data) -> [(kind: UInt8, body: [UInt8])]? {
            buffer.append(contentsOf: data)
            var out: [(UInt8, [UInt8])] = []
            var at = 0
            while buffer.count - at >= 4 {
                let n = Int(buffer[at + 1]) << 16 | Int(buffer[at + 2]) << 8 | Int(buffer[at + 3])
                guard buffer.count - at - 4 >= n else { break }
                out.append((buffer[at], Array(buffer[(at + 4)..<(at + 4 + n)])))
                at += 4 + n
            }
            if at > 0 { buffer.removeFirst(at) }
            return out
        }
    }

    /// The other Mac's routes to its own Screen Sharing: from each of its own IPv4 addresses (not
    /// loopback, link-local or Tailscale's), plainly and with the UDP ports shared, then from
    /// loopback. The helper's client tried the same, in the same order.
    public struct Route: Equatable {
        public var name: String
        public var local: String
        public var udpBind: String
        public var reusePort: Bool
    }

    public static func routes() -> [Route] {
        var routes: [Route] = []
        var seen = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let i = p {
                defer { p = i.pointee.ifa_next }
                let flags = Int32(i.pointee.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let v = UInt32(bigEndian: addr.s_addr)
                let a = UInt8(v >> 24), b = UInt8((v >> 16) & 0xff)
                if a == 127 || (a == 169 && b == 254) || (a == 100 && b & 0xc0 == 64) { continue }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: text)
                guard seen.insert(ip).inserted else { continue }
                routes.append(Route(name: "own-to-lo:\(ip)", local: ip, udpBind: ip, reusePort: false))
                routes.append(Route(name: "own-to-lo-reuse:\(ip)", local: ip, udpBind: ip, reusePort: true))
            }
            freeifaddrs(first)
        }
        routes.append(Route(name: "lo", local: "127.0.0.1", udpBind: "", reusePort: false))
        routes.append(Route(name: "lo-reuse", local: "127.0.0.1", udpBind: "127.0.0.1", reusePort: true))
        return routes
    }
}

// MARK: - This Mac's end: the client's connection to the other Mac's Screen Sharing

/// The road to the other Mac's Screen Sharing, as the client uses it: a TCP connection it reads and
/// writes with blocking calls (ScreenIO), on a thread of its own, and the two UDP ports as datagrams
/// it sends and is handed.
public final class ScreenTunnelLink: ScreenIO, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.hopo.qingyan.screen.tunnel")
    private let condition = NSCondition()
    private var incoming: [UInt8] = []
    private var readAt = 0
    private var closed = false
    private var parser = ScreenTunnel.Parser()
    private var words: [[String: Any]] = []
    /// Datagrams from Screen Sharing: the control port's (0) and the video port's (1). Called on the
    /// tunnel's queue, one at a time, in order.
    public var onDatagram: ((Int, [UInt8]) -> Void)?
    /// Bytes of datagrams sent and not yet taken by the road.
    private var datagramsPending = 0
    private static let datagramsMost = 4 << 20

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public func start() {
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                guard let frames = self.parser.feed(data) else { self.close(); return }
                for (kind, body) in frames {
                    switch kind {
                    case ScreenTunnel.tcp:
                        self.condition.lock()
                        self.incoming.append(contentsOf: body)
                        self.condition.broadcast()
                        self.condition.unlock()
                    case ScreenTunnel.udpControl: self.onDatagram?(0, body)
                    case ScreenTunnel.udpVideo: self.onDatagram?(1, body)
                    case ScreenTunnel.word:
                        if let object = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] {
                            self.condition.lock()
                            self.words.append(object)
                            if object["t"] as? String == "closed" { self.closed = true }
                            self.condition.broadcast()
                            self.condition.unlock()
                        }
                    default: break
                    }
                }
            }
            if complete || error != nil { self.close(); return }
            self.receive()
        }
    }

    /// The next word from the other Mac, waiting at most `timeout`; nil when none came or the road closed.
    public func nextWord(timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while words.isEmpty && !closed {
            if !condition.wait(until: deadline) { break }
        }
        return words.isEmpty ? nil : words.removeFirst()
    }

    public func say(_ object: [String: Any]) {
        connection.send(content: ScreenTunnel.word(object), completion: .contentProcessed { _ in })
    }

    // ScreenIO
    public func readFull(_ count: Int) throws -> [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        while incoming.count - readAt < count {
            if closed { throw ScreenTunnelError.closed }
            condition.wait()
        }
        let out = Array(incoming[readAt..<(readAt + count)])
        consume(count)
        return out
    }

    /// Whatever has come, at least one byte and at most `most`, waiting for it; with a timeout, an
    /// empty answer when nothing came in that time.
    public func readSome(most: Int, timeout: TimeInterval? = nil) throws -> [UInt8] {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        condition.lock()
        defer { condition.unlock() }
        while incoming.count == readAt {
            if closed { throw ScreenTunnelError.closed }
            if let deadline {
                if !condition.wait(until: deadline) && incoming.count == readAt { return [] }
            } else {
                condition.wait()
            }
        }
        let n = min(most, incoming.count - readAt)
        let out = Array(incoming[readAt..<(readAt + n)])
        consume(n)
        return out
    }

    /// The next `count` bytes without taking them, once they have come; nil when they have not
    /// within `timeout`.
    public func peek(_ count: Int, timeout: TimeInterval) throws -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while incoming.count - readAt < count {
            if closed { throw ScreenTunnelError.closed }
            if !condition.wait(until: deadline) && incoming.count - readAt < count { return nil }
        }
        return Array(incoming[readAt..<(readAt + count)])
    }

    /// Drops whatever of the TCP connection has come and not been read: a connection hung up for
    /// another leaves nothing for it.
    public func forgetIncoming() {
        condition.lock()
        incoming.removeAll(keepingCapacity: true)
        readAt = 0
        condition.unlock()
    }

    private func consume(_ n: Int) {
        readAt += n
        if readAt == incoming.count { incoming.removeAll(keepingCapacity: true); readAt = 0 }
        else if readAt > 1 << 20 { incoming.removeFirst(readAt); readAt = 0 }
    }

    /// Writes and waits until the road has taken it, so a writer never runs ahead of the road.
    public func write(_ bytes: [UInt8]) throws {
        var at = 0
        repeat {
            let n = min(bytes.count - at, 60 << 10)
            let done = DispatchSemaphore(value: 0)
            var failed: NWError?
            connection.send(content: ScreenTunnel.frame(ScreenTunnel.tcp, Array(bytes[at..<(at + n)])), completion: .contentProcessed { error in
                failed = error
                done.signal()
            })
            done.wait()
            if failed != nil || isClosed { throw ScreenTunnelError.closed }
            at += n
        } while at < bytes.count
    }

    /// Sends a datagram to Screen Sharing's control (0) or video (1) port; dropped when the road is
    /// this far behind.
    public func sendDatagram(_ channel: Int, _ bytes: [UInt8]) {
        queue.sync {
            guard datagramsPending < Self.datagramsMost else { return }
            datagramsPending += bytes.count
        }
        let n = bytes.count
        connection.send(content: ScreenTunnel.frame(channel == 0 ? ScreenTunnel.udpControl : ScreenTunnel.udpVideo, bytes),
                        completion: .contentProcessed { [weak self] _ in self?.queue.async { self?.datagramsPending -= n } })
    }

    public var isClosed: Bool {
        condition.lock(); defer { condition.unlock() }
        return closed
    }

    public func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
        connection.cancel()
    }
}

public enum ScreenTunnelError: Error { case closed }

// MARK: - The other Mac's end: carrying bytes to its own Screen Sharing

/// On the Mac whose screen is shown: connects to its own Screen Sharing as the viewer asks (a route,
/// and UDP or not) and carries bytes and datagrams both ways without reading them. The viewer may
/// hang the TCP connection up and ask for another on the same route (Screen Sharing's own client
/// connects once, says hello and hangs up before its session: the warmup); the UDP ports stay.
///
/// Words from the viewer: connect {route, udp} and hangup. To it: connected {route, routes},
/// failed {why: no-vnc (Screen Sharing is off), bind, connect, no-route}, closed (Screen Sharing
/// hung up).
public final class ScreenForward: @unchecked Sendable {
    private let viewer: NWConnection
    private let queue = DispatchQueue(label: "local.hopo.qingyan.screen.forward")
    private var parser = ScreenTunnel.Parser()
    private var tcp: Int32 = -1
    /// The TCP connection was hung up from this side: its end is not Screen Sharing's.
    private var hungUp = false
    private var udp: [Int32] = [-1, -1]
    private var route: ScreenTunnel.Route?
    private var ended = false
    private var pumping = false
    /// Bytes of datagrams handed to the viewer's road and not yet taken.
    private var pending = 0
    private static let pendingMost = 4 << 20
    public var onEnd: (() -> Void)?

    public init(viewer: NWConnection) { self.viewer = viewer }

    public func start() { receive() }

    public func end() { queue.async { self.finish() } }

    private func receive() {
        viewer.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.ended else { return }
                if let data, !data.isEmpty {
                    guard let frames = self.parser.feed(data) else { self.finish(); return }
                    for (kind, body) in frames { self.take(kind, body) }
                }
                if complete || error != nil { self.finish(); return }
                self.receive()
            }
        }
    }

    private func take(_ kind: UInt8, _ body: [UInt8]) {
        switch kind {
        case ScreenTunnel.word:
            guard let object = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] else { return }
            switch object["t"] as? String {
            case "connect":
                guard tcp < 0 else { return }
                connect(route: object["route"] as? Int ?? 0, udp: object["udp"] as? Bool ?? false)
            case "hangup":
                guard tcp >= 0 else { return }
                hungUp = true
                shutdown(tcp, SHUT_RDWR)
            default: break
            }
        case ScreenTunnel.tcp:
            guard tcp >= 0, !hungUp else { return }
            if !Self.sendAll(tcp, body) { finish() }
        case ScreenTunnel.udpControl, ScreenTunnel.udpVideo:
            let i = kind == ScreenTunnel.udpControl ? 0 : 1
            guard udp[i] >= 0 else { return }
            var to = Self.address("127.0.0.1", ScreenTunnel.port + UInt16(i))
            _ = body.withUnsafeBytes { b in
                withUnsafePointer(to: &to) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(udp[i], b.baseAddress, body.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        default: break
        }
    }

    private func connect(route index: Int, udp wanted: Bool) {
        let routes = ScreenTunnel.routes()
        if route == nil {
            let chosen = wanted ? (routes.indices.contains(index) ? routes[index] : nil) : ScreenTunnel.Route(name: "lo", local: "127.0.0.1", udpBind: "", reusePort: false)
            guard let chosen else { fail("no-route", routes.count); return }
            route = chosen
            if wanted {
                for i in 0..<2 {
                    let fd = socket(AF_INET, SOCK_DGRAM, 0)
                    guard fd >= 0 else { fail("bind", routes.count); return }
                    var one: Int32 = 1
                    if chosen.reusePort {
                        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
                        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
                    }
                    var size: Int32 = 4 << 20
                    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
                    var at = Self.address(chosen.udpBind.isEmpty ? "0.0.0.0" : chosen.udpBind, ScreenTunnel.port + UInt16(i))
                    let bound = withUnsafePointer(to: &at) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                    guard bound == 0 else { Darwin.close(fd); fail("bind", routes.count); return }
                    udp[i] = fd
                }
            }
        }
        guard let route else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("connect", routes.count); return }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var local = Self.address(route.local, 0)
        var remote = Self.address("127.0.0.1", ScreenTunnel.port)
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        let connected = bound && withUnsafePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        guard connected else {
            let why = errno == ECONNREFUSED ? "no-vnc" : "connect"
            Darwin.close(fd)
            fail(why, routes.count)
            return
        }
        tcp = fd
        hungUp = false
        say(["t": "connected", "route": route.name, "routes": routes.count])
        if !pumping {
            pumping = true
            let thread = Thread { [weak self] in self?.pump() }
            thread.name = "local.hopo.qingyan.screen.forward"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    private func fail(_ why: String, _ routes: Int) {
        say(["t": "failed", "why": why, "route": route?.name ?? "", "routes": routes])
        finish()
    }

    /// Reads Screen Sharing's TCP and UDP and hands them to the viewer's road: a TCP read waits until
    /// the road has taken the last, so Screen Sharing is held back as the road is.
    private func pump() {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let (stop, tcp, udp) = queue.sync { (self.ended, self.tcp, self.udp) }
            if stop { return }
            var fds: [pollfd] = []
            if tcp >= 0 { fds.append(pollfd(fd: tcp, events: Int16(POLLIN), revents: 0)) }
            for fd in udp where fd >= 0 { fds.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0)) }
            if fds.isEmpty { usleep(20_000); continue }
            guard poll(&fds, nfds_t(fds.count), 200) >= 0 else { if errno == EINTR { continue }; return }
            for p in fds where p.revents != 0 {
                if p.fd == tcp {
                    let n = recv(tcp, &buffer, buffer.count, 0)
                    if n <= 0 {
                        // Hung up here (the viewer asked), or by Screen Sharing.
                        let ours = queue.sync { () -> Bool in
                            let ours = self.hungUp
                            if self.tcp == tcp { Darwin.close(tcp); self.tcp = -1 }
                            return ours
                        }
                        if !ours { say(["t": "closed"]); queue.async { self.finish() }; return }
                        continue
                    }
                    let done = DispatchSemaphore(value: 0)
                    var failed = false
                    viewer.send(content: ScreenTunnel.frame(ScreenTunnel.tcp, Array(buffer[0..<n])), completion: .contentProcessed { error in
                        failed = error != nil
                        done.signal()
                    })
                    done.wait()
                    if failed { queue.async { self.finish() }; return }
                } else if p.revents & Int16(POLLIN) != 0 {
                    let n = recv(p.fd, &buffer, buffer.count, 0)
                    guard n > 0 else { continue }
                    let kind = p.fd == udp[0] ? ScreenTunnel.udpControl : ScreenTunnel.udpVideo
                    let take = queue.sync { () -> Bool in
                        guard self.pending < Self.pendingMost else { return false }
                        self.pending += n
                        return true
                    }
                    guard take else { continue }
                    viewer.send(content: ScreenTunnel.frame(kind, Array(buffer[0..<n])), completion: .contentProcessed { [weak self] _ in
                        self?.queue.async { self?.pending -= n }
                    })
                }
            }
        }
    }

    private func say(_ object: [String: Any]) {
        viewer.send(content: ScreenTunnel.word(object), completion: .contentProcessed { _ in })
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        if tcp >= 0 {
            // Reset, as Screen Sharing's own viewer ends: its agent then goes at once.
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(tcp, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
            Darwin.close(tcp)
            tcp = -1
        }
        for i in 0..<2 where udp[i] >= 0 { Darwin.close(udp[i]); udp[i] = -1 }
        let viewer = viewer
        viewer.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in viewer.cancel() })
        let onEnd = onEnd
        DispatchQueue.main.async { onEnd?() }
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var at = 0
        while at < bytes.count {
            let n = bytes[at...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 { if errno == EINTR { continue }; return false }
            at += n
        }
        return true
    }

    private static func address(_ ip: String, _ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &a.sin_addr)
        return a
    }
}
