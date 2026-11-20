import AppKit
import SwiftUI
import QingyanCore

/// The compact version of the panel (user 2026-11-20: a compact version of the panel that stays on
/// top; chose the bar with the Shelf under it, entered from the panel's title row): a small glass bar that
/// floats above every window on every Space until the full panel is brought back. Top row: start
/// or stop, what is happening, the last result (a click copies it) and the way back to the full
/// panel; under it, the Shelf as a strip, which takes drops and gives its items by click or drag.
struct CompactBar: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var meter: AudioMeter
    var glass = true
    var onExpand: () -> Void
    @State private var copied = false
    @State private var hovered: UUID?
    @State private var recordHovered = false

    static let width: CGFloat = 340
    private static let corner: CGFloat = 13

    private var recording: Bool { controller.phase == .recording }
    private var processing: Bool { controller.phase == .processing }

    /// What is happening, in a word or two: the capsule's own words while busy, and otherwise the
    /// panel's own reading of whether this Mac can record (or, receiving only, receive).
    private var state: String {
        if recording { return tr("Recording") + " " + String(format: "%d:%02d", meter.elapsed / 60, meter.elapsed % 60) }
        if processing { return controller.capsuleSummary }
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

    var body: some View {
        VStack(spacing: 0) {
            topRow.frame(height: 44)
            Rectangle().fill(Palette.line).frame(height: 1)
            shelfRow.frame(height: 54)
        }
        .frame(width: Self.width)
        .background {
            ZStack {
                if glass { Glass() } else { Color(nsColor: .windowBackgroundColor) }
                if shelf.targeted { Palette.accent.opacity(0.16) }
                // The bar moves by any part of it that is not a control.
                WindowDragArea()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).stroke(Palette.line, lineWidth: 1))
        .foregroundStyle(Palette.ink).tint(Palette.accent)
        .controlSize(.small)
        .onDrop(of: ShelfModel.types, isTargeted: $shelf.targeted) { shelf.accept($0) }
        .animation(Motion.quick, value: shelf.targeted)
        .animation(Motion.quick, value: hovered)
        .animation(Motion.standard, value: controller.phase)
        .id(settings.preferences.language)
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            recordButton
            Text(state)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(recording ? Color.red : Palette.ink)
                .lineLimit(1).fixedSize()
                .allowsHitTesting(false)
            resultButton
            Spacer(minLength: 0)
            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 24)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line, lineWidth: 0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Back to the full panel"))
            .accessibilityLabel(tr("Back to the full panel"))
        }
        .padding(.horizontal, 9)
    }

    private var recordButton: some View {
        let symbol = recording ? "stop.fill" : "mic.fill"
        let tint: Color = recording ? .red : Palette.ink
        let fill: Color = recording ? Color.red.opacity(recordHovered ? 0.24 : 0.18) : Color.primary.opacity(recordHovered ? 0.2 : 0.13)
        return Button { controller.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(fill, in: Circle())
                .overlay(Circle().stroke(recording ? Color.red.opacity(0.35) : Palette.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { recordHovered = $0 }
        .disabled(processing).opacity(processing ? 0.35 : 1)
        .help(recording ? tr("Stop recording") : tr("Start recording"))
        .accessibilityLabel(recording ? tr("Stop recording") : tr("Start recording"))
    }

    /// The last result on one line; a click copies it.
    private var resultButton: some View {
        let text = lastText
        return Button {
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Text(copied ? tr("Copied") : text.isEmpty ? tr("Nothing dictated yet") : "“" + text.replacingOccurrences(of: "\n", with: " ") + "”")
                .font(.system(size: 11))
                .foregroundStyle(copied ? Palette.accent : Palette.muted)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shelf.items) { tile($0).transition(Motion.pop) }
                    }
                }
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
        let copiedHere = shelf.copiedID == item.id
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
                }.opacity(stage == .here && !copiedHere ? 1 : 0.35)
                if copiedHere {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.accent).transition(Motion.pop)
                } else if stage != .here {
                    Image(systemName: "icloud.and.arrow.down").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            .frame(width: 40, height: 40)
            .background(Color.primary.opacity(hovered == item.id ? 0.11 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(copiedHere ? Palette.accent.opacity(0.6) : Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture {
                if case .fetching = stage { shelf.cancelFetch(item) } else { shelf.copy(item) }
            }
            .onDrag { shelf.provider(item) }
            .help(item.name)
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
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { Area() }
    func updateNSView(_ view: NSView, context: Context) {}
}
