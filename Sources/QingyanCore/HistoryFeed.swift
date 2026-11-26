import Foundation
import Network

/// out's History on the Monitor page's Clipboard tab, through the Monitor helper on this Mac (the
/// helper's put_history.go). Two connections wait at put.sock; when the owner's Monitor page asks
/// (signed by a key the helper has pinned, over its tunnel, where the helper's console is on), the
/// helper asks one of them and out answers with its History as one line, then leaves another.
/// Nothing is sent before the page asks, and nothing goes anywhere but the helper on this Mac.
@MainActor
public final class HistoryFeed {
    /// Connections kept waiting at the helper, so that two pages asking at once are both answered.
    public static let waiting = 2

    private var loops: [Task<Void, Never>] = []
    private var parked: [ObjectIdentifier: NWConnection] = [:]
    private var entries: () -> [HistoryEntry] = { [] }

    public init() {}

    /// Starts once; the History is read each time the page asks.
    public func start(entries: @escaping () -> [HistoryEntry]) {
        self.entries = entries
        guard loops.isEmpty else { return }
        for _ in 0..<Self.waiting {
            loops.append(Task { @MainActor [weak self] in await self?.loop() })
        }
    }

    public func stop() {
        for loop in loops { loop.cancel() }
        loops.removeAll()
        for connection in parked.values { connection.cancel() }
        parked.removeAll()
    }

    /// A helper from before the History answers the wait with unknown-op at once.
    private struct TooOld: Error {}

    private func loop() async {
        var pause: UInt64 = 1
        while !Task.isCancelled {
            var wait = pause
            do {
                try await serveOnce()
                pause = 1
                continue
            } catch is TooOld {
                wait = 600
            } catch {
                if Task.isCancelled { return }
            }
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            pause = min(pause * 2, 60)
        }
    }

    /// One wait at the helper, and the answer when it asks.
    private func serveOnce() async throws {
        let connection = try await HelperLink.connect()
        let id = ObjectIdentifier(connection)
        parked[id] = connection
        defer { parked.removeValue(forKey: id); connection.cancel() }
        try await HelperLink.bounded(connection, 5) { try await HelperLink.ask(connection, ["op": "history"]) }
        let question = try await withTaskCancellationHandler {
            try await HelperLink.readLine(connection)
        } onCancel: { connection.cancel() }
        guard question["ask"] as? String == "history" else { throw TooOld() }
        let before = (question["before"] as? NSNumber)?.int64Value ?? 0
        let beforeID = question["beforeId"] as? String ?? ""
        let budget = min(max((question["max"] as? NSNumber)?.intValue ?? 0, 4 << 10), 1 << 20)
        let line = Self.page(entries(), before: before, beforeID: beforeID, budget: budget)
        try await HelperLink.bounded(connection, 10) { try await RemoteIO.write(connection, line) }
    }

    /// The longest text an entry is sent with, in bytes; longer is cut there and marked so.
    static let textLimit = 16 << 10

    /// A page of the History as the helper reads it, one line: newest first (by id within a
    /// millisecond), the entries after the one at `before` (Unix milliseconds) with `beforeID`, or
    /// from the newest when `before` is 0, as many as fit in `budget` bytes and at least one; each
    /// with its id, when it was recorded, its text, its state and its length in seconds, and `more`
    /// when older ones are left.
    static func page(_ entries: [HistoryEntry], before: Int64, beforeID: String, budget: Int) -> Data {
        typealias Row = (at: Int64, id: String, entry: HistoryEntry)
        let rows: [Row] = entries.map { entry in
            let ms = entry.date.timeIntervalSince1970 * 1000
            return (ms.isFinite && abs(ms) < 1e15 ? Int64(ms.rounded()) : 0, entry.id.uuidString.lowercased(), entry)
        }.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id > $1.id }
        var list: [[String: Any]] = []
        var size = 0, more = false
        for row in rows {
            if before > 0 && !(row.at < before || (row.at == before && row.id < beforeID)) { continue }
            let (text, cut) = Self.cut(row.entry.text)
            let seconds = row.entry.seconds.isFinite && row.entry.seconds >= 0 ? (row.entry.seconds * 10).rounded() / 10 : 0
            var item: [String: Any] = ["id": row.id, "at": row.at, "text": text, "state": row.entry.state.rawValue, "secs": seconds]
            if cut { item["cut"] = true }
            let length = (try? JSONSerialization.data(withJSONObject: item).count) ?? 0
            if !list.isEmpty && size + length + 1 > budget { more = true; break }
            size += length + 1
            list.append(item)
        }
        var line = (try? JSONSerialization.data(withJSONObject: ["entries": list, "more": more])) ?? Data("{\"entries\":[]}".utf8)
        line.append(0x0A)
        return line
    }

    /// The text up to textLimit bytes, cut where a character starts.
    static func cut(_ text: String) -> (String, Bool) {
        let utf8 = text.utf8
        guard utf8.count > textLimit else { return (text, false) }
        var end = utf8.index(utf8.startIndex, offsetBy: textLimit)
        while end > utf8.startIndex {
            if let head = String(utf8[..<end]) { return (head, true) }
            end = utf8.index(before: end)
        }
        return ("", true)
    }
}
