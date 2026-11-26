import AppKit
import SwiftUI
import QingyanCore

/// The panel is glass: nothing in it is opaque, so every colour is a tint of the label colour
/// and reads on whatever is behind the window, in light and dark alike.
enum Palette {
    static let ink = Color.primary
    static let muted = Color.secondary
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.72, green: 0.84, blue: 0.60, alpha: 1)
            : NSColor(red: 0.27, green: 0.38, blue: 0.20, alpha: 1)
    })
    static let fill = Color.primary.opacity(0.05)
    static let strong = Color.primary.opacity(0.14)
    static let line = Color.primary.opacity(0.09)
}

/// The whole app is one narrow column of fixed width. Its height is what the user dragged it to,
/// but never more than its content needs: folding a block shortens the panel.
enum Metrics {
    static let width: CGFloat = 280
    /// The title row, from the window's top to where the content starts: its buttons, and the
    /// window's own close and minimize buttons (TitleRowLights), sit in its middle (user 2026-11-22:
    /// the buttons at the top were too close to the window's top).
    static let titlebar: CGFloat = 38
    /// How far below a title row the content under it starts, before anything is scrolled.
    static let underBar: CGFloat = 8
    /// The side drawer (History or Settings) that slides out beside the column.
    static let drawer: CGFloat = 316
    static let minHeight: CGFloat = 260
    static let defaultHeight: CGFloat = 680
    /// Before macOS 26 controls are a little wider, and rows draw their gaps a little tighter.
    static let legacy: Bool = {
        if #available(macOS 26.0, *) { return false } else { return true }
    }()
}

/// Cached motion preferences so animations never query NSWorkspace IPC on every render.
@MainActor
enum Motion {
    private static var cachedReduced: Bool = {
        let initial = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                cachedReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
        return initial
    }()

    static var reduced: Bool { cachedReduced }
    static let duration = 0.22
    static let curve: (Double, Double, Double, Double) = (0.25, 0.1, 0.25, 1)
    static var standard: Animation? { reduced ? nil : .timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration) }
    static var quick: Animation? { reduced ? nil : .easeOut(duration: 0.13) }
    static var resize: Animation? { nil }
    static var pop: AnyTransition { reduced ? .identity : .opacity }
}

/// Shared clipboard helper for instant click-to-copy across all text surfaces.
@MainActor
enum ClipboardCopy {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        PasteboardLease.general.keep(text)
    }
}

/// Universal click-to-copy text surface: clicking anywhere on the text immediately copies it to
/// the clipboard without requiring a tiny secondary button or manual text selection.
struct CopyableText: View {
    let text: String
    var copyValue: String?
    var font: Font = .system(size: 12)
    var color: Color = Palette.ink
    var lineSpacing: CGFloat = 2.5
    var lineLimit: Int? = nil
    var block: Bool = false
    var enabled: Bool = true
    var onCopied: (() -> Void)? = nil

    @State private var hovered = false
    @State private var copied = false
    @State private var token = UUID()

    init(
        _ text: String,
        copyValue: String? = nil,
        font: Font = .system(size: 12),
        color: Color = Palette.ink,
        lineSpacing: CGFloat = 2.5,
        lineLimit: Int? = nil,
        block: Bool = false,
        enabled: Bool = true,
        onCopied: (() -> Void)? = nil
    ) {
        self.text = text
        self.copyValue = copyValue
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
        self.lineLimit = lineLimit
        self.block = block
        self.enabled = enabled
        self.onCopied = onCopied
    }

    private var payload: String { copyValue ?? text }

    var body: some View {
        if !enabled || payload.isEmpty {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineSpacing(lineSpacing)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button(action: triggerCopy) {
                ZStack(alignment: .topTrailing) {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineSpacing(lineSpacing)
                        .lineLimit(lineLimit)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: block ? .infinity : nil, alignment: .leading)
                        .padding(.horizontal, block ? 7 : 3)
                        .padding(.vertical, block ? 5 : 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: block ? 7 : 5, style: .continuous)
                                .fill(copied ? Palette.accent.opacity(0.14) : (hovered ? Color.primary.opacity(0.065) : Color.clear))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: block ? 7 : 5, style: .continuous)
                                .stroke(copied ? Palette.accent.opacity(0.45) : (block && hovered ? Palette.line : Color.clear), lineWidth: 0.8)
                        )
                    if copied {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                            Text(tr("Copied")).font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous).stroke(Palette.accent.opacity(0.4), lineWidth: 0.75))
                        .padding(block ? 3 : 0)
                        .offset(x: block ? 0 : 2, y: block ? 0 : -4)
                        .transition(Motion.pop)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovered = inside
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onDisappear {
                if hovered {
                    hovered = false
                    NSCursor.arrow.set()
                }
            }
            .help(copied ? tr("Copied to the clipboard") : tr("Click to copy"))
            .contextMenu {
                Button(tr("Copy")) { triggerCopy() }
            }
            .accessibilityLabel(tr("%@, click to copy", text))
        }
    }

    private func triggerCopy() {
        guard !payload.isEmpty else { return }
        ClipboardCopy.copy(payload)
        onCopied?()
        let current = UUID()
        token = current
        withAnimation(Motion.quick) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if token == current {
                withAnimation(Motion.quick) { copied = false }
            }
        }
    }
}

/// Tactile copy button with built-in checkmark confirmation.
struct CopyActionButton: View {
    let text: String
    var title: String = tr("Copy")
    var onCopy: (() -> Void)? = nil
    @State private var copied = false
    @State private var token = UUID()

    var body: some View {
        Button {
            guard !text.isEmpty else { return }
            ClipboardCopy.copy(text)
            onCopy?()
            let current = UUID()
            token = current
            withAnimation(Motion.quick) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                if token == current {
                    withAnimation(Motion.quick) { copied = false }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(copied ? tr("Copied") : title)
            }
            .foregroundStyle(copied ? Palette.accent : Palette.ink)
        }
        .buttonStyle(QuietButton())
        .disabled(text.isEmpty)
    }
}

/// How much taller the column will be once every `Reveal` in it has finished moving.
struct RevealPendingKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

struct RevealLayout: Layout {
    var fraction: CGFloat
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: natural.height * min(1, max(0, fraction)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Content that opens and closes. Most blocks of the panel do it in one step (operator 2026-11-14:
/// the height changing frame by frame, with the window stretching along, was choppy and ugly).
/// An `animated` one moves (operator 2026-11-18: clicking a connected Mac opened and closed its
/// details without a smooth animation): a paired Mac's details, the microphone list.
/// Its height runs between nothing and what the content needs on one curve, the content stays
/// anchored at the top and is cut at the moving edge, and the window takes the column's height
/// of each frame as it comes (MainView.report, AppDelegate.arrange) — it has no animation of its
/// own, so its edge and the content cannot drift apart, which is what made the old movement stutter.
struct Reveal<Content: View>: View {
    let open: Bool
    var animated = false
    var content: () -> Content

    init(open: Bool, animated: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.open = open
        self.animated = animated
        self.content = content
    }

    var body: some View {
        if animated && !Motion.reduced {
            MovingReveal(open: open, content: content)
        } else if open {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The moving kind of `Reveal`. Its content is built only while it is open or on its way shut,
/// so a closed one costs nothing. While it moves, RevealPendingKey says how far it still has to go,
/// which tells the panel that the window is following a movement rather than settling.
private struct MovingReveal<Content: View>: View {
    let open: Bool
    let content: () -> Content
    @State private var mounted: Bool
    @State private var unmount: Task<Void, Never>?

    init(open: Bool, content: @escaping () -> Content) {
        self.open = open
        self.content = content
        _mounted = State(initialValue: open)
    }

    var body: some View {
        RevealLayout(fraction: open ? 1 : 0) {
            if open || mounted {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { Color.clear.preference(key: RevealPendingKey.self, value: open ? $0.size.height : 0) })
            }
        }
        .clipped()
        .background(GeometryReader { Color.clear.preference(key: RevealPendingKey.self, value: -$0.size.height) })
        .opacity(open ? 1 : 0)
        .allowsHitTesting(open)
        .accessibilityHidden(!open)
        .animation(Motion.standard, value: open)
        .onChange(of: open) { _, now in
            unmount?.cancel()
            if now {
                mounted = true
            } else {
                unmount = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64((Motion.duration + 0.06) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    mounted = false
                }
            }
        }
    }
}

/// Blurs what is behind the window. Always active, so the panel stays glass when it is not in front.
struct Glass: NSViewRepresentable {
    var dark = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        if dark { view.appearance = NSAppearance(named: .darkAqua) }
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct Card<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }
}

private struct StyledButtonSurface<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let baseOpacity: Double = prominent
            ? (isPressed ? 0.28 : (hovered ? 0.22 : 0.16))
            : (isPressed ? 0.18 : (hovered ? 0.13 : 0.08))
        label
            .font(.system(size: 11.5, weight: prominent ? .semibold : .medium))
            .padding(.horizontal, prominent ? 12 : 10)
            .padding(.vertical, 5.5)
            .frame(minHeight: 26)
            .foregroundStyle(Palette.ink)
            .background(Color.primary.opacity(baseOpacity), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.line, lineWidth: prominent ? 0.6 : 0.9))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.36)
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(Motion.quick, value: isPressed)
            .onHover { hovered = $0 }
    }
}

struct SolidButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButtonSurface(label: configuration.label, isPressed: configuration.isPressed, prominent: true)
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButtonSurface(label: configuration.label, isPressed: configuration.isPressed, prominent: false)
    }
}

/// A button of a title row: the panel's, and the screen window's (ScreenTitleRow).
struct HeaderIconButton: View {
    let symbol: String
    let active: Bool
    let helpText: String
    let accessibility: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Palette.accent : Palette.ink)
                .frame(width: 28, height: 24)
                .background(
                    active ? Palette.strong : Color.primary.opacity(hovered ? 0.13 : 0.075),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(active ? Palette.accent.opacity(0.45) : Palette.line, lineWidth: 0.8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(helpText)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

extension View {
    /// A text field without the system's opaque bezel.
    func glassField() -> some View {
        textFieldStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5.5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }
}

/// A segmented choice drawn in tints; the system control paints an opaque selection.
struct GlassSegments<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var compact = false
    @Namespace private var highlight
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let on = options[index].value == selection
                Button { selection = options[index].value } label: {
                    Text(options[index].title).font(.system(size: 11.5, weight: on ? .semibold : .regular)).lineLimit(1)
                        .padding(.horizontal, compact ? 9 : 6)
                        .frame(minWidth: compact ? 36 : nil, maxWidth: compact ? nil : .infinity, minHeight: compact ? 22 : 26)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                    .fill(Palette.strong)
                                    .matchedGeometryEffect(id: "chosen", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(Motion.quick, value: selection)
        .padding(2.5)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8.5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8.5, style: .continuous).stroke(Palette.line, lineWidth: 0.8))
        .accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

/// Text polishing, off unless it is turned on here in Settings (user 2026-11-20). Off
/// writes the transcript as is and Settings shows nothing else about polishing; on starts with
/// Polish, and Style chooses among the rest.
struct PolishSwitch: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Row(tr("Text polishing"), info: tr("Off: the recognized text is entered as is, and nothing is sent to a polishing service.\nOn: each dictation is written in the style chosen below, through the polishing service.")) {
            GlassSegments(label: tr("Text polishing"),
                          selection: Binding(
                            get: { settings.preferences.style != StyleChoice.standard },
                            set: { on in
                                // Pressing On again keeps the style that is chosen.
                                guard on != (settings.preferences.style != StyleChoice.standard) else { return }
                                settings.preferences.style = on ? "polish" : StyleChoice.standard
                            }),
                          options: [(false, tr("Off")), (true, tr("On"))], compact: true)
        }
    }
}

/// How a polished dictation is written, as a choice that says what it is. Only in Settings, and
/// only while Text polishing is on: the panel never shows it (user 2026-11-20).
struct PolishChoice: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        let customs = settings.preferences.customStyles.filter(\.usable)
        let options: [(value: String, title: String)] =
            [("polish", tr("Polish")), ("structured", tr("Structured")), ("formal", tr("Formal"))]
            + customs.map { (value: $0.id.uuidString, title: $0.name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        Row(tr("Style"), info: tr("Polish adds punctuation and paragraph breaks and removes filler words and spoken repetitions. Nothing is shortened, rewritten or translated; if the model strays from what was said, the original transcript is kept. With Polish you can also edit the text in the current field by voice (for example “change Wednesday to Thursday” or “clear everything”); the field's text is read only when what you said is taken as an edit command.\nStructured turns what you said into a clear prompt for an AI assistant: what you want first, then the details as numbered points.\nFormal rewrites it as formal written prose.\nA custom style follows the instructions written for it in Settings.\nStructured, Formal and custom styles change the wording, so their result is not compared with what was said, and editing by voice is not available with them.")) {
            GlassMenu(label: tr("Style"),
                      selection: Binding(
                        // An id that is not offered — an unfinished custom style — shows "—": it writes as is.
                        get: { settings.preferences.style },
                        set: { settings.preferences.style = $0 }),
                      options: options)
        }
    }
}

/// A pop-up choice without the system's opaque bezel.
struct GlassMenu<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @State private var hovered = false

    var body: some View {
        let title = Self.short(options.first { $0.value == selection }?.title ?? "—")
        // A borderless menu button puts an image in its label first and adds an arrow of its own:
        // two arrows on every menu (seen on macOS 27, user 2026-11-26), and before macOS 26 a width
        // that overflowed the Settings drawer. So the menu shows the name alone, with no arrow of its
        // own, and the arrows sit beside it.
        HStack(spacing: 4) {
            Menu { items } label: { Text(title).lineLimit(1) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            chevron.allowsHitTesting(false)
        }
        // The menu button before macOS 26 brings a little room of its own around the name.
        .padding(.horizontal, Metrics.legacy ? 7 : 9).padding(.vertical, 4.5)
        .frame(minHeight: 26)
        .background(Color.primary.opacity(hovered ? 0.11 : 0.065), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line, lineWidth: 0.85))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }

    @ViewBuilder private var items: some View {
        ForEach(options.indices, id: \.self) { index in
            Button { selection = options[index].value } label: {
                if options[index].value == selection { Label(options[index].title, systemImage: "checkmark") }
                else { Text(options[index].title) }
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Palette.muted)
    }

    /// A long name (a model typed in by hand) is shortened in the middle, so that the menu, which
    /// keeps its full width, still fits its row.
    static func short(_ title: String) -> String {
        title.count <= 22 ? title : String(title.prefix(10)) + "…" + String(title.suffix(10))
    }
}

/// Two corners of a frame, upper left and lower right, as a pair of corner brackets stands: back to the full
/// panel, on the bar (user 2026-11-23). Their arms are long and do not meet.
struct CornerMarks: Shape {
    func path(in rect: CGRect) -> Path {
        let arm: CGFloat = 0.72
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm * rect.height))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm * rect.width, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm * rect.height))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - arm * rect.width, y: rect.maxY))
        return path
    }
}

/// A ring that grows out of the record button and fades, over and over, while recording.
struct RecordingRing: View {
    @State private var out = false
    var body: some View {
        Circle().stroke(Color.red.opacity(0.55), lineWidth: 1.5)
            .scaleEffect(out ? 1.5 : 1).opacity(out ? 0 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { out = true } }
            .allowsHitTesting(false)
    }
}

/// Words of the interface itself: a hint, a status, a notice. Shown, and wrapped, but never copied
/// with a click (user 2026-11-26: only what was dictated or received is copied by clicking it; the
/// interface's own words being copyable was strange).
func words(_ text: String, size: CGFloat = 11, color: Color = Palette.muted, lineSpacing: CGFloat = 2.5, lineLimit: Int? = nil) -> some View {
    Text(text).font(.system(size: size)).foregroundStyle(color).lineSpacing(lineSpacing).lineLimit(lineLimit)
        .fixedSize(horizontal: false, vertical: true)
}

/// Small print under a control.
func caption(_ text: String) -> some View { words(text, size: 10.5, lineSpacing: 2) }

/// The long explanation, one click away instead of taking panel height: a click on the mark shows it
/// at once, and a click anywhere else puts it away (user 2026-11-26: the mark could not be clicked,
/// and its tooltip came only after a while on it). No tooltip as well: one place for the words.
struct Info: View {
    let text: String
    @State private var shown = false
    @State private var hovered = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 11.5))
                .foregroundStyle(shown || hovered ? Palette.ink : Palette.muted)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(text)
        .popover(isPresented: $shown) {
            words(text, size: 11.5, color: Palette.ink)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}

struct Row<Trailing: View>: View {
    let label: String
    var info: String?
    var trailing: Trailing
    init(_ label: String, info: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.label = label; self.info = info; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: Metrics.legacy ? 4 : 6) {
            // Shortened only as a last resort: a row too narrow for its label and control must not push
            // the card past its column.
            Text(label).font(.system(size: 12)).lineLimit(1).layoutPriority(1)
            if let info { Info(text: info) }
            Spacer(minLength: 2)
            trailing
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A list that is as tall as its rows until `maxHeight`, then scrolls inside the panel, with no
/// scroll bar (user 2026-11-23: no scroll bar in any window).
struct FittedScroll<Content: View>: View {
    let maxHeight: CGFloat
    /// All the height it is given instead, whatever its rows need.
    var fills = false
    var content: Content
    @State private var height: CGFloat = 64
    init(maxHeight: CGFloat, fills: Bool = false, @ViewBuilder content: () -> Content) { self.maxHeight = maxHeight; self.fills = fills; self.content = content() }
    var body: some View {
        ScrollView {
            content.background(GeometryReader { Color.clear.preference(key: ListHeightKey.self, value: $0.size.height) })
        }
        .scrollIndicators(.never)
        .frame(height: fills ? nil : min(max(height, 1), maxHeight))
        .frame(maxHeight: fills ? .infinity : nil, alignment: .top)
        .onPreferenceChange(ListHeightKey.self) { next in
            if abs(height - next) > 0.5 { height = next }
        }
    }
}

/// The panel's blocks, folded away under the Shelf while it is expanded over the whole panel
/// (user 2026-11-27), and back.
private struct UnderShelf: ViewModifier {
    let expanded: Bool
    func body(content: Content) -> some View {
        content
            .frame(maxHeight: expanded ? 0 : nil, alignment: .top)
            .clipped()
            .opacity(expanded ? 0 : 1)
            .allowsHitTesting(!expanded)
            .accessibilityHidden(expanded)
    }
}

private struct ShelfHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ColumnHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    struct Cache {
        var width: CGFloat = -1
        var count: Int = -1
        var points: [CGPoint] = []
        var sizes: [CGSize] = []
        var naturalWidth: CGFloat = 0
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let targetWidth = proposal.width ?? .infinity
        compute(targetWidth, subviews: subviews, cache: &cache)
        return CGSize(width: proposal.width ?? cache.naturalWidth, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        compute(bounds.width, subviews: subviews, cache: &cache)
        for (index, point) in cache.points.enumerated() where index < subviews.count {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  proposal: ProposedViewSize(width: cache.sizes[index].width, height: nil))
        }
    }

    private func compute(_ width: CGFloat, subviews: Subviews, cache: inout Cache) {
        if abs(cache.width - width) < 0.5 && cache.count == subviews.count { return }
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        var points: [CGPoint] = []
        var sizes: [CGSize] = []
        points.reserveCapacity(subviews.count)
        sizes.reserveCapacity(subviews.count)
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height); widest = max(widest, x - spacing)
        }
        cache = Cache(width: width, count: subviews.count, points: points, sizes: sizes, naturalWidth: widest, height: y + rowHeight)
    }
}

/// Unified sideways drawer beside the main column, hosting both History and Settings so both
/// slide open and closed with identical 120fps native window-frame smoothness.
struct SideDrawer: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    var windowed = true

    private var showingSettings: Bool { settings.page == .settings }

    /// The pages end at the title row's lower edge, as the panel's content does: nothing passes
    /// under the row, and the row has no cover of its own, so it is one piece of glass with the
    /// rest of the window (user 2026-11-23: over some backgrounds the top row and the window under
    /// it were not one piece; that was macOS 26's soft blur under the row).
    @ViewBuilder private var layout: some View {
        bar
        pages(top: Metrics.underBar)
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Image(systemName: showingSettings ? "gearshape" : PanelSection.history.symbol)
                .font(.system(size: 11.5, weight: .semibold))
            Text(showingSettings ? tr("Settings") : tr("History"))
                .font(.system(size: 13, weight: .bold))
            if !showingSettings { HistoryBarCount(clipboard: controller.clipboard, settings: settings) }
            Spacer()
            if !showingSettings && settings.preferences.clipHistory { ClipboardPauseButton(clipboard: controller.clipboard) }
            HeaderIconButton(
                symbol: "xmark",
                active: false,
                helpText: showingSettings ? tr("Hide Settings") : tr("Hide History"),
                accessibility: showingSettings ? tr("Hide Settings") : tr("Hide History")
            ) {
                settings.closeDrawer()
            }
        }
        .padding(.leading, windowed && settings.drawerLeft ? 54 : 12)
        .padding(.trailing, 8)
        .frame(height: Metrics.titlebar)
    }

    /// History and Settings, one over the other; in the window each scrolls whole, with no scroll bar.
    private func pages(top: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                if windowed {
                    // A row chosen with the keys is scrolled into view.
                    ScrollViewReader { proxy in
                        ScrollView {
                            HistoryPage(model: controller.historyPage, settings: settings, controller: controller,
                                        shelve: { controller.shelf.put($0, from: controller.clipboard) })
                                .padding(.horizontal, 10).padding(.top, top).padding(.bottom, 10)
                        }
                        .scrollIndicators(.never)
                        .onReceive(controller.historyPage.$reveal) { id in
                            guard let id else { return }
                            proxy.scrollTo(id)
                            controller.historyPage.reveal = nil
                        }
                    }
                } else {
                    HistoryPage(model: controller.historyPage, settings: settings, controller: controller,
                                shelve: { controller.shelf.put($0, from: controller.clipboard) })
                        .padding(.horizontal, 10).padding(.bottom, 10)
                }
            }
            .opacity(showingSettings ? 0 : 1)
            .offset(x: showingSettings ? -10 : 0)
            .allowsHitTesting(!showingSettings)
            .accessibilityHidden(showingSettings)

            Group {
                if windowed {
                    ScrollView {
                        SettingsPage(settings: settings, controller: controller)
                            .padding(.horizontal, 10).padding(.top, top).padding(.bottom, 12)
                    }
                    .scrollIndicators(.never)
                } else {
                    SettingsPage(settings: settings, controller: controller)
                        .padding(.horizontal, 10).padding(.bottom, 12)
                }
            }
            .opacity(showingSettings ? 1 : 0)
            .offset(x: showingSettings ? 0 : 10)
            .allowsHitTesting(showingSettings)
            .accessibilityHidden(!showingSettings)
        }
        .animation(Motion.standard, value: showingSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { layout }
        .frame(width: Metrics.drawer)
        .frame(maxHeight: windowed ? .infinity : nil, alignment: .top)
        .clipped()
        .overlay(alignment: settings.drawerLeft ? .trailing : .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
        .foregroundStyle(Palette.ink).tint(Palette.accent)
        .controlSize(.small)
        .ignoresSafeArea()
        // A change of language builds the words again everywhere below.
        .id(settings.preferences.language)
    }
}

struct MainView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    @ObservedObject var shelf: ShelfModel
    var windowed = true
    var onFit: (CGFloat, Bool) -> Void = { _, _ in }
    @Environment(\.colorScheme) private var scheme
    @State private var columnHeight: CGFloat = 0
    @State private var shelfHeight: CGFloat = 0
    @State private var pending: CGFloat = 0
    @State private var lastReported: CGFloat = 0
    @State private var lastMoving = false
    @State private var shownResult = Outcome(message: "", text: "", latency: nil, failed: false)
    @State private var shownSteps: [Step] = []
    @State private var recordButtonHovered = false
    @State private var shortcutHovered = false

    private struct Outcome: Equatable {
        var message: String
        var text: String
        var latency: Double?
        var failed: Bool
    }
    /// Text another Mac sent has the Received card, not this one: a message set later shows here
    /// without it.
    private var outcome: Outcome {
        Outcome(message: controller.message, text: controller.resultIsReceived ? "" : controller.result, latency: controller.latency, failed: controller.phase == .error)
    }
    private var resultOpen: Bool { !controller.message.isEmpty && !recording && !controller.messageIsReceived }

    /// The window is as tall as the column is now. While a moving `Reveal` is on its way (pending
    /// is how far it still has to go), that is a new height on every frame, sent as `live`: the
    /// window takes each one at once and keeps no animation of its own. Settled, it is sent once.
    private func report() {
        // The Shelf over the whole panel keeps the window as it was: it fills it and scrolls.
        guard windowed, columnHeight > 0, !shelf.expanded else { return }
        let height = Metrics.titlebar + columnHeight + shelfHeight
        let moving = abs(pending) > 0.5
        guard abs(height - lastReported) > 0.01 || moving != lastMoving else { return }
        lastReported = height
        lastMoving = moving
        onFit(height, moving)
    }

    var body: some View {
        Group {
            if windowed { column } else {
                HStack(alignment: .top, spacing: 0) {
                    column
                    if settings.drawerOpen { SideDrawer(settings: settings, controller: controller, windowed: false) }
                }
                .background {
                    ZStack {
                        LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.78), Color(red: 0.80, green: 0.52, blue: 0.60), Color(red: 0.92, green: 0.78, blue: 0.48)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        (scheme == .dark ? Color(white: 0.13) : Color(white: 0.95)).opacity(0.74)
                    }
                }
            }
        }
        .foregroundStyle(Palette.ink).tint(Palette.accent)
        .controlSize(.small)
        .onDrop(of: ShelfModel.types, isTargeted: $shelf.targeted) { shelf.accept($0) }
        // Put back: what changed meanwhile sizes the window again.
        .onChange(of: shelf.expanded) { _, _ in report() }
        .ignoresSafeArea()
        // A change of language builds the words again everywhere below.
        .id(settings.preferences.language)
    }

    private var column: some View {
        VStack(spacing: 0) {
            if windowed { scroller } else { header; content.modifier(UnderShelf(expanded: shelf.expanded)) }
            ShelfBar(shelf: shelf)
                .background(GeometryReader { Color.clear.preference(key: ShelfHeightKey.self, value: $0.size.height) })
                .onPreferenceChange(ShelfHeightKey.self) { next in
                    if abs(shelfHeight - next) > 0.5 { shelfHeight = next; report() }
                }
        }
        .frame(width: Metrics.width)
        .frame(maxHeight: windowed ? .infinity : nil, alignment: .top)
    }

    private func measuredContent(top: CGFloat = 0) -> some View {
        content
            .padding(.top, top)
            .background(GeometryReader { Color.clear.preference(key: ColumnHeightKey.self, value: $0.size.height) })
            .onPreferenceChange(ColumnHeightKey.self) { next in
                if abs(columnHeight - next) > 0.5 { columnHeight = next; report() }
            }
            .onPreferenceChange(RevealPendingKey.self) { next in
                if abs(pending - next) > 0.5 { pending = next; report() }
            }
    }

    /// The content ends at the title row's lower edge on every system: macOS 26's soft blur under
    /// the row made it a band apart from the window over some backgrounds (user 2026-11-23).
    @ViewBuilder private var scroller: some View {
        header
        ScrollView { measuredContent(top: Metrics.underBar) }.scrollIndicators(.never)
            .modifier(UnderShelf(expanded: shelf.expanded))
    }

    private var receiving: Bool { settings.receiverOnly }
    private var recording: Bool { controller.phase == .recording }
    private var processing: Bool { controller.phase == .processing }

    private var header: some View {
        // Buttons alone: no name and no dot (user 2026-11-23). The first shrinks the panel into the
        // bar; a window going to a corner, not a pin, since the bar is what it is for.
        HStack(spacing: 5) {
            Spacer(minLength: 4)
            HeaderIconButton(
                symbol: "rectangle.inset.topright.filled",
                active: false,
                helpText: tr("Shrink the panel into a bar that stays on top"),
                accessibility: tr("Shrink the panel into a bar that stays on top")
            ) {
                settings.setCompact?(true)
            }
            HeaderIconButton(
                symbol: "keyboard",
                active: controller.phase == .processing && controller.capsuleStep == .typing,
                helpText: tr("Type the Clipboard (⌃⌥V)"),
                accessibility: tr("Type the clipboard into the field in front, key by key")
            ) {
                controller.typeClipboard(from: .panel)
            }
            .disabled(controller.busy)
            .padding(.leading, 3)
            .padding(.leading, 3)
            HeaderIconButton(
                symbol: PanelSection.history.symbol,
                active: settings.historyOpen,
                helpText: settings.historyOpen ? tr("Hide History") : tr("History (%ld)", settings.history.count),
                accessibility: settings.historyOpen ? tr("Hide History") : tr("Open History")
            ) {
                settings.toggleHistory()
            }
            .padding(.leading, 3)
            HeaderIconButton(
                symbol: "gearshape",
                active: settings.page == .settings,
                helpText: settings.page == .settings ? tr("Hide Settings (⌘,)") : tr("Settings (⌘,)"),
                accessibility: settings.page == .settings ? tr("Close Settings") : tr("Settings")
            ) {
                settings.toggleSettings()
            }
        }
        .padding(.leading, windowed ? 54 : 12)
        .padding(.trailing, 8).frame(height: Metrics.titlebar)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No Style here: polishing is chosen only in Settings (user 2026-11-20).
            recordStrip
            // No Microphone block here: it is chosen in Settings alone (user 2026-11-23: one thing in one place).
            Reveal(open: !missing.isEmpty) { setupCard.padding(.top, 8) }
            Reveal(open: controller.learnedWord != nil) { learnedCard.padding(.top, 8) }
            Reveal(open: resultOpen) { resultCard.padding(.top, 8) }
            Reveal(open: controller.lastReceived != nil) {
                if let received = controller.lastReceived { receivedCard(received).padding(.top, 8) }
            }
            remoteCard.padding(.top, 8)
        }
        // Right under the title row, which keeps the space above the first block.
        .padding(.horizontal, 10).padding(.bottom, 10)
        .contentTransition(.identity)
        .onChange(of: outcome, initial: true) { _, now in if resultOpen { shownResult = now } }
        .onChange(of: resultOpen) { _, open in if open { shownResult = outcome } }
        .onChange(of: missing.map(\.id), initial: true) { _, _ in if !missing.isEmpty { shownSteps = missing } }
    }

    private var recordStrip: some View {
        let micOffline = !receiving && controller.boundMicrophoneMissing
        let choosing = controller.recordingShortcut
        let headline: String = choosing ? tr("Press the new shortcut")
            : recording ? tr("Recording, tap again to stop") : processing ? tr("Writing the text…")
            : micOffline ? tr("Locked microphone not connected") : tr("Tap to start, tap again to stop")
        let subline: String = choosing ? (controller.shortcutNote.isEmpty ? tr("Fn, a Command key, an F key, or a key with Control or Option · Esc cancels") : controller.shortcutNote)
            : micOffline ? tr("“%@” offline, no input", controller.boundMicrophoneLabel)
            // Short enough for one line in the strip, in either language (user 2026-11-25: the panel's details).
            : settings.sendsRemotely ? tr("Types on the focused Mac") : tr("Types at the cursor")
        // Worked out one by one: as one expression the button's styling is too much for the type checker.
        let hovered = recordButtonHovered
        let symbol: String = recording ? "stop.fill" : (micOffline ? "mic.slash.fill" : "mic.fill")
        let tint: Color = recording ? Color.red : (micOffline ? Color.orange : Palette.ink)
        let fill: Color
        if recording { fill = Color.red.opacity(hovered ? 0.24 : 0.18) }
        else if micOffline { fill = Color.orange.opacity(hovered ? 0.22 : 0.15) }
        else { fill = Color.primary.opacity(hovered ? 0.21 : 0.14) }
        let rim: Color = recording ? Color.red.opacity(0.35) : (micOffline ? Color.orange.opacity(0.4) : Palette.line)
        let buttonHelp: String = recording ? tr("Stop recording")
            : (micOffline ? tr("The locked microphone is not connected. Click for details.") : tr("Start recording"))
        // Tinted only while recording, or warning; otherwise a card like the others (user 2026-11-25:
        // green while idle meant nothing).
        let stripFill: Color = micOffline ? Color.orange.opacity(0.10) : (recording ? Palette.accent.opacity(0.10) : Palette.fill)
        let stripRim: Color = micOffline ? Color.orange.opacity(0.32) : Palette.line
        let headlineTint: Color = micOffline && !recording && !choosing ? Color.orange : Palette.ink
        let label = settings.shortcutLabel
        let badgeFill: Color = choosing ? Palette.accent.opacity(0.18) : Color.primary.opacity(shortcutHovered ? 0.15 : 0.09)
        let badgeRim: Color = choosing ? Palette.accent.opacity(0.7) : Palette.line
        let refused = choosing && !controller.shortcutNote.isEmpty
        return HStack(spacing: 9) {
            // Clicked, it waits for the new shortcut (user 2026-11-19).
            Button { controller.recordShortcut() } label: {
                Text(choosing ? "…" : label)
                    .font(.system(size: choosing || label == "fn" ? 15 : 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .padding(.horizontal, 9).frame(minWidth: 32).frame(height: 32)
                    .background(badgeFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(badgeRim, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { shortcutHovered = $0 }
            .disabled(controller.busy)
            .help(choosing ? tr("Press the new shortcut, or Esc to keep %@", label) : tr("Shortcut: %@ · Click to change it", label))
            .accessibilityLabel(choosing ? tr("Press the new shortcut, or Esc to keep %@", label) : tr("Shortcut: %@ · Click to change it", label))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(headlineTint)
                Text(subline)
                    .font(.system(size: 10.5)).foregroundStyle(refused ? Color.orange : Palette.muted)
                    .lineLimit(choosing ? 4 : 1).fixedSize(horizontal: false, vertical: choosing)
            }
            Spacer(minLength: 2)
            // With the locked microphone away, the press opens Settings, where it is chosen.
            Button {
                if micOffline && !recording { if settings.page != .settings { settings.toggleSettings() } } else { controller.toggle() }
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(fill, in: Circle())
                    .overlay(Circle().stroke(rim, lineWidth: 1))
                    .overlay { if recording && !Motion.reduced { RecordingRing() } }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { recordButtonHovered = $0 }
            .disabled(processing).opacity(processing ? 0.35 : 1)
            .help(buttonHelp)
            .accessibilityLabel(recording ? tr("Stop recording") : tr("Start recording"))
        }
        .padding(10)
        .background(stripFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(stripRim, lineWidth: 1))
        .animation(Motion.standard, value: controller.phase)
        .animation(Motion.standard, value: micOffline)
    }

    private struct Step: Identifiable {
        let id: String
        let title: String
        let detail: String
        let buttonTitle: String
        let action: () -> Void
    }

    private var missing: [Step] {
        var steps: [Step] = []
        if !receiving && !settings.hasKey {
            steps.append(Step(id: "key", title: tr("Add an API key"), detail: tr("Stored encrypted in the keychain"), buttonTitle: tr("Set up")) { settings.reveal(.connection) })
        }
        if !receiving && !settings.microphoneAllowed {
            steps.append(Step(id: "microphone", title: tr("Allow microphone access"), detail: tr("Audio is captured only while you record"), buttonTitle: tr("Grant access")) { settings.requestMicrophone() })
        }
        if !settings.accessibilityAllowed {
            steps.append(Step(id: "accessibility", title: tr("Allow Accessibility access"), detail: receiving ? tr("Used to type text at the cursor") : tr("Used for the shortcut and for typing text"), buttonTitle: tr("Grant access")) {
                settings.requestAccessibility()
            })
        } else if !receiving && !controller.hotkeyInstalled {
            steps.append(Step(id: "shortcut", title: tr("Turn on the shortcut"), detail: tr("Takes over the key so it does not trigger system actions"), buttonTitle: tr("Set up")) { settings.reveal(.keyboard) })
        }
        return steps
    }

    /// Learn from corrections: a word the user changed after put wrote it, offered for the
    /// personal dictionary; nothing is added without tapping Add.
    private var learnedCard: some View {
        Card {
            HStack(spacing: 8) {
                Circle().fill(Color.orange).frame(width: 5.5, height: 5.5)
                Text(tr("Corrected after dictation: add “%@” to the personal dictionary?", controller.learnedWord ?? ""))
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Button(tr("Add")) { controller.acceptLearned() }.buttonStyle(SolidButton())
                Button(tr("Don't add")) { controller.declineLearned() }.buttonStyle(QuietButton())
            }
        }
    }

    private var setupCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Finish these steps to start (%ld)", shownSteps.count)).font(.system(size: 12, weight: .semibold))
                ForEach(shownSteps) { step in
                    HStack(spacing: 8) {
                        Circle().fill(Color.orange).frame(width: 5.5, height: 5.5)
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(step.title).font(.system(size: 12, weight: .medium))
                            Text(step.detail).font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 4)
                        Button(step.buttonTitle, action: step.action).buttonStyle(QuietButton())
                    }
                }
            }
        }
    }

    private var resultCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                words(shownResult.message, color: shownResult.failed ? Color.orange : Palette.muted)
                if !shownResult.text.isEmpty {
                    CopyableText(
                        shownResult.text,
                        font: .system(size: 12.5),
                        color: Palette.ink,
                        lineSpacing: 3,
                        lineLimit: 6,
                        block: true
                    )
                    HStack {
                        if let latency = shownResult.latency {
                            Text(String(format: "%.2f s", latency)).font(.system(size: 10.5)).monospacedDigit()
                                .foregroundStyle(Palette.muted).help(tr("Time from the final key press until the text was typed"))
                        }
                        Spacer()
                        CopyActionButton(text: shownResult.text, title: tr("Copy text")) {
                            controller.copyResult()
                        }
                    }
                }
            }
        }
    }

    /// The text another Mac sent last: from which Mac and when, the text, and what became of it here
    /// (user 2026-11-25). It stays until the next one; History keeps them all.
    private func receivedCard(_ received: DictationController.ReceivedText) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 10.5)).accessibilityLabel(tr("Received"))
                    // A long name gives way; the time stays whole.
                    Text(tr("From %@", received.from)).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Text("· " + received.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).fixedSize()
                    Spacer(minLength: 4)
                    CopyActionButton(text: received.text)
                }
                .foregroundStyle(Palette.muted)
                CopyableText(received.text, font: .system(size: 12.5), color: Palette.ink, lineSpacing: 3, lineLimit: 6, block: true)
                Text(received.status).font(.system(size: 10.5))
                    .foregroundStyle(received.written ? Palette.muted : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(received.id)
    }

    private func isFolded(_ section: PanelSection) -> Bool {
        settings.preferences.foldedBlocks.contains(String(describing: section))
    }

    private func blockHeader(_ section: PanelSection, title: String, detail: String, more: String? = nil, less: String = "") -> some View {
        let folded = isFolded(section)
        return HStack(spacing: 7) {
            Button {
                let key = String(describing: section)
                if folded { settings.preferences.foldedBlocks.removeAll { $0 == key } }
                else {
                    settings.preferences.foldedBlocks.append(key)
                    if settings.section == section { settings.section = nil }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(folded ? 0 : 90)).frame(width: 9)
                        .animation(Motion.standard, value: folded)
                    Image(systemName: section.symbol).font(.system(size: 11)).frame(width: 15)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer(minLength: 6)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(folded ? tr("Expand") : tr("Collapse")).accessibilityLabel(folded ? tr("Expand %@", title) : tr("Collapse %@", title))
            if !folded, let more {
                Button(settings.section == section ? less : more) { settings.section = settings.section == section ? nil : section }
                    .buttonStyle(QuietButton())
            }
        }
    }

    private var remoteSummary: String {
        guard settings.preferences.linkEnabled else { return tr("This Mac only") }
        if [.missing, .stopped, .noTunnel].contains(controller.helperState) { return tr("No helper") }
        let count = settings.preferences.devices.count
        return count == 0 ? tr("No other Mac") : count == 1 ? tr("1 Mac") : tr("%ld Macs", count)
    }

    private var remoteCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                blockHeader(.remote, title: tr("Multiple Macs"), detail: remoteSummary)
                Reveal(open: !isFolded(.remote)) {
                    RemoteSection(settings: settings, controller: controller, shelf: controller.shelf)
                        .disabled(controller.busy)
                        .padding(.top, 8)
                }
            }
        }
    }
}

struct MicrophoneOptionRow: View {
    let title: String
    let badge: String
    let symbol: String
    let active: Bool
    var warning: Bool = false
    let action: () -> Void
    @State private var hovered = false

    // Written out: the private @State makes the synthesized one file-private, and the settings
    // page builds these rows from another file.
    init(title: String, badge: String, symbol: String, active: Bool, warning: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.badge = badge
        self.symbol = symbol
        self.active = active
        self.warning = warning
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(warning ? Color.orange : active ? Palette.accent : Palette.muted)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(warning ? Color.orange : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(badge)
                    .font(.system(size: 10, weight: active || warning ? .semibold : .regular))
                    .foregroundStyle(warning ? Color.orange : active ? Palette.accent : Palette.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .background(
                warning ? Color.orange.opacity(0.11)
                        : active ? Palette.accent.opacity(hovered ? 0.19 : 0.14)
                        : Color.primary.opacity(hovered ? 0.09 : 0.045),
                in: RoundedRectangle(cornerRadius: 7.5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .stroke(
                        warning ? Color.orange.opacity(0.35)
                                : active ? Palette.accent.opacity(0.42)
                                : Palette.line,
                        lineWidth: 0.8
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(title), \(badge)")
    }
}

/// Multiple Macs: on or off, and the owner's other Macs as the Monitor helper on this Mac lists
/// them (HelperLink). Nothing is paired here: the Macs are the ones on the owner's Monitor page,
/// which tells their helpers about each other.
struct RemoteSection: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    @ObservedObject var shelf: ShelfModel

    var body: some View {
        let on = settings.preferences.linkEnabled
        return VStack(alignment: .leading, spacing: 0) {
            Row(tr("Work across Macs"), info: tr("When on, out on this Mac connects to out on your other Macs through the Monitor helper, types text on the one you are controlling by remote desktop, and keeps the Shelf in sync. The Macs are the ones on your Monitor page; nothing is paired here.")) {
                Toggle(tr("Work across Macs"), isOn: $settings.preferences.linkEnabled).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    .onChange(of: settings.preferences.linkEnabled) { _, _ in controller.linkChanged() }
            }
            Reveal(open: on && !(problem ?? "").isEmpty) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.shield").font(.system(size: 11)).foregroundStyle(.orange).padding(.top, 2)
                        words(problem ?? "", color: .orange)
                    }
                    // The helper is installed from the Monitor page, whose line carries the account and the
                    // key the Macs trust: its Install window opens with put's switch on.
                    if controller.linkProblem.isEmpty && [.missing, .stopped, .noTunnel].contains(controller.helperState) {
                        Button(tr("Install the helper on the Monitor page")) { NSWorkspace.shared.open(HelperLink.installPage) }
                            .buttonStyle(QuietButton())
                    }
                }.padding(.top, 8)
            }
            Reveal(open: on && problem == nil) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(settings.preferences.devices) { device in row(device) }
                    if settings.preferences.devices.isEmpty {
                        caption(tr("No other Mac with out is on your Monitor page yet. Open the Monitor page once: while it is open, it tells your Macs about each other.")).padding(.top, 8)
                    }
                }
            }
            Reveal(open: !on) {
                caption(tr("Text is typed on this Mac only. When on, results go to the Mac you are controlling by remote desktop, and the Shelf is shared.")).padding(.top, 8)
            }
            // While another Mac's out shows this screen (user 2026-11-25: no switch for the Monitor
            // page; its screen follows the helper's console switch).
            Reveal(open: controller.screenState == .viewing) { screenStatus.padding(.top, 10) }
        }
        .onAppear { controller.refreshHelper(force: true); controller.testPeers() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            controller.refreshHelper(); controller.testPeers()
        }
    }

    /// Who is viewing this screen, with a press to stop it.
    @ViewBuilder private var screenStatus: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.accent).frame(width: 6, height: 6)
            Text(tr("Being viewed from %@", controller.screen.viewer ?? ""))
                .font(.system(size: 11)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button(tr("Stop")) { controller.screen.stopViewing() }.buttonStyle(QuietButton())
        }
    }

    /// What stands in the way, if anything: this Mac's keys, or its helper.
    private var problem: String? {
        if !controller.linkProblem.isEmpty { return controller.linkProblem }
        switch controller.helperState {
        case .missing: return tr("out works across Macs through the Monitor helper. Install it on this Mac from the Monitor page, or update it if it is installed.")
        case .stopped: return tr("The Monitor helper on this Mac is not running.")
        case .noTunnel: return tr("The Monitor helper on this Mac has no direct connection. Install it from the Monitor page with direct connections on.")
        case .checking, .ready: return nil
        }
    }

    private func row(_ device: TrustedDevice) -> some View {
        let called = controller.peerReachable[device.key], calledIn = shelf.linkedKeys.contains(device.key)
        let ok: Bool? = calledIn ? true : called
        // Its screen on its way: the row says so where it says Online (user 2026-11-25: not a turning
        // sign; the window still comes only once connected, with its first picture).
        let opening = controller.screenOpening.contains(device.key)
        let status = opening ? tr("Connecting…")
            : controller.peerTesting.contains(device.key) ? tr("Checking…")
            : ok == true ? tr("Online") : ok == false ? tr("Not connected") : tr("Not checked")
        return HStack(spacing: 6) {
            Circle().fill(ok == true ? Palette.accent : ok == false ? Color.orange : Palette.muted.opacity(0.5))
                .frame(width: 6, height: 6)
            // The name keeps its room before the status does; neither may make the row wider than
            // the panel (user 2026-11-26: a status held at its full width, "Connecting to the remote
            // window…" in English, pushed the panel's content past both its edges).
            Text(device.label).font(.system(size: 12))
                .lineLimit(1).layoutPriority(1)
            // Its screen in a window of out's own (user 2026-11-21): a Mac reached through the helper,
            // and not one whose out has said it has no Apple silicon (user 2026-11-25: an Intel Mac
            // cannot be shown in High Performance, so it has no button).
            if HelperLink.agent(of: device.host) != nil, controller.peerAppleSilicon[device.key] != false {
                Button { ScreenViewer.show(device, controller: controller) } label: {
                    Image(systemName: "display")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(opening ? Palette.accent : Palette.ink.opacity(0.8))
                        .frame(width: 22, height: 18)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Show %@’s screen and work it from here", device.label))
                .accessibilityLabel(tr("Show %@’s screen", device.label))
            }
            // This Mac's microphone as that Mac's out Mic (user 2026-11-27: a virtual microphone there, for meetings).
            let link = controller.microphone
            let sending = link.sendingTo == device.key
            let micOpening = link.opening == device.key
            Button { controller.toggleMicrophone(device) } label: {
                Image(systemName: sending ? "mic.fill" : "mic")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(sending || micOpening ? Palette.accent : Palette.ink.opacity(0.8))
                    .frame(width: 22, height: 18)
                    .background(sending ? Palette.accent.opacity(0.16) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!device.reachable)
            .help(sending ? tr("Stop sending this Mac's microphone to %@", device.label)
                          : tr("Send this Mac's microphone to %@, where meeting apps pick it as out Mic", device.label))
            .accessibilityLabel(sending ? tr("Stop sending this Mac's microphone to %@", device.label) : tr("Send this Mac's microphone to %@", device.label))
            // That Mac's microphone is coming in here: a mark, not a control.
            if link.receivingFrom == device.key {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .help(tr("%@’s microphone comes in here as out Mic", device.label))
                    .accessibilityLabel(tr("%@’s microphone comes in here as out Mic", device.label))
            }
            Spacer(minLength: 6)
            let micProblem = link.problems[device.key]
            Text(micOpening ? tr("Connecting…") : micProblem != nil ? tr("Microphone not sent") : status)
                .font(.system(size: 10.5))
                .foregroundStyle(opening || micOpening ? Palette.accent : micProblem != nil || ok == false ? Color.orange : Palette.muted)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 6).padding(.vertical, 4.5)
        .help(controller.microphone.problems[device.key] ?? controller.peerStatus[device.key] ?? "")
        .padding(.top, 6)
    }
}

struct OverlaySizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 { value = next }
    }
}

/// The recording's level running across as wide as it is given, newest at the right edge, older
/// moments drifting left and fading at the left edge (user 2026-11-27: the bar kept on top showed five
/// short bars beside the time; nothing is transcribed while recording, so the waveform can take the
/// row and the time go to its end). Each bar is a fixed slice of time, the loudest level heard in it,
/// so the waveform runs at an even pace however often the microphone reports; slices nothing was
/// heard for are dots, so the line is whole from the start. With Reduce Motion it steps a slice at a
/// time instead of gliding.
struct LevelTrace: View {
    let meter: AudioMeter
    private static let bar: CGFloat = 2
    private static let pitch: CGFloat = 3.5
    private static let slice: TimeInterval = 0.06
    /// How far behind the moment the right edge runs: a moment's level is reported a little after it
    /// (the microphone's buffer, at most every 45 ms), and a slice is drawn once it is known.
    private static let lag: TimeInterval = 0.15

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            Canvas { graphics, size in
                let trace = meter.trace
                var end = context.date.timeIntervalSinceReferenceDate - Self.lag
                if Motion.reduced { end = (end / Self.slice).rounded(.down) * Self.slice }
                let newest = Int((end / Self.slice).rounded(.down))
                let middle = size.height / 2
                // Walks back through the trace as the slices go back in time.
                var index = trace.count
                for back in 0..<(Int(size.width / Self.pitch) + 2) {
                    let start = Double(newest - back) * Self.slice
                    let x = size.width - Self.bar - CGFloat((end - start) / Self.slice) * Self.pitch
                    guard x > -Self.bar else { break }
                    while index > 0 && trace[index - 1].at >= start { index -= 1 }
                    // The loudest level reported in the slice, else the next one after it (its buffer
                    // covered the slice), unless that came much later: nothing was heard then.
                    var level: Float?
                    if index < trace.count, trace[index].at - (start + Self.slice) < 0.25 {
                        var loudest = trace[index].level
                        var next = index + 1
                        while next < trace.count && trace[next].at < start + Self.slice { loudest = max(loudest, trace[next].level); next += 1 }
                        level = loudest
                    }
                    let height = max(Self.bar, pow(CGFloat(level ?? 0), 0.75) * size.height)
                    let rect = CGRect(x: x, y: middle - height / 2, width: Self.bar, height: height)
                    graphics.fill(Path(roundedRect: rect, cornerRadius: Self.bar / 2, style: .continuous),
                                  with: .color(CapsuleTint.green.opacity(level == nil ? 0.35 : 1)))
                }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14), .init(color: .black, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .accessibilityHidden(true)
    }
}

/// Isolated compact timer label driven solely by `AudioMeter`.
struct CapsuleClock: View {
    @ObservedObject var meter: AudioMeter
    let online: Bool

    var body: some View {
        let time = String(format: "%d:%02d", meter.elapsed / 60, meter.elapsed % 60)
        Text(online ? time : tr("%@ · Offline", time))
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .fixedSize()
            // Only the digits that change roll (user 2026-11-26, the chosen demo).
            .contentTransition(.numericText())
            .animation(Motion.reduced ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: meter.elapsed)
    }
}

/// The ring that turns while the capsule (or the bar kept on top) waits for something.
struct CapsuleSpinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            Circle().trim(from: 0.08, to: 0.78)
                .stroke(Palette.ink.opacity(0.85), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .frame(width: 11.5, height: 11.5)
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 260))
        }
        .frame(width: 14, height: 14)
    }
}

/// Reports the pointer entering and leaving, whichever app is active: SwiftUI's own hover follows
/// only while this app is, and the capsule sits over other apps.
struct HoverArea: NSViewRepresentable {
    var onChange: (Bool) -> Void
    final class Area: NSView {
        var onChange: (Bool) -> Void = { _ in }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }
    func makeNSView(context: Context) -> Area { let area = Area(); area.onChange = onChange; return area }
    func updateNSView(_ area: Area, context: Context) { area.onChange = onChange }
}

/// The colours the capsule tints its glass with, each in a shade for light and for dark glass.
enum CapsuleTint {
    private static func pair(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    static let green = pair(light: (0.11, 0.60, 0.29), dark: (0.30, 0.86, 0.47))
    static let amber = pair(light: (0.78, 0.47, 0.03), dark: (0.98, 0.70, 0.22))
    static let red = pair(light: (0.80, 0.23, 0.16), dark: (1.00, 0.46, 0.38))
    /// The mark drawn on a filled sign, as the glass shows through a symbol's cut-out mark.
    static let knockout = pair(light: (1, 1, 1), dark: (0.13, 0.13, 0.14))
}

/// The same glass as the panel, light or dark with the system (user 2026-11-20). The state is a
/// tint over it: green that swells with the voice while speaking, green when done, amber when the
/// text is not where it was meant to go, red on an error. A finished state's colour comes in as its
/// sign fills, a moment after the ring has closed (user 2026-11-26, the chosen demo).
private struct CapsuleSurface: View {
    let phase: DictationPhase
    @ObservedObject var meter: AudioMeter
    /// Off only for still images, which have nothing behind them to blur.
    let glass: Bool
    /// Done, but the text is not where it was meant to go: amber, not green.
    var warning = false

    var body: some View {
        let level = phase == .recording ? Double(meter.level) : 0
        let tint: Color? = switch phase {
        case .recording: CapsuleTint.green
        case .done: warning ? CapsuleTint.amber : CapsuleTint.green
        case .error: CapsuleTint.red
        case .processing, .receiving, .idle: nil
        }
        let strength: Double = switch phase {
        case .recording: 0.24 + level * 0.26
        case .done, .error: 0.18
        case .processing, .receiving, .idle: 0
        }
        surface(tint: tint, strength: strength, level: level)
            .animation(.easeOut(duration: 0.09), value: meter.level)
            .animation(colourChange, value: colourKey)
    }

    /// The glass's colour, as one value.
    private var colourKey: Int {
        switch phase {
        case .recording: 1
        case .done: warning ? 3 : 2
        case .error: 4
        case .processing, .receiving, .idle: 0
        }
    }

    private var colourChange: Animation {
        if Motion.reduced { return .easeOut(duration: 0.18) }
        return phase == .done || phase == .error ? .easeOut(duration: 0.32).delay(0.16) : .easeOut(duration: 0.24)
    }

    /// Liquid Glass on macOS 26 and later (user 2026-11-26, the demo at m2:8847): the state is the
    /// glass's own tint, the edge and shadow are the glass's, and only a state keeps its coloured
    /// edge and, while speaking, its green glow. Before it, and for still images, as it was.
    @ViewBuilder private func surface(tint: Color?, strength: Double, level: Double) -> some View {
        let shade: Color? = tint?.opacity(strength)
        let width: CGFloat = phase == .recording ? 1 : 0.8
        let glow: Color = phase == .recording ? CapsuleTint.green.opacity(0.30 + level * 0.30) : Color.clear
        let radius: CGFloat = 5 + CGFloat(level) * 2.0
        if glass {
            if #available(macOS 26, *) {
                Color.clear
                    .glassEffect(.regular.tint(shade), in: Capsule(style: .continuous))
                    .overlay {
                        if let tint { Capsule(style: .continuous).strokeBorder(tint.opacity(0.45), lineWidth: width) }
                    }
                    .shadow(color: glow, radius: radius, x: 0, y: 1.5)
            } else {
                frosted(Glass(), tint: tint, strength: strength, level: level)
            }
        } else {
            frosted(Color(nsColor: .windowBackgroundColor).opacity(0.94), tint: tint, strength: strength, level: level)
        }
    }

    private func frosted<Base: View>(_ base: Base, tint: Color?, strength: Double, level: Double) -> some View {
        let edge: Color = (tint ?? Color.primary).opacity(tint == nil ? 0.12 : 0.45)
        let width: CGFloat = phase == .recording ? 1 : 0.8
        let glow: Color = phase == .recording ? CapsuleTint.green.opacity(0.30 + level * 0.30) : Color.black.opacity(0.18)
        let radius: CGFloat = phase == .recording ? 5 + CGFloat(level) * 2.0 : 4
        let shade: Color? = tint?.opacity(strength)
        return ZStack {
            base
            if let shade { shade }
        }
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(edge, lineWidth: width))
        .shadow(color: glow, radius: radius, x: 0, y: 1.5)
    }
}

/// The capsule's sign: one drawing through every state, so that each change is a movement rather
/// than a swap (user 2026-11-26, the chosen demo). The waveform gathers into the ring; the
/// ring slows, closes and takes the state's colour; the filled circle springs out of it and its mark
/// draws itself. "Not typed" is an amber circle like the red one of an error, so that it comes the
/// same way. With Reduce Motion each state's sign only dissolves into the next.
struct CapsuleGlyph: View {
    enum Kind: Equatable { case wave, ring, done, warning, error }
    let kind: Kind
    @ObservedObject var meter: AudioMeter
    /// The side of the sign's square: 15 in the capsule. The waveform is as wide as 19 of that.
    var side: CGFloat = 15

    @State private var spinFrom = Date()
    @State private var stoppedAt: Date?
    @State private var settling = false

    private var unit: CGFloat { side / 15 }
    private var finished: Bool { kind == .done || kind == .warning || kind == .error }
    private var tint: Color { kind == .warning ? CapsuleTint.amber : kind == .error ? CapsuleTint.red : CapsuleTint.green }

    var body: some View {
        Group {
            if Motion.reduced {
                ZStack { still.id(kind).transition(.opacity) }
                    .animation(.easeOut(duration: 0.16), value: kind)
            } else {
                moving
            }
        }
        .frame(width: (kind == .wave ? 19 : 15) * unit, height: side)
        .onChange(of: kind) { old, new in
            if new == .ring, old != .ring { spinFrom = Date(); stoppedAt = nil }
            if old == .ring, new != .ring {
                stoppedAt = Date()
                settling = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    settling = false
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var still: some View {
        switch kind {
        case .wave: GlyphWave(meter: meter, gathered: false, unit: unit)
        case .ring: ring(to: 0.7, colour: Palette.ink.opacity(0.85))
        case .done, .warning, .error: ZStack { disk; mark(check: kind == .done, drawn: true) }
        }
    }

    private var moving: some View {
        let gathered = kind != .wave
        let arcEnd: CGFloat = kind == .wave ? 0 : (finished ? 1 : 0.7)
        return ZStack {
            GlyphWave(meter: meter, gathered: gathered, unit: unit)
                .animation(.easeInOut(duration: 0.18), value: gathered)
            ring(to: arcEnd, colour: finished ? tint : Palette.ink.opacity(0.85))
                .animation(finished ? .easeOut(duration: 0.22) : .easeOut(duration: 0.3).delay(0.09), value: arcEnd)
                .opacity(kind == .ring ? 1 : 0)
                .animation(kind == .ring ? nil : .easeOut(duration: 0.12).delay(0.3), value: kind == .ring)
            disk
                .scaleEffect(finished ? 1 : 0.001)
                .animation(finished ? .spring(response: 0.32, dampingFraction: 0.62).delay(0.14) : nil, value: finished)
            mark(check: kind == .done, drawn: finished)
        }
    }

    private var disk: some View {
        Circle().fill(tint).frame(width: 12.4 * unit, height: 12.4 * unit)
    }

    /// The ring, turning at 260° a second; once stopped it slows to rest over 0.38 s.
    private func ring(to end: CGFloat, colour: Color) -> some View {
        TimelineView(.animation(minimumInterval: nil, paused: !(kind == .ring || settling))) { context in
            Circle()
                .trim(from: 0, to: end)
                .stroke(colour, style: StrokeStyle(lineWidth: 1.7 * unit, lineCap: .round))
                .frame(width: 11.2 * unit, height: 11.2 * unit)
                .rotationEffect(.degrees(angle(at: context.date) - 90))
        }
    }

    private func angle(at date: Date) -> Double {
        let speed = 260.0, rest = 0.38
        guard kind != .ring, let stop = stoppedAt else { return speed * date.timeIntervalSince(spinFrom) }
        let p = min(1, max(0, date.timeIntervalSince(stop) / rest))
        return speed * stop.timeIntervalSince(spinFrom) + speed * rest * (1 - pow(1 - p, 3)) / 3
    }

    private func mark(check: Bool, drawn: Bool) -> some View {
        let ink = CapsuleTint.knockout
        let line = StrokeStyle(lineWidth: 1.75 * unit, lineCap: .round, lineJoin: .round)
        let tick = drawn && check, bang = drawn && !check
        let moves = !Motion.reduced
        return ZStack {
            GlyphCheck().trim(from: 0, to: tick ? 1 : 0).stroke(ink, style: line)
                .animation(tick && moves ? .easeOut(duration: 0.24).delay(0.23) : nil, value: tick)
            GlyphBang().trim(from: 0, to: bang ? 1 : 0).stroke(ink, style: line)
                .animation(bang && moves ? .easeOut(duration: 0.17).delay(0.23) : nil, value: bang)
            GlyphDot().fill(ink)
                .scaleEffect(bang ? 1 : 0.001, anchor: UnitPoint(x: 0.5, y: 11.25 / 16))
                .animation(bang && moves ? .spring(response: 0.32, dampingFraction: 0.62).delay(0.33) : nil, value: bang)
        }
        .frame(width: 15 * unit, height: 15 * unit)
    }
}

/// The waveform of the capsule's sign; gathered, its bars shrink to dots, meet in the middle and go.
private struct GlyphWave: View {
    @ObservedObject var meter: AudioMeter
    let gathered: Bool
    let unit: CGFloat
    private static let weights: [CGFloat] = [7.5, 13, 9.5, 14, 8.5]

    var body: some View {
        HStack(spacing: 2 * unit) {
            ForEach(0..<5, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(CapsuleTint.green)
                    .frame(width: 2.2 * unit,
                           height: gathered ? 2.2 * unit : max(3.5, CGFloat(meter.level) * Self.weights[index]) * unit)
                    .offset(x: gathered ? CGFloat(2 - index) * 4.2 * unit : 0)
                    .opacity(gathered ? 0 : 1)
            }
        }
        .frame(width: 19 * unit, height: 14 * unit)
        .animation(.easeOut(duration: 0.08), value: meter.level)
    }
}

/// The check, the stroke and the dot of the capsule's sign, drawn on a 16-unit square.
private struct GlyphCheck: Shape {
    func path(in rect: CGRect) -> Path {
        let u = rect.width / 16
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 5 * u, y: rect.minY + 8.3 * u))
        path.addLine(to: CGPoint(x: rect.minX + 7.1 * u, y: rect.minY + 10.35 * u))
        path.addLine(to: CGPoint(x: rect.minX + 11.05 * u, y: rect.minY + 5.9 * u))
        return path
    }
}

private struct GlyphBang: Shape {
    func path(in rect: CGRect) -> Path {
        let u = rect.width / 16
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 8 * u, y: rect.minY + 4.5 * u))
        path.addLine(to: CGPoint(x: rect.minX + 8 * u, y: rect.minY + 8.7 * u))
        return path
    }
}

private struct GlyphDot: Shape {
    func path(in rect: CGRect) -> Path {
        let u = rect.width / 16, r = 1.05 * u
        return Path(ellipseIn: CGRect(x: rect.minX + 8 * u - r, y: rect.minY + 11.25 * u - r, width: 2 * r, height: 2 * r))
    }
}

/// How the capsule's words change (user 2026-11-26, the chosen demo): the old words go up
/// and the new ones come up from below, each a little blurred. With Reduce Motion they dissolve.
extension AnyTransition {
    @MainActor static var capsuleWords: AnyTransition {
        guard !Motion.reduced else { return .opacity.animation(.easeOut(duration: 0.16)) }
        return .asymmetric(
            insertion: .modifier(active: WordsRoll(y: 7, blur: 2, opacity: 0), identity: WordsRoll(y: 0, blur: 0, opacity: 1))
                .animation(.spring(response: 0.30, dampingFraction: 0.9).delay(0.07)),
            removal: .modifier(active: WordsRoll(y: -7, blur: 2, opacity: 0), identity: WordsRoll(y: 0, blur: 0, opacity: 1))
                .animation(.easeIn(duration: 0.16)))
    }
}

private struct WordsRoll: ViewModifier {
    let y: CGFloat
    let blur: CGFloat
    let opacity: Double
    func body(content: Content) -> some View { content.offset(y: y).blur(radius: blur).opacity(opacity) }
}

/// How the status capsule comes and goes in its window (AppDelegate.showOverlay and hideOverlay).
final class CapsuleStage: ObservableObject {
    /// On screen and arrived; false before it arrives and once it has gone.
    @Published var shown: Bool
    /// Going: the words go, the capsule gathers round its sign, then shrinks away.
    @Published var leaving = false
    /// The corner of its window the capsule keeps to, as the window is placed (OverlayPlacement).
    @Published var corner: OverlayPlacement.AnchorCorner = .topCenter
    init(shown: Bool = true) { self.shown = shown }
}

/// The size of what is in the capsule, as it lays itself out.
private struct CapsuleContentSize: PreferenceKey {
    static let defaultValue: CGSize = .zero
    /// The view that measures is not the only one asked: the others say zero, which is not a size.
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 { value = next }
    }
}

/// A frame laid out afresh on every frame of its animation (a plain frame's content and clip take the
/// new size at once and only its drawing moves). Zero leaves the content at its own size.
private struct SpringFrame: ViewModifier, Animatable {
    var size: CGSize
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set { size = CGSize(width: newValue.first, height: newValue.second) }
    }
    func body(content: Content) -> some View {
        content.frame(width: size.width > 0 ? size.width : nil, height: size.height > 0 ? size.height : nil, alignment: .leading)
    }
}

private struct BloomState {
    var scale: CGFloat = 0.6
    var opacity: Double = 0
}

/// Miniature floating status capsule — glass like the panel, tinted green while speaking, and
/// docks predictably right below the top menu bar without obstructing sight. Every change of state
/// moves (user 2026-11-26, "the change to done is rough"; the chosen demo): its size
/// springs, its words roll, its sign turns from one state into the next, and it arrives and goes
/// with a movement of its own.
struct VoiceBar: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var meter: AudioMeter
    @ObservedObject var settings: SettingsStore
    @ObservedObject var stage: CapsuleStage
    var glass = true
    /// In the overlay's window, which is larger than the capsule while the capsule changes size: the
    /// capsule keeps to the window's anchor corner. Off for measuring and for still images.
    var fillWindow = false
    var onSize: ((CGSize) -> Void)? = nil
    /// Keeps the window on top where it is (user 2026-11-21: the capsule and the bar kept on top are
    /// one window): a pin button that shows while the pointer is over the capsule.
    var onPin: (() -> Void)? = nil
    /// For still images: the pin as the pointer over the capsule shows it.
    var pinShownForPreview = false
    @State private var copied = false
    @State private var copyToken = UUID()
    @State private var pointerOver = false
    @State private var pointerLeft = UUID()
    @State private var bloomCount = 0
    /// The size the capsule shows, springing to the size of what is in it (follow).
    @State private var drawn: CGSize = .zero

    init(
        controller: DictationController,
        meter: AudioMeter? = nil,
        settings: SettingsStore,
        stage: CapsuleStage? = nil,
        glass: Bool = true,
        fillWindow: Bool = false,
        onSize: ((CGSize) -> Void)? = nil,
        onPin: (() -> Void)? = nil,
        pinShownForPreview: Bool = false
    ) {
        self.controller = controller
        self.meter = meter ?? controller.meter
        self.settings = settings
        self.stage = stage ?? CapsuleStage()
        self.glass = glass
        self.fillWindow = fillWindow
        self.onSize = onSize
        self.onPin = onPin
        self.pinShownForPreview = pinShownForPreview
    }

    private var pinShown: Bool { onPin != nil && (pointerOver || pinShownForPreview) }
    /// The room the pin takes, given back by the words so the capsule stays inside its window.
    private var pinRoom: CGFloat { pinShown ? 25 : 0 }

    private var copyablePayload: String {
        // Nothing of the incoming text is here yet.
        if controller.phase == .receiving { return "" }
        if controller.phase == .recording, !controller.partial.isEmpty { return controller.partial }
        if !controller.result.isEmpty { return controller.result }
        if controller.phase == .error, !controller.message.isEmpty { return controller.message }
        return ""
    }

    var body: some View {
        let reduced = Motion.reduced
        let arrived = stage.shown && !stage.leaving
        let fromTop = stage.corner == .topCenter || stage.corner == .topLeading || stage.corner == .topTrailing
        let away: CGFloat = stage.leaving ? 6 : 8
        capsule
            // Arriving, it drops in from its corner's side of the screen, a little small; going, once
            // gathered round its sign, it shrinks away the same way.
            .scaleEffect(arrived || reduced ? 1 : (stage.leaving ? 0.55 : 0.94))
            .offset(y: arrived || reduced ? 0 : (fromTop ? -away : away))
            .opacity(arrived ? 1 : 0)
            .animation(reduced ? .easeOut(duration: 0.18)
                       : arrived ? .spring(response: 0.38, dampingFraction: 0.82) : .easeIn(duration: 0.2).delay(0.3),
                       value: arrived)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            // Without the pointer (VoiceOver), keeping on top is an action of the capsule.
            .accessibilityAction(named: Text(tr("Keep on Top"))) { onPin?() }
            // The pin stays a moment after the pointer leaves, so that it can be reached across the gap.
            .background(HoverArea { inside in
                let token = UUID()
                pointerLeft = token
                if inside { pointerOver = true; return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if pointerLeft == token { pointerOver = false } }
            })
            // A change of language builds the words again everywhere below.
            .id(settings.preferences.language)
            .frame(maxWidth: fillWindow ? .infinity : nil, maxHeight: fillWindow ? .infinity : nil, alignment: anchor)
    }

    /// The capsule itself. Going (stage.leaving), only its sign stays, in a circle that fits it.
    private var capsule: some View {
        let leaving = stage.leaving && !Motion.reduced
        return HStack(spacing: 7) {
            CapsuleGlyph(kind: glyphKind, meter: meter)
            if !leaving {
                ZStack(alignment: .leading) {
                    labelContent
                        .id(wordsKey)
                        .transition(.capsuleWords)
                }
                .transition(.capsuleWords)
                trailingControls
                    .transition(.opacity.animation(.easeIn(duration: 0.13)))
            }
        }
        .padding(.leading, leaving ? 6.5 : 11)
        .padding(.trailing, leaving ? 6.5 : (hasTrailingButtons ? 6 : 11))
        .padding(.vertical, 5.5)
        .frame(minHeight: 28)
        .animation(shapeAnimation(leaving: leaving), value: shapeKey)
        .fixedSize()
        // Its own size, which the capsule springs to: the frame is laid out afresh on every frame of
        // the spring, so the words, the glass and the clip all follow it, and what does not fit yet is
        // cut off at the capsule's edge.
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CapsuleContentSize.self, value: proxy.size)
        })
        .onPreferenceChange(CapsuleContentSize.self) { size in follow(size) }
        .modifier(SpringFrame(size: drawn))
        .clipShape(Capsule(style: .continuous))
        .foregroundStyle(Palette.ink)
        .background {
            ZStack {
                CapsuleSurface(phase: controller.phase, meter: meter, glass: glass, warning: notTyped)
                bloom
                WindowDragArea().clipShape(Capsule(style: .continuous))
            }
        }
        .onChange(of: glyphKind) { old, new in
            let finishing = new == .done || new == .warning || new == .error
            if finishing, old == .ring || old == .wave, !Motion.reduced { bloomCount += 1 }
        }
    }

    /// The size of what is in the capsule changed: the window is told the size it is going to (with
    /// room round it for its shadow and its arrival), and the capsule springs to it. Before it has
    /// arrived, it takes the size at once.
    private func follow(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        onSize?(CGSize(width: size.width + 20, height: size.height + 18))
        guard size != drawn else { return }
        // With Reduce Motion the window takes the new size at once, and so does the capsule.
        guard drawn != .zero, stage.shown, !Motion.reduced else { drawn = size; return }
        withAnimation(shapeAnimation(leaving: stage.leaving)) { drawn = size }
    }

    /// The state's colour spreading from the sign across the capsule as the sign fills, then giving
    /// way to the glass's own lighter tint.
    private var bloom: some View {
        GeometryReader { proxy in
            let reach = max(4, proxy.size.width * 2.2 / 16)
            KeyframeAnimator(initialValue: BloomState(), trigger: bloomCount) { value in
                Circle()
                    .fill(glyphTint)
                    .frame(width: 16, height: 16)
                    .scaleEffect(value.scale)
                    .opacity(value.opacity)
                    .position(x: 11 + 7.5, y: proxy.size.height / 2)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: 0.15)
                    MoveKeyframe(0.55)
                    LinearKeyframe(0, duration: 0.52, timingCurve: .easeOut)
                }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.6, duration: 0.15)
                    LinearKeyframe(reach, duration: 0.52, timingCurve: .easeOut)
                }
            }
        }
        .clipShape(Capsule(style: .continuous))
        .allowsHitTesting(false)
    }

    private var glyphKind: CapsuleGlyph.Kind {
        switch controller.phase {
        case .recording: .wave
        case .processing, .receiving: .ring
        case .error: .error
        case .done, .idle: notTyped ? .warning : .done
        }
    }

    private var glyphTint: Color {
        switch glyphKind {
        case .warning: CapsuleTint.amber
        case .error: CapsuleTint.red
        default: CapsuleTint.green
        }
    }

    /// What the words say, as one value: a new value rolls the words. Recording keeps one value, so
    /// that only the clock's changed digits roll.
    private var wordsKey: String {
        if copied { return "copied" }
        if controller.phase == .recording { return "recording" }
        if controller.phase == .done, case let .notWritten(title, detail) = controller.capsuleResult { return "not-written \(title) \(detail)" }
        return "\(controller.phase) \(controller.capsuleSummary)"
    }

    /// What decides the capsule's size, as one value: a new value springs it to its new size.
    private var shapeKey: String {
        "\(stage.leaving) \(hasTrailingButtons) \(pinShown) \(wordsKey)"
    }

    private func shapeAnimation(leaving: Bool) -> Animation {
        if Motion.reduced { return .easeInOut(duration: 0.18) }
        return leaving ? .spring(response: 0.30, dampingFraction: 0.9).delay(0.06) : .spring(response: 0.34, dampingFraction: 0.86)
    }

    private var anchor: Alignment {
        switch stage.corner {
        case .topCenter: .top
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    private var notTyped: Bool {
        if controller.phase == .done, case .notWritten = controller.capsuleResult { return true }
        return false
    }

    /// Cancel while busy, Close on an error.
    private var closable: Bool {
        controller.phase == .recording || controller.phase == .processing || controller.phase == .error
    }

    private var hasTrailingButtons: Bool { closable || pinShown }

    @ViewBuilder private var labelContent: some View {
        if copied {
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
                Text(tr("Copied")).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Palette.ink)
        } else if controller.phase == .recording {
            HStack(spacing: 5) {
                CapsuleClock(meter: meter, online: controller.recordingOnline)
                if !controller.partial.isEmpty {
                    Text("·").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.muted)
                    Button(action: copyFromCapsule) {
                        Text(String(controller.partial.suffix(12)))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: 96, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("Click to copy the text recognized so far"))
                }
            }
        } else if controller.phase == .done, case let .notWritten(title, detail) = controller.capsuleResult {
            // Which Mac, and why the text is not there: two short lines, each cut short to stay inside
            // the capsule's window (the tooltip and the panel have the whole of it).
            Button(action: copyFromCapsule) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: 210 - pinRoom, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("%@\nClick to copy", controller.message.isEmpty ? controller.capsuleSummary : controller.message))
        } else {
            let text = controller.capsuleSummary
            // Text on its way between two Macs names the other Mac: more room than a step's word.
            // Up to the capsule window's 284 pt: the sending capsule also holds its Cancel button.
            let remote: CGFloat? = controller.phase == .receiving ? 210 - pinRoom
                : controller.phase == .processing && controller.capsuleStep == .sending ? 194 - pinRoom : nil
            if !copyablePayload.isEmpty {
                Button(action: copyFromCapsule) {
                    Text(text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        // A long Mac name gives way in its middle, so the words around it stay.
                        .truncationMode(remote == nil ? .tail : .middle)
                        .frame(maxWidth: remote ?? 152 - pinRoom, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("%@\nClick to copy", text))
            } else {
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(remote == nil ? .tail : .middle)
                    .frame(maxWidth: remote ?? 140 - pinRoom, alignment: .leading)
                    .help(text)
            }
        }
    }

    @ViewBuilder private var trailingControls: some View {
        HStack(spacing: 3.5) {
            if controller.phase == .recording {
                Button { controller.finish() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.12), in: Circle())
                        .frame(width: 21, height: 21)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tr("Stop recording (%@)", settings.shortcutLabel))
                .accessibilityLabel(tr("Stop recording"))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if closable {
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
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if pinShown, let onPin {
                Button(action: onPin) {
                    Image(systemName: "pin")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Palette.ink.opacity(0.85))
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.09), in: Circle())
                        .frame(width: 21, height: 21)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tr("Keep on Top: always shown here"))
                .accessibilityLabel(tr("Keep on Top"))
                .transition(.opacity)
            }
        }
    }

    private func copyFromCapsule() {
        let value = copyablePayload
        guard !value.isEmpty else { return }
        ClipboardCopy.copy(value)
        let current = UUID()
        copyToken = current
        withAnimation(Motion.quick) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copyToken == current {
                withAnimation(Motion.quick) { copied = false }
            }
        }
    }
}
