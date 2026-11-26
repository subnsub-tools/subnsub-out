import AppKit
import SwiftUI
import QingyanCore

/// The bar kept on top: the status capsule and the compact panel as one window (user 2026-11-21:
/// the two become one and never show at once; the design was chosen from a demo). Not kept on top, the window is the capsule, which shows only while something happens. Kept on top,
/// it stays, a glass bar above every window on every Space, and its first row is the capsule: what
/// the capsule would show (recording, processing, sending, receiving, the result) shows there in
/// place, and otherwise the row has the record button, whether this Mac is ready, and the last
/// result (a click copies it). At its end: hide or show the Shelf, stop keeping on top, and back to
/// the full panel. Under it, the Shelf as a strip, which takes drops and gives its items by click or
/// drag. The bar moves by any part that is not a control.
struct CompactBar: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var meter: AudioMeter
    var glass = true
    var onExpand: () -> Void
    var onUnpin: () -> Void = {}
    /// The bar's size whenever it changes (the Shelf hidden or shown), for its window.
    var onSize: ((CGSize) -> Void)? = nil
    @AppStorage(CompactBar.foldedKey) private var shelfFolded = false
    @State private var copied = false
    @State private var hovered: UUID?
    @State private var recordHovered = false

    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 44
    static let shelfHeight: CGFloat = 54
    /// Where it is kept whether the Shelf is hidden.
    static let foldedKey = "compactShelfFolded"
    /// The bar's height: its first row, and under a line the Shelf unless it is hidden. Its window is
    /// given this height outright, when it is made, each time it is shown and at each press of the
    /// button that hides or shows the Shelf (user 2026-11-23: the bar was cut off at its top and
    /// bottom: a window still as tall as the first row alone, with the Shelf shown under it; the
    /// size the view reports back had not reached the window).
    static func height(shelfFolded: Bool) -> CGFloat { rowHeight + (shelfFolded ? 0 : 1 + shelfHeight) }
    private static let corner: CGFloat = 13

    private var recording: Bool { controller.phase == .recording }
    /// Text on its way between two Macs: the words name the other Mac.
    private var remote: Bool { controller.phase == .receiving || (controller.phase == .processing && controller.capsuleStep == .sending) }

    /// The first row shows what the capsule would: while busy, and while the capsule's moment lasts.
    private var live: Bool { controller.busy || (controller.capsuleShown && controller.phase != .idle) }

    private var notTyped: Bool {
        if controller.phase == .done, case .notWritten = controller.capsuleResult { return true }
        return false
    }

    /// Whether this Mac can record (or, receiving only, receive), in a word or two.
    private var state: String {
        if settings.receiverOnly {
            return settings.accessibilityAllowed && controller.remoteListening ? tr("Ready to receive") : tr("Setup needed")
        }
        if controller.boundMicrophoneMissing { return tr("Locked microphone not connected") }
        return settings.ready && controller.hotkeyInstalled ? tr("Ready") : tr("Setup needed")
    }

    /// The latest text written, or the newest finished dictation in History with any text (a
    /// recording under way is in History already, still empty).
    private var lastText: String {
        let now = controller.result.trimmingCharacters(in: .whitespacesAndNewlines)
        if !now.isEmpty { return now }
        return settings.history.lazy
            .filter { ($0.status ?? .completed) == .completed }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    /// The capsule's tint, over the first row only.
    private var rowTint: Color? {
        guard live else { return nil }
        switch controller.phase {
        case .recording: return CapsuleTint.green.opacity(0.24 + Double(meter.level) * 0.26)
        case .done: return (notTyped ? CapsuleTint.amber : CapsuleTint.green).opacity(0.18)
        case .error: return CapsuleTint.red.opacity(0.18)
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topRow.frame(height: Self.rowHeight)
            if !shelfFolded {
                Rectangle().fill(Palette.line).frame(height: 1)
                shelfRow.frame(height: Self.shelfHeight)
            }
        }
        .frame(width: Self.width)
        .background {
            ZStack(alignment: .top) {
                if glass { Glass() } else { Color(nsColor: .windowBackgroundColor) }
                if let rowTint { rowTint.frame(height: Self.rowHeight) }
                if shelf.targeted { Palette.accent.opacity(0.16) }
                // The bar moves by any part of it that is not a control.
                WindowDragArea()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
            .stroke(recording ? CapsuleTint.green.opacity(0.45) : Palette.line, lineWidth: 1))
        .foregroundStyle(Palette.ink).tint(Palette.accent)
        .controlSize(.small)
        // What the Shelf says floats over the bar's foot, within it: the bar stays as it is.
        .overlay(alignment: .bottom) { ShelfToast(shelf: shelf, size: 10.5, lines: 2).padding(.horizontal, 10).padding(.bottom, 5) }
        .onDrop(of: ShelfModel.types, isTargeted: $shelf.targeted) { shelf.accept($0) }
        .background(GeometryReader { proxy in Color.clear.preference(key: CompactSizeKey.self, value: proxy.size) })
        .onPreferenceChange(CompactSizeKey.self) { size in if size.width > 0 && size.height > 0 { onSize?(size) } }
        .animation(Motion.quick, value: shelf.targeted)
        .animation(Motion.quick, value: hovered)
        .animation(Motion.standard, value: controller.phase)
        .id(settings.preferences.language)
    }

    private var topRow: some View {
        HStack(spacing: 7) {
            lead.frame(width: 28, height: 28)
            middle.frame(maxWidth: .infinity, alignment: .leading)
            if live && (controller.busy || controller.phase == .error) { closeButton }
            Rectangle().fill(Palette.line).frame(width: 1, height: 20)
            barButton(shelfFolded ? "chevron.down" : "chevron.up", shelfFolded ? tr("Show the Shelf") : tr("Hide the Shelf")) {
                let folded = !shelfFolded
                shelfFolded = folded
                // The window is told at once, not only by the size read back from the view.
                onSize?(CGSize(width: Self.width, height: Self.height(shelfFolded: folded)))
            }
            barButton("pin.fill", tr("Stop Keeping on Top"), help: tr("Stop keeping on top: shown only while dictating and with results"), tint: Palette.accent, action: onUnpin)
            barButton(tr("Back to the full panel"), action: onExpand) {
                CornerMarks().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 10, height: 10)
            }
        }
        .padding(.leading, 8).padding(.trailing, 7)
        .accessibilityElement(children: .contain)
    }

    /// The round button or sign at the start of the row: record, stop, or the capsule's sign.
    @ViewBuilder private var lead: some View {
        if !live {
            recordButton
        } else {
            if controller.phase == .recording {
                Button { controller.finish() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CapsuleTint.green)
                        .frame(width: 28, height: 28)
                        .background(CapsuleTint.green.opacity(0.2), in: Circle())
                        .overlay(Circle().stroke(CapsuleTint.green.opacity(0.55), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tr("Stop recording (%@)", settings.shortcutLabel))
                .accessibilityLabel(tr("Stop recording"))
            } else {
                // One sign from the wait to its end, as in the capsule (user 2026-11-26).
                CapsuleGlyph(kind: glyph, meter: meter, side: 17)
            }
        }
    }

    private var glyph: CapsuleGlyph.Kind {
        switch controller.phase {
        case .recording, .processing, .receiving: .ring
        case .error: .error
        case .done, .idle: notTyped ? .warning : .done
        }
    }

    /// What the live row's words say, as one value: a new value rolls them, as in the capsule.
    private var wordsKey: String { "\(controller.phase) \(controller.capsuleSummary) \(copied)" }

    @ViewBuilder private var middle: some View {
        if !live {
            HStack(spacing: 6) {
                // Before the last result, which gives way first; never wider than the bar.
                Text(state)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).layoutPriority(1)
                    .allowsHitTesting(false)
                if !settings.receiverOnly {
                    Text(settings.shortcutLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Palette.line, lineWidth: 0.5))
                        .lineLimit(1).fixedSize()
                        .allowsHitTesting(false)
                        .accessibilityLabel(tr("Shortcut: %@", settings.shortcutLabel))
                }
                resultButton
                // What is left of the row moves the bar.
                Spacer(minLength: 0)
            }
        } else if recording {
            HStack(spacing: 5) {
                MicroWaveform(meter: meter)
                CapsuleClock(meter: meter, online: controller.recordingOnline)
                if copied {
                    Text(tr("Copied")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.accent)
                } else if !controller.partial.isEmpty {
                    Text("·").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.muted)
                    Button { copy(controller.partial) } label: {
                        Text(controller.partial)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1).truncationMode(.head)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("Click to copy the text recognized so far"))
                }
                Spacer(minLength: 0)
            }
        } else {
            ZStack(alignment: .leading) {
                words.id(wordsKey).transition(.capsuleWords)
            }
            .animation(Motion.reduced ? .easeOut(duration: 0.16) : .spring(response: 0.34, dampingFraction: 0.86), value: wordsKey)
        }
    }

    /// The live row's words after recording: why the text is not there, or the state.
    @ViewBuilder private var words: some View {
        if case let .notWritten(title, detail) = controller.capsuleResult, controller.phase == .done {
            Button { copy(controller.result) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(copied ? tr("Copied") : title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.result.isEmpty)
            .help(tr("%@\nClick to copy", controller.message.isEmpty ? controller.capsuleSummary : controller.message))
        } else {
            HStack(spacing: 6) {
                Text(controller.capsuleSummary)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    // A long Mac name gives way in its middle, so the words around it stay.
                    .truncationMode(remote ? .middle : .tail)
                    .layoutPriority(1)
                    .help(controller.phase == .error ? controller.message : controller.capsuleSummary)
                if controller.phase == .done { resultButton }
                Spacer(minLength: 0)
            }
        }
    }

    private var closeButton: some View {
        Button { controller.cancel() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Palette.ink.opacity(0.8))
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.09), in: Circle())
                .frame(width: 21, height: 21)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(controller.busy ? tr("Cancel (Esc)") : tr("Close"))
        .accessibilityLabel(controller.busy ? tr("Cancel this recording") : tr("Dismiss"))
    }

    private func barButton(_ symbol: String, _ label: String, help: String? = nil, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        barButton(label, help: help, tint: tint, action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
    }

    private func barButton<Icon: View>(_ label: String, help: String? = nil, tint: Color? = nil, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .foregroundStyle(tint ?? Palette.ink)
                .frame(width: 26, height: 24)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line, lineWidth: 0.8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(label)
    }

    private var recordButton: some View {
        let fill: Color = Color.primary.opacity(recordHovered ? 0.2 : 0.13)
        return Button { controller.toggle() } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 28, height: 28)
                .background(fill, in: Circle())
                .overlay(Circle().stroke(Palette.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { recordHovered = $0 }
        .help(tr("Start recording"))
        .accessibilityLabel(tr("Start recording"))
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    /// The last result on one line, as wide as its words (the rest of the row moves the bar); a click copies it.
    private var resultButton: some View {
        let text = lastText
        return Button { copy(text) } label: {
            Text(copied ? tr("Copied") : text.isEmpty ? tr("Nothing dictated yet") : "“" + text.replacingOccurrences(of: "\n", with: " ") + "”")
                .font(.system(size: 11))
                .foregroundStyle(copied ? Palette.accent : Palette.muted)
                .lineLimit(1).truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
        .help(text.isEmpty ? "" : tr("Click to copy"))
        .accessibilityLabel(text.isEmpty ? tr("Nothing dictated yet") : tr("Copy text"))
    }

    private var shelfRow: some View {
        HStack(spacing: 6) {
            if shelf.items.isEmpty {
                Text(tr("Drop files, images or text here"))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.muted.opacity(0.42), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .allowsHitTesting(false)
            } else {
                // Lazy, as the panel's grid is: only the tiles in sight are made (all of them at once
                // held up the bar's first showing).
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(shelf.items) { tile($0).transition(Motion.pop) }
                    }
                }
                // Only as wide as its items: what is left of the strip moves the bar.
                .frame(maxWidth: CGFloat(shelf.items.count) * 49 - 6)
                Spacer(minLength: 0)
            }
            Button { shelf.addClipboard() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 40)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.line, lineWidth: 0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Put what is on the clipboard on the Shelf"))
            .accessibilityLabel(tr("Put what is on the clipboard on the Shelf"))
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
    }

    private func tile(_ item: ShelfItem) -> some View {
        let stage = shelf.stage(item)
        return ZStack(alignment: .topTrailing) {
            ZStack {
                Group {
                    if item.kind == .text {
                        Text(shelf.snippet(item)).font(.system(size: 7.5)).lineLimit(4)
                            .padding(3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if let image = shelf.thumbnail(item) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else if item.kind == .image {
                        Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(Palette.muted)
                    } else {
                        Image(nsImage: shelf.icon(item)).resizable().frame(width: 26, height: 26)
                    }
                }.opacity(stage == .here ? 1 : 0.35)
                if stage != .here {
                    Image(systemName: "icloud.and.arrow.down").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            .frame(width: 40, height: 40)
            .background(Color.primary.opacity(hovered == item.id ? 0.11 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture {
                if case .fetching = stage { shelf.cancelFetch(item) } else { shelf.click(item) }
            }
            .onDrag { ShelfPeek.shared.hide(); return shelf.provider(item) }
            .help(shelf.hint(item, stage))
            .contextMenu { ShelfItemMenu(shelf: shelf, item: item) }
            .background(ShelfPeekSource(item: item, shelf: shelf))
            if hovered == item.id {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 6.5, weight: .bold)).foregroundStyle(Palette.ink)
                        .frame(width: 14, height: 14)
                        .background(Color.primary.opacity(0.24), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).offset(x: 3, y: -3)
                .help(tr("Remove from the Shelf")).accessibilityLabel(tr("Remove %@", item.name))
                .transition(Motion.pop)
            }
        }
        .padding(.top, 3).padding(.trailing, 3)
        .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
    }
}

/// A view that moves its window when dragged, for a borderless window whose controls cover the rest.
struct WindowDragArea: NSViewRepresentable {
    final class Area: NSView {
        override func mouseDown(with event: NSEvent) {
            (window as? FloatingPanel)?.onDragBegan?()
            window?.performDrag(with: event)
        }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { Area() }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct CompactSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
