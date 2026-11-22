#if DEBUG
import AppKit
import Network
import QingyanCore

/// out's two halves of a screen session joined in one process: ScreenPipe, as the Mac being viewed
/// runs it, and ScreenLink, as the viewing window runs it, over a local socket. The helper's side is
/// whatever answers at the socket given; the helper's own test serves its real session there
/// (TestScreenHPServeSocket), signed in to this Mac's Screen Sharing. Signs in, watches for ten
/// seconds, presses Stop, and writes what the viewer counted:
/// `Qingyan --screen-pipe-selftest <helper socket> <account> <report.json>`, the password in
/// OUT_SCREEN_PASSWORD.
enum ScreenPipeSelfTest {
    @MainActor private final class Seen {
        var statuses: [String] = []
        var ended: String?
        var pipe: ScreenPipe?
    }

    @MainActor static func run(socket: String, account: String, report: String) async throws -> Bool {
        HelperLink.socketOverride = socket
        let password = ProcessInfo.processInfo.environment["OUT_SCREEN_PASSWORD"] ?? ""
        let seen = Seen()
        let path = NSTemporaryDirectory() + "out-pipe-\(getpid()).sock"
        unlink(path)
        defer { unlink(path) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            MainActor.assumeIsolated {
                let pipe = ScreenPipe(viewer: connection)
                seen.pipe = pipe
                pipe.start()
            }
        }
        listener.start(queue: .main)
        try await Task.sleep(nanoseconds: 300_000_000)
        let viewer = NWConnection(to: .unix(path: path), using: .tcp)
        viewer.start(queue: .main)
        for _ in 0..<50 where viewer.state != .ready { try await Task.sleep(nanoseconds: 100_000_000) }
        guard viewer.state == .ready else { throw VoiceError("The self-test could not reach its own socket.") }

        let link = ScreenLink(name: "self-test")
        link.onStatus = { status in seen.statuses.append(status["s"] as? String ?? "?") }
        link.onHello = { _, codecs in
            seen.statuses.append("hello")
            link.send(ScreenWire.control(["t": "open", "codecs": codecs, "audio": true, "kbps": ScreenWire.kbpsDefault,
                                          "user": account, "password": password]))
        }
        link.onEnd = { why in seen.ended = why }
        link.start(viewer, scale: 2)

        try await Task.sleep(nanoseconds: 10_000_000_000)
        let watched = link.counts
        seen.pipe?.end("stopped")
        for _ in 0..<30 where seen.ended == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        listener.cancel()
        link.close()

        let result: [String: Any] = ["statuses": seen.statuses, "ended": seen.ended ?? "", "counts": watched]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: report))
        return (watched["enqueued"] ?? 0) > 10 && seen.ended == "stopped"
    }
}
#endif
