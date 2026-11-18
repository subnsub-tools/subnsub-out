import AppKit
import ApplicationServices
import QingyanCore

/// Diagnosis only: a dry run of the knock, without any text. It is started by a file rather than
/// a button because the question is always about another window — the one in front right now.
/// Create `knock-locate.trigger` in Application Support/Qingyan (its content may be the key spacing
/// in milliseconds); the answer is appended to `knock-locate.log` next to it.
@MainActor
enum KnockProbe {
    private static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Qingyan", isDirectory: true)
    private static let trigger = directory.appendingPathComponent("knock-locate.trigger")
    private static let log = directory.appendingPathComponent("knock-locate.log")
    private static var running = false

    static func poll(settings: SettingsStore, identity: DeviceIdentity?, name: String, busy: Bool) {
        guard !running, !busy, access(trigger.path, F_OK) == 0,
              let request = try? String(contentsOf: trigger, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: trigger)
        guard let identity else { return }
        let peers = settings.preferences.devices.filter(\.reachable)
        let spacing = UInt64(request.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 * 1_000_000 } ?? 12_000_000
        running = true
        Task { @MainActor in
            defer { running = false }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            let session = RemoteSession(devices: peers, identity: identity, name: name, listening: settings.preferences.remotePort)
            let started = Date()
            await session.arm(timeout: 1.5)
            let armed = Date().timeIntervalSince(started)
            let knocked = Date()
            let found = await session.locate { await KnockKeys.post(nonce: session.nonce, spacing: spacing) }
            let waited = Date().timeIntervalSince(knocked)
            session.close()
            note("front=\(front) linking=\(settings.preferences.linkEnabled) trusted=\(AXIsProcessTrusted()) peers=\(peers.count) armed=\(session.armedCount) "
                + String(format: "arm=%.0fms spacing=%dms patience=%.0fms ", armed * 1000, Int(spacing / 1_000_000), session.patience * 1000)
                + (found.map { "claimed-by=\(session.name($0)) " } ?? "claimed-by=nobody ")
                + String(format: "knock+wait=%.0fms", waited * 1000)
                + (session.problems.isEmpty ? "" : " problems=\(session.problems.joined(separator: " | "))"))
        }
    }

    private static func note(_ text: String) {
        let line = String(format: "%.3f ", Date().timeIntervalSince1970) + text + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: log)
        }
    }
}
