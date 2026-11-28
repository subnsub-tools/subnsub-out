import AppKit
import QuartzCore
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
    private let browseFace: NSHostingView<NotchFace>, messageFace: NSHostingView<NotchFace>
    private let plate = NSView(), aperture = CALayer()
    private let cameraTarget = CALayer(), bodyTarget = CALayer()
    private var landing = NSRect.null
    private var shown: NSSize, goal = NSSize.zero, velocity = NSSize.zero
    private var browseMix: CGFloat = 1, wantedMix: CGFloat = 1
    private var frames: CADisplayLink?, lastFrame: CFTimeInterval = 0
    private enum Phase { case idle, browsing, armed, ready, feedback, stopped }
    private var phase = Phase.idle
    private var turn = 0
    private var pointerWatch: Timer?
    private var releasedAt: TimeInterval?
    private var hoverSince: TimeInterval?, hoverMoved = false
    private var lastPointer = NSEvent.mouseLocation
    private static let images = NSImage.imageTypes.filter { UTType($0)?.conforms(to: .image) == true }.map { NSPasteboard.PasteboardType($0) }
    private static let types = [.fileURL, .png, .tiff, .URL, .string] + images

    init(housing: NSRect, shelf: ShelfModel) {
        self.housing = housing; self.shelf = shelf
        shown = NSSize(width: housing.width, height: 0)
        browseFace = NSHostingView(rootView: NotchFace(shelf: shelf, browsing: true))
        messageFace = NSHostingView(rootView: NotchFace(shelf: shelf))
        super.init(contentRect: housing, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false; hasShadow = false; hidesOnDeactivate = false; ignoresMouseEvents = true
        backgroundColor = .clear; animationBehavior = .none
        let root = NSView(); root.wantsLayer = true; contentView = root
        // Only these nearly transparent pixels catch native drags before the face is revealed.
        for target in [cameraTarget, bodyTarget] {
            target.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
            root.layer?.addSublayer(target)
        }
        plate.wantsLayer = true; plate.layer?.backgroundColor = NSColor.black.cgColor
        aperture.backgroundColor = NSColor.black.cgColor; aperture.cornerCurve = .continuous
        aperture.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        plate.layer?.mask = aperture; root.addSubview(plate)
        for face in [messageFace, browseFace] {
            face.sizingOptions = []; face.safeAreaRegions = []; face.isHidden = true; plate.addSubview(face)
        }
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
        frames?.invalidate(); frames = nil
        turn += 1; phase = .stopped; unregisterDraggedTypes(); orderOut(nil)
    }

    private func trackPointer() {
        let point = NSEvent.mouseLocation, buttons = NSEvent.pressedMouseButtons
        let moved = point != lastPointer; lastPointer = point
        let now = ProcessInfo.processInfo.systemUptime
        if buttons == 0 {
            if phase == .armed || phase == .ready {
                // Give AppKit the drop even if mouse-up precedes performDragOperation.
                if let releasedAt, now - releasedAt > 0.18 { collapse() }
                else if releasedAt == nil { releasedAt = now }
            }
            let inside = housing.insetBy(dx: 0, dy: -1).contains(point) ||
                (wantedMix == 1 && visibleBody.contains(point))
            if phase == .idle && inside {
                hoverMoved = hoverMoved || moved
                if let hoverSince, now - hoverSince >= 0.095 {
                    let cue = hoverMoved
                    phase = .browsing; presentFace()
                    if cue { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted) }
                } else if hoverSince == nil { hoverSince = now }
            } else if phase == .browsing && !inside {
                if let hoverSince, now - hoverSince >= 0.165 { collapse() }
                else if hoverSince == nil { hoverSince = now }
            } else { hoverSince = nil; hoverMoved = false }
        } else {
            hoverSince = nil; hoverMoved = false
            guard buttons & 1 != 0 else { return }
            releasedAt = nil
            if phase == .browsing && !visibleBody.contains(point) { collapse() }
            let near = housing.insetBy(dx: -100, dy: -100).contains(point)
            if near && (phase == .idle || phase == .feedback) { arm() }
            if !near && phase == .armed { collapse() }
        }
    }

    private func belowCamera(width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: housing.midX - width / 2, y: housing.minY - height, width: width, height: height)
    }

    private var visibleBody: NSRect { belowCamera(width: shown.width, height: shown.height) }

    // The window and the SwiftUI tiles stay still. Animate just the mask below the camera.
    private func presentFace(keeping accepted: NSRect = .null) {
        hoverSince = nil; hoverMoved = false
        guard let display = NSScreen.screens.first(where: { $0.frame.contains(housing) }) else { return }
        let halfWidth = min(housing.midX - display.frame.minX, display.frame.maxX - housing.midX) - 8
        let browse = belowCamera(width: min(460, 2 * halfWidth), height: 100)
        let message = belowCamera(width: min(max(284, housing.width + 24), 2 * halfWidth), height: 56)
        let canvas = browse.union(message)
        let dragging = phase == .armed || phase == .ready
        let band = housing.insetBy(dx: 0, dy: -2)
        let windowRect = dragging ? canvas.union(band) : canvas
        let body = phase == .browsing ? browse : message
        goal = (phase == .idle || phase == .armed) ? NSSize(width: housing.width, height: 0) : body.size
        if goal.height > 0 { wantedMix = phase == .browsing ? 1 : 0 }
        if shown.height == 0 { browseMix = wantedMix }
        // A drag accepted on a wide tile remains droppable there as the message narrows.
        landing = phase == .ready ? message.union(accepted) : .null
        ignoresMouseEvents = phase == .idle || phase == .feedback
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if frame != windowRect { setFrame(windowRect, display: false) }
        func local(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: -windowRect.minX, dy: -windowRect.minY) }
        cameraTarget.frame = dragging ? local(band) : .zero
        bodyTarget.frame = landing.isNull ? .zero : local(landing)
        plate.frame = local(canvas)
        browseFace.frame = browse.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
        messageFace.frame = message.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
        drawReveal()
        CATransaction.commit()
        if phase != .idle && !isVisible { orderFrontRegardless() }
        if Motion.reduced || (shown == goal && velocity == .zero && browseMix == wantedMix) { settle(); return }
        if frames == nil {
            lastFrame = CACurrentMediaTime()
            let link = display.displayLink(target: self, selector: #selector(advanceReveal(_:)))
            frames = link; link.add(to: .main, forMode: .common)
        }
    }

    @objc private func advanceReveal(_ link: CADisplayLink) {
        if Motion.reduced { settle(); return }
        let dt = CGFloat(min(0.05, max(0, link.targetTimestamp - lastFrame))); lastFrame = link.targetTimestamp
        // Exact critically damped step; a reversal keeps both position and velocity.
        func step(_ x: CGFloat, _ v: CGFloat, _ to: CGFloat, _ rate: CGFloat) -> (CGFloat, CGFloat) {
            let d = x - to, c = v + rate * d, decay = exp(-rate * dt)
            return (to + (d + c * dt) * decay, (v - rate * c * dt) * decay)
        }
        let closing = goal.height == 0
        (shown.width, velocity.width) = step(shown.width, velocity.width, goal.width, closing ? 25 : 29)
        (shown.height, velocity.height) = step(shown.height, velocity.height, goal.height, closing ? 31 : 19)
        browseMix += (wantedMix - browseMix) * (1 - exp(-24 * dt))
        if abs(shown.width - goal.width) < 0.14 && abs(shown.height - goal.height) < 0.14 &&
            abs(velocity.width) < 3 && abs(velocity.height) < 3 && abs(browseMix - wantedMix) < 0.003 { settle(); return }
        drawReveal()
    }

    private func drawReveal() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        aperture.frame = NSRect(x: (plate.bounds.width - shown.width) / 2, y: plate.bounds.height - shown.height,
                                width: shown.width, height: shown.height)
        aperture.cornerRadius = min(16, shown.height / 2)
        let reveal = min(1, max(0, (shown.height - 4) / 38))
        browseFace.alphaValue = reveal * browseMix; browseFace.isHidden = browseFace.alphaValue == 0
        messageFace.alphaValue = reveal * (1 - browseMix); messageFace.isHidden = messageFace.alphaValue == 0
        CATransaction.commit()
    }

    private func settle() {
        frames?.invalidate(); frames = nil; shown = goal; velocity = .zero; browseMix = wantedMix; drawReveal()
        if phase == .idle { orderOut(nil) }
    }

    private func arm() {
        turn += 1; phase = .armed; presentFace()
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convertPoint(toScreen: sender.draggingLocation)
        let inside = housing.insetBy(dx: 0, dy: -2).contains(point) ||
            (phase == .ready && landing.contains(point)) || (phase == .browsing && visibleBody.contains(point))
        guard inside, phase == .armed || phase == .ready || phase == .browsing, sender.draggingSourceOperationMask.contains(.copy),
              (sender.draggingSource as? NSView)?.window !== self,
              sender.draggingPasteboard.availableType(from: Self.types) != nil else {
            if phase == .ready { arm() }; return []
        }
        if phase != .ready {
            let accepted = phase == .browsing ? visibleBody : .null
            phase = .ready
            show("tray", tr("Release to add to the Shelf"), tr("Move away to cancel"))
            presentFace(keeping: accepted)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
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
        phase = .feedback; presentFace()
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
            if turn == drop { collapse() }
        }
        return true
    }

    private func show(_ icon: String, _ title: String, _ detail: String) {
        messageFace.rootView = NotchFace(shelf: shelf, icon: icon, title: title, detail: detail)
    }

    private func collapse() {
        turn += 1; phase = .idle; lastPointer = NSEvent.mouseLocation; presentFace()
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
            } else if !title.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 21)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                    }.lineLimit(2)
                }.padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 56)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).environment(\.colorScheme, .dark)
    }
}
