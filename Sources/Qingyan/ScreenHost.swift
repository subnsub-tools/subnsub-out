import AppKit
import Network
import QingyanCore

/// This Mac's screen, shown in another Mac's out. The picture, the sound and the input are this
/// Mac's own Screen Sharing, and the client is that other Mac's out (ScreenClient.swift): out here
/// only carries Screen Sharing's bytes between the road the helpers keep and this Mac's own port
/// (ScreenForward in ScreenTunnel.swift), and reads none of them (user 2026-11-25: the helper only
/// gives a road and a port; it has nothing to do with screen sharing). Until then the Monitor helper
/// here signed in to Screen Sharing for the viewer and spoke ScreenWire (helper/go/screenhp.go).
/// out records nothing (until 0.1.59 it recorded the screen itself, which macOS allows only with
/// the Screen Recording permission). One viewer at a time.
///
/// The Monitor page shows this screen another way, by this Mac's own VNC through the helper alone
/// (helper/go/screen.go), and out has no part in it. Until 0.1.91 out had a switch for that (user
/// 2026-11-25: remove it; the page's screen follows the helper's console switch, as on any other
/// machine).
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

    private var forward: ScreenForward?

    func stop() {
        forward?.end()
        forward = nil
        viewer = nil
        viewerKey = nil
        state = .off
    }

    /// Ends the view in progress.
    func stopViewing() { forward?.end() }

    /// Another Mac's out asks to show this screen (RemoteReceiver.onScreen): a trusted Mac, allowed
    /// to type here, through the Monitor helper (user 2026-11-21: the Macs in Multiple Macs can be
    /// worked from each other's out).
    func serveRemote(_ connection: NWConnection, key: String, viewer: String) {
        guard forward == nil else {
            // One at a time: the second is told so and let go.
            connection.send(content: ScreenTunnel.word(["t": "failed", "why": "busy"]), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let next = ScreenForward(viewer: connection)
        forward = next
        self.viewer = viewer
        viewerKey = key
        state = .viewing
        next.onEnd = { [weak self, weak next] in
            MainActor.assumeIsolated {
                guard let self, self.forward === next else { return }
                self.forward = nil
                self.viewer = nil
                self.viewerKey = nil
                self.state = .off
            }
        }
        next.start()
    }
}
