import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QingyanCore

/// The camera band comes from each display, in global AppKit points. It is not the frame
/// of any system activity shown around the camera. Leave that band alone during browsing.
@MainActor
final class NotchShelf: NSPanel, NSDraggingDestination {
    static func housing(on screen: NSScreen) -> NSRect? {
        let top = screen.safeAreaInsets.top
        guard top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              !left.isEmpty, !right.isEmpty, right.minX > left.maxX else { return nil }
        return NSRect(x: left.maxX, y: screen.frame.maxY - top, width: right.minX - left.maxX, height: top)
    }

    let housing: NSRect
    private let shelf: ShelfModel
    private let face: NSHostingView<NotchFace>
    private enum Phase { case idle, browsing, armed, ready, feedback, stopped }
    private var phase = Phase.idle
    private var turn = 0
    private var pointerWatch: Timer?
    private var releasedAt: TimeInterval?
    private static let images = NSImage.imageTypes.filter { UTType($0)?.conforms(to: .image) == true }.map { NSPasteboard.PasteboardType($0) }
    private static let types = [.fileURL, .png, .tiff, .URL, .string] + images

    init(housing: NSRect, shelf: ShelfModel) {
        self.housing = housing; self.shelf = shelf
        face = NSHostingView(rootView: NotchFace(shelf: shelf))
        super.init(contentRect: housing, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false; hasShadow = false; hidesOnDeactivate = false; ignoresMouseEvents = true
        backgroundColor = .clear; animationBehavior = .none
        face.sizingOptions = []; face.safeAreaRegions = []; contentView = face
        registerForDraggedTypes(Self.types)
        // Window drag sessions can consume their source's mouse events. Read only the pointer
        // position and buttons, without installing an event tap or asking for Input Monitoring.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        timer.tolerance = 0.008; pointerWatch = timer; RunLoop.main.add(timer, forMode: .common)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func stop() {
        pointerWatch?.invalidate(); pointerWatch = nil
        unregisterDraggedTypes(); collapse(); phase = .stopped
    }

    private func trackPointer() {
        let point = NSEvent.mouseLocation, buttons = NSEvent.pressedMouseButtons
        if buttons == 0 {
            if phase == .armed || phase == .ready {
                // Give AppKit the drop even if mouse-up precedes performDragOperation.
                let now = ProcessInfo.processInfo.systemUptime
                if let releasedAt, now - releasedAt > 0.18 { collapse() }
                else if releasedAt == nil { releasedAt = now }
            }
            hover(at: point)
        } else if buttons & 1 != 0 {
            releasedAt = nil
            if phase == .browsing && !frame.contains(point) { collapse() }
            let near = housing.insetBy(dx: -100, dy: -100).contains(point)
            if near && (phase == .idle || phase == .feedback) { arm() }
            if !near && phase == .armed { collapse() }
        }
    }

    private func belowCamera(height: CGFloat) -> NSRect {
        let width = max(284, housing.width + 24)
        return NSRect(x: housing.midX - width / 2, y: housing.minY - height, width: width, height: height)
    }

    private func hover(at point: NSPoint) {
        let atCamera = housing.insetBy(dx: 0, dy: -1).contains(point)
        if phase == .idle && atCamera {
            phase = .browsing; face.rootView = NotchFace(shelf: shelf, browsing: true)
            setFrame(belowCamera(height: 100), display: true)
            ignoresMouseEvents = false; orderFrontRegardless()
        } else if phase == .browsing && !atCamera && !frame.contains(point) { collapse() }
    }

    private func arm() {
        turn += 1; phase = .armed
        face.rootView = NotchFace(shelf: shelf)
        // The nearly transparent pixels receive native dragging sessions, even from a source
        // that does not publish anything to the named drag pasteboard until the actual drop.
        backgroundColor = NSColor.black.withAlphaComponent(0.01); ignoresMouseEvents = false
        setFrame(housing.insetBy(dx: 0, dy: -2), display: true); orderFrontRegardless()
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convertPoint(toScreen: sender.draggingLocation)
        let inside = housing.insetBy(dx: 0, dy: -2).contains(point) ||
            (phase == .ready && belowCamera(height: 56).contains(point)) || (phase == .browsing && frame.contains(point))
        guard inside, phase == .armed || phase == .ready || phase == .browsing, sender.draggingSourceOperationMask.contains(.copy),
              (sender.draggingSource as? NSView)?.window !== self,
              sender.draggingPasteboard.availableType(from: Self.types) != nil else {
            if phase == .ready { arm() }; return []
        }
        if phase != .ready {
            phase = .ready
            let below = belowCamera(height: 56)
            setFrame(below.union(housing), display: true)
            show("tray", tr("Release to add to the Shelf"), tr("Move away to cancel"))
        }
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) { if phase == .ready { arm() } }

    func draggingEnded(_ sender: NSDraggingInfo) {
        if phase == .armed || phase == .ready { collapse() }
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingUpdated(sender) == .copy }

    private enum Item {
        case file(URL), image(Data), text(String), unreadable

        @MainActor init(_ item: NSPasteboardItem) {
            if item.types.contains(.fileURL) {
                if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL { self = .file(url) }
                else { self = .unreadable }
            } else if let type = item.availableType(from: [.png, .tiff] + NotchShelf.images), let data = item.data(forType: type) { self = .image(data) }
            else if let text = item.string(forType: .URL) ?? item.string(forType: .string) { self = .text(text) }
            else { self = .unreadable }
        }
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard prepareForDragOperation(sender), let items = sender.draggingPasteboard.pasteboardItems?.map(Item.init), !items.isEmpty else { return false }
        turn += 1; let drop = turn
        phase = .feedback; ignoresMouseEvents = true; backgroundColor = .clear
        let detail: String
        if items.count == 1, case let .file(url) = items[0] { detail = url.lastPathComponent }
        else { detail = tr("%ld items", items.count) }
        show("tray.and.arrow.down", tr("Adding to the Shelf…"), detail)
        Task { [weak self, shelf] in
            var added = 0, failed = 0, reason = ""
            for item in items {
                do {
                    switch item {
                    case let .file(url): if try await shelf.importFile(url) { added += 1 }
                    case let .text(text): if try shelf.importText(text) { added += 1 }
                    case let .image(data): try shelf.importImage(data); added += 1
                    case .unreadable: throw VoiceError(tr("Could not add to the Shelf"))
                    }
                } catch { failed += 1; if reason.isEmpty { reason = error.localizedDescription } }
            }
            guard let self, turn == drop else { return }
            let title: String
            if failed == items.count { title = tr("Could not add to the Shelf") }
            else if failed > 0 { title = tr("%ld of %ld on the Shelf", items.count - failed, items.count) }
            else { title = added == 0 ? tr("Already on the Shelf") : tr("Added to the Shelf") }
            let subtitle = failed > 0 ? reason : added > 0 && items.count > 1 ? tr("Added: %ld", added) : detail
            show(failed > 0 ? "exclamationmark.circle" : "checkmark.circle.fill", title, subtitle)
            AccessibilityNotification.Announcement(title + ". " + subtitle).post()
            try? await Task.sleep(for: .seconds(failed > 0 ? 3.5 : 1.35))
            if turn == drop { collapse(); if NSEvent.pressedMouseButtons == 0 { hover(at: NSEvent.mouseLocation) } }
        }
        return true
    }

    private func show(_ icon: String, _ title: String, _ detail: String) {
        face.rootView = NotchFace(shelf: shelf, icon: icon, title: title, detail: detail)
    }

    private func collapse() {
        turn += 1; phase = .idle; ignoresMouseEvents = true; backgroundColor = .clear
        orderOut(nil)
    }
}

private struct NotchFace: View {
    @ObservedObject var shelf: ShelfModel
    var browsing = false, icon = "tray", title = "", detail = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if browsing {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(tr("Shelf"), systemImage: "tray").font(.system(size: 12, weight: .semibold))
                        Spacer(); Text(tr("%ld items", shelf.items.count)).font(.caption).foregroundStyle(.secondary)
                    }
                    if shelf.items.isEmpty {
                        Text(tr("Drop files, images or text here")).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: ShelfRows.cell)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: ShelfRows.gap) {
                                ForEach(shelf.items) { item in ShelfTile(shelf: shelf, item: item, cells: shelf.cells(item)) }
                            }
                        }.frame(height: ShelfRows.cell)
                    }
                }.padding(.horizontal, 12).frame(height: 100)
                    .background(Color.black, in: shape)
            } else if !title.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 21)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                    }.lineLimit(2)
                }.padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 56)
                    .background(Color.black, in: shape)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).environment(\.colorScheme, .dark)
    }

    private var shape: UnevenRoundedRectangle { UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous) }
}
