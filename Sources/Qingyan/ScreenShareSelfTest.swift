#if DEBUG
import AppKit
import Network
import QingyanCore

/// out's two halves of a screen session joined in one process, against this Mac's own Screen
/// Sharing: ScreenForward, as the Mac being viewed runs it, and ScreenLink with out's own client,
/// as the viewing window runs it, over a local socket in place of the helpers' road. Signs in,
/// watches for ten seconds, takes a screenshot as the window's toolbar does, ends, and writes what
/// the viewer counted:
/// `Qingyan --screen-selftest <account> <report.json> [standard|hp]`, the password in
/// OUT_SCREEN_PASSWORD.
enum ScreenShareSelfTest {
    @MainActor private final class Seen {
        var statuses: [String] = []
        var notes: [String] = []
        var ended: String?
        var forwards: [ScreenForward] = []
        var shot: (width: Int, height: Int)?
        var shotDone = false
    }

    @MainActor static func run(account: String, report: String, highPerformance: Bool) async throws -> Bool {
        let password = ProcessInfo.processInfo.environment["OUT_SCREEN_PASSWORD"] ?? ""
        let seen = Seen()
        let path = NSTemporaryDirectory() + "out-share-\(getpid()).sock"
        unlink(path)
        defer { unlink(path) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            MainActor.assumeIsolated {
                let forward = ScreenForward(viewer: connection)
                seen.forwards.append(forward)
                forward.start()
            }
        }
        listener.start(queue: .main)
        try await Task.sleep(nanoseconds: 300_000_000)
        @Sendable func road() -> ScreenTunnelLink? {
            let connection = NWConnection(to: .unix(path: path), using: .tcp)
            let ready = DispatchSemaphore(value: 0)
            connection.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
            connection.start(queue: DispatchQueue(label: "local.hopo.qingyan.selftest.road"))
            guard ready.wait(timeout: .now() + 5) == .success else { connection.cancel(); return nil }
            return ScreenTunnelLink(connection)
        }
        let first = await Task.detached { road() }.value
        guard let first else { throw VoiceError("The self-test could not reach its own socket.") }

        let link = ScreenLink(name: "self-test")
        link.onStatus = { status in
            let s = status["s"] as? String ?? "?"
            seen.statuses.append(s)
            if s == "note", let text = status["text"] as? String { seen.notes.append(text) }
            if s == "end" { seen.notes.append("end: \(status["why"] as? String ?? "")") }
            if s == "stats" { seen.notes.append("stats: keyframes \(status["keyframes"] ?? 0), asks \(status["asks"] ?? 0), lost \(status["lost"] ?? 0), bad \(status["bad"] ?? 0), fps \(status["fps"] ?? 0), kbps \(status["kbps"] ?? 0)") }
        }
        link.onHello = { _, codecs in
            seen.statuses.append("hello")
            var open: [String: Any] = ["t": "open", "codecs": codecs, "audio": true, "kbps": ScreenWire.kbpsDefault,
                                       "user": account, "password": password]
            if !highPerformance { open["standard"] = true; open["jpeg"] = true; open["scaled"] = true; open["mvs"] = true }
            link.send(ScreenWire.control(open))
        }
        link.onEnd = { why in seen.ended = why }
        // Something on the screen that keeps changing, so that the session always has a picture to send.
        let blinker = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 160, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        blinker.level = .floating
        blinker.backgroundColor = .systemRed
        blinker.orderFrontRegardless()
        var flip = false
        let blink = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                flip.toggle()
                blinker.backgroundColor = flip ? .systemBlue : .systemRed
            }
        }
        defer { blink.invalidate(); blinker.orderOut(nil) }
        let host = ScreenSession.Host(name: "self-test", user: account, appleSilicon: ScreenTunnel.appleSilicon)
        link.start(first, host: host, reopen: { road() }, scale: 2)

        try await Task.sleep(nanoseconds: 14_000_000_000)
        let watched = link.counts
        link.capture { image in
            seen.shot = image.map { ($0.width, $0.height) }
            seen.shotDone = true
        }
        for _ in 0..<70 where !seen.shotDone { try await Task.sleep(nanoseconds: 100_000_000) }
        for forward in seen.forwards { forward.end() }
        for _ in 0..<30 where seen.ended == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        listener.cancel()
        link.close()

        let result: [String: Any] = ["statuses": seen.statuses, "notes": seen.notes, "ended": seen.ended ?? "", "counts": watched,
                                     "screenshot": seen.shot.map { "\($0.width)x\($0.height)" } ?? ""]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: report))
        return (watched["enqueued"] ?? 0) > 10 && seen.shot != nil
    }
}
#endif
