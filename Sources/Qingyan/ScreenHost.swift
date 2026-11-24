import AppKit
import Network
import QingyanCore

/// This Mac's screen, shown in another Mac's out (ScreenWire has the protocol). The picture, the
/// sound and the input are this Mac's own Screen Sharing: the Monitor helper here signs in to it
/// with the account name and password the viewer gives, and speaks ScreenWire
/// (helper/go/screenhp.go). out records nothing (until 0.1.59 it recorded the screen itself, which
/// macOS allows only with the Screen Recording permission; user 2026-11-22: take the recording out):
/// it lets a viewer in and carries the session between it and the helper. One viewer at a time.
///
/// The Monitor page shows this screen another way, by this Mac's own VNC through the helper alone
/// (helper/go/screen.go), and out has no part in it. Until 0.1.91 out had a switch for that, and kept
/// connections waiting at the helper while it was on (user 2026-11-25: remove it; the page's screen
/// follows the helper's console switch, as on any other machine).
@MainActor
final class ScreenHost: ObservableObject {
    enum State: Equatable {
        case off
        case viewing
    }
    @Published private(set) var state = State.off {
        didSet { if state != oldValue { onChange?() } }
    }
    /// Called when the state changes; set by the controller, which shows it.
    var onChange: (() -> Void)?
    /// While viewing: the other Mac whose out shows this screen.
    @Published private(set) var viewer: String?
    /// That Mac's key, so that its view ends once it is no longer trusted to work this Mac.
    private(set) var viewerKey: String?

    private var session: ScreenPipe?

    func stop() {
        session?.end("off")
        session = nil
        state = .off
    }

    /// Ends the view in progress.
    func stopViewing() { session?.end("stopped") }

    /// Another Mac's out asks to show this screen (RemoteReceiver.onScreen): a trusted Mac, allowed
    /// to type here, through the Monitor helper (user 2026-11-21: the Macs in Multiple Macs can be
    /// worked from each other's out).
    func serveRemote(_ connection: NWConnection, key: String, viewer: String) {
        guard session == nil else {
            // One at a time: the second is told so and let go.
            connection.send(content: ScreenWire.status(["s": "end", "why": "busy"]), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let next = ScreenPipe(viewer: connection)
        session = next
        self.viewer = viewer
        viewerKey = key
        state = .viewing
        next.onEnd = { [weak self, weak next] in
            Task { @MainActor in
                guard let self, self.session === next else { return }
                self.session = nil
                self.viewer = nil
                self.viewerKey = nil
                self.state = .off
            }
        }
        next.start()
    }
}

/// One view: the viewer's connection (a page's, handed over by the helper, or another Mac's out's)
/// joined to a session the helper opens with this Mac's Screen Sharing (HelperLink.screenStream).
/// out reads neither side; on the way to the viewer it follows only where frames begin, so that it
/// can end a view with a word of its own between two frames.
final class ScreenPipe: @unchecked Sendable {
    var onEnd: (() -> Void)?

    private let viewer: NWConnection
    private var helper: NWConnection?
    /// Everything the pipe keeps is touched on this queue.
    private let queue = DispatchQueue(label: "local.hopo.qingyan.screen")
    private var ended = false
    /// Why the view is to end, once the frame on its way to the viewer is through.
    private var ending: String?
    /// Of the frame going to the viewer: the header bytes seen, and the body bytes still to come.
    private var header: [UInt8] = []
    private var bodyLeft = 0
    /// How long the frame in progress may take to get through once the view is ending.
    private static let endingGrace: TimeInterval = 2

    init(viewer: NWConnection) { self.viewer = viewer }

    /// The viewer is read once the helper's session is there: it says nothing before the session's hello.
    func start() {
        Task {
            do {
                let connection = try await HelperLink.screenStream()
                queue.async { self.attach(connection) }
            } catch let refusal as HelperLink.ScreenStreamRefusal {
                // A helper that does not know the question is older than the High Performance session.
                queue.async { self.finish(refusal.code == "unknown-op" ? "helper-old" : "failed") }
            } catch {
                queue.async { self.finish((error as? HelperLink.Absence) == .notInstalled ? "helper-old" : "helper") }
            }
        }
    }

    /// Ends the view: between two frames, with the reason as the viewer's last word.
    func end(_ why: String) {
        queue.async {
            guard !self.ended else { return }
            if self.helper == nil || self.atBoundary { self.finish(why); return }
            // Nothing more from the viewer reaches the Mac from now on; and a viewer that does not take
            // the rest of the frame in time is let go without the last word.
            self.ending = why
            self.queue.asyncAfter(deadline: .now() + Self.endingGrace) { if !self.ended { self.finish(why) } }
        }
    }

    private var atBoundary: Bool { header.isEmpty && bodyLeft == 0 }

    private func attach(_ connection: NWConnection) {
        guard !ended else { connection.cancel(); return }
        helper = connection
        fromViewer()
        fromHelper()
    }

    private func fromViewer() {
        guard let helper else { return }
        viewer.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                // An ending view takes no more input: what the viewer still sends goes nowhere.
                guard !self.ended, self.ending == nil else { return }
                if let data, !data.isEmpty {
                    helper.send(content: data, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        self.queue.async {
                            if error != nil { self.finish(nil); return }
                            if complete { self.finish(nil) } else { self.fromViewer() }
                        }
                    })
                    return
                }
                if complete || error != nil { self.finish(nil); return }
                self.fromViewer()
            }
        }
    }

    private func fromHelper() {
        guard let helper else { return }
        helper.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.ended else { return }
                guard let data, !data.isEmpty else {
                    if complete || error != nil { self.finish(nil) } else { self.fromHelper() }
                    return
                }
                let (passed, rest) = self.cut(data)
                self.viewer.send(content: passed, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.ended else { return }
                        if error != nil { self.finish(nil); return }
                        if let why = self.ending, rest != nil { self.finish(why); return }
                        if complete { self.finish(nil) } else { self.fromHelper() }
                    }
                })
            }
        }
    }

    /// What of `data` goes to the viewer now: all of it, or, while the view is ending, up to the end
    /// of the frame in progress (and non-nil `rest`, which is let go).
    private func cut(_ data: Data) -> (Data, Data?) {
        var at = data.startIndex
        while at < data.endIndex {
            if bodyLeft > 0 {
                let take = min(bodyLeft, data.endIndex - at)
                at += take
                bodyLeft -= take
                continue
            }
            if header.isEmpty, ending != nil { return (Data(data[data.startIndex..<at]), Data(data[at...])) }
            header.append(data[at])
            at += 1
            if header.count == 4 {
                bodyLeft = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
                header = []
            }
        }
        if ending != nil, atBoundary { return (data, Data()) }
        return (data, nil)
    }

    /// The end of the view: `why` is said to the viewer first when there is something to say and the
    /// viewer is between frames.
    private func finish(_ why: String?) {
        guard !ended else { return }
        ended = true
        helper?.cancel()
        let viewer = viewer
        if let why, atBoundary || helper == nil {
            viewer.send(content: ScreenWire.status(["s": "end", "why": why]), completion: .contentProcessed { _ in viewer.cancel() })
        } else {
            viewer.cancel()
        }
        let onEnd = onEnd
        DispatchQueue.main.async { onEnd?() }
    }
}
