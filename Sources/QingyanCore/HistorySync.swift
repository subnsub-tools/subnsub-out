import Foundation

/// Keeps History the same on the owner's Macs that are linked for the Shelf (user 2026-11-27:
/// on every Mac with the Monitor helper, all History is in step, and says which Mac each record
/// came from). It rides the Shelf's links (ShelfSync), on Macs whose out says it can.
///
/// What goes: finished voice records (their text; the audio stays on the Mac that recorded it, and
/// so does a retry), and the clipboard history: text and images with every format they were copied
/// in, files by their names alone (the files themselves go on the Shelf). A removal, and clearing
/// the copies or the voice records, goes to every Mac too, when it was made while History was being
/// shared (the confirmation then said so); what a Mac's own limits let go does not.
///
/// When two Macs link, each says (in pages, under the links' frame limit) what it has with when each
/// last changed, what it removed, up to when it cleared, and the oldest it would keep; each then
/// sends the other what it lacks or has older. Every change after that goes to every link, and a
/// Mac passes on to its other links what changed it, so Macs linked only through a third one agree
/// too. The same copy made on two Macs is one entry, under the smaller of its two identifiers,
/// everywhere. A copy's formats go one copy at a time on each link, read from its file in pieces.
@MainActor
public final class HistorySync {
    /// The voice records, as the app keeps them (its published list goes through these).
    public struct Voice {
        public var entries: @MainActor () -> [HistoryEntry]
        public var horizon: @MainActor () -> Date
        /// Takes a finished record from another Mac; whether it is kept.
        public var take: @MainActor (HistoryEntry) -> Bool
        public var drop: @MainActor (Set<UUID>) -> Void
        public var dropCleared: @MainActor (Date) -> Void
        public init(entries: @escaping @MainActor () -> [HistoryEntry], horizon: @escaping @MainActor () -> Date,
                    take: @escaping @MainActor (HistoryEntry) -> Bool, drop: @escaping @MainActor (Set<UUID>) -> Void,
                    dropCleared: @escaping @MainActor (Date) -> Void) {
            self.entries = entries; self.horizon = horizon; self.take = take; self.drop = drop; self.dropCleared = dropCleared
        }
    }

    /// A change to the voice records made here, for the other Macs.
    public enum VoiceChange {
        case upsert(HistoryEntry)
        case removed(UUID)
        case cleared(Date)
    }

    /// Whether History is shared now (Work across Macs on, with Macs to share it with): a removal
    /// or a clear made while it is not stays on this Mac, as its confirmation said.
    public var sharing: @MainActor () -> Bool = { true }
    /// Whether copies are kept here (the clipboard history is on): when not, none are sent or taken.
    public var keepsCopies: @MainActor () -> Bool = { true }
    /// This Mac as the others know it: its key in their lists (helper:<agent id>), and its name.
    public var selfKey: String?
    public var selfName = ""

    /// A copy is sent in pieces of this many bytes.
    public static let piece = 256 << 10
    /// So many identifiers go in one page of a hello.
    public static let page = 3000
    /// A removal is remembered this long, so that a Mac that was away does not bring it back.
    public static let remembered: TimeInterval = 60 * 86_400

    private struct State: Codable {
        var gone: [UUID: Date] = [:]
        var clearedVoice = Date.distantPast
        var clearedCopies = Date.distantPast
    }

    /// What the Mac at the other end of a link has, as it said in its last hello and as it was told since.
    private struct Peer {
        var voice: [UUID: Double] = [:]
        var copies: [UUID: Double] = [:]
        var takesCopies = false
    }

    /// A copy whose formats are arriving: under the number of its transfer, so that the pieces of
    /// another transfer of it are not taken for its own.
    private struct Incoming {
        var entry: ClipEntry
        let size: Int
        let transfer: Int
        var data = Data()
    }

    private let shelf: ShelfSync
    private let clipboard: ClipboardHistory
    private let voice: Voice
    private let stateURL: URL?
    private var state = State()
    private var peers: [String: Peer] = [:]
    private var incoming: [String: [UUID: Incoming]] = [:]
    /// Hellos arriving in pages, by link.
    private var hellos: [String: [String: Any]] = [:]
    /// Copies whose formats wait to go on each link, and the one going now.
    private var queued: [String: [UUID]] = [:]
    private var sending: [String: UUID] = [:]

    public init(shelf: ShelfSync, clipboard: ClipboardHistory, voice: Voice, stateURL: URL?) {
        self.shelf = shelf; self.clipboard = clipboard; self.voice = voice; self.stateURL = stateURL
        if let stateURL, let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
        shelf.onHistoryLink = { [weak self] key in self?.linked(key) }
        shelf.onHistoryUnlink = { [weak self] key in self?.unlinked(key) }
        shelf.onHistoryFrame = { [weak self] frame, key in self?.handle(frame, from: key) }
        clipboard.announce = { [weak self] change in self?.copyChanged(change) }
    }

    /// Says hello again on every link, and asks for one back: after the clipboard history was
    /// turned on or off here.
    public func refresh() {
        for key in shelf.historyKeys { sayHello(to: key, again: true) }
    }

    // MARK: Changes made here

    public func voiceChanged(_ change: VoiceChange) {
        switch change {
        case .upsert(let entry):
            guard entry.state == .completed, state.gone[entry.id] == nil else { return }
            for key in shelf.historyKeys { sendVoice(entry, to: key) }
        case .removed(let id):
            guard sharing() else { return }
            remember([id])
            broadcast(["history": "remove", "ids": [id.uuidString]], except: nil)
        case .cleared(let moment):
            guard sharing() else { return }
            state.clearedVoice = max(state.clearedVoice, moment)
            save()
            broadcast(["history": "clear", "what": "voice", "at": moment.timeIntervalSince1970], except: nil)
        }
    }

    private func copyChanged(_ change: ClipboardHistory.Change) {
        switch change {
        case .upsert(let entry, let fresh):
            guard keepsCopies(), state.gone[entry.id] == nil else { return }
            for key in shelf.historyKeys { send(entry, to: key, whole: fresh || peers[key]?.copies[entry.id] == nil) }
        case .removed(let ids):
            guard sharing() else { return }
            remember(ids)
            broadcast(["history": "remove", "ids": ids.map(\.uuidString)], except: nil)
        case .cleared(let moment):
            guard sharing() else { return }
            state.clearedCopies = max(state.clearedCopies, moment)
            save()
            broadcast(["history": "clear", "what": "copies", "at": moment.timeIntervalSince1970], except: nil)
        }
    }

    // MARK: Links

    private func linked(_ key: String) {
        unlinked(key)
        peers[key] = Peer()
        sayHello(to: key, again: false)
    }

    private func unlinked(_ key: String) {
        peers[key] = nil; incoming[key] = nil; hellos[key] = nil
        queued[key] = nil; sending[key] = nil
    }

    /// A hello in pages: what this Mac has, removed and cleared, and the oldest it keeps.
    /// `again`: the Mac at the other end answers with a hello of its own.
    private func sayHello(to key: String, again: Bool) {
        let copies = keepsCopies()
        var first: [String: Any] = [
            "history": "hello",
            "clearedVoice": state.clearedVoice.timeIntervalSince1970,
            "clearedCopies": state.clearedCopies.timeIntervalSince1970,
            "voiceHorizon": voice.horizon().timeIntervalSince1970,
            "takesCopies": copies,
            "again": again,
        ]
        if copies { first["copyHorizon"] = clipboard.horizon.timeIntervalSince1970 }
        var frames = [first]
        func pages<T>(_ items: [T], _ make: ([T]) -> [String: Any]) {
            stride(from: 0, to: items.count, by: Self.page).forEach { start in
                frames.append(make(Array(items[start..<min(items.count, start + Self.page)])))
            }
        }
        pages(voice.entries().filter { $0.state == .completed }) { part in
            ["history": "have", "voice": Dictionary(part.map { ($0.id.uuidString, $0.changed.timeIntervalSince1970) }, uniquingKeysWith: max)]
        }
        if copies {
            pages(clipboard.entries) { part in
                ["history": "have", "copies": Dictionary(part.map { ($0.id.uuidString, $0.changed.timeIntervalSince1970) }, uniquingKeysWith: max)]
            }
        }
        pages(Array(state.gone.keys)) { part in ["history": "have", "gone": part.map(\.uuidString)] }
        frames.append(["history": "hello-end"])
        send(frames, to: key)
    }

    private func handle(_ frame: [String: Any], from key: String) {
        switch frame["history"] as? String {
        case "hello":
            hellos[key] = frame
        case "have":
            guard var hello = hellos[key] else { return }
            for name in ["voice", "copies"] {
                var all = hello[name] as? [String: Double] ?? [:]
                for (id, at) in frame[name] as? [String: Double] ?? [:] { all[id] = at }
                hello[name] = all
            }
            hello["gone"] = (hello["gone"] as? [String] ?? []) + (frame["gone"] as? [String] ?? [])
            hellos[key] = hello
        case "hello-end":
            guard let hello = hellos.removeValue(forKey: key) else { return }
            self.hello(hello, from: key)
            if hello["again"] as? Bool == true { sayHello(to: key, again: false) }
        case "voice":
            guard var entry = decode(HistoryEntry.self, frame["entry"]) else { return }
            mark(&entry.origin, &entry.originName, from: key)
            peers[key]?.voice[entry.id] = entry.changed.timeIntervalSince1970
            let have = voice.entries().contains { $0.id == entry.id }
            guard entry.state == .completed, state.gone[entry.id] == nil, have || entry.changed > state.clearedVoice else { return }
            entry.request = nil; entry.problem = nil; entry.failures = nil
            if voice.take(entry) { for other in shelf.historyKeys where other != key { sendVoice(entry, to: other) } }
        case "copy":
            guard var entry = decode(ClipEntry.self, frame["entry"]) else { return }
            mark(&entry.origin, &entry.originName, from: key)
            peers[key]?.copies[entry.id] = entry.changed.timeIntervalSince1970
            copyArrived(entry, size: frame["size"] as? Int ?? 0, transfer: frame["t"] as? Int ?? 0, from: key)
        case "bytes":
            guard let id = (frame["id"] as? String).flatMap(UUID.init(uuidString:)), let pending = incoming[key]?[id],
                  pending.transfer == frame["t"] as? Int else { return }
            guard let data = (frame["data"] as? String).flatMap({ Data(base64Encoded: $0) }), pending.data.count + data.count <= pending.size else {
                incoming[key]?[id] = nil; return
            }
            // In place: a copy of the pending bytes taken out of the table would be copied whole each time.
            incoming[key]?[id]?.data.append(data)
        case "end":
            guard let id = (frame["id"] as? String).flatMap(UUID.init(uuidString:)), let pending = incoming[key]?[id],
                  pending.transfer == frame["t"] as? Int else { return }
            incoming[key]?[id] = nil
            // Removed, cleared or no longer kept while it was on its way: not put back.
            guard pending.data.count == pending.size, keepsCopies(), state.gone[id] == nil, admits(pending.entry) else { return }
            took(clipboard.take(pending.entry, stored: pending.data), from: key)
        case "cancel":
            guard let id = (frame["id"] as? String).flatMap(UUID.init(uuidString:)), incoming[key]?[id]?.transfer == frame["t"] as? Int else { return }
            incoming[key]?[id] = nil
        case "want":
            guard keepsCopies(), peers[key]?.takesCopies == true,
                  let id = (frame["id"] as? String).flatMap(UUID.init(uuidString:)), clipboard.entries.contains(where: { $0.id == id }) else { return }
            queue(id, to: key)
        case "remove":
            let ids = Set((frame["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))).filter { state.gone[$0] == nil }
            guard !ids.isEmpty else { return }
            removeHere(ids)
            broadcast(["history": "remove", "ids": ids.map(\.uuidString)], except: key)
        case "clear":
            guard let at = frame["at"] as? Double, at.isFinite else { return }
            let moment = Date(timeIntervalSince1970: at)
            switch frame["what"] as? String {
            case "voice":
                guard moment > state.clearedVoice else { return }
                state.clearedVoice = moment
                voice.dropCleared(moment)
            case "copies":
                guard moment > state.clearedCopies else { return }
                state.clearedCopies = moment
                clipboard.drop(clearedAt: moment)
                for id in Array(incoming.values.flatMap(\.keys)) { dropPending(id, unless: { $0.pinned || $0.changed > moment }) }
            default: return
            }
            save()
            broadcast(frame, except: key)
        default: break
        }
    }

    /// A copy's entry arrived, with its formats following (`size` bytes) or none.
    private func copyArrived(_ entry: ClipEntry, size: Int, transfer: Int, from key: String) {
        guard keepsCopies(), state.gone[entry.id] == nil else { return }
        // A change made to it while its formats are on their way: kept with them.
        if size == 0, var pending = incoming[key]?[entry.id] {
            if entry.changed > pending.entry.changed { pending.entry = entry; incoming[key]?[entry.id] = pending }
            return
        }
        let have = clipboard.entries.contains { $0.id == entry.id }
        if have {
            // A change to one this Mac has: whatever the date, as an unpin after a clear must reach it.
            took(clipboard.take(entry, stored: nil), from: key)
            return
        }
        guard admits(entry) else { return }
        if entry.kind == .files {
            took(clipboard.take(entry, stored: nil), from: key)
        } else if size > 0 {
            guard size <= ClipboardHistory.itemMax + (1 << 20) else { return }
            incoming[key, default: [:]][entry.id] = Incoming(entry: entry, size: size, transfer: transfer)
        } else {
            // Its formats did not come (that Mac thought this one had it): asked for, if it would be kept here.
            let taken = clipboard.take(entry, stored: nil)
            if taken == .nothing, entry.pinned || entry.date > clipboard.horizon {
                send([["history": "want", "id": entry.id.uuidString]], to: key)
            } else {
                took(taken, from: key)
            }
        }
    }

    /// Whether a copy this Mac does not have may come in: not cleared here since it last changed.
    private func admits(_ entry: ClipEntry) -> Bool {
        entry.pinned || entry.changed > state.clearedCopies
    }

    private func dropPending(_ id: UUID, unless keep: (ClipEntry) -> Bool) {
        for key in Array(incoming.keys) {
            if let pending = incoming[key]?[id], !keep(pending.entry) { incoming[key]?[id] = nil }
        }
    }

    private func hello(_ frame: [String: Any], from key: String) {
        func moment(_ name: String) -> Date {
            (frame[name] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } ?? .distantPast
        }
        func changes(_ name: String) -> [UUID: Double] {
            var out: [UUID: Double] = [:]
            for (id, at) in frame[name] as? [String: Double] ?? [:] { if let id = UUID(uuidString: id) { out[id] = at } }
            return out
        }
        // What it has now, as it says: what was sent before may not have been kept.
        let peer = Peer(voice: changes("voice"), copies: changes("copies"), takesCopies: frame["takesCopies"] as? Bool == true)
        peers[key] = peer
        if !peer.takesCopies { queued[key] = nil }
        // What that Mac cleared and removed, done here too and passed on.
        let clearedVoice = moment("clearedVoice"), clearedCopies = moment("clearedCopies")
        if clearedVoice > state.clearedVoice {
            state.clearedVoice = clearedVoice
            broadcast(["history": "clear", "what": "voice", "at": clearedVoice.timeIntervalSince1970], except: key)
        }
        if clearedCopies > state.clearedCopies {
            state.clearedCopies = clearedCopies
            broadcast(["history": "clear", "what": "copies", "at": clearedCopies.timeIntervalSince1970], except: key)
        }
        let removed = Set((frame["gone"] as? [String] ?? []).compactMap(UUID.init(uuidString:))).filter { state.gone[$0] == nil }
        if !removed.isEmpty {
            for id in removed { state.gone[id] = Date() }
            broadcast(["history": "remove", "ids": removed.map(\.uuidString)], except: key)
        }
        // Every removal and clear known here, done again: one that failed on the disk before is tried again.
        let gone = Set(state.gone.keys)
        voice.drop(gone); clipboard.drop(gone)
        voice.dropCleared(state.clearedVoice); clipboard.drop(clearedAt: state.clearedCopies)
        save()
        // What it lacks and would keep, or has older.
        let voiceHorizon = moment("voiceHorizon")
        for entry in voice.entries().reversed() where entry.state == .completed && state.gone[entry.id] == nil {
            if let theirs = peer.voice[entry.id] {
                if theirs < entry.changed.timeIntervalSince1970 { sendVoice(entry, to: key) }
            } else if entry.date > voiceHorizon && entry.changed > state.clearedVoice {
                sendVoice(entry, to: key)
            }
        }
        guard peer.takesCopies && keepsCopies() else { return }
        let copyHorizon = moment("copyHorizon")
        for entry in clipboard.entries.reversed() where state.gone[entry.id] == nil {
            if let theirs = peer.copies[entry.id] {
                if theirs < entry.changed.timeIntervalSince1970 { send(entry, to: key, whole: false) }
            } else if entry.pinned || (entry.date > copyHorizon && entry.changed > state.clearedCopies) {
                send(entry, to: key, whole: true)
            }
        }
    }

    /// What taking a copy from the Mac with `key` did here, passed on to the other Macs.
    private func took(_ taken: ClipboardHistory.Taken, from key: String) {
        switch taken {
        case .nothing: return
        case .kept(let entry):
            for other in shelf.historyKeys where other != key { send(entry, to: other, whole: peers[other]?.copies[entry.id] == nil) }
        case .merged(let entry, let dropped):
            remember([dropped])
            broadcast(["history": "remove", "ids": [dropped.uuidString]], except: nil)
            for other in shelf.historyKeys { send(entry, to: other, whole: peers[other]?.copies[entry.id] == nil) }
        }
    }

    // MARK: Sending

    private func sendVoice(_ entry: HistoryEntry, to key: String) {
        var out = entry
        out.request = nil; out.problem = nil; out.failures = nil
        if out.origin == nil { out.origin = selfKey; out.originName = selfName }
        guard let encoded = encode(out) else { return }
        peers[key]?.voice[entry.id] = entry.changed.timeIntervalSince1970
        send([["history": "voice", "entry": encoded]], to: key)
    }

    /// A copy's entry as it is here, for the other Mac.
    private func outgoing(_ id: UUID) -> String? {
        guard var entry = clipboard.entries.first(where: { $0.id == id }), state.gone[id] == nil else { return nil }
        if entry.origin == nil { entry.origin = selfKey; entry.originName = selfName }
        return encode(entry)
    }

    /// A copy to the Mac with `key`: its entry alone, or (`whole`) with its formats. Files go by
    /// name alone, whoever copied them: their formats hold this Mac's paths.
    private func send(_ entry: ClipEntry, to key: String, whole: Bool) {
        guard peers[key]?.takesCopies ?? false else { return }
        peers[key]?.copies[entry.id] = entry.changed.timeIntervalSince1970
        if whole && entry.kind != .files && !entry.namesOnly { queue(entry.id, to: key); return }
        guard let encoded = outgoing(entry.id) else { return }
        send([["history": "copy", "entry": encoded, "size": 0, "t": 0]], to: key)
    }

    /// A copy whose formats go to the Mac with `key`, after the ones queued before it.
    private func queue(_ id: UUID, to key: String) {
        guard sending[key] != id, !(queued[key] ?? []).contains(id) else { return }
        queued[key, default: []].append(id)
        next(key)
    }

    /// The next copy's formats, read from its file a piece at a time: one copy at a time on a link,
    /// each piece between the link's other frames. It stops (and says so) when copies stop being
    /// kept here or there, or the copy is removed.
    private func next(_ key: String) {
        guard sending[key] == nil, var list = queued[key], !list.isEmpty else { return }
        let id = list.removeFirst()
        queued[key] = list
        sending[key] = id
        let transfer = Int.random(in: 1...Int(Int32.max))
        var file: (handle: FileHandle, size: Int)?
        var started = false
        func done() {
            try? file?.handle.close(); file = nil
            if sending[key] == id { sending[key] = nil }
            next(key)
        }
        let queuedWork = shelf.send(ShelfSync.LinkWork { [weak self] write in
            guard let self else { return false }
            let allowed = self.keepsCopies() && self.peers[key]?.takesCopies == true && self.state.gone[id] == nil
                && self.clipboard.entries.contains { $0.id == id }
            if !started {
                started = true
                guard allowed, let encoded = self.outgoing(id), let opened = self.clipboard.storedCopyFile(id) else { done(); return false }
                file = opened
                try await write(["history": "copy", "entry": encoded, "size": opened.size, "t": transfer])
                return true
            }
            guard let handle = file?.handle else { done(); return false }
            guard allowed else {
                try await write(["history": "cancel", "id": id.uuidString, "t": transfer])
                done(); return false
            }
            if let data = try handle.read(upToCount: Self.piece), !data.isEmpty {
                try await write(["history": "bytes", "id": id.uuidString, "t": transfer, "data": data.base64EncodedString()])
                return true
            }
            try await write(["history": "end", "id": id.uuidString, "t": transfer])
            done()
            return false
        }, to: key)
        if !queuedWork { sending[key] = nil; queued[key] = nil }
    }

    private func send(_ frames: [[String: Any]], to key: String) {
        var index = 0
        shelf.send(ShelfSync.LinkWork { write in
            guard index < frames.count else { return false }
            try await write(frames[index])
            index += 1
            return index < frames.count
        }, to: key)
    }

    private func broadcast(_ frame: [String: Any], except source: String?) {
        for key in shelf.historyKeys where key != source { send([frame], to: key) }
    }

    // MARK: Here

    /// The Mac a record came from: what it says, else the Mac that sent it; this Mac's own
    /// records coming back are this Mac's.
    private func mark(_ origin: inout String?, _ name: inout String?, from key: String) {
        if origin == nil || origin == "" { origin = key }
        if let selfKey, origin == selfKey { origin = nil; name = nil }
        name = name.map { String($0.prefix(80)) }
    }

    private func removeHere(_ ids: Set<UUID>) {
        remember(Array(ids))
        voice.drop(ids)
        clipboard.drop(ids)
        for id in ids { dropPending(id, unless: { _ in false }) }
    }

    /// Removed here or there: remembered, so that it is not taken back.
    private func remember(_ ids: [UUID]) {
        let now = Date()
        for id in ids { state.gone[id] = now }
        save()
    }

    private func save() {
        let cutoff = Date().addingTimeInterval(-Self.remembered)
        state.gone = state.gone.filter { $0.value > cutoff }
        guard let stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let text = value as? String, text.utf8.count <= 512 << 10 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}
