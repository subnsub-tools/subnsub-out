import AppKit

/// Temporarily supplies paste text without losing prior rich clipboard contents or newer user copies.
@MainActor
public final class PasteboardLease {
    public static let general = PasteboardLease(board: .general)
    private let board: NSPasteboard
    private var snapshot: [[(NSPasteboard.PasteboardType, Data)]]?
    private var writtenCount: Int?
    private var restoration: Task<Void, Never>?

    public init(board: NSPasteboard) { self.board = board }

    /// `hold`: how long the text stays on the clipboard before the old contents come back.
    /// Longer when many keys are queued ahead of the paste keystroke.
    /// `keep`: the old contents do not come back; the text stays after the paste.
    public func supply(_ text: String, hold: TimeInterval = 0.9, keep: Bool = false, paste: () -> Void) {
        restoration?.cancel()
        if keep {
            restoration = nil; snapshot = nil; writtenCount = nil
            board.clearContents()
            board.setString(text, forType: .string)
            paste()
            return
        }
        if writtenCount != board.changeCount || snapshot == nil {
            snapshot = (board.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        writtenCount = board.changeCount
        paste()
        restoration = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)) } catch { return }
            self?.restore()
        }
    }

    /// Leaves `text` on the clipboard for good: it reached no cursor, or nothing shows that it did,
    /// so ⌘V has to produce it. What the clipboard held before is not brought back.
    /// No keystroke follows this one — so while an earlier paste is still on its way, the
    /// clipboard is left to it, and `text` takes the place of what would have come back.
    public func keep(_ text: String) {
        if restoration != nil, snapshot != nil, board.changeCount == writtenCount {
            snapshot = [[(.string, Data(text.utf8))]]
            return
        }
        restoration?.cancel(); restoration = nil
        snapshot = nil; writtenCount = nil
        board.clearContents()
        board.setString(text, forType: .string)
    }

    public func restore() {
        restoration?.cancel(); restoration = nil
        defer { snapshot = nil; writtenCount = nil }
        guard let snapshot, board.changeCount == writtenCount else { return }
        board.clearContents()
        let items = snapshot.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}
