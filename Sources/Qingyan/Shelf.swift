import AppKit
import SwiftUI
import QuickLookThumbnailing
import SystemConfiguration
import UniformTypeIdentifiers
import QingyanCore

/// The shelf as the panel shows it: what is on it, how to put things on and take them off.
@MainActor
final class ShelfModel: ObservableObject {
    @Published var items: [ShelfItem] = []
    /// How many other Macs share this shelf right now.
    @Published var linked = 0
    /// The Macs with a live connection to this one, whoever called whom.
    @Published var linkedKeys: Set<String> = []
    /// What the Shelf has to say for a moment, shown over the panel rather than in it: nothing the
    /// Shelf does moves the panel or the tiles (user 2026-11-27: no click on the Shelf may change the
    /// panel; a toast may say what was copied).
    @Published private(set) var notice: ShelfNotice?
    @Published var targeted = false
    /// The Shelf over the whole panel, until it is put back (user 2026-11-27).
    @Published var expanded = false
    /// Widths set by hand on this Mac, in cells. The rest are worked out here from the item, so
    /// nothing about them travels to the other Macs (user 2026-11-27).
    @Published private(set) var widths: [UUID: Int] = [:]
    private static let widthsKey = "shelf.widths"
    private var nameWidths: [String: CGFloat] = [:]
    private var icons: [UUID: NSImage] = [:]
    /// Copied files on their way onto the Shelf, so that one copied twice in a row goes on once.
    private var shelving: Set<String> = []
    /// Put on the Shelf by a copy: kept on the primary helper only once their link is asked for.
    private var quiet: Set<UUID> = []
    /// The items this Mac was given a link for, and the link.
    @Published private(set) var links: [UUID: String] = [:]
    /// Links being made: how much of the file has gone to the primary helper.
    @Published private(set) var linking: [UUID: Double] = [:]
    /// Whether the helper on this Mac knows a primary helper to keep files on.
    @Published private(set) var linkable = false
    private var linkTasks: [UUID: Task<Void, Never>] = [:]
    /// Links still to be taken down at the primary helper: their items left the Shelf.
    private var unlinking: Set<UUID> = []
    /// Items whose bytes were sent for a link that this Mac never heard of: the primary helper may
    /// hold them all the same, so they are taken down with the item.
    private var maybeLinked: Set<UUID> = []
    /// The take-downs that are on their way or waiting their turn.
    private var retiring: Set<UUID> = []
    private var unlinkTried = Date.distantPast
    /// What is asked of the primary helper about one item, in order: a link being made and a link
    /// being taken down must not pass each other on the way there.
    private var asks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private(set) var store: ShelfStore?
    private(set) var sync: ShelfSync?
    private var thumbnails: [UUID: NSImage] = [:]
    /// Tiles being made off the main thread.
    private var makingTiles: Set<UUID> = []
    private var snippets: [UUID: String] = [:]
    /// Items the user clicked before their bytes were here: copy them once they arrive.
    private var copyWhenHere: Set<UUID> = []
    /// Items asked to be downloaded to this Mac: shown in the Finder once they arrive.
    private var revealWhenHere: Set<UUID> = []
    private var expiryChecked = Date.distantPast
    private var peeks: [UUID: NSImage] = [:]
    /// Clicked while its link was still being made for it, as it was put on the Shelf: copied when it comes.
    private var copyWhenLinked: Set<UUID> = []
    /// This Mac's own images and files not yet kept on the primary helper, and when to try again.
    private var hostAgain: [UUID: (at: Date, wait: TimeInterval)] = [:]
    /// The images and files on the Shelf at the last look: any one of them that leaves it is taken
    /// down at the primary helper by every Mac, which any may do, whoever sent it there.
    private var hostable: Set<UUID> = []
    /// Drags of a card waiting for its bytes, each told the file when it has come (nil: it will not).
    private var dragWaiters: [UUID: [(URL?) -> Void]] = [:]
    /// Downloads straight from the primary helper, when no Mac that holds the file is online.
    private var helperDownloads: [UUID: Task<Void, Never>] = [:]
    let name: String
    /// What a drop on the panel may carry.
    static let types: [UTType] = [.fileURL, .image, .url, .utf8PlainText, .plainText]

    init(preview: Bool) {
        name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
        guard !preview else { return }
        if let saved = UserDefaults.standard.dictionary(forKey: Self.widthsKey) as? [String: Int] {
            widths = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Qingyan/Shelf", isDirectory: true)
            let store = try ShelfStore(directory: directory)
            let sync = ShelfSync(store: store, name: name)
            store.onChange = { [weak self] in self?.reload() }
            sync.onStatus = { [weak self, weak sync] in
                guard let self else { return }
                let nextLinked = sync?.linked ?? 0
                let nextKeys = sync?.linkedKeys ?? []
                if self.linked != nextLinked { self.linked = nextLinked }
                if self.linkedKeys != nextKeys { self.linkedKeys = nextKeys }
            }
            sync.onTransfer = { [weak self] in self?.transferMoved() }
            self.store = store; self.sync = sync
            loadLinks()
            reload()
        } catch { say(tr("Could not open the Shelf folder. Check disk space and access permissions."), for: nil, mark: .problem) }
    }

    private func reload() {
        let next = store?.items ?? []
        if items != next { items = next }
        let present = Set(next.map(\.id))
        thumbnails = thumbnails.filter { present.contains($0.key) }
        icons = icons.filter { present.contains($0.key) }
        snippets = snippets.filter { present.contains($0.key) }
        peeks = peeks.filter { present.contains($0.key) }
        // An item removed from the Shelf, here or on another Mac, takes its link with it. Removed,
        // not merely missing: a Shelf that could not be read has no items and no removals, and takes
        // nothing down.
        if let store {
            // A width set by hand goes with its item; not when the Shelf could not be read.
            let stale = widths.keys.filter { !present.contains($0) && store.isGone($0) }
            if !stale.isEmpty { stale.forEach { widths[$0] = nil }; saveWidths() }
            let unquiet = quiet.filter { !present.contains($0) && store.isGone($0) }
            if !unquiet.isEmpty { quiet.subtract(unquiet); saveLinks() }
            let wasHostable = hostable
            hostable = Set(next.filter { $0.kind != .text && $0.card == true }.map(\.id))
            // Taken down by whichever Mac sees it leave (any may), but only where a primary helper keeps files.
            let left = linkable ? wasHostable.filter { !present.contains($0) && store.isGone($0) } : []
            let orphaned = Set(links.keys).union(maybeLinked).filter { !present.contains($0) && store.isGone($0) }.union(left)
            if !orphaned.isEmpty {
                for id in orphaned { links[id] = nil; maybeLinked.remove(id); unlinking.insert(id); linkTasks[id]?.cancel() }
                saveLinks()
                takeDown(now: true)
            }
        }
    }

    /// Shows `text` for `seconds` (nil: until something else is said), and has VoiceOver read it.
    private func say(_ text: String, for seconds: Double? = 2.4, mark: ShelfNotice.Mark = .none) {
        let next = ShelfNotice(text: text, mark: mark)
        notice = next
        AccessibilityNotification.Announcement(text).post()
        guard let seconds else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.notice?.id == next.id else { return }
            self.notice = nil
        }
    }

    // MARK: Putting things on

    /// A drop on the panel. Each provider becomes one item: a file, an image, or text.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        guard store != nil else { return false }
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in self.addFile(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in self.addImage(data) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in self.addText(text) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.addText(url.absoluteString) }
                }
            }
        }
        return handled
    }

    /// Whatever is on the system clipboard: files, else an image, else text.
    func addClipboard() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach(addFile)
        } else if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            addImage(data)
        } else if let text = board.string(forType: .string), !text.isEmpty {
            addText(text)
        } else { say(tr("The clipboard holds nothing to put on the Shelf.")) }
    }

    /// An entry of the clipboard history: its files, its picture or its text.
    func put(_ entry: ClipEntry, from history: ClipboardHistory) {
        guard store != nil else { return }
        switch entry.kind {
        case .files: history.files(entry).forEach(addFile)
        case .image: if let data = history.imageBytes(entry) { addImage(data) }
        case .text: if let text = history.text(entry) { addText(text) }
        }
    }

    /// Every file copied on this Mac goes on the Shelf as History keeps it (user 2026-11-27: whatever
    /// is a file in History is on the Shelf too). Quietly: nothing is said, and nothing is sent to the
    /// primary helper until its link is asked for. A folder, a file already on the Shelf, or one that
    /// cannot be read stays in History alone. The files are looked at off the main thread: one may
    /// be on a slow disk or a network volume.
    func shelveCopied(_ files: [URL]) {
        guard let store, !files.isEmpty, files.count <= Self.quietCopyMost else { return }
        let home = store.directory
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { files.compactMap { Self.copied($0, home: home) } }.value
            guard let self else { return }
            for file in found { self.addQuietly(file) }
        }
    }

    /// A copy of more files at once than this stays in History alone: a whole folder's worth would
    /// bury the Shelf and send a card of each to every Mac.
    private static let quietCopyMost = 20
    /// The most a copied file from another disk may be to go on the Shelf by itself: on the Shelf's
    /// own disk a file is a clone and takes no space, from another one it is copied whole.
    nonisolated private static let quietCopyLimit = 1 << 30

    private struct Copied: Sendable {
        let url: URL
        let name: String
        let size: Int
        let modified: Date?
        let image: Bool
        var token: String { "\(name)\u{0}\(size)\u{0}\(modified?.timeIntervalSince1970 ?? 0)" }
    }

    nonisolated private static func copied(_ url: URL, home: URL) -> Copied? {
        guard url.isFileURL, !url.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path),
              let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .volumeIdentifierKey]),
              values.isDirectory != true, let size = values.fileSize, size > 0 else { return nil }
        if size > quietCopyLimit {
            let shelfDisk = (try? home.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
            guard let disk = values.volumeIdentifier as? NSObject, let shelfDisk, disk.isEqual(shelfDisk) else { return nil }
        }
        return Copied(url: url, name: url.lastPathComponent, size: size,
                      modified: values.contentModificationDate, image: values.contentType?.conforms(to: .image) == true)
    }

    private func addQuietly(_ file: Copied) {
        let name = ShelfStore.cleanName(file.name)
        guard let store, !shelving.contains(file.token),
              !items.contains(where: { $0.kind != .text && $0.name == name && $0.size == file.size && $0.modified == file.modified }) else { return }
        shelving.insert(file.token)
        Task { [weak self] in
            guard let self else { return }
            defer { self.shelving.remove(file.token) }
            let thumbnail = await Self.quickLook(file.url)
            guard let item = try? await store.add(copying: file.url, kind: file.image ? .image : .file, origin: self.name, thumbnail: thumbnail) else { return }
            // Remembered across restarts: the primary helper gets it only when its link is asked for.
            self.quiet.insert(item.id)
            self.saveLinks()
        }
    }

    private func addFile(_ url: URL) {
        guard let store else { return }
        guard !url.standardizedFileURL.path.hasPrefix(store.directory.standardizedFileURL.path) else { return }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let image = values?.contentType?.conforms(to: .image) == true
        let large = (values?.fileSize ?? 0) > ShelfStore.eagerBytes
        if large { say(tr("Adding “%@”…", url.lastPathComponent), for: 60) }
        Task { [weak self] in
            guard let self else { return }
            // Every file and image is a card on the other Macs: each has its thumbnail.
            let thumbnail = await Self.quickLook(url)
            do {
                let item = try await store.add(copying: url, kind: image ? .image : .file, origin: self.name, thumbnail: thumbnail)
                if large { self.say(tr("Added “%@”. Other Macs fetch it when it is needed.", item.name), for: 3.5, mark: .done) }
                self.keep(item)
            } catch { self.say(error.localizedDescription, for: 4, mark: .problem) }
        }
    }

    /// The thumbnail the other Macs' card shows, and the picture that floats out of a tile: large
    /// enough for that, small enough to travel with the card (under 200 KB).
    private static let thumbnailSide: CGFloat = 280

    private static func quickLook(_ url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: thumbnailSide, height: thumbnailSide), scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return jpeg(representation.nsImage)
    }

    private static func jpeg(_ image: NSImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let k = min(1, thumbnailSide * 2 / max(image.size.width, image.size.height))
        let size = NSSize(width: max(1, (image.size.width * k).rounded()), height: max(1, (image.size.height * k).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        for quality in [0.7, 0.5, 0.35] {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= 190_000 { return data }
        }
        return nil
    }

    /// Kept on the primary helper as it is put on the Shelf here, so that Copy link on any Mac copies
    /// its link at once; nothing is copied now.
    private func keep(_ item: ShelfItem) {
        guard item.kind != .text, linkable else { return }
        link(item, copying: false)
    }

    private func addImage(_ data: Data) {
        guard let store else { return }
        let stamp = Date().formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: ",", with: "")
        var payload = data, kind = "png"
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0x89, 0x50, 0x4e, 0x47]) { kind = "png" }
        else if head.starts(with: [0xff, 0xd8, 0xff]) { kind = "jpg" }
        else if head.starts(with: [0x47, 0x49, 0x46]) { kind = "gif" }
        else if let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) { payload = png }
        else { say(tr("This image format is not supported, so it was not put on the Shelf."), for: 4, mark: .problem); return }
        // The name is for people to read (it becomes the file's name when dragged out); nothing matches on it.
        do {
            let item = try store.add(payload, kind: .image, name: tr("Image %@.%@", stamp, kind), origin: name,
                                     thumbnail: NSImage(data: payload).flatMap(Self.jpeg))
            keep(item)
        } catch { say(error.localizedDescription, for: 4, mark: .problem) }
    }

    private func addText(_ text: String) {
        guard let store, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !items.contains(where: { $0.kind == .text && store.text($0) == text }) else { return }
        do { try store.add(Data(text.utf8), kind: .text, name: tr("Text.txt"), origin: name) }
        catch { say(error.localizedDescription, for: 4, mark: .problem) }
    }

    // MARK: Taking things off

    func snippet(_ item: ShelfItem) -> String {
        if let known = snippets[item.id] { return known }
        let text = String((store?.text(item) ?? "").prefix(160))
        snippets[item.id] = text
        return text
    }

    func fullText(_ item: ShelfItem) -> String {
        store?.text(item) ?? snippet(item)
    }

    /// A tile's picture: 128 points square, the picture filling it. From the cache, or nil while it
    /// is made off the main thread (the Shelf is drawn again once it is there). It used to be the
    /// whole picture decoded on the main thread, tile after tile: 1.3 to 1.8 s for 14 screenshots,
    /// and the bar kept on top, which shows every tile, took seconds to come the first time after a
    /// start (user 2026-11-26). ImageIO makes the 14 at their size in about 0.25 s, off the main thread.
    func thumbnail(_ item: ShelfItem) -> NSImage? {
        if let known = thumbnails[item.id] { return known }
        guard let store, !makingTiles.contains(item.id) else { return nil }
        let card = store.thumbnail(item)
        let file: URL? = item.kind == .image && store.isPresent(item.id) ? store.url(item) : nil
        guard card != nil || file != nil else { return nil }
        makingTiles.insert(item.id)
        let id = item.id
        Task.detached(priority: .userInitiated) {
            let tile = Self.tile(card: card, file: file)
            await MainActor.run {
                self.makingTiles.remove(id)
                guard let tile else { return }
                self.objectWillChange.send()
                self.thumbnails[id] = tile
            }
        }
        return nil
    }

    /// 256 pixels square (128 points), the picture filling it about its middle: from the card's
    /// thumbnail where there is one, else from the file, decoded by ImageIO no larger than needed.
    nonisolated private static func tile(card: Data?, file: URL?) -> NSImage? {
        let side = 256
        guard let source = card.flatMap({ CGImageSourceCreateWithData($0 as CFData, nil) })
                ?? file.flatMap({ CGImageSourceCreateWithURL($0 as CFURL, nil) }) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? side
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? side
        // The short side at the tile's size at least, so that the picture fills it.
        let longest = Double(side) * Double(max(width, height)) / Double(max(min(width, height), 1))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(Int(longest.rounded(.up)), 4096),
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              picture.width > 0, picture.height > 0,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = max(Double(side) / Double(picture.width), Double(side) / Double(picture.height))
        let drawn = CGSize(width: Double(picture.width) * scale, height: Double(picture.height) * scale)
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(x: (Double(side) - drawn.width) / 2, y: (Double(side) - drawn.height) / 2,
                                         width: drawn.width, height: drawn.height))
        guard let made = context.makeImage() else { return nil }
        return NSImage(cgImage: made, size: NSSize(width: 128, height: 128))
    }

    // MARK: Widths

    /// Pictures and videos show themselves, one cell wide (user 2026-11-27).
    func isPicture(_ item: ShelfItem) -> Bool {
        if item.kind == .image { return true }
        guard item.kind == .file, let type = UTType(filenameExtension: (item.name as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// The widest an item may be: a picture one cell, text two, any other file three.
    func mostCells(_ item: ShelfItem) -> Int { isPicture(item) ? 1 : item.kind == .text ? 2 : 3 }

    /// How many cells an item is wide: as set by hand on this Mac, else text two, and any other file
    /// two when its name fits on its line there, three when it does not (user 2026-11-27).
    func cells(_ item: ShelfItem) -> Int {
        let most = mostCells(item)
        if let set = widths[item.id] { return min(max(set, 1), most) }
        if most == 1 { return 1 }
        if item.kind == .text { return 2 }
        return nameWidth(item.name) <= ShelfRows.nameRoom(2) ? 2 : 3
    }

    func setCells(_ item: ShelfItem, _ cells: Int) {
        let next = min(max(cells, 1), mostCells(item))
        guard widths[item.id] != next else { return }
        widths[item.id] = next
        saveWidths()
    }

    private func saveWidths() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: widths.map { ($0.key.uuidString, $0.value) }), forKey: Self.widthsKey)
    }

    private func nameWidth(_ name: String) -> CGFloat {
        if let known = nameWidths[name] { return known }
        let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: ShelfRows.nameSize, weight: .medium)]).width.rounded(.up)
        nameWidths[name] = width
        return width
    }

    /// The first line under a file's name: its size and its type.
    func facts(_ item: ShelfItem) -> String {
        let type = (item.name as NSString).pathExtension.uppercased()
        return type.isEmpty ? Self.size(item.size) : "\(Self.size(item.size)) · \(type)"
    }

    /// The second: when the file was changed, as the Finder writes it and with no word before it
    /// (user 2026-11-27: the time says what it is), or how it is coming. Nothing for a file put on
    /// the Shelf by an earlier version, which did not keep that time.
    func detail(_ item: ShelfItem, _ stage: Stage, wide: Bool) -> String? {
        switch stage {
        case .fetching(let progress): return tr("Fetching %ld%%", Int(progress * 100))
        case .failed(let reason): return reason
        case .elsewhere, .unreachable: return tr("On %@", item.origin)
        case .here: return item.modified.map { Self.changed($0, wide: wide) }
        }
    }

    /// Today and yesterday by name with the time; an earlier day by its date, and its time where
    /// the tile is wide enough for it.
    static func changed(_ date: Date, wide: Bool) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return relativeDay.string(from: date) + " " + date.formatted(date: .omitted, time: .shortened)
        }
        return wide ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) : date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static let relativeDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    // MARK: Large items

    enum Stage: Equatable {
        case here
        case elsewhere
        case unreachable
        case fetching(Double)
        case failed(String)
    }
    #if DEBUG
    var previewStages: [UUID: Stage] = [:]
    #endif

    func stage(_ item: ShelfItem) -> Stage {
        #if DEBUG
        if let staged = previewStages[item.id] { return staged }
        #endif
        guard let store, let sync else { return .here }
        if store.isPresent(item.id) { return .here }
        if let progress = sync.progress(item.id) { return .fetching(progress) }
        if let failure = sync.failures[item.id] { return .failed(failure) }
        return sync.isAvailable(item.id) ? .elsewhere : .unreachable
    }

    static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    func fetch(_ item: ShelfItem) {
        guard let sync, stage(item) != .here else { return }
        sync.fetch(item.id)
        if let failure = sync.failures[item.id] { say(failure, for: 4, mark: .problem) }
    }

    func cancelFetch(_ item: ShelfItem) { copyWhenHere.remove(item.id); revealWhenHere.remove(item.id); sync?.cancel(item.id) }

    /// A click on a tile copies the item itself, an image, a file or text; one that is not on this Mac
    /// is downloaded first and copied once it is here. Its link is Copy link in the right-click menu
    /// (user 2026-11-25: a click copies the picture, a right-click the link; until then a click on an
    /// item with a link copied the link, user 2026-11-22).
    func click(_ item: ShelfItem) { copy(item) }

    /// What a tile says when the pointer rests on it: what it is, where from, what a click does, and
    /// the day it leaves the Shelf.
    func hint(_ item: ShelfItem, _ stage: Stage) -> String {
        let title = item.kind == .text ? snippet(item) : "\(item.name) · \(Self.size(item.size))"
        var leaves = tr("Removed from the Shelf on %@", item.expires.formatted(date: .abbreviated, time: .omitted))
        if let modified = item.modified { leaves = tr("Modified %@", Self.changed(modified, wide: true)) + "\n" + leaves }
        // An item with a link has it in the right-click menu.
        let linked = item.kind != .text && canLink(item)
        let line: String
        switch stage {
        case .fetching(let progress): line = tr("%@\nFetching %ld%% · Click to pause; what has arrived is kept", title, Int(progress * 100))
        case .failed(let reason): line = linked ? tr("%@\n%@ · Click to download it again and copy it · Right-click to copy its link", title, reason)
                                                : tr("%@\n%@ · Click to try again", title, reason)
        case .here: line = linked ? tr("%@\nFrom %@ · Click to copy, or drag it out · Right-click to copy its link", title, item.origin)
                                  : tr("%@\nFrom %@ · Click to copy, or drag it out", title, item.origin)
        case .elsewhere: line = linked ? tr("%@\nFrom %@ · Click to download and copy it · Right-click to copy its link", title, item.origin)
                                       : tr("%@\nFrom %@ · Click to download and copy it", title, item.origin)
        case .unreachable: line = linked ? tr("%@\nFrom %@ · No Mac that holds this file is online · Click to download it from the primary helper and copy it · Right-click to copy its link", title, item.origin)
                                         : tr("%@\nFrom %@ · No Mac that holds this file is online", title, item.origin)
        }
        return line + "\n" + leaves
    }

    /// Right-click, Download to This Mac: the file is fetched here and shown in the Finder when it has come.
    func download(_ item: ShelfItem) {
        guard stage(item) != .here else { reveal(item); return }
        revealWhenHere.insert(item.id)
        fetch(item)
        if case .fetching = stage(item) {
            say(tr("Downloading “%@” (%@). It is shown in the Finder when it arrives.", item.name, Self.size(item.size)), for: 4)
        } else if canLink(item) {
            // No Mac that holds it is online: the primary helper keeps it.
            fromHelper(item)
        } else { revealWhenHere.remove(item.id) }
    }

    /// The file as the primary helper keeps it, through its link, when no Mac that holds it is online;
    /// `copying`: for a click, which copies it once it is here, rather than Download to This Mac.
    private func fromHelper(_ item: ShelfItem, copying: Bool = false) {
        guard let store, helperDownloads[item.id] == nil else { return }
        let id = item.id
        say(copying ? tr("Downloading “%@” (%@) from the primary helper. It is copied when it arrives.", item.name, Self.size(item.size))
                    : tr("Downloading “%@” (%@) from the primary helper. It is shown in the Finder when it arrives.", item.name, Self.size(item.size)), for: 4)
        helperDownloads[id] = Task { [weak self] in
            var failure: String?
            do {
                let known = await MainActor.run { self?.links[id] }
                let address: String
                if let known { address = known }
                else { address = try await HelperLink.host(id: id, name: item.name, size: item.size, file: nil, progress: nil) }
                guard let url = URL(string: address) else { throw VoiceError(tr("Could not get this file.")) }
                let (file, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == item.size else {
                    try? FileManager.default.removeItem(at: file)
                    throw VoiceError(tr("The primary helper no longer has “%@”.", item.name))
                }
                await MainActor.run {
                    guard let self, store.has(id), !store.isPresent(id) else { try? FileManager.default.removeItem(at: file); return }
                    try? FileManager.default.removeItem(at: store.partialURL(item))
                    do { try FileManager.default.moveItem(at: file, to: store.partialURL(item)); try store.finishFetch(item) }
                    catch { failure = error.localizedDescription }
                }
            } catch { failure = error.localizedDescription }
            await MainActor.run {
                guard let self else { return }
                self.helperDownloads[id] = nil
                if let failure {
                    self.revealWhenHere.remove(id)
                    self.copyWhenHere.remove(id)
                    self.answerDrags(id, with: nil)
                    self.say(tr("Could not fetch “%@”: %@", item.name, failure), for: 5, mark: .problem)
                } else { self.transferMoved() }
            }
        }
    }

    private func answerDrags(_ id: UUID, with url: URL?) {
        for waiter in dragWaiters.removeValue(forKey: id) ?? [] { waiter(url) }
    }

    /// The picture that floats out of a tile: the image itself where it is here, else the card's thumbnail.
    func peek(_ item: ShelfItem) -> NSImage? {
        if let known = peeks[item.id] { return known }
        guard let store, item.kind != .text else { return nil }
        // The card's picture is made for this size; an image put on the Shelf before it had one is
        // read at that size from the file, never whole.
        var image = store.thumbnail(item).flatMap(NSImage.init(data:))
        if image == nil, item.kind == .image, store.isPresent(item.id),
           let source = CGImageSourceCreateWithURL(store.url(item) as CFURL, nil),
           let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: Int(Self.thumbnailSide * 2),
                                                                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            image = NSImage(cgImage: small, size: NSSize(width: small.width / 2, height: small.height / 2))
        }
        if let image { peeks[item.id] = image }
        return image
    }
    func release(_ item: ShelfItem) { store?.release(item.id) }
    func canRelease(_ item: ShelfItem) -> Bool { store.map { item.isLarge && $0.isPresent(item.id) && !$0.isOwn(item.id) } ?? false }

    private func transferMoved() {
        objectWillChange.send()
        guard let store, let sync else { return }
        for id in Array(dragWaiters.keys) {
            guard let item = store.item(id) else { answerDrags(id, with: nil); continue }
            if store.isPresent(id) { answerDrags(id, with: store.url(item)) }
            else if sync.progress(id) == nil, helperDownloads[id] == nil {
                if sync.failures[id] != nil, canLink(item) { fromHelper(item) } else { answerDrags(id, with: nil) }
            }
        }
        for id in revealWhenHere {
            guard let item = store.item(id) else { revealWhenHere.remove(id); continue }
            if store.isPresent(id) { revealWhenHere.remove(id); reveal(item) }
            else if sync.progress(id) == nil, helperDownloads[id] == nil {
                // The Mac it was coming from went away: the primary helper keeps it too.
                if sync.failures[id] != nil, canLink(item) { fromHelper(item); continue }
                revealWhenHere.remove(id)
                if let failure = sync.failures[id] { say(tr("Could not fetch “%@”: %@", item.name, failure), for: 5, mark: .problem) }
            }
        }
        for id in copyWhenHere {
            guard let item = store.item(id) else { copyWhenHere.remove(id); continue }
            if store.isPresent(id) { copyWhenHere.remove(id); copy(item) }
            else if sync.progress(id) == nil, helperDownloads[id] == nil {
                // The Mac it was coming from went away: the primary helper keeps it too.
                if sync.failures[id] != nil, canLink(item) { fromHelper(item, copying: true); continue }
                copyWhenHere.remove(id)
                if let failure = sync.failures[id] { say(tr("Could not fetch “%@”: %@", item.name, failure), for: 5, mark: .problem) }
            }
        }
    }

    func icon(_ item: ShelfItem) -> NSImage {
        let here = store?.isPresent(item.id) == true
        if here, let known = icons[item.id] { return known }
        guard let store, here else { return NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data) }
        let icon = NSWorkspace.shared.icon(forFile: store.url(item).path)
        icons[item.id] = icon
        return icon
    }

    /// Puts the item on the system clipboard, in the forms other apps expect.
    func copy(_ item: ShelfItem) {
        guard let store else {
            if item.kind == .text {
                PasteboardLease.general.keep(snippet(item))
                say(tr("Copied “%@”, ready to paste.", String(snippet(item).prefix(12))), mark: .done)
            }
            return
        }
        guard store.isPresent(item.id) else {
            copyWhenHere.insert(item.id)
            fetch(item)
            if case .fetching = stage(item) { say(tr("Fetching “%@” (%@). It is copied when it arrives.", item.name, Self.size(item.size)), for: 4) }
            // No Mac that holds it is online: the primary helper keeps it.
            else if item.kind != .text, canLink(item) { fromHelper(item, copying: true) }
            else { copyWhenHere.remove(item.id) }
            return
        }
        store.touch(item.id)
        let board = NSPasteboard.general
        board.clearContents()
        switch item.kind {
        case .text:
            PasteboardLease.general.keep(store.text(item) ?? "")
        case .image:
            let entry = NSPasteboardItem()
            entry.setString(store.url(item).absoluteString, forType: .fileURL)
            // Pixels too for a small image, whether or not it travels as a card.
            if item.size <= ShelfStore.eagerBytes, let tiff = NSImage(contentsOf: store.url(item))?.tiffRepresentation { entry.setData(tiff, forType: .tiff) }
            board.writeObjects([entry])
        case .file:
            board.writeObjects([store.url(item) as NSURL])
        }
        say(tr("Copied “%@”, ready to paste.", item.kind == .text ? String(snippet(item).prefix(12)) : item.name), mark: .done)
    }

    func provider(_ item: ShelfItem) -> NSItemProvider {
        guard let store else { return NSItemProvider() }
        guard store.isPresent(item.id) else {
            // The file is promised to where it is dropped, and handed over once it has come.
            let id = item.id
            let provider = NSItemProvider()
            provider.suggestedName = item.name
            let type = UTType(filenameExtension: (item.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier
            provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { [weak self] completion in
                let progress = Progress(totalUnitCount: 1)
                Task { @MainActor in
                    guard let self else { completion(nil, false, nil); return }
                    self.dragWaiters[id, default: []].append { url in
                        progress.completedUnitCount = 1
                        completion(url, false, url == nil ? VoiceError(tr("Could not get this file.")) : nil)
                    }
                    self.fetch(item)
                    if case .fetching = self.stage(item) {} else if self.canLink(item) { self.fromHelper(item) } else { self.answerDrags(id, with: nil) }
                }
                return progress
            }
            say(tr("Fetching “%@” from the other Mac. It can be dragged out when it arrives.", item.name), for: 4)
            return provider
        }
        store.touch(item.id)
        if item.kind == .text { return NSItemProvider(object: (store.text(item) ?? "") as NSString) }
        return NSItemProvider(contentsOf: store.url(item)) ?? NSItemProvider()
    }

    // MARK: Links

    private struct LinkFile: Codable {
        var links: [String: String]
        var unlinking: [String]
        var maybe: [String]?
        var quiet: [String]?
    }
    private var linkFile: URL? { store?.directory.appendingPathComponent("links.json") }

    private func loadLinks() {
        guard let linkFile, let data = try? Data(contentsOf: linkFile), let saved = try? JSONDecoder().decode(LinkFile.self, from: data) else { return }
        links = Dictionary(saved.links.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
        unlinking = Set(saved.unlinking.compactMap { UUID(uuidString: $0) })
        maybeLinked = Set((saved.maybe ?? []).compactMap { UUID(uuidString: $0) })
        quiet = Set((saved.quiet ?? []).compactMap { UUID(uuidString: $0) })
    }

    /// Runs work for this item after whatever was asked about it before.
    @discardableResult
    private func ask(_ id: UUID, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let before = asks[id]?.task
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await before?.value
            await work()
            if self?.asks[id]?.token == token { self?.asks[id] = nil }
        }
        asks[id] = (token, task)
        return task
    }

    private func saveLinks() {
        guard let linkFile else { return }
        let file = LinkFile(links: Dictionary(links.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first }),
                            unlinking: unlinking.map(\.uuidString).sorted(), maybe: maybeLinked.map(\.uuidString).sorted(),
                            quiet: quiet.map(\.uuidString).sorted())
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: linkFile, options: .atomic) }
    }

    /// What the helper on this Mac says about links, each time it is asked for the other Macs.
    func helperSaid(linkable next: Bool) {
        let became = next && !linkable
        if linkable != next { linkable = next }
        if next { takeDown() }
        if became { hostPending(all: true) }
    }

    /// This Mac's own images and files the primary helper does not keep yet: a helper that learned of
    /// one only after they were put on the Shelf, or a send that did not go through.
    private func hostPending(all: Bool = false) {
        guard linkable, let store else { return }
        let now = Date()
        for item in store.items where item.kind != .text && item.card == true && store.isOwn(item.id) && store.isPresent(item.id)
            && links[item.id] == nil && linkTasks[item.id] == nil && !quiet.contains(item.id) {
            if !all, let again = hostAgain[item.id], again.at > now { continue }
            if hostAgain[item.id] == nil { hostAgain[item.id] = (now, 30) }
            link(item, copying: false)
        }
    }

    func hasLink(_ item: ShelfItem) -> Bool { links[item.id] != nil }
    func canLink(_ item: ShelfItem) -> Bool { linkable || links[item.id] != nil }

    private func title(_ item: ShelfItem) -> String { item.kind == .text ? String(snippet(item).prefix(12)) : item.name }

    private func place(_ link: String, for item: ShelfItem) {
        PasteboardLease.general.keep(link)
        say(tr("Link to “%@” copied. It opens on devices on your tailnet.", title(item)), for: 4, mark: .done)
    }

    nonisolated private func sent(_ id: UUID, _ fraction: Double) {
        Task { @MainActor [weak self] in
            guard let self, self.linking[id] != nil else { return }
            self.linking[id] = fraction
        }
    }

    /// Copies the item's link. The primary helper keeps the item and gives the address it opens at
    /// on the tailnet; a link this Mac was given before is copied at once and checked afterwards.
    /// `copying: false`: the item is only kept on the primary helper (as it is put on the Shelf).
    func link(_ item: ShelfItem, copying: Bool = true) {
        if linkTasks[item.id] != nil {
            // Being made already (as it was put on the Shelf): its link is copied when it comes.
            if copying, copyWhenLinked.insert(item.id).inserted {
                say(tr("Sending “%@” to the primary helper. Its link is copied when it arrives.", title(item)), for: 4)
            }
            return
        }
        guard let store else { return }
        let id = item.id
        let known = links[id]
        if let known, copying { place(known, for: item) }
        let file = store.isPresent(id) ? store.url(item) : nil
        if known == nil {
            linking[id] = 0
            if copying, item.size > ShelfStore.eagerBytes, file != nil {
                say(tr("Sending “%@” (%@) to the primary helper. Its link is copied when it arrives.", item.name, Self.size(item.size)), for: 4)
            }
        }
        // A take-down still waiting its turn is called off; one on its way is let finish first.
        let called = unlinking.remove(id) != nil
        let sending = known == nil && file != nil && maybeLinked.insert(id).inserted
        if called || sending { saveLinks() }
        linkTasks[id] = ask(id) { [weak self] in await self?.makeLink(item, known: known, file: file, copying: copying) }
    }

    private func progress(for id: UUID) -> @Sendable (Double) -> Void {
        { [weak self] fraction in self?.sent(id, fraction) }
    }

    private func makeLink(_ item: ShelfItem, known: String?, file: URL?, copying: Bool) async {
        let id = item.id
        var made: String?
        var failure: Error?
        let moved: (@Sendable (Double) -> Void)? = known == nil ? progress(for: id) : nil
        do { made = try await HelperLink.host(id: id, name: item.name, size: item.size, file: file, progress: moved) }
        catch { failure = error }
        linkTasks[id] = nil
        linking[id] = nil
        guard store?.has(id) == true else {
            // Removed while its link was being made. Whether or not the answer came, the primary
            // helper may hold it now: it is taken down.
            maybeLinked.remove(id)
            unlinking.insert(id)
            saveLinks()
            takeDown(now: true)
            return
        }
        let wanted = copyWhenLinked.remove(id) != nil
        if let made {
            hostAgain[id] = nil
            let changed = links[id] != made
            if changed || maybeLinked.contains(id) { links[id] = made; maybeLinked.remove(id); saveLinks() }
            if known == nil, copying || wanted { place(made, for: item) }
            else if changed, let known, NSPasteboard.general.string(forType: .string) == known { PasteboardLease.general.keep(made) }
        } else if let failure, known == nil, !copying, !wanted, !(failure is CancellationError) {
            // Kept on the primary helper as it was put on the Shelf, and that did not go: tried again later.
            let wait = min((hostAgain[id]?.wait ?? 30) * 2, 3600)
            hostAgain[id] = (Date().addingTimeInterval(wait), wait)
        } else if let failure, known == nil, copying || wanted, !(failure is CancellationError) {
            // A link copied already stays as it is; only a first try says why it failed.
            say(failure.localizedDescription, for: 6, mark: .problem)
        }
    }

    func cancelLink(_ item: ShelfItem) { linkTasks[item.id]?.cancel() }

    /// Takes the item's link down: the primary helper lets its copy go, and the link stops opening.
    func unlink(_ item: ShelfItem) {
        linkTasks[item.id]?.cancel()
        guard links[item.id] != nil else { return }
        let id = item.id, name = title(item)
        links[id] = nil
        unlinking.insert(id)
        saveLinks()
        ask(id) { [weak self] in
            // Given a link again before this one's turn came: nothing to take down.
            guard let self, self.unlinking.contains(id) else { return }
            var down = true
            do { try await HelperLink.unhost(id: id) } catch { down = false }
            // Asked for again while this was on its way: that link is made next, and says so itself.
            guard self.unlinking.contains(id) else { return }
            if down {
                self.unlinking.remove(id)
                self.saveLinks()
                self.say(tr("Link to “%@” removed.", name), for: 3, mark: .done)
            } else {
                self.say(tr("The link to “%@” still opens: the primary helper could not be reached. It is taken down once it can be.", name), for: 6, mark: .problem)
            }
        }
    }

    /// Asks the primary helper to let go of what is no longer on the Shelf, at most once a minute
    /// while it cannot be reached. Each goes in its item's turn.
    private func takeDown(now: Bool = false) {
        guard !unlinking.isEmpty, now || Date().timeIntervalSince(unlinkTried) > 60 else { return }
        unlinkTried = Date()
        for id in unlinking where retiring.insert(id).inserted {
            ask(id) { [weak self] in
                guard let self else { return }
                defer { self.retiring.remove(id) }
                guard self.unlinking.contains(id) else { return }
                guard (try? await HelperLink.unhost(id: id)) != nil else { return }
                if self.unlinking.remove(id) != nil { self.saveLinks() }
            }
        }
    }

    func reveal(_ item: ShelfItem) {
        guard let store, store.isPresent(item.id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.url(item)])
    }

    func remove(_ item: ShelfItem) { store?.remove(item.id) }
    func clear() { store?.clear() }

    func probe() {
        guard let store else { return }
        if Date().timeIntervalSince(expiryChecked) > 60 {
            expiryChecked = Date()
            store.expire()
            hostPending()
        }
        let trigger = store.directory.deletingLastPathComponent().appendingPathComponent("shelf-probe.trigger")
        guard access(trigger.path, F_OK) == 0,
              let request = (try? String(contentsOf: trigger, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        try? FileManager.default.removeItem(at: trigger)
        if request == "fetch" {
            for item in store.items where item.isLarge && !store.isPresent(item.id) { sync?.fetch(item.id) }
        } else if request.hasPrefix("big "), let megabytes = Int(request.dropFirst(4)), (1...2048).contains(megabytes) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("out sync self-test \(megabytes)MB.bin")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            var block = [UInt8](repeating: 0, count: 1 << 20)
            for megabyte in 0..<megabytes {
                for index in stride(from: 0, to: block.count, by: 4096) { block[index] = UInt8((megabyte &* 7 &+ index / 4096) % 251) }
                try? handle.write(contentsOf: Data(block))
            }
            try? handle.close()
            Task { [weak self] in
                guard let self, let item = try? await store.add(copying: file, kind: .file, origin: self.name) else { return }
                try? FileManager.default.removeItem(at: file)
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                self.store?.remove(item.id)
            }
        } else {
            guard let item = try? store.add(Data("out sync self-test \(request)".utf8), kind: .text, name: tr("Text.txt"), origin: name) else { return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self?.store?.remove(item.id)
            }
        }
    }

    #if DEBUG
    func previewFill() {
        let tiles: [(ShelfItem.Kind, String, String)] = [(.image, "Screenshot.png", ""), (.text, "Text.txt", "Plan review on Thursday at 3 p.m., third-floor meeting room."),
                                                        (.file, "Report final.pdf", ""), (.image, "Photo.jpg", ""), (.text, "Text.txt", "https://example.com/a/very/long/link"),
                                                        (.file, "data.csv", ""), (.file, "Screen recording.mov", ""), (.file, "Assets.zip", ""), (.file, "Interview.mp4", ""), (.file, "Backup.dmg", "")]
        let sizes = [1000, 1000, 1000, 1000, 1000, 1000, 1_480_000_000, 612_000_000, 2_300_000_000, 94_000_000]
        items = tiles.enumerated().map { index, tile in
            ShelfItem(kind: tile.0, name: tile.1, size: sizes[index], date: Date().addingTimeInterval(Double(-index)), origin: index % 2 == 0 ? "Study Mac mini" : name)
        }
        previewStages = [items[6].id: .elsewhere, items[7].id: .fetching(0.42), items[8].id: .unreachable, items[9].id: .failed(tr("Connection lost"))]
        for (item, tile) in zip(items, tiles) {
            snippets[item.id] = tile.2
            if tile.0 == .image || item.name.hasSuffix("mov") || item.name.hasSuffix("mp4") {
                let hue = item.name.hasSuffix("png") ? 0.58 : item.name.hasSuffix("mov") ? 0.36 : item.name.hasSuffix("mp4") ? 0.82 : 0.08
                thumbnails[item.id] = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
                    NSGradient(starting: NSColor(hue: hue, saturation: 0.5, brightness: 0.9, alpha: 1),
                               ending: NSColor(hue: hue + 0.1, saturation: 0.7, brightness: 0.6, alpha: 1))?.draw(in: rect, angle: 60)
                    return true
                }
            }
        }
        linked = 1
    }

    func previewSay(_ text: String, mark: ShelfNotice.Mark = .done) { say(text, for: nil, mark: mark) }
    func previewQuiet() { notice = nil }
    #endif
}

/// One thing the Shelf says: copied, on its way, or what went wrong.
struct ShelfNotice: Equatable, Identifiable {
    enum Mark { case none, done, problem }
    let id = UUID()
    let text: String
    let mark: Mark
}

/// What the Shelf says, floating over the bottom of the panel or the bar for a moment: never a line
/// of its own that would push the panel taller, and never in the way of a click (user 2026-11-27).
struct ShelfToast: View {
    @ObservedObject var shelf: ShelfModel
    var size: CGFloat = 11
    var lines = 3

    var body: some View {
        ZStack {
            if let notice = shelf.notice {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    switch notice.mark {
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                    case .problem: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    case .none: EmptyView()
                    }
                    Text(notice.text).foregroundStyle(Palette.ink).lineLimit(lines).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: size, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
                .id(notice.id)
                .transition(Motion.reduced ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 5)), removal: .opacity))
            }
        }
        .animation(Motion.reduced ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.9), value: shelf.notice?.id)
        .allowsHitTesting(false)
        // VoiceOver hears it as it is said; it is not something to land on.
        .accessibilityHidden(true)
    }
}

/// The Shelf's tiles: rows of four cells, every tile one row high and one to three cells wide
/// (user 2026-11-27), placed by `ShelfGrid`.
enum ShelfRows {
    static let cell: CGFloat = 60
    static let gap: CGFloat = 6
    static let columns = 4
    static let icon: CGFloat = 34
    static let nameSize: CGFloat = 11
    static func width(_ cells: Int) -> CGFloat { CGFloat(cells) * (cell + gap) - gap }
    /// What a file's name has beside its icon in a tile `cells` wide.
    static func nameRoom(_ cells: Int) -> CGFloat { width(cells) - 6 - icon - 6 - 7 }
}

/// The shelf, pinned to the bottom of the panel. Drop anything on the panel to park it here;
/// click a tile to copy it, drag a tile out to use it. The same shelf shows on every paired Mac.
struct ShelfBar: View {
    @ObservedObject var shelf: ShelfModel
    @State private var hovered: UUID?
    @State private var confirm = false
    /// While a tile's right edge is dragged: the tile, and how wide it was when the drag began.
    @State private var sizing: UUID?
    @State private var sizingFrom = 2
    /// The edge that pushed the resize cursor, the only one that pops it; and the edge under the pointer.
    @State private var cursorOwner: UUID?
    @State private var edgeHovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "tray").font(.system(size: 11)).frame(width: 15)
                Text(tr("Shelf")).font(.system(size: 12, weight: .semibold))
                // How many Macs it is shared with is Multiple Macs' to say; here only that it is not.
                if shelf.linked == 0 {
                    Text(tr("This Mac only")).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(tr("Paste")) { shelf.addClipboard() }.buttonStyle(QuietButton()).help(tr("Put what is on the clipboard on the Shelf"))
                if !shelf.items.isEmpty { Button(tr("Clear")) { confirm = true }.buttonStyle(QuietButton()) }
                expandButton
            }
            if shelf.items.isEmpty {
                Text(tr("Drop files, images or text here to keep them on the Shelf, in sync with your other Macs."))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                    // As tall as a row of tiles: the first item put on, or the last taken off, leaves the panel as it is.
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.muted.opacity(0.42), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .padding(.top, 4)
                    .frame(maxHeight: shelf.expanded ? .infinity : nil, alignment: .top)
            } else {
                // Two whole rows (60 + 6 + 60) and the room above them; more scroll. Expanded, all
                // the room the panel has.
                FittedScroll(maxHeight: 130, fills: shelf.expanded) {
                    // Row by row and lazily: only the rows in view are made, and read their pictures.
                    LazyVStack(alignment: .leading, spacing: ShelfRows.gap) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: ShelfRows.gap) {
                                ForEach(row, id: \.item.id) { place in tile(place.item, cells: place.cells).transition(Motion.pop) }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)
        .frame(maxHeight: shelf.expanded ? .infinity : nil, alignment: .top)
        .background(shelf.targeted ? Palette.accent.opacity(0.18) : Palette.fill)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .overlay(alignment: .bottom) { ShelfToast(shelf: shelf).padding(.horizontal, 14).padding(.bottom, 12) }
        .contentTransition(.identity)
        .animation(Motion.quick, value: shelf.targeted)
        .animation(Motion.quick, value: hovered)
        .alert(tr("Clear everything on the Shelf? The Shelf on your other Macs will be cleared too."), isPresented: $confirm) {
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Clear"), role: .destructive) { shelf.clear() }
        }
    }

    /// The items in their rows, each with its width.
    private var rows: [[(item: ShelfItem, cells: Int)]] {
        let items = shelf.items
        var rows: [[(item: ShelfItem, cells: Int)]] = []
        for (item, place) in zip(items, ShelfGrid.places(items.map { shelf.cells($0) }, columns: ShelfRows.columns)) {
            if place.row == rows.count { rows.append([]) }
            rows[place.row].append((item, place.cells))
        }
        return rows
    }

    /// Up over the whole panel, and back (user 2026-11-27). The window keeps its size.
    private var expandButton: some View {
        let title = shelf.expanded ? tr("Collapse the Shelf") : tr("Expand the Shelf")
        return Button {
            withAnimation(Motion.standard) { shelf.expanded.toggle() }
        } label: {
            Image(systemName: shelf.expanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 13)
        }
        .buttonStyle(QuietButton())
        .help(title)
        .accessibilityLabel(title)
    }

    private func tile(_ item: ShelfItem, cells: Int) -> some View {
        let stage = shelf.stage(item)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ZStack(alignment: .topTrailing) {
            face(item, stage: stage, cells: cells)
                .frame(width: ShelfRows.width(cells), height: ShelfRows.cell)
                .background(Color.primary.opacity(hovered == item.id ? 0.11 : 0.07))
                .clipShape(shape)
                .overlay(shape.stroke(sizing == item.id ? Palette.accent : Palette.line, lineWidth: sizing == item.id ? 1.5 : 1))
                .contentShape(shape)
                .onTapGesture {
                    if case .fetching = stage { shelf.cancelFetch(item) } else { shelf.click(item) }
                }
                .onDrag { ShelfPeek.shared.hide(); return shelf.provider(item) }
            if hovered == item.id {
                // Inside the tile's corner: the Shelf scrolls, and what stood out past the tile was cut
                // off at the Shelf's edge (user 2026-11-25).
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(Palette.ink)
                        .frame(width: 16, height: 16)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().stroke(Palette.line, lineWidth: 0.5))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(tr("Remove from the Shelf")).accessibilityLabel(tr("Remove %@", item.name))
                    .transition(Motion.pop)
            }
        }
        .overlay(alignment: .trailing) {
            // Always there, seen only under the pointer: the pointer leaving it is what puts the cursor back.
            if shelf.mostCells(item) > 1 { edge(item, cells: cells).opacity(hovered == item.id || sizing == item.id ? 1 : 0) }
        }
        .overlay(alignment: .topLeading) { linkControl(item) }
        .background(ShelfPeekSource(item: item, shelf: shelf))
        .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
        .help(hint(item, stage))
        .contextMenu { ShelfItemMenu(shelf: shelf, item: item, sizable: true) }
        .accessibilityLabel(tr("%@, %@", item.kind == .text ? shelf.snippet(item) : item.name, hint(item, stage)))
    }

    /// One cell: the picture, or the icon with the name under it, or a few lines of text. Wider, a
    /// file is its icon, its name on one line, and two lines under it; text has more room.
    @ViewBuilder private func face(_ item: ShelfItem, stage: ShelfModel.Stage, cells: Int) -> some View {
        if cells > 1 && item.kind == .file {
            wideFile(item, stage: stage, cells: cells)
        } else if cells > 1 && item.kind == .text {
            Text(shelf.snippet(item)).font(.system(size: 11)).lineSpacing(1.5).lineLimit(3).multilineTextAlignment(.leading)
                .padding(.horizontal, 9).padding(.vertical, 7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ZStack {
                Group {
                    if item.kind == .text {
                        Text(shelf.snippet(item)).font(.system(size: 9.5)).lineSpacing(1).multilineTextAlignment(.leading)
                            .padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if let image = shelf.thumbnail(item) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else if item.kind == .image {
                        Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(Palette.muted)
                    } else {
                        VStack(spacing: 2) {
                            Image(nsImage: shelf.icon(item)).resizable().frame(width: 30, height: 30)
                            if stage == .here { Text(item.name).font(.system(size: 9)).lineLimit(1).truncationMode(.middle) }
                        }.padding(.horizontal, 4)
                    }
                }.opacity(stage == .here ? 1 : 0.35)
                if stage != .here {
                    badge(stage, size: item.size).transition(Motion.pop)
                }
            }
        }
    }

    private func wideFile(_ item: ShelfItem, stage: ShelfModel.Stage, cells: Int) -> some View {
        let failed: Bool
        if case .failed = stage { failed = true } else { failed = false }
        let detailTint: Color = failed ? Color.orange : Palette.muted
        return HStack(spacing: 6) {
            ZStack {
                Image(nsImage: shelf.icon(item)).resizable().interpolation(.high)
                    .frame(width: ShelfRows.icon, height: ShelfRows.icon)
                    .opacity(stage == .here ? 1 : 0.35)
                if stage != .here { mark(stage).transition(Motion.pop) }
            }
            .frame(width: ShelfRows.icon, height: ShelfRows.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: ShelfRows.nameSize, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(shelf.facts(item)).font(.system(size: 9.5)).foregroundStyle(Palette.muted).lineLimit(1)
                if let detail = shelf.detail(item, stage, wide: cells > 2) {
                    Text(detail).font(.system(size: 9.5)).foregroundStyle(detailTint).lineLimit(1)
                }
            }
            .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.leading, 6).padding(.trailing, 7)
    }

    /// On the icon of a file that is not here: where it stands.
    @ViewBuilder private func mark(_ stage: ShelfModel.Stage) -> some View {
        switch stage {
        case .fetching(let progress):
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().stroke(Color.primary.opacity(0.18), lineWidth: 2)
                Circle().trim(from: 0, to: max(0.02, progress)).stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.reduced ? nil : .linear(duration: 0.2), value: progress)
            }.frame(width: 20, height: 20)
        case .elsewhere: Image(systemName: "arrow.down.circle").font(.system(size: 18, weight: .light))
        case .unreachable: Image(systemName: "wifi.slash").font(.system(size: 14, weight: .light)).foregroundStyle(Palette.muted)
        case .failed: Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 16, weight: .light)).foregroundStyle(.orange)
        case .here: EmptyView()
        }
    }

    /// The right edge of a tile, dragged: one, two or three cells, as far as the item may go.
    private func edge(_ item: ShelfItem, cells: Int) -> some View {
        Capsule().fill(Palette.muted.opacity(sizing == item.id ? 0.8 : 0.5)).frame(width: 3, height: 22)
            .frame(width: 10, height: 44)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    edgeHovered = item.id
                    if cursorOwner == nil { NSCursor.resizeLeftRight.push(); cursorOwner = item.id }
                } else {
                    if edgeHovered == item.id { edgeHovered = nil }
                    if cursorOwner == item.id, sizing != item.id { NSCursor.pop(); cursorOwner = nil }
                }
            }
            .onDisappear {
                if edgeHovered == item.id { edgeHovered = nil }
                if sizing == item.id { sizing = nil }
                if cursorOwner == item.id { NSCursor.pop(); cursorOwner = nil }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if sizing != item.id { sizing = item.id; sizingFrom = cells; ShelfPeek.shared.hide() }
                    let wanted = ((ShelfRows.width(sizingFrom) + value.translation.width + ShelfRows.gap) / (ShelfRows.cell + ShelfRows.gap)).rounded()
                    let next = min(max(Int(wanted), 1), shelf.mostCells(item))
                    if next != shelf.cells(item) { withAnimation(Motion.standard) { shelf.setCells(item, next) } }
                }
                .onEnded { _ in
                    sizing = nil
                    // Still over its edge: the cursor stays until the pointer leaves it.
                    if cursorOwner == item.id, edgeHovered != item.id { NSCursor.pop(); cursorOwner = nil }
                })
            .help(tr("Drag to change the width"))
            .accessibilityHidden(true)
    }

    /// In the tile's top left corner, inside it (user 2026-11-25: the mark stood out past the tile and
    /// the Shelf's edge cut it off): how far the file has got while its link is being made, and a
    /// small mark on an item that has a link.
    @ViewBuilder private func linkControl(_ item: ShelfItem) -> some View {
        if let progress = shelf.linking[item.id] {
            Button { shelf.cancelLink(item) } label: {
                ZStack {
                    Circle().fill(.regularMaterial)
                    Circle().trim(from: 0, to: max(0.06, progress)).stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(3)
                }
                .frame(width: 16, height: 16).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help(tr("Sending to the primary helper. Click to stop.")).accessibilityLabel(tr("Stop sending %@", item.name))
        } else if shelf.hasLink(item) {
            Image(systemName: "link").font(.system(size: 7, weight: .bold)).foregroundStyle(Palette.ink)
                .frame(width: 14, height: 14)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Palette.line, lineWidth: 0.5))
                .padding(4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func badge(_ stage: ShelfModel.Stage, size: Int) -> some View {
        VStack(spacing: 2) {
            switch stage {
            case .fetching(let progress):
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.18), lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.02, progress)).stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(Motion.reduced ? nil : .linear(duration: 0.2), value: progress)
                    Text("\(Int(progress * 100))").font(.system(size: 8.5, weight: .semibold, design: .rounded))
                }.frame(width: 26, height: 26)
            case .elsewhere: Image(systemName: "arrow.down.circle").font(.system(size: 20, weight: .light))
            case .unreachable: Image(systemName: "wifi.slash").font(.system(size: 16, weight: .light)).foregroundStyle(Palette.muted)
            case .failed: Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 18, weight: .light)).foregroundStyle(.orange)
            case .here: EmptyView()
            }
            Text(ShelfModel.size(size)).font(.system(size: 8.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 3)
    }

    private func hint(_ item: ShelfItem, _ stage: ShelfModel.Stage) -> String {
        shelf.hint(item, stage)
    }
}

/// What a right-click on a tile offers, the same on the panel and on the bar kept on top (user
/// 2026-11-22: a right-click downloads it to this Mac, or shows it in the Finder when it is here
/// already; 2026-11-25: a click copies the item, downloading it first where it is not here, and its
/// link is Copy link here, first).
struct ShelfItemMenu: View {
    @ObservedObject var shelf: ShelfModel
    let item: ShelfItem
    /// On the panel, where a tile may be one to three cells wide; the bar kept on top has one size.
    var sizable = false

    var body: some View {
        let stage = shelf.stage(item)
        if shelf.canLink(item) { Button(tr("Copy link")) { shelf.link(item) } }
        if shelf.hasLink(item) { Button(tr("Remove link")) { shelf.unlink(item) } }
        switch stage {
        case .here:
            if item.kind != .text { Button(tr("Show in Finder")) { shelf.reveal(item) } }
            Button(item.kind == .text ? tr("Copy") : tr("Copy the file")) { shelf.copy(item) }
            if shelf.canRelease(item) { Button(tr("Free the copy on this Mac")) { shelf.release(item) } }
        case .fetching: Button(tr("Stop transfer")) { shelf.cancelFetch(item) }
        default: Button(tr("Download to This Mac")) { shelf.download(item) }
        }
        if sizable && shelf.mostCells(item) > 1 {
            Picker(tr("Width"), selection: Binding(get: { shelf.cells(item) },
                                                   set: { next in withAnimation(Motion.standard) { shelf.setCells(item, next) } })) {
                Text(tr("One cell")).tag(1)
                Text(tr("Two cells")).tag(2)
                if shelf.mostCells(item) > 2 { Text(tr("Three cells")).tag(3) }
            }
            .pickerStyle(.menu)
        }
        Divider()
        Button(tr("Remove")) { shelf.remove(item) }
    }
}

/// The tile's picture, larger, floating out beside it while the pointer is over it (user 2026-11-22),
/// on the panel and on the bar kept on top alike. It takes no click and no keys.
@MainActor
final class ShelfPeek {
    static let shared = ShelfPeek()
    private var panel: NSPanel?
    private var host: NSHostingView<ShelfPeekView>?
    private var shown: UUID?
    private var pending: DispatchWorkItem?
    /// While shown: the tile's place and window. The peek goes when the pointer is no longer over
    /// the tile or the window is put away, whatever events did or did not come.
    private var watch: Timer?
    private var tile = NSRect.zero
    private weak var source: NSWindow?

    /// The pointer came over a tile (`rect`, in screen coordinates) or left it.
    func hover(_ item: ShelfItem, shelf: ShelfModel, rect: NSRect, inside: Bool, window: NSWindow? = nil) {
        pending?.cancel()
        guard inside else {
            if shown == item.id { hide() }
            return
        }
        let work = DispatchWorkItem { [weak self, weak shelf, weak window] in
            guard let self, let shelf, window?.isVisible != false, rect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
            self.source = window
            self.show(item, shelf: shelf, rect: rect)
        }
        pending = work
        // A pointer passing over the Shelf on its way elsewhere brings nothing up.
        DispatchQueue.main.asyncAfter(deadline: .now() + (shown == nil ? 0.3 : 0.05), execute: work)
    }

    func hide() {
        pending?.cancel()
        watch?.invalidate(); watch = nil
        shown = nil
        panel?.orderOut(nil)
    }

    private func show(_ item: ShelfItem, shelf: ShelfModel, rect: NSRect) {
        let view = ShelfPeekView(item: item, image: shelf.peek(item), text: item.kind == .text ? String(shelf.fullText(item).prefix(600)) : nil,
                                 icon: item.kind == .file ? shelf.icon(item) : nil, size: ShelfModel.size(item.size))
        let content = view.fitted
        let size = NSSize(width: content.width + 24, height: content.height + 24)
        if panel == nil {
            let made = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            made.isFloatingPanel = true
            // Above the bar kept on top, which floats itself.
            made.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            made.ignoresMouseEvents = true
            made.isOpaque = false
            made.backgroundColor = .clear
            made.hasShadow = false
            made.hidesOnDeactivate = false
            let hosting = NSHostingView(rootView: view)
            made.contentView = hosting
            panel = made; host = hosting
        }
        guard let panel, let host else { return }
        host.rootView = view
        // Above the tile, else below it, inside the pointer's screen.
        let pointer = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.screens.first { $0.frame.intersects(rect) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? rect
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY - 4)
        if origin.y + size.height > screen.maxY { origin.y = rect.minY - size.height + 4 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        shown = item.id
        tile = rect
        watch?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.source?.isVisible == false || !self.tile.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) { self.hide() }
            }
        }
        watch = timer
        panel.alphaValue = Motion.reduced ? 1 : 0
        panel.orderFrontRegardless()
        if !Motion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }
}

/// The floating picture: as large as fits 280 points, its name and size under it.
struct ShelfPeekView: View {
    let item: ShelfItem
    let image: NSImage?
    let text: String?
    let icon: NSImage?
    let size: String

    static let side: CGFloat = 280

    /// The picture's size in points, in its own proportions.
    private var picture: CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return CGSize(width: 96, height: 96) }
        let k = min(Self.side / image.size.width, Self.side / image.size.height, 2)
        return CGSize(width: max(60, image.size.width * k), height: max(40, image.size.height * k))
    }

    /// The whole view's size, without its margin for the shadow.
    var fitted: CGSize {
        if let text {
            // As tall as the text, up to a few lines more than a tile shows.
            let laid = (text as NSString).boundingRect(with: NSSize(width: Self.side - 16, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                       attributes: [.font: NSFont.systemFont(ofSize: 12)])
            let lines = (laid.height / 15).rounded(.up)
            return CGSize(width: Self.side, height: min(220, max(44, laid.height + lines * 2 + 16)))
        }
        let p = picture
        return CGSize(width: max(p.width, 160), height: p.height + 34)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 6) {
            if let text {
                Text(text).font(.system(size: 12)).lineSpacing(2).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: picture.width, height: picture.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let icon {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            } else {
                Image(systemName: item.kind == .image ? "photo" : "doc").font(.system(size: 40)).foregroundStyle(Palette.muted).frame(width: 96, height: 96)
            }
            if text == nil {
                HStack(spacing: 4) {
                    Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text("·").foregroundStyle(Palette.muted)
                    Text(size).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize()
                }
                .foregroundStyle(Palette.ink).frame(maxWidth: picture.width)
            }
        }
        .padding(8)
        .frame(width: fitted.width, height: fitted.height)
        .background(Glass())
        .clipShape(shape)
        .overlay(shape.stroke(Palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .padding(12)
    }
}

/// Under a tile: tells ShelfPeek where the tile is on screen when the pointer comes over it and
/// leaves, whichever app is in front.
struct ShelfPeekSource: NSViewRepresentable {
    let item: ShelfItem
    let shelf: ShelfModel

    final class Area: NSView {
        var item: ShelfItem?
        weak var shelf: ShelfModel?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        private func tell(_ inside: Bool) {
            guard let item, let shelf, let window else { return }
            ShelfPeek.shared.hover(item, shelf: shelf, rect: window.convertToScreen(convert(bounds, to: nil)), inside: inside, window: window)
        }
        override func mouseEntered(with event: NSEvent) { tell(true) }
        override func mouseExited(with event: NSEvent) { tell(false) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { ShelfPeek.shared.hide() }
        }
    }

    func makeNSView(context: Context) -> Area { let area = Area(); area.item = item; area.shelf = shelf; return area }
    func updateNSView(_ area: Area, context: Context) { area.item = item; area.shelf = shelf }
}
