import AppKit
import QingyanCore
import SwiftUI
import UniformTypeIdentifiers

/// One row of History: something copied on this Mac, or something said to out.
enum HistoryItem: Identifiable {
    case copied(ClipEntry)
    case voice(HistoryEntry)

    var id: UUID {
        switch self {
        case .copied(let entry): return entry.id
        case .voice(let entry): return entry.id
        }
    }

    var date: Date {
        switch self {
        case .copied(let entry): return entry.date
        case .voice(let entry): return entry.date
        }
    }

    var pinned: Bool {
        if case .copied(let entry) = self { return entry.pinned }
        return false
    }
}

/// What the History page shows and keeps while the panel is open: the search, the kind chosen,
/// the row chosen, and the icons and thumbnails already read.
@MainActor
final class HistoryPageModel: ObservableObject {
    enum Kind: Hashable { case all, voice, text, images, files }
    enum Clearing: Hashable { case copied, voice }
    @Published var query = ""
    @Published var kind = Kind.all
    @Published var selection: UUID?
    /// A row chosen with the keys, to be scrolled into view.
    @Published var reveal: UUID?
    /// Whether the search field has the keyboard: the keys that choose and paste are read then.
    var searchFocused = false
    @Published var clearing: Clearing?
    let clipboard: ClipboardHistory
    private var icons: [String: NSImage] = [:]
    private var thumbnails: [UUID: NSImage] = [:]
    private var fileIcons: [String: NSImage] = [:]

    init(clipboard: ClipboardHistory) { self.clipboard = clipboard }

    /// The pinned copies first, then everything else newest first, as the search and the kind
    /// leave them.
    func shown(voice records: [HistoryEntry]) -> [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let copied: [ClipEntry] = kind == .voice ? [] : clipboard.shown(matching: query).filter { entry in
            switch kind {
            case .text: return entry.kind == .text
            case .images: return entry.kind == .image
            case .files: return entry.kind == .files
            case .all, .voice: return true
            }
        }
        let voice: [HistoryEntry] = kind != .all && kind != .voice ? [] : trimmed.isEmpty ? records : records.filter {
            $0.text.localizedCaseInsensitiveContains(trimmed) || $0.mode.title.localizedCaseInsensitiveContains(trimmed)
        }
        let pinned = copied.filter(\.pinned).map(HistoryItem.copied)
        let rest = (copied.filter { !$0.pinned }.map(HistoryItem.copied) + voice.map(HistoryItem.voice))
            .sorted { $0.date > $1.date }
        return pinned + rest
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
        guard let image = clipboard.thumbnail(entry) else { return nil }
        // Pictures of items no longer kept go.
        if thumbnails.count >= 40 {
            let kept = Set(clipboard.entries.map(\.id))
            thumbnails = thumbnails.filter { kept.contains($0.key) }
        }
        thumbnails[entry.id] = image
        return image
    }

    func fileIcon(_ name: String) -> NSImage {
        let type = (name as NSString).pathExtension.lowercased()
        if let known = fileIcons[type] { return known }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: type) ?? .data)
        fileIcons[type] = icon
        return icon
    }
}

/// History, the side drawer's page: what was said to out and what was copied on this Mac, in one
/// list, the pinned copies on top and the rest by day, searched by text, file name or app, and put
/// back from here.
struct HistoryPage: View {
    @ObservedObject var model: HistoryPageModel
    @ObservedObject var clipboard: ClipboardHistory
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    var shelve: (ClipEntry) -> Void
    @FocusState private var searchFocus: Bool

    init(model: HistoryPageModel, settings: SettingsStore, controller: DictationController, shelve: @escaping (ClipEntry) -> Void) {
        self.model = model
        clipboard = model.clipboard
        self.settings = settings
        self.controller = controller
        self.shelve = shelve
    }

    private struct Day: Identifiable {
        let id: String
        let items: [HistoryItem]
    }

    private static func days(_ shown: [HistoryItem]) -> [Day] {
        let calendar = Calendar.current
        var pinned: [HistoryItem] = [], today: [HistoryItem] = [], yesterday: [HistoryItem] = [], earlier: [HistoryItem] = []
        for item in shown {
            if item.pinned { pinned.append(item) }
            else if calendar.isDateInToday(item.date) { today.append(item) }
            else if calendar.isDateInYesterday(item.date) { yesterday.append(item) }
            else { earlier.append(item) }
        }
        return [(tr("Pinned"), pinned), (tr("Today"), today), (tr("Yesterday"), yesterday), (tr("Earlier"), earlier)]
            .filter { !$0.1.isEmpty }.map { Day(id: $0.0, items: $0.1) }
    }

    private var voiceLocked: Bool { controller.busy || controller.retryingID != nil }

    private func canRetry(_ entry: HistoryEntry) -> Bool {
        entry.canRetry && !voiceLocked && (controller.retryRequest(entry).map { controller.canRun($0) } ?? false)
    }

    var body: some View {
        page
        // Typing a search chooses its first match, for Return to paste.
        .onChange(of: model.query) { _, query in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            model.selection = trimmed.isEmpty ? nil : model.shown(voice: settings.history).first?.id
        }
    }

    private var page: some View {
        let shown = model.shown(voice: settings.history)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                TextField(tr("Search History…"), text: $model.query).glassField()
                    .focused($searchFocus)
                    .onChange(of: searchFocus) { _, focused in model.searchFocused = focused }
                    .onDisappear { model.searchFocused = false }
                Menu {
                    Button(tr("Copied Items…")) { model.clearing = .copied }
                        .disabled(clipboard.entries.allSatisfy(\.pinned))
                    Button(tr("Voice Records…")) { model.clearing = .voice }
                        .disabled(settings.history.isEmpty || voiceLocked)
                } label: {
                    Text(tr("Clear"))
                }
                .menuStyle(.button).buttonStyle(QuietButton()).menuIndicator(.hidden).fixedSize()
            }
            GlassSegments(label: tr("Kind"), selection: $model.kind, options: [
                (value: HistoryPageModel.Kind.all, title: tr("All")), (value: .voice, title: tr("Voice")),
                (value: .text, title: tr("Text")), (value: .images, title: tr("Images")), (value: .files, title: tr("Files")),
            ])
            if !controller.networkAvailable {
                Label(tr("Offline · Recordings are kept on this Mac and transcribed once online"), systemImage: "wifi.slash")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            }
            if !settings.historyMessage.isEmpty {
                words(settings.historyMessage, color: .orange)
            }
            if !settings.preferences.clipHistory {
                banner(symbol: "nosign", tint: Palette.muted, text: tr("The clipboard history is off."), button: tr("Turn On")) {
                    settings.preferences.clipHistory = true
                }
            } else if clipboard.paused {
                banner(symbol: "pause.circle.fill", tint: .orange, text: tr("Paused: what is copied now is not kept."), button: tr("Resume")) {
                    clipboard.paused = false
                }
            }
            if clipboard.entries.isEmpty && settings.history.isEmpty {
                caption(tr("Nothing here yet. What you dictate, and what you copy while the clipboard history is on, is kept here, on this Mac only.")).padding(.top, 4)
            } else if shown.isEmpty {
                caption(tr("Nothing matches.")).padding(.top, 4)
            } else {
                list(shown)
                caption(tr("Up and Down choose an item, Return pastes it into the app that was in front (Shift + Return as plain text), and Command + 1 to 9 paste one of the first nine."))
                    .padding(.top, 4)
            }
        }
        .alert(tr("Remove every copied item but the pinned ones?"), isPresented: clearing(.copied)) {
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Remove"), role: .destructive) { clipboard.clear() }
        }
        .alert(tr("Remove every voice record, and the audio waiting to be transcribed, from this Mac?"), isPresented: clearing(.voice)) {
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Remove"), role: .destructive) {
                // A recording may have started being transcribed while this was asked.
                if voiceLocked { NSSound.beep() } else { settings.clearHistory() }
            }
        }
    }

    private func clearing(_ which: HistoryPageModel.Clearing) -> Binding<Bool> {
        Binding(get: { model.clearing == which }, set: { if !$0 { model.clearing = nil } })
    }

    /// Off or paused: said above the list, which stays, with the button that ends it.
    private func banner(symbol: String, tint: Color, text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).buttonStyle(QuietButton())
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(tint.opacity(0.3), lineWidth: 1))
    }

    private func list(_ shown: [HistoryItem]) -> some View {
        let numbers = Dictionary(uniqueKeysWithValues: shown.enumerated().map { ($0.element.id, $0.offset) })
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Self.days(shown)) { day in
                Text(day.id).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                ForEach(Array(day.items.enumerated()), id: \.element.id) { offset, item in
                    if offset > 0 {
                        // No rule against the chosen row, which has a frame of its own.
                        let near = item.id == model.selection || day.items[offset - 1].id == model.selection
                        Divider().opacity(near ? 0 : 0.7).padding(.horizontal, 8)
                    }
                    Group {
                        switch item {
                        case .copied(let entry): copiedRow(entry, number: numbers[entry.id] ?? 99)
                        case .voice(let entry): voiceRow(entry, number: numbers[entry.id] ?? 99)
                        }
                    }
                    .id(item.id)
                }
            }
        }
    }

    private func meta<Leading: View>(number: Int, pinned: Bool = false, @ViewBuilder _ leading: () -> Leading) -> some View {
        HStack(spacing: 5) {
            leading()
            Spacer(minLength: 4)
            if pinned {
                Image(systemName: "pin.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.accent)
            }
            if number < 9 { Text(verbatim: "⌘\(number + 1)").monospacedDigit().foregroundStyle(Palette.muted.opacity(0.8)) }
        }
        .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
    }

    private func copiedRow(_ entry: ClipEntry, number: Int) -> some View {
        let chosen = entry.id == model.selection
        return VStack(alignment: .leading, spacing: 6) {
            meta(number: number, pinned: entry.pinned) {
                if let icon = model.icon(entry) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
                }
                Text(entry.app.isEmpty ? tr("Copied") : entry.app).lineLimit(1)
                Text(verbatim: "·")
                Text(ClipWords.when(entry.date)).lineLimit(1).layoutPriority(1)
                if entry.kind == .image && entry.width > 0 {
                    Text(verbatim: "·")
                    Text(verbatim: "\(entry.width) × \(entry.height)").lineLimit(1).layoutPriority(1)
                } else if entry.kind == .files && entry.count > 1 {
                    Text(verbatim: "·")
                    Text(tr("%ld files", entry.count)).lineLimit(1).layoutPriority(1)
                }
            }
            content(entry, chosen: chosen)
            if chosen {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button(entry.pinned ? tr("Unpin") : tr("Pin")) { clipboard.pin(entry.id, !entry.pinned) }.buttonStyle(QuietButton())
                    Button(tr("Remove")) { clipboard.remove(entry.id) }.buttonStyle(QuietButton())
                    Button(tr("Copy")) { clipboard.put(entry) }.buttonStyle(QuietButton())
                    Button(tr("Paste")) { controller.pasteClip(entry, plain: false) }.buttonStyle(SolidButton())
                }
                .padding(.top, 2)
            }
        }
        .modifier(HistoryRowChrome(chosen: chosen))
        .onTapGesture(count: 2) { controller.pasteClip(entry, plain: false) }
        .onTapGesture { model.selection = entry.id }
        .contextMenu {
            Button(tr("Paste")) { controller.pasteClip(entry, plain: false) }
            if entry.kind != .image { Button(tr("Paste as Plain Text")) { controller.pasteClip(entry, plain: true) } }
            Button(tr("Copy")) { clipboard.put(entry) }
            Button(tr("Put on the Shelf")) { shelve(entry) }
            Divider()
            Button(entry.pinned ? tr("Unpin") : tr("Pin")) { clipboard.pin(entry.id, !entry.pinned) }
            Button(tr("Remove")) { clipboard.remove(entry.id) }
        }
    }

    private func voiceRow(_ entry: HistoryEntry, number: Int) -> some View {
        let chosen = entry.id == model.selection
        let placeholder = entry.state == .recording ? tr("Recording. The audio is being saved on this Mac…") : tr("The audio is saved on this Mac, waiting to be transcribed.")
        let busy = entry.state == .recording || entry.state == .processing
        return VStack(alignment: .leading, spacing: 6) {
            meta(number: number) {
                Image(systemName: entry.mode.symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(Palette.accent)
                    .frame(width: 14, height: 14)
                    .background(Palette.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(entry.mode.title).lineLimit(1)
                Text(verbatim: "·")
                Text(ClipWords.when(entry.date)).lineLimit(1).layoutPriority(1)
                Text(verbatim: "·")
                Text(verbatim: "\(max(1, Int(entry.seconds.rounded()))) s").lineLimit(1).layoutPriority(1)
                if entry.state != .completed {
                    Text(verbatim: "·")
                    Text(entry.state.title).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Text(entry.text.isEmpty ? placeholder : entry.text).font(.system(size: 12))
                .foregroundStyle(entry.text.isEmpty ? Palette.muted : Palette.ink)
                .lineSpacing(3).lineLimit(chosen ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let problem = entry.problem {
                words(problem, size: 10.5, color: .orange.opacity(0.9), lineLimit: chosen ? nil : 2)
            }
            if chosen {
                if entry.state != .completed && !entry.text.isEmpty {
                    caption(tr("This is the text recognized so far. It is updated when a retry finishes."))
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button(tr("Delete")) { settings.removeHistory(id: entry.id) }.buttonStyle(QuietButton()).disabled(busy)
                    if entry.canRetry {
                        let retry = Button(tr("Retry")) { controller.retry(entry.id) }.disabled(!canRetry(entry))
                        if entry.text.isEmpty { retry.buttonStyle(SolidButton()) } else { retry.buttonStyle(QuietButton()) }
                    }
                    if !entry.text.isEmpty {
                        CopyActionButton(text: entry.text)
                        Button(tr("Paste")) { controller.pasteText(entry.text) }.buttonStyle(SolidButton())
                    }
                }
                .padding(.top, 2)
            }
        }
        .modifier(HistoryRowChrome(chosen: chosen))
        .onTapGesture(count: 2) { if !entry.text.isEmpty { controller.pasteText(entry.text) } }
        .onTapGesture { model.selection = entry.id }
        .contextMenu {
            if !entry.text.isEmpty {
                Button(tr("Paste")) { controller.pasteText(entry.text) }
                Button(tr("Copy")) { ClipboardCopy.copy(entry.text) }
            }
            if entry.canRetry { Button(tr("Retry")) { controller.retry(entry.id) }.disabled(!canRetry(entry)) }
            Divider()
            Button(tr("Delete")) { settings.removeHistory(id: entry.id) }.disabled(busy)
        }
    }

    @ViewBuilder private func content(_ entry: ClipEntry, chosen: Bool) -> some View {
        switch entry.kind {
        case .text:
            Text(entry.preview).font(.system(size: 12)).foregroundStyle(Palette.ink)
                .lineSpacing(3).lineLimit(chosen ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image:
            if let image = model.thumbnail(entry) {
                // As tall as a few lines of text, chosen a little taller, never wider than the row.
                let ratio = entry.width > 0 && entry.height > 0 ? CGFloat(entry.width) / CGFloat(entry.height) : image.size.width / max(image.size.height, 1)
                let height = min(chosen ? 132 : 76, 270 / max(ratio, 0.01))
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: height * ratio, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Palette.line, lineWidth: 1))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(tr("Image")).font(.system(size: 12)).foregroundStyle(Palette.ink)
            }
        case .files:
            let names = entry.preview.split(separator: "\n").map(String.init)
            let limit = chosen ? 6 : 3
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(names.prefix(limit).enumerated()), id: \.offset) { _, name in
                    HStack(spacing: 6) {
                        Image(nsImage: model.fileIcon(name)).resizable().interpolation(.high).frame(width: 16, height: 16)
                        Text(name).font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                    }
                }
                if names.count > limit {
                    Text(tr("and %ld more", names.count - limit)).font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}

/// A row's frame: the chosen one on a ground of its own.
private struct HistoryRowChrome: ViewModifier {
    let chosen: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background {
                if chosen { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.fill) }
            }
            .overlay {
                if chosen { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.line, lineWidth: 1) }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// How many things History holds, beside its title; it follows both lists.
struct HistoryBarCount: View {
    @ObservedObject var clipboard: ClipboardHistory
    @ObservedObject var settings: SettingsStore
    var body: some View {
        let count = clipboard.entries.count + settings.history.count
        if count > 0 {
            Text(count == 1 ? tr("1 item") : tr("%ld items", count))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}

/// Pauses keeping what is copied; what is said is kept all the same.
struct ClipboardPauseButton: View {
    @ObservedObject var clipboard: ClipboardHistory
    var body: some View {
        HeaderIconButton(
            symbol: "pause.circle",
            active: clipboard.paused,
            helpText: clipboard.paused ? tr("Resume") : tr("Pause Clipboard History"),
            accessibility: clipboard.paused ? tr("Resume") : tr("Pause Clipboard History")
        ) {
            clipboard.paused.toggle()
        }
    }
}
