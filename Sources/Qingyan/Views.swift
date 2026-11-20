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
    static let titlebar: CGFloat = 30
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
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Palette.accent.opacity(0.4), lineWidth: 0.75))
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

private struct HeaderIconButton: View {
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
    }
}

extension View {
    /// A text field without the system's opaque bezel.
    func glassField(mono: Bool = false) -> some View {
        textFieldStyle(.plain).font(.system(size: 12, design: mono ? .monospaced : .default))
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

/// How a dictation is written before it is entered, as a choice that says what it is. Only in
/// Settings: the panel never shows it (user 2026-11-20).
struct PolishChoice: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        let customs = settings.preferences.customStyles.filter(\.usable)
        let options: [(value: String, title: String)] =
            [("raw", tr("Raw")), ("polish", tr("Polish")), ("structured", tr("Structured")), ("formal", tr("Formal"))]
            + customs.map { (value: $0.id.uuidString, title: $0.name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        Row(tr("Style"), info: tr("Raw enters the recognized text as is.\nPolish adds punctuation and paragraph breaks and removes filler words and spoken repetitions. Nothing is shortened, rewritten or translated; if the model strays from what was said, the original transcript is kept. With Polish you can also edit the text in the current field by voice (for example “change Wednesday to Thursday” or “clear everything”); the field's text is read only when what you said is taken as an edit command.\nStructured turns what you said into a clear prompt for an AI assistant: what you want first, then the details as numbered points.\nFormal rewrites it as formal written prose.\nA custom style follows the instructions written for it in Settings.\nStructured, Formal and custom styles change the wording, so their result is not compared with what was said, and editing by voice is not available with them.")) {
            GlassMenu(label: tr("Style"),
                      selection: Binding(
                        // An id that is not offered — a deleted or unfinished custom style — shows Raw.
                        get: { options.contains { $0.value == settings.preferences.style } ? settings.preferences.style : StyleChoice.standard },
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
        Group {
            if #available(macOS 26.0, *) {
                Menu { items } label: { HStack(spacing: 4) { Text(title).lineLimit(1); chevron } }
                    .menuStyle(.borderlessButton).fixedSize()
            } else {
                // Before macOS 26 a borderless menu button puts an image in its label first and adds an
                // arrow of its own, which made the model menus so wide that the Settings drawer
                // overflowed its edge: there the menu shows the name alone and the arrows sit beside it.
                HStack(spacing: 4) {
                    Menu { items } label: { Text(title).lineLimit(1) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    chevron.allowsHitTesting(false)
                }
            }
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

/// Small print under a control. Wraps and supports direct click-to-copy.
func caption(_ text: String) -> some View {
    CopyableText(text, font: .system(size: 10.5), color: Palette.muted, lineSpacing: 2)
}

/// The long explanation stays one hover away instead of taking panel height.
struct Info: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            .frame(width: 18, height: 18).contentShape(Rectangle())
            .help(text).accessibilityLabel(text)
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

/// A list that is as tall as its rows until `maxHeight`, then scrolls inside the panel.
struct FittedScroll<Content: View>: View {
    let maxHeight: CGFloat
    var content: Content
    @State private var height: CGFloat = 64
    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) { self.maxHeight = maxHeight; self.content = content() }
    var body: some View {
        ScrollView {
            content.background(GeometryReader { Color.clear.preference(key: ListHeightKey.self, value: $0.size.height) })
        }
        .frame(height: min(max(height, 1), maxHeight))
        .onPreferenceChange(ListHeightKey.self) { next in
            if abs(height - next) > 0.5 { height = next }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: showingSettings ? "gearshape" : PanelSection.history.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(showingSettings ? tr("Settings") : tr("History"))
                    .font(.system(size: 13, weight: .bold))
                if !showingSettings && !settings.history.isEmpty {
                    Text(settings.history.count == 1 ? tr("1 record") : tr("%ld records", settings.history.count)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
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

            ZStack(alignment: .topLeading) {
                HistorySection(settings: settings, controller: controller, full: true, fills: windowed)
                    .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
                    .opacity(showingSettings ? 0 : 1)
                    .offset(x: showingSettings ? -10 : 0)
                    .allowsHitTesting(!showingSettings)
                    .accessibilityHidden(showingSettings)

                Group {
                    if windowed {
                        ScrollView {
                            SettingsPage(settings: settings, controller: controller)
                                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 12)
                        }
                        .scrollIndicators(.never)
                    } else {
                        SettingsPage(settings: settings, controller: controller)
                            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 12)
                    }
                }
                .opacity(showingSettings ? 1 : 0)
                .offset(x: showingSettings ? 0 : 10)
                .allowsHitTesting(showingSettings)
                .accessibilityHidden(!showingSettings)
            }
            .animation(Motion.standard, value: showingSettings)
        }
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
    @State private var micExpanded = false

    private struct Outcome: Equatable {
        var message: String
        var text: String
        var latency: Double?
        var failed: Bool
    }
    private var outcome: Outcome {
        Outcome(message: controller.message, text: controller.result, latency: controller.latency, failed: controller.phase == .error)
    }
    private var resultOpen: Bool { !controller.message.isEmpty && !recording }

    /// The window is as tall as the column is now. While a moving `Reveal` is on its way (pending
    /// is how far it still has to go), that is a new height on every frame, sent as `live`: the
    /// window takes each one at once and keeps no animation of its own. Settled, it is sent once.
    private func report() {
        guard windowed, columnHeight > 0 else { return }
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
        .ignoresSafeArea()
        // A change of language builds the words again everywhere below.
        .id(settings.preferences.language)
    }

    private var column: some View {
        VStack(spacing: 0) {
            if windowed { scroller } else { header; content }
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

    @ViewBuilder private var scroller: some View {
        if #available(macOS 26.0, *) {
            ScrollView { measuredContent(top: 4) }
                .scrollIndicators(.never)
                .safeAreaBar(edge: .top, spacing: 0) { header }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            header
            ScrollView { measuredContent() }.scrollIndicators(.never)
        }
    }

    private var receiving: Bool { settings.receiverOnly }
    private var recording: Bool { controller.phase == .recording }
    private var processing: Bool { controller.phase == .processing }

    /// The state, as the dot on put and, on hover, in words (user 2026-11-19: no words in the title row).
    private var status: (ok: Bool, text: String) {
        if recording { return (true, tr("Recording · Tap %@ again to stop.", settings.shortcutLabel)) }
        if processing { return (true, tr("Processing · The text is being written.")) }
        if receiving {
            let ok = settings.accessibilityAllowed && controller.remoteListening
            return (ok, ok ? tr("Ready to receive · Text from the other Macs is typed at the cursor on this Mac.")
                           : tr("Setup needed · The panel lists the steps still missing."))
        }
        if controller.boundMicrophoneMissing { return (false, tr("Device offline · The locked microphone is not connected.")) }
        let ok = settings.ready && controller.hotkeyInstalled
        return (ok, ok ? tr("Ready · Tap %@ to start.", settings.shortcutLabel) : tr("Setup needed · The panel lists the steps still missing."))
    }

    private var header: some View {
        HStack(spacing: 5) {
            HStack(alignment: .top, spacing: 2) {
                Text("put").font(.system(size: 13, weight: .bold))
                Circle().fill(status.ok ? Palette.accent : Color.orange).frame(width: 6, height: 6).padding(.top, 1)
            }
            .contentShape(Rectangle())
            .help(status.text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("put · " + status.text)
            Spacer(minLength: 4)
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
            Reveal(open: !receiving) { microphoneCard.padding(.top, 8) }
            Reveal(open: !missing.isEmpty) { setupCard.padding(.top, 8) }
            Reveal(open: controller.learnedWord != nil) { learnedCard.padding(.top, 8) }
            Reveal(open: resultOpen) { resultCard.padding(.top, 8) }
            remoteCard.padding(.top, 8)
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
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
            : settings.sendsRemotely ? tr("Types at the cursor on the focused Mac") : tr("Types the result at the cursor")
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
        let stripTint: Color = micOffline ? Color.orange : Palette.accent
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
            Button { controller.toggle() } label: {
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
        .background(stripTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(stripRim, lineWidth: 1))
        .animation(Motion.standard, value: controller.phase)
        .animation(Motion.standard, value: micOffline)
    }

    private var microphoneCard: some View {
        let resolution = controller.microphoneResolution
        let offline = controller.boundMicrophoneMissing
        let isOpen = micExpanded || offline
        let boundUID = settings.preferences.microphone
        let badgeText: String = {
            switch resolution {
            case .boundAvailable(let info): return info.name
            case .boundMissing(_, let name): return tr("%@ · Not connected", name)
            case .systemDefault(let info): return tr("System default · %@", info.name)
            case .noInputDevices: return tr("No input available")
            }
        }()
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    let opening = !micExpanded
                    micExpanded = opening
                    if opening { settings.detailOpened.send() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                            .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 9)
                            .animation(Motion.standard, value: isOpen)
                        Image(systemName: offline ? "exclamationmark.triangle.fill" : resolution.isBound ? "lock.fill" : "mic")
                            .font(.system(size: 11))
                            .foregroundStyle(offline ? Color.orange : resolution.isBound ? Palette.accent : Palette.ink)
                            .frame(width: 15)
                        Text(tr("Microphone")).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 4)
                        Text(badgeText)
                            .font(.system(size: 10.5, weight: resolution.isBound ? .medium : .regular))
                            .foregroundStyle(offline ? Color.orange : resolution.isBound ? Palette.accent : Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? tr("Hide the microphone list") : tr("Show the list and lock a microphone"))
                .accessibilityLabel(tr("Microphone lock"))

                Reveal(open: isOpen, animated: true) {
                    VStack(alignment: .leading, spacing: 5) {
                        if offline {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "mic.slash.fill").font(.system(size: 11)).foregroundStyle(.orange).padding(.top, 2)
                                CopyableText(tr("The locked microphone “%@” is not in the device list, so there is no input. Reconnect it, or click a device below to lock that one instead.", controller.boundMicrophoneLabel),
                                             font: .system(size: 10.5), color: .orange)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.orange.opacity(0.32), lineWidth: 0.8))
                        } else {
                            caption(resolution.isBound ? tr("This microphone is locked. If it disconnects, put pauses and you are notified; put never switches to another microphone on its own.") : tr("Click any microphone below to lock it permanently."))
                        }

                        ForEach(controller.microphones.all) { mic in
                            let selected = boundUID == mic.uid
                            MicrophoneOptionRow(
                                title: mic.name,
                                badge: selected ? tr("Locked") : tr("Lock"),
                                symbol: selected ? "lock.fill" : "mic",
                                active: selected,
                                warning: false
                            ) {
                                settings.bindMicrophone(uid: mic.uid, name: mic.name)
                            }
                        }

                        if controller.microphones.all.isEmpty && !settings.preview {
                            caption(tr("No connected microphone was found."))
                        }

                        MicrophoneOptionRow(
                            title: tr("System default"),
                            badge: boundUID.isEmpty ? tr("Current") : tr("Unlock"),
                            symbol: boundUID.isEmpty ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath",
                            active: boundUID.isEmpty,
                            warning: false
                        ) {
                            settings.bindMicrophone(uid: "", name: "")
                        }
                    }
                    .disabled(controller.busy)
                    .padding(.top, 8)
                }
            }
        }
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
                CopyableText(
                    shownResult.message,
                    copyValue: shownResult.text.isEmpty ? shownResult.message : shownResult.text,
                    font: .system(size: 11),
                    color: shownResult.failed ? Color.orange : Palette.muted
                )
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
                            Text(String(format: "%.2f s", latency)).font(.system(size: 10.5, design: .monospaced))
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
            Row(tr("Work across Macs"), info: tr("When on, put on this Mac reaches put on your other Macs through the Monitor helper, types text on the one you are controlling by remote desktop, and keeps the Shelf in sync. The Macs are the ones on your Monitor page; nothing is paired here.")) {
                Toggle(tr("Work across Macs"), isOn: $settings.preferences.linkEnabled).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    .onChange(of: settings.preferences.linkEnabled) { _, _ in controller.linkChanged() }
            }
            Reveal(open: on && !(problem ?? "").isEmpty) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.shield").font(.system(size: 11)).foregroundStyle(.orange).padding(.top, 2)
                        CopyableText(problem ?? "", font: .system(size: 11), color: .orange)
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
                        caption(tr("No other Mac with put is on your Monitor page yet. Open the Monitor page once: while it is open, it tells your Macs about each other.")).padding(.top, 8)
                    }
                }
            }
            Reveal(open: !on) {
                caption(tr("Text is typed on this Mac only. When on, results go to the Mac you are controlling by remote desktop, and the Shelf is shared.")).padding(.top, 8)
            }
        }
        .onAppear { controller.refreshHelper(force: true); controller.testPeers() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            controller.refreshHelper(); controller.testPeers()
        }
    }

    /// What stands in the way, if anything: this Mac's keys, or its helper.
    private var problem: String? {
        if !controller.linkProblem.isEmpty { return controller.linkProblem }
        switch controller.helperState {
        case .missing: return tr("put works across Macs through the Monitor helper. Install it on this Mac from the Monitor page, or update it if it is installed.")
        case .stopped: return tr("The Monitor helper on this Mac is not running.")
        case .noTunnel: return tr("The Monitor helper on this Mac has no direct connection. Install it from the Monitor page with direct connections on.")
        case .checking, .ready: return nil
        }
    }

    private func row(_ device: TrustedDevice) -> some View {
        let called = controller.peerReachable[device.key], calledIn = shelf.linkedKeys.contains(device.key)
        let ok: Bool? = calledIn ? true : called
        let status = controller.peerTesting.contains(device.key) ? tr("Checking…")
            : ok == true ? tr("Online") : ok == false ? tr("Not connected") : tr("Not checked")
        return HStack(spacing: 6) {
            Circle().fill(ok == true ? Palette.accent : ok == false ? Color.orange : Palette.muted.opacity(0.5))
                .frame(width: 6, height: 6)
            CopyableText(device.label, font: .system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(status).font(.system(size: 10.5)).foregroundStyle(ok == false ? Color.orange : Palette.muted).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 6).padding(.vertical, 4.5)
        .help(controller.peerStatus[device.key] ?? "")
        .padding(.top, 6)
    }
}

struct HistorySection: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: DictationController
    var full: Bool
    var fills = false
    @State private var query = ""
    @State private var confirm = false
    @State private var expanded: Set<HistoryEntry.ID> = []
    private static let recent = 4

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private var entries: [HistoryEntry] {
        guard full else { return Array(settings.history.prefix(Self.recent)) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return settings.history }
        return settings.history.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        let shown = entries
        VStack(alignment: .leading, spacing: 7) {
            if full {
                HStack(spacing: 6) {
                    TextField(tr("Search History…"), text: $query).glassField()
                    Button(tr("Clear")) { confirm = true }.buttonStyle(QuietButton())
                        .disabled(settings.history.isEmpty || controller.busy || controller.retryingID != nil)
                }
            }
            if !controller.networkAvailable {
                Label(tr("Offline · Recordings are kept on this Mac and transcribed once online"), systemImage: "wifi.slash")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            }
            if !settings.historyMessage.isEmpty {
                CopyableText(settings.historyMessage, font: .system(size: 11), color: .orange)
            }
            if settings.history.isEmpty {
                caption(tr("No records yet. You can record at any time, even with no text field in focus; results and audio waiting to be transcribed are kept on this Mac."))
            } else if shown.isEmpty {
                caption(tr("No matching records."))
            } else if fills {
                ScrollView { lazyList(shown) }.frame(maxHeight: .infinity)
            } else if full {
                FittedScroll(maxHeight: 380) { lazyList(shown) }
            } else {
                lazyList(shown)
            }
        }.alert(tr("Clear all History and audio waiting to be transcribed on this Mac?"), isPresented: $confirm) {
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Clear"), role: .destructive) { settings.clearHistory() }
        }
    }

    private func lazyList(_ shown: [HistoryEntry]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                row(entry)
            }
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        let open = expanded.contains(entry.id)
        let long = entry.text.count > 64 || entry.text.filter({ $0 == "\n" }).count > 2
        let placeholder = entry.state == .recording ? tr("Recording. The audio is being saved on this Mac…") : tr("The audio is saved on this Mac, waiting to be transcribed.")
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: entry.mode.symbol)
                Text(Self.dateFormatter.string(from: entry.date))
                Text("\(max(1, Int(entry.seconds.rounded()))) s")
                if entry.state != .completed { Text(entry.state.title).foregroundStyle(.orange) }
                Spacer(minLength: 4)
                if !full {
                    if entry.canRetry {
                        Button(tr("Retry")) { controller.retry(entry.id) }
                            .buttonStyle(QuietButton())
                            .disabled(controller.busy || controller.retryingID != nil || !(controller.retryRequest(entry).map { controller.canRun($0) } ?? false))
                    }
                    CopyActionButton(text: entry.text)
                }
            }.font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            CopyableText(
                entry.text.isEmpty ? placeholder : entry.text,
                copyValue: entry.text,
                font: .system(size: 12),
                color: entry.text.isEmpty ? Palette.muted : Palette.ink,
                lineSpacing: 3,
                lineLimit: full ? (open ? nil : 4) : 3,
                block: !entry.text.isEmpty,
                enabled: !entry.text.isEmpty
            )
            if let problem = entry.problem {
                CopyableText(problem, font: .system(size: 10.5), color: .orange.opacity(0.9), lineLimit: full ? nil : 2)
            }
            if full {
                if entry.state != .completed && !entry.text.isEmpty {
                    caption(tr("This is the text recognized so far. It is updated when a retry finishes."))
                }
                HStack(spacing: 6) {
                    Spacer()
                    if long {
                        Button(open ? tr("Show less") : tr("Show more")) {
                            if open { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                        }.buttonStyle(QuietButton())
                    }
                    if entry.canRetry {
                        Button(tr("Retry")) { controller.retry(entry.id) }.buttonStyle(SolidButton())
                            .disabled(controller.busy || controller.retryingID != nil || !(controller.retryRequest(entry).map { controller.canRun($0) } ?? false))
                    }
                    CopyActionButton(text: entry.text)
                    Button(tr("Delete")) { settings.removeHistory(id: entry.id) }.buttonStyle(QuietButton())
                        .disabled(entry.state == .recording || entry.state == .processing)
                }
            }
        }.padding(.vertical, 7)
    }
}

struct OverlaySizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 { value = next }
    }
}

/// Isolated 5-bar micro-waveform driven solely by `AudioMeter`.
private struct MicroWaveform: View {
    @ObservedObject var meter: AudioMeter
    private static let weights: [CGFloat] = [7.5, 13, 9.5, 14, 8.5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.96))
                    .frame(width: 2.2, height: max(3.5, CGFloat(meter.level) * Self.weights[index]))
            }
        }
        .frame(width: 19, height: 14)
        .animation(.easeOut(duration: 0.08), value: meter.level)
    }
}

/// Isolated compact timer label driven solely by `AudioMeter`.
private struct CapsuleClock: View {
    @ObservedObject var meter: AudioMeter
    let online: Bool

    var body: some View {
        let time = String(format: "%d:%02d", meter.elapsed / 60, meter.elapsed % 60)
        Text(online ? time : tr("%@ · Offline", time))
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Dynamic luminous green background driven solely by `AudioMeter` while speaking.
private struct CapsuleSurface: View {
    let phase: DictationPhase
    @ObservedObject var meter: AudioMeter
    let glass: Bool
    /// Done, but the text is not where it was meant to go: amber, not green.
    var warning = false

    var body: some View {
        let boost = phase == .recording ? Double(meter.level) * 0.12 : 0
        ZStack {
            if glass && phase == .processing { Glass(dark: true) }
            switch phase {
            case .recording:
                LinearGradient(
                    colors: [
                        Color(red: min(1, 0.16 + boost), green: min(1, 0.79 + boost * 0.65), blue: min(1, 0.37 + boost * 0.35)),
                        Color(red: min(1, 0.09 + boost * 0.6), green: min(1, 0.64 + boost * 0.75), blue: min(1, 0.28 + boost * 0.3))
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .done:
                LinearGradient(
                    colors: warning ? [Color(red: 0.86, green: 0.55, blue: 0.10), Color(red: 0.74, green: 0.43, blue: 0.06)]
                        : [Color(red: 0.15, green: 0.74, blue: 0.36), Color(red: 0.10, green: 0.60, blue: 0.28)],
                    startPoint: .top,
                    endPoint: .bottom
                ).opacity(0.95)
            case .error:
                LinearGradient(
                    colors: [Color(red: 0.84, green: 0.34, blue: 0.22), Color(red: 0.70, green: 0.24, blue: 0.16)],
                    startPoint: .top,
                    endPoint: .bottom
                ).opacity(0.95)
            case .processing, .idle:
                Color(red: 0.09, green: 0.20, blue: 0.14).opacity(glass ? 0.62 : 0.92)
            }
        }
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(phase == .recording ? 0.52 : 0.28),
                            .white.opacity(phase == .recording ? 0.20 : 0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: phase == .recording ? 1 : 0.8
                )
        )
        .shadow(
            color: phase == .recording
                ? Color(red: 0.14, green: 0.84, blue: 0.40).opacity(0.42 + Double(meter.level) * 0.36)
                : Color.black.opacity(0.24),
            radius: phase == .recording ? 5.5 + CGFloat(meter.level) * 2.0 : 4,
            x: 0,
            y: 1.5
        )
        .animation(.easeOut(duration: 0.09), value: meter.level)
        .animation(Motion.standard, value: phase)
    }
}

/// Miniature floating status capsule — lights up completely in luminous emerald green while
/// speaking, and docks predictably right below the top menu bar without obstructing sight.
struct VoiceBar: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var meter: AudioMeter
    @ObservedObject var settings: SettingsStore
    var glass = true
    var onSize: ((CGSize) -> Void)? = nil
    @State private var copied = false
    @State private var copyToken = UUID()

    init(
        controller: DictationController,
        meter: AudioMeter? = nil,
        settings: SettingsStore,
        glass: Bool = true,
        onSize: ((CGSize) -> Void)? = nil
    ) {
        self.controller = controller
        self.meter = meter ?? controller.meter
        self.settings = settings
        self.glass = glass
        self.onSize = onSize
    }

    private var copyablePayload: String {
        if controller.phase == .recording, !controller.partial.isEmpty { return controller.partial }
        if !controller.result.isEmpty { return controller.result }
        if controller.phase == .error, !controller.message.isEmpty { return controller.message }
        return ""
    }

    var body: some View {
        HStack(spacing: 7) {
            leadingIndicator
            labelContent
            trailingControls
        }
        .padding(.leading, 11)
        .padding(.trailing, hasTrailingButtons ? 6 : 11)
        .padding(.vertical, 5.5)
        .frame(minHeight: 28)
        .foregroundStyle(.white)
        .background { CapsuleSurface(phase: controller.phase, meter: meter, glass: glass, warning: notTyped) }
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: OverlaySizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(OverlaySizeKey.self) { size in
            if size.width > 0 && size.height > 0 { onSize?(size) }
        }
        .preferredColorScheme(.dark)
        // A change of language builds the words again everywhere below.
        .id(settings.preferences.language)
    }

    private var notTyped: Bool {
        if controller.phase == .done, case .notWritten = controller.capsuleResult { return true }
        return false
    }

    private var hasTrailingButtons: Bool {
        controller.phase == .recording || controller.phase == .processing || controller.phase == .error
    }

    @ViewBuilder private var leadingIndicator: some View {
        switch controller.phase {
        case .recording:
            MicroWaveform(meter: meter)
        case .processing:
            TimelineView(.animation(minimumInterval: 0.05)) { context in
                Circle().trim(from: 0.08, to: 0.78)
                    .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                    .frame(width: 11.5, height: 11.5)
                    .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 260))
            }
            .frame(width: 14, height: 14)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
        case .done, .idle:
            if notTyped {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder private var labelContent: some View {
        if copied {
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
                Text(tr("Copied")).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
        } else if controller.phase == .recording {
            HStack(spacing: 5) {
                CapsuleClock(meter: meter, online: controller.connected)
                if !controller.partial.isEmpty {
                    Text("·").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.65))
                    Button(action: copyFromCapsule) {
                        Text(String(controller.partial.suffix(12)))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.96))
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
            // Which Mac, and why the text is not there: two short lines, the second may wrap once.
            Button(action: copyFromCapsule) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.86))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: 210, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("%@\nClick to copy", controller.message.isEmpty ? controller.capsuleSummary : controller.message))
        } else {
            let text = controller.capsuleSummary
            if !copyablePayload.isEmpty {
                Button(action: copyFromCapsule) {
                    Text(text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 152, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("%@\nClick to copy", text))
            } else {
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
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
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(.black.opacity(0.20), in: Circle())
                        .frame(width: 21, height: 21)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tr("Stop recording (%@)", settings.shortcutLabel))
                .accessibilityLabel(tr("Stop recording"))
            }
            if hasTrailingButtons {
                Button { controller.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 18, height: 18)
                        .background(.black.opacity(0.16), in: Circle())
                        .frame(width: 21, height: 21)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(controller.busy ? tr("Cancel (Esc)") : tr("Close"))
                .accessibilityLabel(controller.busy ? tr("Cancel this recording") : tr("Dismiss"))
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
