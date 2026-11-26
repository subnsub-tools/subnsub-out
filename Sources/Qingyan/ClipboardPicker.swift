import AppKit
import Combine
import SwiftUI
import QingyanCore

/// The clipboard history over whatever app is in front, without taking it out of front: opened
/// with Control + Option + C, from the menu or from the panel. Typing searches, the arrows choose,
/// Return pastes into that app; ⇧Return pastes plain text, ⌥Return types it key by key, ⌘Return
/// copies it alone, ⌘1 to ⌘9 paste one of the first nine, ⌘P pins, ⌘Delete removes, Esc closes.
@MainActor
final class ClipboardPicker: NSObject, NSWindowDelegate {
    enum Use { case paste, plain, type, copy }

    let model: ClipboardPickerModel
    private let history: ClipboardHistory
    private var panel: PickerPanel?
    /// Types the clipboard's text key by key into the app in front (Type the Clipboard).
    var onType: (() -> Void)?
    /// Puts an entry on the Shelf.
    var onShelf: ((ClipEntry) -> Void)?
    /// Turns the clipboard history on.
    var onTurnOn: (() -> Void)?
    var isOn: () -> Bool = { true }

    init(history: ClipboardHistory) {
        self.history = history
        model = ClipboardPickerModel(history: history)
        super.init()
        model.choose = { [weak self] entry, use in self?.choose(entry, use) }
        model.shelve = { [weak self] entry in self?.hide(); self?.onShelf?(entry) }
        model.turnOn = { [weak self] in self?.onTurnOn?(); self?.model.on = true }
    }

    var visible: Bool { panel?.isVisible == true }

    func toggle() { if visible { hide() } else { show() } }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.on = isOn()
        model.reset()
        place(panel)
        // The panel takes the keys without making out the active app: the app in front stays in front.
        panel.makeKeyAndOrderFront(nil)
        model.focus &+= 1
    }

    func hide() {
        model.confirmingClear = false
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func makePanel() -> PickerPanel {
        let panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 430),
                                styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        let host = NSHostingView(rootView: ClipboardPickerView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        return panel
    }

    /// In the upper part of the screen the pointer is on, as Spotlight opens.
    private func place(_ panel: PickerPanel) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame, size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + (area.height - size.height) * 0.68))
    }

    private func handle(_ event: NSEvent) -> Bool {
        // While an input method is composing in the search field, its keys are the input method's.
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        // Only these exact chords are the picker's; others (VoiceOver's Control + Option, say) go on.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
        if model.confirmingClear {
            // Asking whether to clear: Esc says no, and the other keys are the question's.
            guard event.keyCode == 53, flags.isEmpty else { return false }
            model.confirmingClear = false
            return true
        }
        switch event.keyCode {
        case 53 where flags.isEmpty: hide(); return true
        case 125 where flags.isEmpty: model.move(1); return true
        case 126 where flags.isEmpty: model.move(-1); return true
        case 36, 76:
            let use: Use? = flags.isEmpty ? .paste : flags == .command ? .copy : flags == .shift ? .plain : flags == .option ? .type : nil
            guard let use else { return false }
            choose(model.selected, use)
            return true
        case 51 where flags == .command:
            if let entry = model.selected { history.remove(entry.id) }
            return true
        case 35 where flags == .command:
            if let entry = model.selected { history.pin(entry.id, !entry.pinned) }
            return true
        default:
            if flags == .command, let index = digits[event.keyCode] {
                if index < model.shown.count { choose(model.shown[index], .paste) }
                return true
            }
            return false
        }
    }

    private func choose(_ entry: ClipEntry?, _ use: Use) {
        guard let entry else { NSSound.beep(); return }
        if use == .type && entry.kind == .image { NSSound.beep(); return }
        hide()
        switch use {
        case .copy:
            history.put(entry)
        case .paste, .plain:
            guard history.put(entry, plain: use == .plain) else { NSSound.beep(); return }
            Self.pasteIntoFront()
        case .type:
            guard history.put(entry, plain: true) else { NSSound.beep(); return }
            onType?()
        }
    }

    /// ⌘V to the app in front, once the panel has let go of the keys, while that app is still in
    /// front and the clipboard still holds the entry. Without Accessibility, or with out itself in
    /// front, the entry is left on the clipboard.
    /// With a target and a count: the app the paste is for and the clipboard as it was put there;
    /// no paste when another app is in front or the clipboard has changed since.
    static func pasteIntoFront(expecting target: pid_t? = nil, count expected: Int? = nil) {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return }
        let pid = front.processIdentifier, count = NSPasteboard.general.changeCount
        if let target, pid != target { return }
        if let expected, count != expected { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, NSPasteboard.general.changeCount == count,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }
}

/// Takes the keys while the app in front stays in front; the keys that choose are read before the
/// search field gets them.
final class PickerPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class ClipboardPickerModel: ObservableObject {
    @Published var query = "" { didSet { refilter() } }
    @Published private(set) var shown: [ClipEntry] = []
    @Published var selection: UUID?
    /// Bumped each time the panel opens, to put the cursor in the search field.
    @Published var focus = 0
    @Published var confirmingClear = false
    @Published var on = true
    let history: ClipboardHistory
    var choose: (ClipEntry?, ClipboardPicker.Use) -> Void = { _, _ in }
    var shelve: (ClipEntry) -> Void = { _ in }
    var turnOn: () -> Void = {}
    private var watch: AnyCancellable?
    private var icons: [String: NSImage] = [:]
    private var thumbnails: [UUID: NSImage] = [:]
    /// The selected entry as read from disk, read once rather than on every redraw.
    private var openedID: UUID?
    private var openedText: String?
    private var openedImage: NSImage?
    private var openedFiles: [URL] = []

    /// Long text is shown up to this many characters.
    static let previewCharacters = 20_000

    private func open(_ entry: ClipEntry) {
        guard openedID != entry.id else { return }
        openedID = entry.id
        openedText = entry.kind == .text ? history.text(entry).map { text in
            text.count > Self.previewCharacters ? String(text.prefix(Self.previewCharacters)) + "…" : text
        } : nil
        openedImage = entry.kind == .image ? history.image(entry) : nil
        openedFiles = entry.kind == .files ? history.files(entry) : []
    }

    func text(_ entry: ClipEntry) -> String { open(entry); return openedText ?? entry.preview }
    func image(_ entry: ClipEntry) -> NSImage? { open(entry); return openedImage }
    func files(_ entry: ClipEntry) -> [URL] { open(entry); return openedFiles }

    init(history: ClipboardHistory) {
        self.history = history
        // Published before it changes: the list is read again once it has.
        watch = history.$entries.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refilter() }
        }
        refilter()
    }

    var selected: ClipEntry? { shown.first { $0.id == selection } }

    func reset() {
        confirmingClear = false
        if query.isEmpty { refilter() } else { query = "" }
        selection = shown.first?.id
    }

    func refilter() {
        shown = history.shown(matching: query)
        if selection == nil || !shown.contains(where: { $0.id == selection }) { selection = shown.first?.id }
        let ids = Set(history.entries.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        if let id = openedID, !ids.contains(id) { openedID = nil }
    }

    func move(_ step: Int) {
        guard !shown.isEmpty else { return }
        let index = shown.firstIndex { $0.id == selection } ?? -1
        selection = shown[min(max(index + step, 0), shown.count - 1)].id
    }

    func icon(_ entry: ClipEntry) -> NSImage? {
        guard !entry.bundle.isEmpty else { return nil }
        if let known = icons[entry.bundle] { return known }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundle) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[entry.bundle] = icon
        return icon
    }

    func thumbnail(_ entry: ClipEntry) -> NSImage? {
        if let known = thumbnails[entry.id] { return known }
        guard let image = history.thumbnail(entry) else { return nil }
        thumbnails[entry.id] = image
        return image
    }
}

/// The words for an entry, in rows and in the preview.
@MainActor
enum ClipWords {
    static func title(_ entry: ClipEntry) -> String {
        switch entry.kind {
        case .text:
            let line = entry.preview.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return String(line ?? "").trimmingCharacters(in: .whitespaces)
        case .image:
            return entry.width > 0 ? tr("Image · %ld × %ld", entry.width, entry.height) : tr("Image")
        case .files:
            let first = entry.preview.split(separator: "\n").first.map(String.init) ?? ""
            return entry.count > 1 ? tr("%@ and %ld more", first, entry.count - 1) : first
        }
    }

    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func detail(_ entry: ClipEntry) -> String {
        let size: String
        switch entry.kind {
        case .text: size = entry.count == 1 ? tr("1 character") : tr("%ld characters", entry.count)
        case .image: size = entry.width > 0 ? tr("%ld × %ld pixels", entry.width, entry.height) : ""
        case .files: size = entry.count == 1 ? tr("1 file") : tr("%ld files", entry.count)
        }
        let copied = entry.app.isEmpty ? tr("Copied · %@", when(entry.date)) : tr("Copied in %@ · %@", entry.app, when(entry.date))
        return size.isEmpty ? copied : copied + " · " + size
    }
}

struct ClipboardPickerView: View {
    @ObservedObject var model: ClipboardPickerModel
    @ObservedObject var history: ClipboardHistory
    @FocusState private var searching: Bool

    init(model: ClipboardPickerModel) {
        self.model = model
        history = model.history
    }

    var body: some View {
        VStack(spacing: 0) {
            search
            Divider().opacity(0.6)
            if history.paused { paused }
            HStack(spacing: 0) {
                list.frame(width: 300)
                Divider().opacity(0.6)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 660, height: 430)
        .background(Glass())
        .foregroundStyle(Palette.ink).tint(Palette.accent)
        .onChange(of: model.focus, initial: true) { _, _ in searching = true }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.muted)
            TextField(tr("Search the clipboard history"), text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused($searching)
            Text(history.entries.count == 1 ? tr("1 item") : tr("%ld items", history.entries.count))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 11)
    }

    private var paused: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle").foregroundStyle(Color.orange)
            Text(tr("Paused: what is copied now is not kept.")).font(.system(size: 11.5))
            Spacer()
            Button(tr("Resume")) { history.paused = false }.buttonStyle(QuietButton())
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private var list: some View {
        Group {
            if model.shown.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Text(!model.on ? tr("The clipboard history is off.")
                         : model.query.isEmpty ? tr("Nothing copied yet.") : tr("Nothing matches."))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    if !model.on { Button(tr("Turn On")) { model.turnOn() }.buttonStyle(QuietButton()) }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.shown.enumerated()), id: \.element.id) { index, entry in
                                row(entry, index: index).id(entry.id)
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: model.selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    private func row(_ entry: ClipEntry, index: Int) -> some View {
        let chosen = entry.id == model.selection
        return HStack(spacing: 8) {
            leading(entry).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(ClipWords.title(entry)).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                Text(entry.app.isEmpty ? ClipWords.when(entry.date) : entry.app + " · " + ClipWords.when(entry.date))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 2)
            if entry.pinned { Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(Palette.muted) }
            if index < 9 { Text(verbatim: "⌘\(index + 1)").font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.muted) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(chosen ? Palette.strong : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.choose(entry, .paste) }
        .onTapGesture { model.selection = entry.id }
        .contextMenu { menu(entry) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityAction { model.choose(entry, .paste) }
    }

    @ViewBuilder private func leading(_ entry: ClipEntry) -> some View {
        if entry.kind == .image, let picture = model.thumbnail(entry) {
            Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if let icon = model.icon(entry) {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: entry.kind == .files ? "doc" : entry.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 13)).foregroundStyle(Palette.muted)
        }
    }

    @ViewBuilder private func menu(_ entry: ClipEntry) -> some View {
        Button(tr("Paste")) { model.choose(entry, .paste) }
        if entry.kind != .image {
            Button(tr("Paste as Plain Text")) { model.choose(entry, .plain) }
            Button(tr("Type It Key by Key")) { model.choose(entry, .type) }
        }
        Button(tr("Copy")) { model.choose(entry, .copy) }
        Button(tr("Put on the Shelf")) { model.shelve(entry) }
        Divider()
        Button(entry.pinned ? tr("Unpin") : tr("Pin")) { history.pin(entry.id, !entry.pinned) }
        Button(tr("Remove")) { history.remove(entry.id) }
    }

    @ViewBuilder private var preview: some View {
        if let entry = model.selected {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    switch entry.kind {
                    case .text:
                        ScrollView {
                            Text(model.text(entry))
                                .font(.system(size: 12)).lineSpacing(2.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    case .image:
                        if let picture = model.image(entry) {
                            Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else { Spacer() }
                    case .files:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.files(entry), id: \.self) { url in
                                    HStack(spacing: 6) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                                        Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    }
                                    .help(url.path)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                Text(ClipWords.detail(entry)).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(2)
            }
            .padding(12)
            .id(entry.id)
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.confirmingClear {
                Text(tr("Remove every item but the pinned ones?")).font(.system(size: 11.5))
                Spacer()
                Button(tr("Cancel")) { model.confirmingClear = false }.buttonStyle(QuietButton())
                Button(tr("Remove")) { history.clear(); model.confirmingClear = false }.buttonStyle(SolidButton())
            } else {
                key("↩", tr("Paste"))
                key("⇧↩", tr("Plain text"))
                key("⌥↩", tr("Type"))
                key("⌘↩", tr("Copy"))
                key("⌘P", tr("Pin"))
                key("⌘⌫", tr("Remove"))
                Spacer(minLength: 4)
                Button(tr("Clear")) { model.confirmingClear = true }
                    .buttonStyle(QuietButton()).disabled(history.entries.allSatisfy(\.pinned))
            }
        }
        .padding(.horizontal, 14).frame(height: 38)
    }

    private func key(_ keys: String, _ name: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 10.5, weight: .semibold, design: .rounded))
            Text(name).font(.system(size: 10.5))
        }
        .foregroundStyle(Palette.muted)
        .lineLimit(1)
    }
}
