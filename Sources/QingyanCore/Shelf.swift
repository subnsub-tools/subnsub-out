import Foundation
import Network

/// One thing parked on the shelf: a piece of text, an image or a file. Its bytes are a file on disk.
public struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, image, file }
    public var id: UUID
    public var kind: Kind
    /// The file's name on disk and what a file is called when it is dragged back out.
    public var name: String
    public var size: Int
    public var date: Date
    /// The Mac it was put on the shelf at.
    public var origin: String

    public init(id: UUID = UUID(), kind: Kind, name: String, size: Int, date: Date = Date(), origin: String) {
        self.id = id; self.kind = kind; self.name = name; self.size = size; self.date = date; self.origin = origin
    }

    /// A large item travels as a card — name, size, thumbnail — and its bytes only when a Mac asks.
    public var isLarge: Bool { size > ShelfStore.eagerBytes }
}

/// The shelf on this Mac: a folder with one sub-folder per item and an index. Newest first.
/// Every Mac has every card; a large item's bytes are only on the Macs that put it there or
/// fetched it. Removed items leave their id behind, so a Mac that was away does not bring them back.
@MainActor
public final class ShelfStore {
    public nonisolated static let maxItems = 40
    /// Up to this size an item is copied to every Mac at once; above it only its card is.
    public nonisolated static let eagerBytes = 8 << 20
    /// The most that may be added from memory (clipboard images, text).
    public nonisolated static let maxDataBytes = 64 << 20
    /// How much fetched content this Mac keeps before the least recently used is let go.
    public nonisolated static let cacheBytes = 5 << 30
    public enum Change { case added(ShelfItem), removed(UUID), presence }

    public let directory: URL
    public private(set) var items: [ShelfItem] = []
    public private(set) var gone: [UUID] = []
    public var onChange: (() -> Void)?
    /// Told about what changed on this Mac, so it can be passed on to the others.
    public var announce: ((Change) -> Void)?
    public var cacheLimit = ShelfStore.cacheBytes

    private struct Index: Codable {
        var items: [ShelfItem]
        var gone: [UUID]
    }
    /// What only this Mac needs to know: which items were put on the shelf here (their bytes are
    /// never let go) and when each fetched one was last used.
    private struct Local: Codable {
        var own: [UUID]
        var used: [String: Double]
    }
    private var present: Set<UUID> = []
    private var own: Set<UUID> = []
    private var used: [UUID: Date] = [:]
    private var index: URL { directory.appendingPathComponent("index.json") }
    private var local: URL { directory.appendingPathComponent("local.json") }

    public init(directory: URL) throws {
        self.directory = directory
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode(Index.self, from: data) {
            // A card needs its folder; a small item also needs its bytes.
            items = saved.items.filter { files.fileExists(atPath: url($0).path) || ($0.isLarge && files.fileExists(atPath: folder($0).path)) }
            gone = saved.gone
        }
        if let data = try? Data(contentsOf: local), let saved = try? JSONDecoder().decode(Local.self, from: data) {
            own = Set(saved.own)
            used = Dictionary(saved.used.compactMap { key, value in UUID(uuidString: key).map { ($0, Date(timeIntervalSince1970: value)) } },
                              uniquingKeysWith: { first, _ in first })
        }
        present = Set(items.filter { files.fileExists(atPath: url($0).path) }.map(\.id))
        // A transfer that was cut off by quitting leaves a partial file behind.
        for name in (try? files.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix("incoming-") {
            try? files.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func folder(_ item: ShelfItem) -> URL { directory.appendingPathComponent(item.id.uuidString, isDirectory: true) }
    public func url(_ item: ShelfItem) -> URL { folder(item).appendingPathComponent(item.name) }
    public func has(_ id: UUID) -> Bool { items.contains { $0.id == id } }
    public func isGone(_ id: UUID) -> Bool { gone.contains(id) }
    public func item(_ id: UUID) -> ShelfItem? { items.first { $0.id == id } }
    /// Whether the item's bytes are on this Mac. Always true for small items.
    public func isPresent(_ id: UUID) -> Bool { present.contains(id) }
    /// Put on the shelf at this Mac, as opposed to fetched from another.
    public func isOwn(_ id: UUID) -> Bool { own.contains(id) }
    /// The large items whose bytes this Mac can hand to another.
    public var held: Set<UUID> { Set(items.filter { $0.isLarge && present.contains($0.id) }.map(\.id)) }

    /// A name that is safe as a single path component, whatever another Mac sent.
    public static func cleanName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        // The fallback is a file name and keeps the bytes it always had: the Chinese word for "file".
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.hasPrefix(".") else { return "\u{6587}\u{4EF6}" }
        return String(cleaned.prefix(200))
    }

    @discardableResult
    public func add(_ data: Data, kind: ShelfItem.Kind, name: String, origin: String) throws -> ShelfItem {
        guard !data.isEmpty else { throw VoiceError(tr("The content is empty and was not added to the Shelf.")) }
        guard data.count <= Self.maxDataBytes else { throw VoiceError(tr("The content is larger than 64 MB. Save it as a file, then drag the file in.")) }
        let item = ShelfItem(kind: kind, name: Self.cleanName(name), size: data.count, origin: origin)
        try makeFolder(item)
        do { try data.write(to: url(item), options: .atomic) }
        catch { discardFolder(item); throw VoiceError(tr("Cannot write to the Shelf folder. Check the free disk space.")) }
        own.insert(item.id); present.insert(item.id)
        insert(item)
        announce?(.added(item))
        return item
    }

    /// Copies a file onto the shelf, off the main thread. On the same disk this is a clone and
    /// takes no extra space; the original may be moved or deleted afterwards.
    /// `thumbnail` is a small JPEG shown on the Macs that have only the card.
    @discardableResult
    public func add(copying file: URL, kind: ShelfItem.Kind, origin: String, thumbnail: Data? = nil) async throws -> ShelfItem {
        let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory != true else { throw VoiceError(tr("Folders cannot be dragged in yet. Compress the folder into a single file first.")) }
        guard let size = values?.fileSize else { throw VoiceError(tr("Cannot read this file.")) }
        guard size > 0 else { throw VoiceError(tr("The file is empty and was not added to the Shelf.")) }
        let item = ShelfItem(kind: kind, name: Self.cleanName(file.lastPathComponent), size: size, origin: origin)
        try makeFolder(item)
        let destination = url(item)
        do { try await Task.detached { try FileManager.default.copyItem(at: file, to: destination) }.value }
        catch { discardFolder(item); throw VoiceError(tr("Cannot copy “%@” to the Shelf folder. Check the free disk space.", file.lastPathComponent)) }
        if let thumbnail { try? thumbnail.write(to: thumbnailURL(item)) }
        own.insert(item.id); present.insert(item.id)
        insert(item)
        announce?(.added(item))
        return item
    }

    public func text(_ item: ShelfItem) -> String? {
        guard item.kind == .text, let data = try? Data(contentsOf: url(item)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func thumbnailURL(_ item: ShelfItem) -> URL { folder(item).appendingPathComponent(".thumbnail") }
    public func thumbnail(_ item: ShelfItem) -> Data? { try? Data(contentsOf: thumbnailURL(item)) }

    /// `announce: false` when the removal came from another Mac and is passed on by whoever received it.
    public func remove(_ id: UUID, announce shouldAnnounce: Bool = true) {
        if let item = item(id) { discardFolder(item) }
        let existed = has(id)
        items.removeAll { $0.id == id }
        present.remove(id); own.remove(id); used[id] = nil
        if !gone.contains(id) { gone.append(id); if gone.count > 300 { gone.removeFirst(gone.count - 300) } }
        save()
        if existed { onChange?() }
        if shouldAnnounce { announce?(.removed(id)) }
    }

    public func clear() { for item in items { remove(item.id) } }

    /// Where a transfer from another Mac is written until it is complete.
    public func incomingURL() -> URL { directory.appendingPathComponent("incoming-\(UUID().uuidString)") }

    /// Takes in a small item that another Mac sent whole. Whoever received it passes it on.
    public func accept(_ item: ShelfItem, from file: URL) throws {
        guard !has(item.id), !isGone(item.id) else { try? FileManager.default.removeItem(at: file); return }
        var item = item
        item.name = Self.cleanName(item.name)
        try makeFolder(item)
        do { try FileManager.default.moveItem(at: file, to: url(item)) }
        catch { discardFolder(item); throw VoiceError(tr("Cannot save the content sent from the other Mac.")) }
        present.insert(item.id)
        insert(item)
    }

    /// Takes in the card of a large item: everything but its bytes.
    public func acceptCard(_ item: ShelfItem, thumbnail: Data?) throws {
        guard !has(item.id), !isGone(item.id) else { return }
        var item = item
        item.name = Self.cleanName(item.name)
        try makeFolder(item)
        if let thumbnail { try? thumbnail.write(to: thumbnailURL(item)) }
        insert(item)
    }

    /// A fetch of a large item's bytes is written here and survives a broken connection, so the
    /// next attempt carries on where this one stopped.
    public func partialURL(_ item: ShelfItem) -> URL { folder(item).appendingPathComponent(".partial") }

    /// The fetch is complete: the partial file becomes the item's bytes.
    public func finishFetch(_ item: ShelfItem) throws {
        guard has(item.id) else { return }
        try? FileManager.default.removeItem(at: url(item))
        do { try FileManager.default.moveItem(at: partialURL(item), to: url(item)) }
        catch { throw VoiceError(tr("Cannot save the retrieved file. Check the free disk space.")) }
        present.insert(item.id); used[item.id] = Date()
        trimCache(keeping: item.id)
        save()
        onChange?()
        announce?(.presence)
    }

    /// Notes that a fetched item was just used, so it is the last to be let go.
    public func touch(_ id: UUID) {
        guard present.contains(id), !own.contains(id) else { return }
        used[id] = Date()
        save()
    }

    /// Lets go of a fetched item's bytes on this Mac; the card stays and it can be fetched again.
    public func release(_ id: UUID) {
        guard let item = item(id), item.isLarge, present.contains(id), !own.contains(id) else { return }
        try? FileManager.default.removeItem(at: url(item))
        present.remove(id); used[id] = nil
        save()
        onChange?()
        announce?(.presence)
    }

    private func trimCache(keeping: UUID) {
        var fetched = items.filter { $0.isLarge && present.contains($0.id) && !own.contains($0.id) }
        var total = fetched.reduce(0) { $0 + $1.size }
        fetched.sort { (used[$0.id] ?? .distantPast) < (used[$1.id] ?? .distantPast) }
        for item in fetched where total > cacheLimit && item.id != keeping {
            try? FileManager.default.removeItem(at: url(item))
            present.remove(item.id); used[item.id] = nil
            total -= item.size
        }
    }

    private func makeFolder(_ item: ShelfItem) throws {
        do { try FileManager.default.createDirectory(at: folder(item), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw VoiceError(tr("Cannot write to the Shelf folder. Check the free disk space.")) }
    }

    private func discardFolder(_ item: ShelfItem) { try? FileManager.default.removeItem(at: folder(item)) }

    private func insert(_ item: ShelfItem) {
        items.append(item)
        items.sort { $0.date > $1.date }
        save()
        onChange?()
        // The oldest make room. Told to the other Macs like any removal, so every shelf agrees.
        while items.count > Self.maxItems, let oldest = items.last { remove(oldest.id) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Index(items: items, gone: gone)) { try? data.write(to: index, options: .atomic) }
        let mine = Local(own: Array(own), used: Dictionary(uniqueKeysWithValues: used.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }))
        if let data = try? JSONEncoder().encode(mine) { try? data.write(to: local, options: .atomic) }
    }
}

/// Keeps the shelves of trusted Macs the same. Each Mac calls the others it shares its shelf with
/// and keeps one long-lived encrypted connection to each; a Mac that is called hands the
/// connection over to this object. When two Macs call each other at once, both keep the same one
/// of the two. After a hello that lists what each side has and what it has removed, both tell the other about
/// every change, and pass on what they receive to their other links, so shelves that are only
/// connected through a third Mac still agree.
///
/// Small items are sent whole. A large item is sent as a card; its bytes move only when a Mac
/// asks for them, as raw chunks that share the link with everything else, and a broken transfer
/// resumes where it stopped. A Mac asked for bytes it does not have, but that a Mac next to it
/// has, fetches them itself first and then serves them — one hop, never further.
@MainActor
public final class ShelfSync {
    private final class Link {
        let channel: Channel
        /// The Mac at the other end, by its identity key.
        let key: String
        /// Whether this Mac made the call.
        let dialled: Bool
        var name = ""
        var alive = true
        var jobs: [Job] = []
        var sending = false
        var incoming: [UUID: Incoming] = [:]
        /// Large items whose bytes the Mac at the other end has itself, and those it can get.
        var holds: Set<UUID> = []
        var offers: Set<UUID> = []
        var told: (holds: Set<UUID>, offers: Set<UUID>)?
        /// The file currently being sent for each item. A serve that is no longer the one listed
        /// here was cancelled or replaced, and stops at its next chunk.
        var serving: [UUID: Serve] = [:]
        init(_ channel: Channel, dialled: Bool) { self.channel = channel; self.key = channel.peerKey; self.dialled = dialled; self.name = channel.peerName }
    }
    private final class Serve {
        let id: UUID
        let handle: FileHandle
        let offset: Int
        var started = false
        init(id: UUID, handle: FileHandle, offset: Int) { self.id = id; self.handle = handle; self.offset = offset }
    }
    private enum Job {
        case item(ShelfItem), remove(UUID), availability
        case fetch(UUID, Int), cancel(UUID), refuse(UUID, String), serve(Serve)
    }
    private struct Incoming {
        let item: ShelfItem
        let handle: FileHandle
        let url: URL
        var received = 0
    }
    private final class Fetch {
        let item: ShelfItem
        let link: Link
        let handle: FileHandle
        var received: Int
        init(item: ShelfItem, link: Link, handle: FileHandle, received: Int) {
            self.item = item; self.link = link; self.handle = handle; self.received = received
        }
    }

    private let store: ShelfStore
    private let name: String
    private var links: [Link] = []
    private var dialling: Set<String> = []
    private var tried: [String: Date] = [:]
    /// Who this Mac is to the others, and the port it listens on itself.
    public var identity = DeviceIdentity()
    /// What the other Macs call this one, where that is not its key: helper:<agent id> through
    /// the Monitor helper (HelperLink), for the tie-break between two calls.
    public var selfID: String?
    public var listening = RemoteWire.defaultPort
    private var fetches: [UUID: Fetch] = [:]
    /// Macs that asked this one for bytes it is itself still fetching, and from where in the file.
    private var waitingForFetch: [UUID: [(Link, Int)]] = [:]
    private var lastProgress = Date.distantPast
    private static let chunk = 256 << 10
    private static let rawChunk = 512 << 10
    /// How many Macs this shelf is connected to right now.
    public var linked: Int { links.count }
    /// The Macs it is connected to right now, by key — whichever of the two made the call.
    public var linkedKeys: Set<String> { Set(links.map(\.key)) }
    public var onStatus: (() -> Void)?
    /// A fetch moved on, ended, or what can be fetched changed.
    public var onTransfer: (() -> Void)?
    /// Why the last fetch of an item did not finish.
    public private(set) var failures: [UUID: String] = [:]

    public init(store: ShelfStore, name: String) {
        self.store = store; self.name = name
        store.announce = { [weak self] change in
            guard let self else { return }
            switch change {
            case .added(let item): self.pass(.item(item), except: nil); self.tellAvailability()
            case .removed(let id): self.forget(id); self.pass(.remove(id), except: nil); self.tellAvailability()
            case .presence: self.tellAvailability()
            }
        }
    }

    /// Long-lived links must notice a Mac that vanished without closing the connection.
    nonisolated static var parameters: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 20; tcp.keepaliveInterval = 10; tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func greeting() -> [String: Any] {
        ["shelf": "hello", "have": store.items.map(\.id.uuidString), "gone": store.gone.map(\.uuidString)]
    }

    private static func ids(_ value: Any?) -> Set<UUID> {
        Set((value as? [String] ?? []).compactMap(UUID.init(uuidString:)))
    }

    // MARK: Links

    /// Call regularly with the Macs this one trusts (none when sharing is off). Calls the ones it
    /// shares the shelf with and has no link to, retrying a Mac that is away every few seconds,
    /// and closes the links to Macs that are no longer trusted with the shelf.
    public func maintain(devices: [TrustedDevice]) {
        let sharing = Dictionary(devices.filter(\.canShelf).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for link in links where sharing[link.key] == nil { drop(link) }
        // The pause between attempts is for a Mac that does not answer, not for one that was taken off the list and put back.
        tried = tried.filter { sharing[$0.key] != nil }
        for (key, device) in sharing where device.reachable && !links.contains(where: { $0.key == key }) && !dialling.contains(key)
            && Date().timeIntervalSince(tried[key] ?? .distantPast) > 8 {
            tried[key] = Date(); dialling.insert(key)
            Task { @MainActor [weak self] in
                await self?.dial(device)
                self?.dialling.remove(key)
            }
        }
    }

    private func dial(_ device: TrustedDevice) async {
        guard let channel = try? await Channel.open(host: device.host, port: device.port, identity: identity, name: name, listening: listening) else { return }
        // Somebody else answers at that address now.
        guard channel.peerKey == device.key else { channel.close(); return }
        let deadline = Task {
            try await Task.sleep(nanoseconds: 4_000_000_000)
            channel.close()
        }
        guard (try? await channel.write(greeting())) != nil, let reply = try? await channel.readObject(), reply["ok"] as? Bool == true else {
            deadline.cancel(); channel.close(); return
        }
        deadline.cancel()
        let link = Link(channel, dialled: true)
        guard settle(link) else { return }
        listen(link)
        reconcile(link, have: Self.ids(reply["have"]), gone: Self.ids(reply["gone"]))
    }

    /// A trusted Mac called and said a shelf hello. Returns the reply; from then on the connection
    /// belongs to this object.
    func adopt(_ channel: Channel, hello: [String: Any]) -> [String: Any] {
        var reply = greeting()
        reply["ok"] = true
        let link = Link(channel, dialled: false)
        let have = Self.ids(hello["have"]), gone = Self.ids(hello["gone"])
        // After this turn, so that the reply is on the wire before anything else.
        Task { @MainActor [weak self] in
            guard let self, self.settle(link) else { return }
            self.listen(link)
            self.reconcile(link, have: have, gone: gone)
        }
        return reply
    }

    /// Adds a new link, unless there already is one to the same Mac: two Macs that called each
    /// other at the same moment keep the call made by the one with the smaller key, and since
    /// both apply the same rule they keep the same one. False when the new link was the one to go.
    private func settle(_ link: Link) -> Bool {
        let mine = HelperLink.agent(of: link.key) != nil ? (selfID ?? identity.publicKey) : identity.publicKey
        func caller(_ link: Link) -> String { link.dialled ? mine : link.key }
        if let existing = links.first(where: { $0.key == link.key }) {
            if caller(existing) <= caller(link) { link.alive = false; link.channel.close(); return false }
            drop(existing)
        }
        links.append(link)
        onStatus?()
        return true
    }

    public func stop() { for link in links { drop(link) } }

    private func reconcile(_ link: Link, have: Set<UUID>, gone: Set<UUID>) {
        for id in gone where store.has(id) || !store.isGone(id) {
            forget(id)
            store.remove(id, announce: false)
            pass(.remove(id), except: link)
        }
        for item in store.items.reversed() where !have.contains(item.id) && !gone.contains(item.id) {
            link.jobs.append(.item(item))
        }
        pump(link)
        tellAvailability()
    }

    private func pass(_ job: Job, except source: Link?) {
        for link in links where link !== source {
            link.jobs.append(job)
            pump(link)
        }
    }

    /// Tells every link which large items this Mac has, and which it could get from the Mac on
    /// another of its links. Only what a Mac has itself is ever passed further, so an offer is at
    /// most one hop away and never circles.
    private func tellAvailability() {
        let mine = store.held
        for link in links {
            var offers = mine
            for other in links where other !== link { offers.formUnion(other.holds) }
            offers = offers.filter { store.has($0) }
            if link.told?.holds != mine || link.told?.offers != offers {
                link.told = (mine, offers)
                link.jobs.append(.availability)
                pump(link)
            }
        }
        onTransfer?()
    }

    /// One writer per link, a frame at a time, so nothing large sits in memory as a queue. A file
    /// being served goes to the back of the queue after each chunk, so cards and removals are not
    /// held up behind gigabytes.
    private func pump(_ link: Link) {
        guard link.alive, !link.sending else { return }
        link.sending = true
        Task { @MainActor [weak self] in
            defer { link.sending = false }
            while let self, link.alive, !link.jobs.isEmpty {
                let job = link.jobs.removeFirst()
                do {
                    switch job {
                    case .remove(let id): try await self.write(link, ["shelf": "remove", "id": id.uuidString])
                    case .item(let item): try await self.push(item, over: link)
                    case .availability:
                        guard let told = link.told else { continue }
                        try await self.write(link, ["shelf": "has", "holds": told.holds.map(\.uuidString), "offers": told.offers.map(\.uuidString)])
                    case .fetch(let id, let offset): try await self.write(link, ["shelf": "fetch", "id": id.uuidString, "offset": offset])
                    case .cancel(let id): try await self.write(link, ["shelf": "cancel", "id": id.uuidString])
                    case .refuse(let id, let message): try await self.write(link, ["shelf": "nofile", "id": id.uuidString, "message": message])
                    case .serve(let serve): try await self.serve(serve, over: link)
                    }
                } catch { self.drop(link); return }
            }
        }
    }

    private func write(_ link: Link, _ object: [String: Any]) async throws { try await link.channel.write(object) }

    private func push(_ item: ShelfItem, over link: Link) async throws {
        // Removed since it was queued: nothing to send.
        guard let item = store.item(item.id) else { return }
        var card: [String: Any] = ["shelf": "item", "id": item.id.uuidString, "kind": item.kind.rawValue, "name": item.name,
                                   "size": item.size, "date": item.date.timeIntervalSince1970, "origin": item.origin]
        if item.isLarge {
            if let thumbnail = store.thumbnail(item), thumbnail.count <= 200_000 { card["thumbnail"] = thumbnail.base64EncodedString() }
            try await write(link, card)
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: store.url(item)) else { return }
        defer { try? handle.close() }
        try await write(link, card)
        while let data = try handle.read(upToCount: Self.chunk), !data.isEmpty {
            try await write(link, ["shelf": "chunk", "id": item.id.uuidString, "data": data.base64EncodedString()])
        }
        try await write(link, ["shelf": "done", "id": item.id.uuidString])
    }

    private func serve(_ serve: Serve, over link: Link) async throws {
        guard link.serving[serve.id] === serve else { try? serve.handle.close(); return }
        if !serve.started {
            serve.started = true
            try await write(link, ["shelf": "file", "id": serve.id.uuidString, "offset": serve.offset])
        }
        guard let data = try? serve.handle.read(upToCount: Self.rawChunk), !data.isEmpty else {
            try? serve.handle.close()
            link.serving[serve.id] = nil
            try await write(link, ["shelf": "filedone", "id": serve.id.uuidString])
            return
        }
        try await link.channel.write(RemoteWire.rawBody(id: serve.id, data))
        link.jobs.append(.serve(serve))
    }

    private func listen(_ link: Link) {
        Task { @MainActor [weak self] in
            while link.alive, let body = try? await link.channel.readBody() {
                guard let self else { return }
                if let (id, data) = RemoteWire.raw(body) { self.receive(data, of: id, from: link) }
                else if let frame = try? RemoteWire.object(body) { self.handle(frame, from: link) }
            }
            self?.drop(link)
        }
    }

    private func handle(_ frame: [String: Any], from link: Link) {
        if frame["shelf"] as? String == "has" {
            link.holds = Self.ids(frame["holds"]); link.offers = Self.ids(frame["offers"])
            tellAvailability()
            return
        }
        guard let id = (frame["id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        switch frame["shelf"] as? String {
        case "item":
            abandon(id, on: link)
            guard !store.has(id), !store.isGone(id), let kind = (frame["kind"] as? String).flatMap(ShelfItem.Kind.init(rawValue:)),
                  let name = frame["name"] as? String, let size = frame["size"] as? Int, size > 0 else { return }
            let item = ShelfItem(id: id, kind: kind, name: ShelfStore.cleanName(name), size: size,
                                 date: Date(timeIntervalSince1970: frame["date"] as? Double ?? Date().timeIntervalSince1970),
                                 origin: String((frame["origin"] as? String ?? "").prefix(80)))
            if item.isLarge {
                let thumbnail = (frame["thumbnail"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { $0.count <= 200_000 ? $0 : nil }
                guard (try? store.acceptCard(item, thumbnail: thumbnail)) != nil, store.has(id) else { return }
                pass(.item(item), except: link)
                return
            }
            let url = store.incomingURL()
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: url) else { return }
            link.incoming[id] = Incoming(item: item, handle: handle, url: url)
        case "chunk":
            guard var incoming = link.incoming[id], let data = (frame["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return }
            incoming.received += data.count
            // More than was announced is not this item; drop it rather than fill the disk.
            guard incoming.received <= incoming.item.size, (try? incoming.handle.write(contentsOf: data)) != nil else { abandon(id, on: link); return }
            link.incoming[id] = incoming
        case "done":
            guard let incoming = link.incoming.removeValue(forKey: id) else { return }
            try? incoming.handle.close()
            guard incoming.received == incoming.item.size, (try? store.accept(incoming.item, from: incoming.url)) != nil, store.has(id) else {
                try? FileManager.default.removeItem(at: incoming.url); return
            }
            pass(.item(incoming.item), except: link)
        case "remove":
            abandon(id, on: link)
            guard store.has(id) || !store.isGone(id) else { return }
            forget(id)
            store.remove(id, announce: false)
            pass(.remove(id), except: link)
            tellAvailability()
        case "fetch":
            answerFetch(id, offset: max(0, frame["offset"] as? Int ?? 0), for: link)
        case "cancel":
            link.serving[id] = nil
            waitingForFetch[id]?.removeAll { $0.0 === link }
        case "file":
            guard let fetch = fetches[id], fetch.link === link else { return }
            // The other Mac says where it starts; make the partial file end exactly there.
            let offset = frame["offset"] as? Int ?? 0
            guard offset <= fetch.received, (try? fetch.handle.truncate(atOffset: UInt64(offset))) != nil,
                  (try? fetch.handle.seekToEnd()) != nil else { fail(id, tr("The transfer went out of step and stopped. Click to retrieve the file again.")); return }
            fetch.received = offset
        case "filedone":
            guard let fetch = fetches[id], fetch.link === link else { return }
            try? fetch.handle.close()
            fetches[id] = nil
            guard fetch.received == fetch.item.size, (try? store.finishFetch(fetch.item)) != nil, store.isPresent(id) else {
                try? FileManager.default.removeItem(at: store.partialURL(fetch.item))
                finish(id, failure: tr("The received file was incomplete and was removed. Click to retrieve it again.")); return
            }
            finish(id, failure: nil)
        case "nofile":
            guard let fetch = fetches[id], fetch.link === link else { return }
            fail(id, frame["message"] as? String ?? tr("The other Mac removed this file."))
        default: break
        }
    }

    private func abandon(_ id: UUID, on link: Link) {
        guard let incoming = link.incoming.removeValue(forKey: id) else { return }
        try? incoming.handle.close()
        try? FileManager.default.removeItem(at: incoming.url)
    }

    private func drop(_ link: Link) {
        guard link.alive else { return }
        link.alive = false
        link.channel.close()
        for id in Array(link.incoming.keys) { abandon(id, on: link) }
        for serve in link.serving.values { try? serve.handle.close() }
        link.serving.removeAll()
        link.jobs.removeAll()
        links.removeAll { $0 === link }
        for (id, fetch) in fetches where fetch.link === link { fail(id, tr("The connection was interrupted. What arrived is kept; click to continue the transfer.")) }
        for id in Array(waitingForFetch.keys) { waitingForFetch[id]?.removeAll { $0.0 === link } }
        onStatus?()
        tellAvailability()
    }

    // MARK: Fetching a large item's bytes

    /// Whether the bytes are here, or a linked Mac has them or can get them.
    public func isAvailable(_ id: UUID) -> Bool { store.isPresent(id) || links.contains { $0.offers.contains(id) } }
    /// How far a running fetch is, 0…1; nil when none is running.
    public func progress(_ id: UUID) -> Double? { fetches[id].map { Double($0.received) / Double(max($0.item.size, 1)) } }
    /// The Mac a running fetch is coming from.
    public func source(_ id: UUID) -> String? { fetches[id]?.link.name }

    /// Starts getting a large item's bytes from a linked Mac. Does nothing when they are here
    /// already or on their way. A partial file from an earlier attempt is carried on.
    public func fetch(_ id: UUID) {
        guard let item = store.item(id), item.isLarge, !store.isPresent(id), fetches[id] == nil else { return }
        failures[id] = nil
        // Straight from a Mac that has it, rather than through one that would have to get it first.
        guard let link = links.first(where: { $0.holds.contains(id) }) ?? links.first(where: { $0.offers.contains(id) }) else {
            finish(id, failure: tr("None of the Macs that hold this file are online.")); return
        }
        let partial = store.partialURL(item)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: partial), let end = try? handle.seekToEnd() else {
            finish(id, failure: tr("Cannot write to the Shelf folder. Check the free disk space.")); return
        }
        var received = Int(end)
        if received >= item.size { try? handle.truncate(atOffset: 0); received = 0 }
        fetches[id] = Fetch(item: item, link: link, handle: handle, received: received)
        link.jobs.append(.fetch(id, received))
        pump(link)
        onTransfer?()
    }

    /// Stops a running fetch. What has arrived is kept for the next attempt.
    public func cancel(_ id: UUID) {
        guard let fetch = fetches[id] else { return }
        fetch.link.jobs.append(.cancel(id))
        pump(fetch.link)
        fail(id, nil)
    }

    private func receive(_ data: Data, of id: UUID, from link: Link) {
        guard let fetch = fetches[id], fetch.link === link else { return }
        fetch.received += data.count
        guard fetch.received <= fetch.item.size, (try? fetch.handle.write(contentsOf: data)) != nil else {
            link.jobs.append(.cancel(id)); pump(link)
            try? fetch.handle.close()
            fetches[id] = nil
            try? FileManager.default.removeItem(at: store.partialURL(fetch.item))
            finish(id, failure: tr("Retrieval failed (the disk is full or the content did not match). What arrived was discarded."))
            return
        }
        if Date().timeIntervalSince(lastProgress) > 0.15 { lastProgress = Date(); onTransfer?() }
    }

    /// Ends a fetch without its bytes. The partial file stays.
    private func fail(_ id: UUID, _ message: String?) {
        guard let fetch = fetches.removeValue(forKey: id) else { return }
        try? fetch.handle.close()
        finish(id, failure: message)
    }

    /// The fetch is over, one way or the other: serve or turn away the Macs that were waiting on it.
    private func finish(_ id: UUID, failure: String?) {
        failures[id] = failure
        for (link, offset) in waitingForFetch.removeValue(forKey: id) ?? [] where link.alive {
            if failure == nil { answerFetch(id, offset: offset, for: link) }
            else { link.jobs.append(.refuse(id, tr("The Mac in between could not get this file."))); pump(link) }
        }
        onTransfer?()
    }

    /// Everything about an item that is going away.
    private func forget(_ id: UUID) {
        if let fetch = fetches.removeValue(forKey: id) {
            try? fetch.handle.close()
            fetch.link.jobs.append(.cancel(id)); pump(fetch.link)
        }
        failures[id] = nil
        for (link, _) in waitingForFetch.removeValue(forKey: id) ?? [] where link.alive {
            link.jobs.append(.refuse(id, tr("This item has been removed from the Shelf."))); pump(link)
        }
        for link in links {
            link.holds.remove(id); link.offers.remove(id)
            link.serving[id] = nil
        }
    }

    /// Another Mac asks for a large item's bytes from `offset` on.
    private func answerFetch(_ id: UUID, offset: Int, for link: Link) {
        guard let item = store.item(id), item.isLarge else {
            link.jobs.append(.refuse(id, tr("This item has been removed from the Shelf."))); pump(link); return
        }
        if store.isPresent(id) {
            guard offset <= item.size, let handle = try? FileHandle(forReadingFrom: store.url(item)),
                  (try? handle.seek(toOffset: UInt64(offset))) != nil else {
                link.jobs.append(.refuse(id, tr("That Mac cannot read this file."))); pump(link); return
            }
            let serve = Serve(id: id, handle: handle, offset: offset)
            link.serving[id] = serve
            link.jobs.append(.serve(serve))
            pump(link)
            return
        }
        // Not here, but next door: get it, then serve it. Only from a Mac that has it itself.
        guard links.contains(where: { $0 !== link && $0.holds.contains(id) }) else {
            link.jobs.append(.refuse(id, tr("None of the Macs that hold this file are online."))); pump(link); return
        }
        waitingForFetch[id, default: []].append((link, offset))
        if fetches[id] == nil {
            fetch(id)
            if fetches[id] == nil { finish(id, failure: failures[id] ?? tr("Could not get this file.")) }
        }
    }
}
