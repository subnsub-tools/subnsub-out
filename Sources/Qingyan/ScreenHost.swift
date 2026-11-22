import AppKit
import Network
import QingyanCore

/// This Mac's screen, shown on the owner's Monitor page and in another Mac's out (ScreenWire has
/// the protocol). The picture, the sound and the input are this Mac's own Screen Sharing in its
/// High Performance mode: the Monitor helper here signs in to it with the account name and
/// password the viewer gives, and speaks ScreenWire (helper/go/screenhp.go). out recorded the
/// screen itself until 0.1.59, which macOS allows only with the Screen Recording permission; now
/// it lets a viewer in and carries the session between it and the helper (user 2026-11-22: why
/// should out need the Screen Recording permission when Screen Sharing is on; take the recording out).
///
/// For the Monitor page, out keeps a connection or two waiting at the helper while the switch is
/// on; another Mac's out needs no switch (RemoteReceiver.onScreen). One viewer at a time.
@MainActor
final class ScreenHost: ObservableObject {
    enum State: Equatable {
        case off
        /// Waiting at the helper for a page.
        case waiting
        case viewing
        /// The helper could not be asked, and why.
        case unavailable(String)
    }
    @Published private(set) var state = State.off {
        didSet { if state != oldValue { onChange?() } }
    }
    /// Called when the state changes; set by the controller, which shows it.
    var onChange: (() -> Void)?
    /// While viewing: the other Mac whose out shows this screen, or nil for the Monitor page.
    @Published private(set) var viewer: String?
    /// That Mac's key, so that its view ends once it is no longer trusted to work this Mac.
    private(set) var viewerKey: String?

    private var loops: [Task<Void, Never>] = []
    private var generation = 0
    private var parked: [ObjectIdentifier: NWConnection] = [:]
    private var session: ScreenPipe?

    func start() {
        guard loops.isEmpty else { return }
        let generation = generation
        // Another Mac may be viewing already; it still is.
        if session == nil { state = .waiting }
        for _ in 0..<2 { loops.append(Task { @MainActor [weak self] in await self?.loop(generation) }) }
    }

    func stop() {
        generation += 1
        for loop in loops { loop.cancel() }
        loops.removeAll()
        for connection in parked.values { connection.cancel() }
        parked.removeAll()
        session?.end("off")
        session = nil
        state = .off
    }

    /// The Monitor page's switch is off: out no longer waits at the helper for a page, and a page's
    /// view ends; another Mac's out that shows this screen goes on.
    func stopWaiting() {
        guard !loops.isEmpty || (session != nil && viewer == nil) else { return }
        generation += 1
        for loop in loops { loop.cancel() }
        loops.removeAll()
        for connection in parked.values { connection.cancel() }
        parked.removeAll()
        if session != nil, viewer == nil { session?.end("off") }
        if session == nil { state = .off }
    }

    /// Ends the view in progress; out goes on waiting for the next.
    func stopViewing() { session?.end("stopped") }

    private func loop(_ generation: Int) async {
        var pause: UInt64 = 1
        while !Task.isCancelled && generation == self.generation {
            do {
                let connection = try await HelperLink.parkScreen()
                guard !Task.isCancelled, generation == self.generation else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                parked[id] = connection
                if session == nil, state != .waiting { state = .waiting }
                do { try await HelperLink.screenArrival(connection) }
                catch { parked.removeValue(forKey: id); connection.cancel(); throw error }
                parked.removeValue(forKey: id)
                guard !Task.isCancelled, generation == self.generation else { connection.cancel(); return }
                pause = 1
                serve(connection)
            } catch {
                if Task.isCancelled || generation != self.generation { return }
                if session == nil {
                    let absence = error as? HelperLink.Absence
                    state = .unavailable(absence == .notInstalled
                        ? tr("The Monitor helper on this Mac is not installed, or is too old to show the screen. Install or update it from the Monitor page.")
                        : tr("The Monitor helper on this Mac is not running."))
                }
                try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
                pause = min(pause * 2, 30)
            }
        }
    }

    /// Another Mac's out asks to show this screen (RemoteReceiver.onScreen): a trusted Mac, allowed
    /// to type here, through the Monitor helper. It needs no switch (user 2026-11-21: the Macs in
    /// Multiple Macs can be worked from each other's out); the switch is the Monitor page's.
    func serveRemote(_ connection: NWConnection, key: String, viewer: String) {
        // Started already: it came through the helper, as a page's does.
        serve(connection, viewer: viewer, key: key)
    }

    private func serve(_ connection: NWConnection, viewer: String? = nil, key: String? = nil) {
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
                if self.state == .viewing { self.state = self.loops.isEmpty ? .off : .waiting }
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
