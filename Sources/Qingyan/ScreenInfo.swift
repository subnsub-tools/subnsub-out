import AppKit
import QingyanCore
import SwiftUI

/// What the screen window tells of the way to the other Mac and of the stream on it (user 2026-11-22:
/// when working a Mac remotely, everything is shown: whether it goes by DERP, a peer relay or
/// directly, and `tailscale ping --c 0 --until-direct=false`). The road the stream was opened on
/// comes from this Mac's helper (HelperLink.route); both roads' pings, a line a second, from it too
/// (HelperLink.path, helper/go/put_path.go); the stream's numbers from the other Mac's helper
/// (status "stats"), and what this Mac decodes from the window's own count.
@MainActor
final class ScreenInfo: ObservableObject {
    struct Ping: Identifiable {
        let id = UUID()
        let at: Date
        let ok: Bool
        let ms: Double
        /// direct, peer-relay or derp; the endpoint, the relay or the region; the node's name; why
        /// there was no pong.
        let via: String, place: String, node: String, why: String
    }

    struct Road {
        var pings: [Ping] = []
        /// The helper's last word on this road was a ping, not that there is nothing to ping.
        var current = false
        /// The path as it is now: the last ping, while the road is there.
        var now: Ping? { current ? pings.last : nil }
        /// Of the last `window` pings: the fastest pong, the mean and the slowest, and the share with none.
        func summary(_ window: Int = 60) -> (min: Double, avg: Double, max: Double, loss: Double)? {
            let recent = pings.suffix(window)
            guard !recent.isEmpty else { return nil }
            let good = recent.filter(\.ok).map(\.ms)
            let loss = Double(recent.count - good.count) / Double(recent.count)
            guard let low = good.min(), let high = good.max() else { return (0, 0, 0, loss) }
            return (low, good.reduce(0, +) / Double(good.count), high, loss)
        }
    }

    let device: String
    /// How this Mac's helper reached that Mac for the stream: "tailnet", "direct" or "derp" (its
    /// tunnel), "" from a helper too old to say (the tunnel, then); nil until the stream is open.
    @Published var route: String?
    @Published var tailnet = Road()
    @Published var tailcat = Road()
    /// Why there are no pings, when that is known.
    @Published var pathNote: String?
    /// The stream's numbers as the other Mac's helper counts them, every two seconds.
    @Published var helper: [String: Double] = [:]
    /// What this Mac decodes: pictures and kilobits a second.
    @Published var local = (fps: 0.0, kbps: 0.0)
    @Published var layout: ScreenWire.Layout?
    @Published var codec = ""
    @Published var own = false
    @Published var sound = true
    @Published var observing = false
    @Published var viewOnly = false
    @Published var fullQuality = false
    @Published var account = ""
    @Published var since: Date?
    @Published var live = false
    /// What the window's buttons and title strip show: the window's settings, whether a session is under way, whether the
    /// pointer and keys go to that Mac, Info open, and full screen.
    @Published var scaled = true
    @Published var clipboard = true
    @Published var ended = true
    @Published var controlling = false
    @Published var showingInfo = false
    @Published var fullScreen = false
    /// The rail at the picture's right shows all its buttons, not Full Screen and More alone: with
    /// the title strip and the line (ScreenContainer says when).
    @Published var railOpen = true
    static let history = 300

    init(device: String) { self.device = device }

    /// A new session: what the last one showed goes; the pings go on.
    func reset() {
        route = nil
        helper = [:]
        local = (0, 0)
        layout = nil
        codec = ""
        account = ""
        since = nil
        live = false
        viewOnly = false
    }

    /// One line of the helper's path report: a ping on one road, or null for a road with nothing
    /// to ping (no longer on a tailnet with that Mac, no tunnel to it).
    func add(_ line: [String: Any]) {
        let at = (line["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
        take(line["tailnet"], at: at, into: &tailnet)
        take(line["tailcat"], at: at, into: &tailcat)
    }

    private func take(_ value: Any?, at: Date, into road: inout Road) {
        switch value {
        case let o as [String: Any]:
            push(&road, Self.ping(o, at: at))
            road.current = true
        case is NSNull:
            road.current = false
        default:
            break
        }
    }

    /// The report stopped: neither road's last ping is the path any more.
    func pathLost() {
        tailnet.current = false
        tailcat.current = false
    }

    private func push(_ road: inout Road, _ ping: Ping) {
        road.pings.append(ping)
        if road.pings.count > Self.history { road.pings.removeFirst(road.pings.count - Self.history) }
    }

    static func ping(_ o: [String: Any], at: Date) -> Ping {
        Ping(at: at, ok: o["ok"] as? Bool == true, ms: (o["ms"] as? NSNumber)?.doubleValue ?? 0,
             via: o["via"] as? String ?? "", place: o["where"] as? String ?? "", node: o["node"] as? String ?? "",
             why: o["why"] as? String ?? "")
    }

    /// The road the stream goes by, by name.
    var roadName: String? {
        guard let route else { return nil }
        return route == "tailnet" ? "tailnet" : "tailcat"
    }

    /// The pings of the road the stream goes by.
    var inUse: Road { route == "tailnet" ? tailnet : tailcat }

    static func path(_ p: Ping) -> String {
        guard p.ok else {
            switch p.why {
            case "absent": return tr("Tailscale is not running on this Mac")
            case "timeout", "no-pong": return tr("No answer")
            case "local": return tr("This Mac")
            default: return tr("Not known")
            }
        }
        switch p.via {
        case "direct": return tr("Direct") + " " + p.place
        case "peer-relay": return tr("Peer relay") + " " + p.place
        case "derp": return "DERP (\(p.place))"
        // This Mac is not on the tailnet itself: its router is, and carries it there.
        case "router": return tr("Through the router")
        default: return p.via
        }
    }

    /// A ping as `tailscale ping` prints it.
    static func line(_ p: Ping) -> String {
        let time = p.at.formatted(date: .omitted, time: .standard)
        guard p.ok else { return "\(time)  " + (p.why.isEmpty ? "no pong" : p.why) }
        let via: String
        switch p.via {
        case "derp": via = "DERP(\(p.place))"
        case "peer-relay": via = "peer-relay(\(p.place))"
        default: via = p.place
        }
        // The node's own name, as `tailscale ping` prints it, without its tailnet's.
        let node = p.node.split(separator: ".").first.map(String.init) ?? ""
        return "\(time)  pong from \(node.isEmpty ? "" : node + " ")via \(via) in \(Self.ms(p.ms))"
    }

    static func ms(_ v: Double) -> String { v < 10 ? String(format: "%.1fms", v) : String(format: "%.0fms", v) }

    static func rate(_ kbps: Double) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", kbps / 1000) : String(format: "%.0f kbps", kbps)
    }

    static func codecName(_ codec: String) -> String { codec == "hevc" ? "HEVC" : codec == "avc" ? "H.264" : codec }

    /// The window's bottom line: the road, the path and its ping; the display, the codec, pictures
    /// and bits a second, and whether the pointer and keys go there.
    var summary: String {
        var parts: [String] = []
        if let roadName { parts.append(roadName) }
        if let p = inUse.now {
            parts.append(Self.path(p))
            if p.ok { parts.append(Self.ms(p.ms)) }
        } else if route == "derp" {
            parts.append("DERP")
        } else if route == "direct" {
            parts.append(tr("Direct"))
        }
        var stream: [String] = []
        if live {
            if let layout { stream.append("\(layout.width)×\(layout.height)") }
            if !codec.isEmpty { stream.append(Self.codecName(codec)) }
            stream.append(String(format: "%.0f fps", helper["fps"] ?? local.fps))
            stream.append(Self.rate(helper["kbps"] ?? local.kbps))
            stream.append(viewOnly ? tr("View only") : observing ? tr("Observing") : tr("Controlling"))
        }
        let line = parts.joined(separator: " · ")
        if stream.isEmpty { return line }
        return line.isEmpty ? stream.joined(separator: " · ") : line + "    " + stream.joined(separator: " · ")
    }
}

/// What the rail's buttons ask the window to do.
enum ScreenAction {
    case observe(Bool), scaling(Bool), dynamic(Bool), quality(Bool), clipboard(Bool), sound(Bool)
    case keys, screenshot, fullScreen, connection
}

/// The screen window's title strip, on its glass as the panel's is (user 2026-11-22: the remote
/// desktop window in the same glass design as out's own): the Mac's name with a dot for whether its
/// screen is shown, beside the window's close, minimize and zoom buttons. The buttons that were here
/// are down the picture's right side (ScreenRail).
struct ScreenTitleRow: View {
    @ObservedObject var info: ScreenInfo

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            HStack(alignment: .top, spacing: 2) {
                Text(info.device).font(.system(size: 13, weight: .bold)).lineLimit(1).truncationMode(.tail)
                Circle().fill(info.live ? Palette.accent : info.ended ? Color.orange : Palette.muted)
                    .frame(width: 6, height: 6).padding(.top, 1)
            }
            .help(info.live ? tr("Showing its screen") : info.ended ? tr("Not connected") : tr("Connecting…"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(info.device + " · " + (info.live ? tr("Showing its screen") : info.ended ? tr("Not connected") : tr("Connecting…")))
            .frame(height: 22)
            Spacer(minLength: 8)
        }
        // The window's close, minimize and zoom buttons sit at the start of the strip where macOS puts
        // them, and the name is level with them; in full screen they are gone.
        .padding(.top, ScreenContainer.lightsMiddle - 11)
        .padding(.leading, info.fullScreen ? 12 : 76)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: ScreenContainer.rowHeight, maxHeight: ScreenContainer.rowHeight, alignment: .top)
        .background(WindowDragArea())
        .foregroundStyle(Palette.ink).tint(Palette.accent)
        .ignoresSafeArea()
    }
}

/// The window's buttons, round and floating over the picture down its right side (user 2026-11-23:
/// no buttons at the top; two floating buttons at the right, Full Screen and More, as the preview
/// window of the user's playhub has them; the pointer on More brings the rest; each is named only
/// while the pointer is on it; all of them at the window's right, in full screen too). They are what
/// Screen Sharing's own toolbar has, lit while on. Where the window is too short for one column, the
/// next goes to its left. Dark with white signs whatever the appearance: they lie on that Mac's
/// picture, not on this window's glass.
struct ScreenRail: View {
    @ObservedObject var info: ScreenInfo
    var act: (ScreenAction) -> Void = { _ in }
    /// A press of More: the pointer on it has already brought the rest (ScreenContainer follows it).
    var more: () -> Void = {}

    static let side: CGFloat = 34
    static let gap: CGFloat = 6
    /// Full Screen and More, then what More brings.
    static let count = 12
    static let moreIndex = 1
    static let scalingIndex = 3
    static let lit = Color(red: 0.72, green: 0.84, blue: 0.60)

    /// How many buttons a column holds in a room that tall.
    static func rows(in height: CGFloat) -> Int { max(2, Int((height + gap) / (side + gap))) }

    /// Where a button is in the rail's room: from the room's top right, down, then the next column to the left.
    static func frame(of index: Int, in room: CGRect) -> CGRect {
        let rows = Self.rows(in: room.height)
        return CGRect(x: room.maxX - side - CGFloat(index / rows) * (side + gap), y: room.minY + CGFloat(index % rows) * (side + gap), width: side, height: side)
    }

    /// The part of the room the first `shown` buttons take.
    static func region(shown: Int, in room: CGRect) -> CGRect {
        let rows = Self.rows(in: room.height)
        let columns = (shown + rows - 1) / rows, tall = min(shown, rows)
        let width = CGFloat(columns) * side + CGFloat(max(columns - 1, 0)) * gap
        return CGRect(x: room.maxX - width, y: room.minY, width: width, height: CGFloat(tall) * side + CGFloat(max(tall - 1, 0)) * gap)
    }

    var body: some View {
        GeometryReader { geometry in
            let rows = Self.rows(in: geometry.size.height)
            let shown = info.railOpen ? Self.count : 2
            let columns = (shown + rows - 1) / rows
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(Array((0..<columns).reversed()), id: \.self) { column in
                    VStack(spacing: Self.gap) {
                        ForEach(Array((column * rows)..<min((column + 1) * rows, shown)), id: \.self) { index in
                            button(index)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
        }
    }

    @ViewBuilder private func button(_ index: Int) -> some View {
        switch index {
        case 0:
            ScreenRailButton(symbol: info.fullScreen ? "arrow.down.forward.and.arrow.up.backward" : "arrow.up.backward.and.arrow.down.forward",
                             title: tr("Full Screen"), active: info.fullScreen, hint: tr("Enter or leave full screen")) {
                act(.fullScreen)
            }
        case 1:
            ScreenRailButton(symbol: "ellipsis", title: tr("More"), active: false, hint: "") { more() }
        case 2:
            ScreenRailButton(symbol: "eye", title: tr("Observe"), active: info.observing,
                             hint: tr("Observe: only watch that Mac; the pointer and keys stay here")) {
                act(.observe(!info.observing))
            }
            .disabled(info.viewOnly)
        case 3:
            ScreenRailButton(symbol: "arrow.down.right.and.arrow.up.left", title: tr("Scaling"), active: info.scaled,
                             hint: tr("Scale the screen to fit the window. Off: it is shown at its own size, and the window scrolls when the pointer reaches an edge.")) {
                act(.scaling(!info.scaled))
            }
        case 4:
            ScreenRailButton(symbol: "aspectratio", title: tr("Dynamic Resolution"), active: info.own,
                             hint: tr("The other Mac shows its screen on a display of its own that follows this window’s size. Its own displays are dark while you view it.")) {
                act(.dynamic(!info.own))
            }
        case 5:
            ScreenRailButton(symbol: "sparkles", title: tr("Full Quality"), active: info.fullQuality,
                             hint: tr("Full Quality lets Screen Sharing send up to 60 Mbps. Off: Adaptive Quality, up to 12 Mbps.")) {
                act(.quality(!info.fullQuality))
            }
        case 6:
            ScreenRailButton(symbol: "doc.on.clipboard", title: tr("Shared Clipboard"), active: info.clipboard,
                             hint: tr("Text copied on either Mac can be pasted on the other while this window is in front.")) {
                act(.clipboard(!info.clipboard))
            }
        case 7:
            ScreenRailButton(symbol: info.sound ? "speaker.wave.2" : "speaker.slash", title: tr("Sound"), active: info.sound,
                             hint: tr("Play that Mac’s sound on this Mac.")) {
                act(.sound(!info.sound))
            }
        case 8:
            ScreenRailButton(symbol: "command", title: tr("Keys"), active: false, hint: tr("Send keys that this Mac keeps for itself")) {
                act(.keys)
            }
            .disabled(!info.controlling)
        case 9:
            ScreenRailButton(symbol: "camera", title: tr("Screenshot"), active: false, hint: tr("Save a picture of the screen to this Mac’s Desktop")) {
                act(.screenshot)
            }
            .disabled(!info.live)
        case 10:
            ScreenRailButton(symbol: "info.circle", title: tr("Info"), active: info.showingInfo,
                             hint: tr("Everything known of the connection and the stream")) {
                info.showingInfo.toggle()
            }
            .accessibilityLabel(tr("Connection Info"))
            .popover(isPresented: $info.showingInfo, arrowEdge: .leading) { ScreenInfoView(info: info) }
        case 11:
            ScreenRailButton(symbol: info.ended ? "arrow.clockwise" : "xmark.circle", title: info.ended ? tr("Connect") : tr("Disconnect"), active: false,
                             hint: info.ended ? tr("Connect to %@ again", info.device) : tr("End the session")) {
                act(.connection)
            }
        default:
            EmptyView()
        }
    }
}

/// A button of the rail: a dark round with its sign, and its name beside it, at its left, only
/// while the pointer is on it.
private struct ScreenRailButton: View {
    let symbol: String
    let title: String
    let active: Bool
    let hint: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? ScreenRail.lit : Color.white)
                .frame(width: ScreenRail.side, height: ScreenRail.side)
                .background(Color.black.opacity(hovered ? 0.64 : 0.46), in: Circle())
                .overlay(Circle().stroke(active ? ScreenRail.lit.opacity(0.7) : Color.white.opacity(0.28), lineWidth: 0.8))
                .opacity(enabled ? 1 : 0.5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .overlay(alignment: .trailing) {
            if hovered {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.64), in: Capsule())
                    .fixedSize()
                    .offset(x: -(ScreenRail.side + 6))
                    .allowsHitTesting(false)
            }
        }
        .zIndex(hovered ? 1 : 0)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The line under the picture; a click opens Info.
struct ScreenInfoBar: View {
    @ObservedObject var info: ScreenInfo
    var open: () -> Void = {}

    var body: some View {
        Button(action: open) { line }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Connection Info"))
            .accessibilityValue(info.summary)
            .help(tr("Everything known of the connection and the stream"))
    }

    private var line: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(info.summary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let note = info.pathNote {
                Text(note).lineLimit(1).truncationMode(.tail).foregroundStyle(.orange)
            }
            Image(systemName: "info.circle")
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        // On the window's glass, as the panel's rows are.
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private var dot: Color {
        switch info.inUse.now.map({ $0.ok ? $0.via : "none" }) ?? (info.route == "derp" ? "derp" : info.route == "direct" ? "direct" : "") {
        case "direct": return .green
        case "peer-relay": return .yellow
        case "derp": return .orange
        // Reached, by the router's own path there, which this Mac cannot see.
        case "router": return .teal
        case "none": return .red
        default: return .gray
        }
    }
}

/// Everything known of the connection and the stream, in a popover.
struct ScreenInfoView: View {
    @ObservedObject var info: ScreenInfo
    /// In a scroll view of the popover's height; the previews draw it whole.
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollView { content }.frame(width: Self.width, height: 580)
        } else {
            content
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                section(tr("Connection")) {
                    row(tr("Road in use"), info.roadName ?? "—")
                    road("tailnet", info.tailnet, missing: tr("Not on a tailnet with this Mac, or its address there is not known"))
                    road("tailcat", info.tailcat, missing: tr("No tunnel to that Mac"))
                    if let note = info.pathNote { row("", note) }
                }
                section(tr("Ping")) {
                    log("tailnet", info.tailnet)
                    log("tailcat", info.tailcat)
                    if info.tailnet.pings.isEmpty && info.tailcat.pings.isEmpty { row("", tr("No pings yet")) }
                }
                section(tr("Stream")) {
                    if let l = info.layout {
                        row(tr("Display"), "\(l.width)×\(l.height) " + tr("points") + " · \(l.pictureWidth)×\(l.pictureHeight) " + tr("pixels"))
                    }
                    row(tr("Dynamic Resolution"), info.own ? tr("On: a display of its own that follows the window") : tr("Off: that Mac’s main display"))
                    row(tr("Codec"), info.codec.isEmpty ? "—" : ScreenInfo.codecName(info.codec))
                    row(tr("Quality"), info.fullQuality ? tr("Full Quality") : tr("Adaptive Quality"))
                    number(tr("Frame rate"), info.helper["fps"], "%.1f fps")
                    if let k = info.helper["kbps"] { row(tr("Bit rate"), ScreenInfo.rate(k)) }
                    number(tr("Sound packets"), info.helper["audio"], "%.0f /s")
                    number(tr("Pictures lost"), info.helper["lost"], "%.0f")
                    number(tr("Key frames"), info.helper["keyframes"], "%.0f")
                    number(tr("Key frames asked for"), info.helper["asks"], "%.0f")
                    number(tr("Packets that failed to authenticate"), info.helper["bad"], "%.0f")
                    number(tr("Pictures skipped (this Mac behind)"), info.helper["dropped"], "%.0f")
                    if info.live {
                        row(tr("Received by this Mac"), String(format: "%.1f fps · ", info.local.fps) + ScreenInfo.rate(info.local.kbps))
                    }
                }
                section(tr("Session")) {
                    row(tr("Mac"), info.device)
                    if !info.account.isEmpty { row(tr("Account"), info.account) }
                    row(tr("Mode"), info.viewOnly ? tr("View only") : info.observing ? tr("Observing") : tr("Controlling"))
                    row(tr("Sound"), info.sound ? tr("On") : tr("Off"))
                    if let since = info.since { row(tr("Connected at"), since.formatted(date: .omitted, time: .standard)) }
                }
            }
            .padding(16)
            .frame(width: Self.width, alignment: .leading)
    }

    static let width: CGFloat = 540
    private static let labels: CGFloat = 220

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: Self.labels, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12).monospacedDigit())
    }

    @ViewBuilder private func number(_ label: String, _ value: Double?, _ format: String) -> some View {
        if let value { row(label, String(format: format, value)) }
    }

    @ViewBuilder private func road(_ name: String, _ road: ScreenInfo.Road, missing: String) -> some View {
        if let now = road.now {
            row(name, ScreenInfo.path(now) + (now.ok ? " · " + ScreenInfo.ms(now.ms) : ""))
        } else {
            row(name, missing)
        }
        if !road.pings.isEmpty {
            if let s = road.summary() {
                row("", "min \(ScreenInfo.ms(s.min)) · avg \(ScreenInfo.ms(s.avg)) · max \(ScreenInfo.ms(s.max)) · "
                    + tr("lost") + String(format: " %.0f%%", s.loss * 100))
            }
            Sparkline(values: road.pings.suffix(60).map { $0.ok ? $0.ms : -1 })
                .frame(height: 28)
                .padding(.leading, Self.labels + 8)
        }
    }

    @ViewBuilder private func log(_ name: String, _ road: ScreenInfo.Road) -> some View {
        if !road.pings.isEmpty {
            Text(name).font(.system(size: 11, weight: .medium))
            Text(road.pings.suffix(10).map(ScreenInfo.line).joined(separator: "\n"))
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The round trips of the last pings as a line, a lost one a gap and a red mark.
struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let top = max(values.max() ?? 1, 1)
            let step = geo.size.width / CGFloat(max(values.count - 1, 1))
            ZStack(alignment: .topLeading) {
                Path { path in
                    var drawing = false
                    for (i, v) in values.enumerated() {
                        guard v >= 0 else { drawing = false; continue }
                        let point = CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(v / top)))
                        if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.2)
                Path { path in
                    for (i, v) in values.enumerated() where v < 0 {
                        path.addRect(CGRect(x: CGFloat(i) * step - 1, y: geo.size.height - 4, width: 2, height: 4))
                    }
                }
                .fill(Color.red)
            }
        }
    }
}
