import AppKit

/// Temporarily supplies paste text without losing prior rich clipboard contents or newer user copies.
@MainActor
public final class PasteboardLease {
    public static let general = PasteboardLease(board: .general)
    private let board: NSPasteboard
    private var snapshot: [[(NSPasteboard.PasteboardType, Data)]]?
    private var writtenCount: Int?
    private var restoration: Task<Void, Never>?
    /// While a watched paste waits for an app to take its text: the clipboard's change count then,
    /// and text that `keep` was given meanwhile, which waits until that paste is settled.
    private var watched: Int?
    private var keptDuring: String?

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

    /// Supplies `text` for one paste keystroke and tells whether an app took it. Some apps show
    /// other apps no text field at all (the ChatGPT app and Chrome pages, built on Chromium: user
    /// 2026-11-23, a paste that went in was reported as not confirmed), so whether the app in front
    /// asks the clipboard for the text after ⌘V is what says that the paste went in. The text is
    /// there as a promise kept when it is asked for, marked transient (nspasteboard.org: clipboard
    /// history tools leave it alone) and for this Mac only (it is not offered to other devices).
    /// Taken within `wait`: what the clipboard held comes back after `hold`, as after any paste.
    /// Not taken: the text stays on the clipboard for good, as `keep` leaves it, so ⌘V still has it.
    /// Something newer put on the clipboard before an app took the text is left there.
    /// `keep`: taken, the text (not what the clipboard held) is there after `hold`, unless something
    /// newer came meanwhile: a copy, or text given to `keep`.
    public func supplyWatched(_ text: String, hold: TimeInterval = 0.9, wait: TimeInterval = 1.0, keep: Bool = false, paste: () -> Void) async -> WatchedPaste {
        restoration?.cancel(); restoration = nil
        if writtenCount != board.changeCount || snapshot == nil {
            snapshot = (board.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }
        let promise = PastePromise(text)
        let item = NSPasteboardItem()
        _ = item.setData(Data(), forType: Self.transient)
        _ = board.prepareForNewContents(with: .currentHostOnly)
        guard item.setDataProvider(promise, forTypes: [.string]), board.writeObjects([item]) else {
            // No promise to watch: the text is simply on the clipboard, and stays.
            snapshot = nil; writtenCount = nil
            board.clearContents()
            board.setString(text, forType: .string)
            paste()
            return .left
        }
        let count = board.changeCount
        writtenCount = count; watched = count; keptDuring = nil
        let start = Date()
        paste()
        // Waited out in a task of its own: a cancelled dictation does not cut it short (the keystroke
        // is on its way, and the clipboard is settled either way) or make it spin.
        await Task { @MainActor in
            while !promise.taken, Date().timeIntervalSince(start) < wait {
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { break }
            }
        }.value
        let kept = watched == count ? keptDuring : nil
        if watched == count { watched = nil; keptDuring = nil }
        // Something else was put on the clipboard meanwhile (another paste, a copy): it is left there.
        guard board.changeCount == count else { return promise.taken ? .taken : .superseded }
        if promise.taken {
            // Text kept meanwhile comes back in place of what the clipboard held, as `keep` does;
            // else, for a keeping paste, its own text.
            if let kept { snapshot = [[(.string, Data(kept.utf8))]] } else if keep { snapshot = [[(.string, Data(text.utf8))]] }
            let left = max(0, hold - Date().timeIntervalSince(start))
            restoration = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) } catch { return }
                self?.restore()
            }
            return .taken
        }
        snapshot = nil; writtenCount = nil
        board.clearContents()
        board.setString(kept ?? text, forType: .string)
        return kept == nil ? .left : .superseded
    }

    /// nspasteboard.org: on the clipboard for a moment, not something the user copied.
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Leaves `text` on the clipboard for good: it reached no cursor, or nothing shows that it did,
    /// so ⌘V has to produce it. What the clipboard held before is not brought back.
    /// No keystroke follows this one — so while an earlier paste is still on its way, the
    /// clipboard is left to it, and `text` takes the place of what would have come back.
    public func keep(_ text: String) {
        // A watched paste is waiting for an app to take its text: the clipboard is its until then.
        if let watched, board.changeCount == watched { keptDuring = text; return }
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

/// What became of a watched paste.
public enum WatchedPaste: Sendable {
    /// An app took the text after the keystroke: it went in.
    case taken
    /// No app took it: it stays on the clipboard for ⌘V.
    case left
    /// Something newer was put on the clipboard before any app took it, and is left there.
    case superseded
}

/// The text of a watched paste, given to the app that asks for it, and whether one has.
private final class PastePromise: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let lock = NSLock()
    private var asked = false

    init(_ text: String) { self.text = text }

    var taken: Bool { lock.lock(); defer { lock.unlock() }; return asked }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock(); asked = true; lock.unlock()
        item.setString(text, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
