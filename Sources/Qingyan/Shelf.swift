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
    @Published var notice = ""
    @Published var targeted = false
    @Published var copiedID: UUID?
    private(set) var store: ShelfStore?
    private(set) var sync: ShelfSync?
    private var thumbnails: [UUID: NSImage] = [:]
    private var snippets: [UUID: String] = [:]
    private var noticeID = UUID()
    private var copiedToken = UUID()
    /// Items the user clicked before their bytes were here: copy them once they arrive.
    private var copyWhenHere: Set<UUID> = []
    let name: String
    /// What a drop on the panel may carry.
    static let types: [UTType] = [.fileURL, .image, .url, .utf8PlainText, .plainText]

    init(preview: Bool) {
        name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
        guard !preview else { return }
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
            reload()
        } catch { notice = tr("Could not open the Shelf folder. Check disk space and access permissions.") }
    }

    private func reload() {
        let next = store?.items ?? []
        if items != next { items = next }
        let present = Set(next.map(\.id))
        thumbnails = thumbnails.filter { present.contains($0.key) }
        snippets = snippets.filter { present.contains($0.key) }
    }

    private func say(_ text: String, for seconds: Double = 2.4) {
        let id = UUID()
        noticeID = id; notice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.noticeID == id else { return }
            self.notice = ""
        }
    }

    private func markCopied(_ id: UUID) {
        let token = UUID()
        copiedToken = token
        copiedID = id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self, self.copiedToken == token else { return }
            self.copiedID = nil
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

    private func addFile(_ url: URL) {
        guard let store else { return }
        guard !url.standardizedFileURL.path.hasPrefix(store.directory.standardizedFileURL.path) else { return }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let image = values?.contentType?.conforms(to: .image) == true
        let large = (values?.fileSize ?? 0) > ShelfStore.eagerBytes
        if large { say(tr("Adding “%@”…", url.lastPathComponent), for: 60) }
        Task { [weak self] in
            guard let self else { return }
            let thumbnail = large ? await Self.quickLook(url) : nil
            do {
                let item = try await store.add(copying: url, kind: image ? .image : .file, origin: self.name, thumbnail: thumbnail)
                if large { self.say(tr("Added “%@”. Other Macs fetch it when it is needed.", item.name), for: 3.5) }
            } catch { self.say(error.localizedDescription, for: 4) }
        }
    }

    private static func quickLook(_ url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128), scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              let tiff = representation.nsImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
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
        else { say(tr("This image format is not supported, so it was not put on the Shelf."), for: 4); return }
        // The name is for people to read (it becomes the file's name when dragged out); nothing matches on it.
        do { try store.add(payload, kind: .image, name: tr("Image %@.%@", stamp, kind), origin: name) }
        catch { say(error.localizedDescription, for: 4) }
    }

    private func addText(_ text: String) {
        guard let store, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !items.contains(where: { $0.kind == .text && store.text($0) == text }) else { return }
        do { try store.add(Data(text.utf8), kind: .text, name: tr("Text.txt"), origin: name) }
        catch { say(error.localizedDescription, for: 4) }
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

    func thumbnail(_ item: ShelfItem) -> NSImage? {
        if let known = thumbnails[item.id] { return known }
        guard let store else { return nil }
        let source = store.thumbnail(item).flatMap(NSImage.init(data:))
            ?? (item.kind == .image && store.isPresent(item.id) ? NSImage(contentsOf: store.url(item)) : nil)
        guard let image = source, image.size.width > 0, image.size.height > 0 else { return nil }
        let side: CGFloat = 128
        let scale = max(side / image.size.width, side / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        thumbnails[item.id] = small
        return small
    }

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
        if let failure = sync.failures[item.id] { say(failure, for: 4) }
    }

    func cancelFetch(_ item: ShelfItem) { copyWhenHere.remove(item.id); sync?.cancel(item.id) }
    func release(_ item: ShelfItem) { store?.release(item.id) }
    func canRelease(_ item: ShelfItem) -> Bool { store.map { item.isLarge && $0.isPresent(item.id) && !$0.isOwn(item.id) } ?? false }

    private func transferMoved() {
        objectWillChange.send()
        guard let store, let sync else { return }
        for id in copyWhenHere {
            guard let item = store.item(id) else { copyWhenHere.remove(id); continue }
            if store.isPresent(id) { copyWhenHere.remove(id); copy(item) }
            else if sync.progress(id) == nil {
                copyWhenHere.remove(id)
                if let failure = sync.failures[id] { say(tr("Could not fetch “%@”: %@", item.name, failure), for: 5) }
            }
        }
    }

    func icon(_ item: ShelfItem) -> NSImage {
        guard let store else { return NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data) }
        return NSWorkspace.shared.icon(forFile: store.url(item).path)
    }

    /// Puts the item on the system clipboard, in the forms other apps expect.
    func copy(_ item: ShelfItem) {
        guard let store else {
            if item.kind == .text {
                PasteboardLease.general.keep(snippet(item))
                markCopied(item.id)
            }
            return
        }
        guard store.isPresent(item.id) else {
            copyWhenHere.insert(item.id)
            fetch(item)
            if case .fetching = stage(item) { say(tr("Fetching “%@” (%@). It is copied when it arrives.", item.name, Self.size(item.size)), for: 4) }
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
            if !item.isLarge, let tiff = NSImage(contentsOf: store.url(item))?.tiffRepresentation { entry.setData(tiff, forType: .tiff) }
            board.writeObjects([entry])
        case .file:
            board.writeObjects([store.url(item) as NSURL])
        }
        markCopied(item.id)
        say(tr("Copied “%@”, ready to paste.", item.kind == .text ? String(snippet(item).prefix(12)) : item.name))
    }

    func provider(_ item: ShelfItem) -> NSItemProvider {
        guard let store else { return NSItemProvider() }
        guard store.isPresent(item.id) else {
            fetch(item)
            if case .fetching = stage(item) { say(tr("Fetching “%@” from the other Mac. It can be dragged out when it arrives.", item.name), for: 4) }
            return NSItemProvider()
        }
        store.touch(item.id)
        if item.kind == .text { return NSItemProvider(object: (store.text(item) ?? "") as NSString) }
        return NSItemProvider(contentsOf: store.url(item)) ?? NSItemProvider()
    }

    func reveal(_ item: ShelfItem) {
        guard let store, store.isPresent(item.id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.url(item)])
    }

    func remove(_ item: ShelfItem) { store?.remove(item.id) }
    func clear() { store?.clear() }

    func probe() {
        guard let store else { return }
        let trigger = store.directory.deletingLastPathComponent().appendingPathComponent("shelf-probe.trigger")
        guard access(trigger.path, F_OK) == 0,
              let request = (try? String(contentsOf: trigger, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        try? FileManager.default.removeItem(at: trigger)
        if request == "fetch" {
            for item in store.items where item.isLarge && !store.isPresent(item.id) { sync?.fetch(item.id) }
        } else if request.hasPrefix("big "), let megabytes = Int(request.dropFirst(4)), (1...2048).contains(megabytes) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("put sync self-test \(megabytes)MB.bin")
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
            guard let item = try? store.add(Data("put sync self-test \(request)".utf8), kind: .text, name: tr("Text.txt"), origin: name) else { return }
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
    #endif
}

/// The shelf, pinned to the bottom of the panel. Drop anything on the panel to park it here;
/// click a tile to copy it, drag a tile out to use it. The same shelf shows on every paired Mac.
struct ShelfBar: View {
    @ObservedObject var shelf: ShelfModel
    @State private var hovered: UUID?
    @State private var confirm = false
    private let columns = Array(repeating: GridItem(.fixed(60), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "tray").font(.system(size: 11)).frame(width: 15)
                Text(tr("Shelf")).font(.system(size: 12, weight: .semibold))
                Text(shelf.linked == 1 ? tr("Connected to 1 Mac") : shelf.linked > 1 ? tr("Connected to %ld Macs", shelf.linked) : tr("This Mac only"))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                Spacer(minLength: 4)
                Button(tr("Paste")) { shelf.addClipboard() }.buttonStyle(QuietButton()).help(tr("Put what is on the clipboard on the Shelf"))
                if !shelf.items.isEmpty { Button(tr("Clear")) { confirm = true }.buttonStyle(QuietButton()) }
            }
            if !shelf.notice.isEmpty {
                CopyableText(shelf.notice, font: .system(size: 10.5), color: Palette.muted)
            }
            if shelf.items.isEmpty {
                Text(tr("Drop files, images or text here to keep them on the Shelf, in sync with your other Macs."))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.muted.opacity(0.42), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                FittedScroll(maxHeight: 128) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(shelf.items) { tile($0).transition(Motion.pop) }
                    }.padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)
        .background(shelf.targeted ? Palette.accent.opacity(0.18) : Palette.fill)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .contentTransition(.identity)
        .animation(Motion.quick, value: shelf.targeted)
        .animation(Motion.quick, value: hovered)
        .alert(tr("Clear everything on the Shelf? The Shelf on your other Macs will be cleared too."), isPresented: $confirm) {
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Clear"), role: .destructive) { shelf.clear() }
        }
    }

    private func tile(_ item: ShelfItem) -> some View {
        let stage = shelf.stage(item)
        let copied = shelf.copiedID == item.id
        return ZStack(alignment: .topTrailing) {
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
                }.opacity(stage == .here && !copied ? 1 : 0.35)
                if copied {
                    VStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.accent)
                        Text(tr("Copied")).font(.system(size: 9, weight: .semibold))
                    }.transition(Motion.pop)
                } else if stage != .here {
                    badge(stage, size: item.size).transition(Motion.pop)
                }
            }
            .frame(width: 60, height: 60)
            .background(Color.primary.opacity(hovered == item.id ? 0.11 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(copied ? Palette.accent.opacity(0.6) : Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                if case .fetching = stage { shelf.cancelFetch(item) } else { shelf.copy(item) }
            }
            .onDrag { shelf.provider(item) }
            if hovered == item.id {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Palette.ink)
                        .frame(width: 17, height: 17)
                        .background(Color.primary.opacity(0.24), in: Circle())
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).offset(x: 5, y: -5).help(tr("Remove from the Shelf")).accessibilityLabel(tr("Remove %@", item.name))
                    .transition(Motion.pop)
            }
        }
        .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
        .help(hint(item, stage))
        .contextMenu {
            switch stage {
            case .here:
                Button(tr("Copy")) { shelf.copy(item) }
                if item.kind != .text { Button(tr("Show in Finder")) { shelf.reveal(item) } }
                if shelf.canRelease(item) { Button(tr("Free the copy on this Mac")) { shelf.release(item) } }
            case .fetching: Button(tr("Stop transfer")) { shelf.cancelFetch(item) }
            default: Button(tr("Fetch to this Mac")) { shelf.fetch(item) }
            }
            Button(tr("Remove")) { shelf.remove(item) }
        }
        .accessibilityLabel(tr("%@, %@", item.kind == .text ? shelf.snippet(item) : item.name, hint(item, stage)))
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
        let title = item.kind == .text ? shelf.snippet(item) : "\(item.name) · \(ShelfModel.size(item.size))"
        switch stage {
        case .here: return tr("%@\nFrom %@ · Click to copy, or drag it out", title, item.origin)
        case .elsewhere: return tr("%@\nFrom %@ · Click to fetch it to this Mac", title, item.origin)
        case .unreachable: return tr("%@\nFrom %@ · No Mac that holds this file is online", title, item.origin)
        case .fetching(let progress): return tr("%@\nFetching %ld%% · Click to pause; what has arrived is kept", title, Int(progress * 100))
        case .failed(let reason): return tr("%@\n%@ · Click to try again", title, reason)
        }
    }
}
