import CoreGraphics
import Foundation

/// Positions the miniature floating status capsule predictably and unobtrusively.
///
/// Rather than scattering across arbitrary window edges, the capsule defaults to a consistent
/// home right beneath the menu bar at top-center (Dynamic Island style) so the user always knows
/// where to glance, and steps aside along the top edge (top-right or top-left) only when the
/// focused input field, pointer, or input's own panel occupies that spot. It never pins to the
/// bottom of the screen.
public enum OverlayPlacement {
    public enum AnchorCorner: String, Sendable, Equatable {
        case topCenter
        case topTrailing
        case topLeading
        case bottomTrailing
        case bottomLeading
    }

    public struct Scene: Sendable {
        public var visibleFrame: CGRect
        public var activeWindow: CGRect?
        public var otherWindows: [CGRect]
        public var focusedField: CGRect?
        public var panelFrame: CGRect?
        public var pointer: CGPoint?
        public var previousOrigin: CGPoint?

        public init(
            visibleFrame: CGRect,
            activeWindow: CGRect? = nil,
            otherWindows: [CGRect] = [],
            focusedField: CGRect? = nil,
            panelFrame: CGRect? = nil,
            pointer: CGPoint? = nil,
            previousOrigin: CGPoint? = nil
        ) {
            self.visibleFrame = visibleFrame
            self.activeWindow = activeWindow
            self.otherWindows = otherWindows
            self.focusedField = focusedField
            self.panelFrame = panelFrame
            self.pointer = pointer
            self.previousOrigin = previousOrigin
        }
    }

    public struct Placement: Sendable, Equatable {
        public let origin: CGPoint
        public let corner: AnchorCorner

        public init(origin: CGPoint, corner: AnchorCorner) {
            self.origin = origin
            self.corner = corner
        }
    }

    /// Compact footprint budget: the capsule stays well below one quarter of the legacy 444×162 bar.
    public static let legacyArea: CGFloat = 444 * 162
    public static let maxAllowedArea: CGFloat = legacyArea / 4
    public static let defaultSize = CGSize(width: 156, height: 46)

    /// Converts a rectangle from Quartz global coordinates (top-left of primary screen) into
    /// AppKit screen coordinates (bottom-left of primary screen).
    public static func quartzToAppKit(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    public static func choose(size rawSize: CGSize, in scene: Scene) -> Placement {
        let visible = scene.visibleFrame
        let size = CGSize(
            width: min(max(rawSize.width, 84), max(84, visible.width - 16)),
            height: min(max(rawSize.height, 24), max(24, visible.height - 16))
        )
        guard visible.width > size.width + 16, visible.height > size.height + 16 else {
            return Placement(origin: visible.origin, corner: .topCenter)
        }

        let candidates = buildCandidates(size: size, scene: scene)
        var best = candidates[0]
        var bestScore = CGFloat.greatestFiniteMagnitude

        for candidate in candidates {
            let rect = CGRect(origin: candidate.origin, size: size)
            let score = penalty(for: rect, baseBias: candidate.bias, in: scene)
            if score < bestScore {
                bestScore = score
                best = candidate
            }
        }
        return Placement(origin: CGPoint(x: round(best.origin.x), y: round(best.origin.y)), corner: best.corner)
    }

    /// Whether an existing capsule frame now collides with input's panel or the active typing field.
    public static func isObstructed(_ rect: CGRect, in scene: Scene) -> Bool {
        if let panel = scene.panelFrame, rect.intersects(panel.insetBy(dx: -8, dy: -8)) {
            return true
        }
        if let focus = scene.focusedField, rect.intersects(focus.insetBy(dx: -36, dy: -24)) {
            return true
        }
        return false
    }

    /// Keeps the capsule anchored to its chosen slot when its text grows or shrinks slightly.
    public static func reanchor(frame: CGRect, newSize: CGSize, corner: AnchorCorner, in visible: CGRect) -> CGRect {
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topCenter:
            x = round(frame.midX - newSize.width / 2)
            y = frame.maxY - newSize.height
        case .topTrailing:
            x = frame.maxX - newSize.width
            y = frame.maxY - newSize.height
        case .topLeading:
            x = frame.minX
            y = frame.maxY - newSize.height
        case .bottomTrailing:
            x = frame.maxX - newSize.width
            y = frame.minY
        case .bottomLeading:
            x = frame.minX
            y = frame.minY
        }
        let clamped = clamp(CGPoint(x: x, y: y), size: newSize, in: visible)
        return CGRect(origin: clamped, size: newSize)
    }

    private struct Candidate {
        let origin: CGPoint
        let corner: AnchorCorner
        let bias: CGFloat
    }

    private static func buildCandidates(size: CGSize, scene: Scene) -> [Candidate] {
        let v = scene.visibleFrame
        let padX: CGFloat = 12
        let padTop: CGFloat = 2
        let w = size.width
        let h = size.height
        let topY = v.maxY - h - padTop

        // Predictable top-edge rail:
        // 1. Primary home: Top-Center right beneath the menu bar — immediately visible on any display.
        // 2. Top-Right beneath the menu bar (or tucked beside input's panel if the panel sits at Top-Right).
        // 3. Top-Left beneath the menu bar (clear of traffic lights).
        var raw: [(CGPoint, AnchorCorner, CGFloat)] = [
            (CGPoint(x: v.midX - w / 2, y: topY), .topCenter, 0),
            (CGPoint(x: v.maxX - w - padX, y: topY), .topTrailing, 1_200),
            (CGPoint(x: v.minX + padX, y: topY), .topLeading, 1_600)
        ]

        if let panel = scene.panelFrame?.intersection(v), !panel.isNull, !panel.isEmpty {
            if panel.minX - v.minX >= w + 16 {
                raw.append((CGPoint(x: panel.minX - w - 8, y: topY), .topTrailing, 1_100))
            }
            if v.maxX - panel.maxX >= w + 16 {
                raw.append((CGPoint(x: panel.maxX + 8, y: topY), .topLeading, 1_150))
            }
        }

        // Fallback slightly lower on the right/left top margin only if the entire top edge is busy.
        raw.append((CGPoint(x: v.maxX - w - padX, y: v.maxY - h - 56), .topTrailing, 4_500))
        raw.append((CGPoint(x: v.minX + padX, y: v.maxY - h - 56), .topLeading, 4_800))

        var result: [Candidate] = []
        for (point, corner, bias) in raw {
            let clamped = clamp(point, size: size, in: v)
            let midX = clamped.x + w / 2
            if clamped.y - v.minY < 72, abs(midX - v.midX) < min(180, v.width * 0.22) {
                continue
            }
            if !result.contains(where: { hypot($0.origin.x - clamped.x, $0.origin.y - clamped.y) < 10 }) {
                result.append(Candidate(origin: clamped, corner: corner, bias: bias))
            }
        }

        if result.isEmpty {
            let fallback = clamp(CGPoint(x: v.midX - w / 2, y: topY), size: size, in: v)
            result.append(Candidate(origin: fallback, corner: .topCenter, bias: 0))
        }
        return result
    }

    private static func penalty(for rect: CGRect, baseBias: CGFloat, in scene: Scene) -> CGFloat {
        var score = baseBias

        // 1. Never cover input's own panel.
        if let panel = scene.panelFrame {
            let guardRect = panel.insetBy(dx: -10, dy: -10)
            if rect.intersects(guardRect) {
                score += 2_000_000 + overlapArea(rect, guardRect) * 100
            }
        }

        // 2. Step aside when the focused text field / caret is right at this top slot (e.g. URL bar / Spotlight).
        if let focus = scene.focusedField {
            let focusGuard = focus.insetBy(dx: -44, dy: -32)
            if rect.intersects(focusGuard) {
                score += 1_200_000 + overlapArea(rect, focusGuard) * 90
            }
        }

        // 3. Avoid popping up directly under the mouse pointer.
        if let pointer = scene.pointer {
            let pointerBox = CGRect(x: pointer.x - 32, y: pointer.y - 24, width: 64, height: 48)
            if rect.intersects(pointerBox) {
                score += 250_000
            }
        }

        // 4. Avoid covering the active window's traffic-lights corner at top-left if another top slot is free.
        if let active = scene.activeWindow {
            let trafficZone = CGRect(x: active.minX, y: active.maxY - 44, width: 96, height: 44)
            if rect.intersects(trafficZone) {
                score += 8_000
            }
        }

        // 5. Hysteresis so an already-shown capsule stays put unless obstructed.
        if let prev = scene.previousOrigin, hypot(rect.minX - prev.x, rect.minY - prev.y) < 40 {
            score -= 600
        }

        return score
    }

    private static func clamp(_ point: CGPoint, size: CGSize, in visible: CGRect) -> CGPoint {
        let insetX: CGFloat = 6
        let insetBottom: CGFloat = 8
        let insetTop: CGFloat = 2
        let minX = visible.minX + insetX
        let maxX = max(minX, visible.maxX - size.width - insetX)
        let minY = visible.minY + insetBottom
        let maxY = max(minY, visible.maxY - size.height - insetTop)
        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        return inter.width * inter.height
    }
}
