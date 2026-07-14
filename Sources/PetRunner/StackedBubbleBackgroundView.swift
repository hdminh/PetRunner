import AppKit
import PetRunnerCore

@MainActor
final class StackedBubbleBackgroundView: NSView {
    static let expandedContentSize = CGSize(width: 264, height: 94)

    private static let cardFrame = CGRect(x: 0, y: 0, width: 248, height: 94)
    private static let railFrame = CGRect(x: 246, y: 0, width: 18, height: 94)
    private static let headerHeight: CGFloat = 22
    private static let statusCellSize = CGSize(width: 12, height: 12)
    private static let compactCellSize = CGSize(width: 16, height: 14)
    private static let statusCellStep: CGFloat = 16

    var sessionCount = 0 { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var providerLabel = "" { didSet { needsDisplay = true } }
    var sessionLabel = "" { didSet { needsDisplay = true } }
    var statusLabel = "" { didSet { needsDisplay = true } }
    var indicatorTones: [AgentStatusTone] = [] { didSet { needsDisplay = true } }
    var isCollapsed = false { didSet { needsDisplay = true } }

    static func contentSize(isCollapsed: Bool, sessionCount: Int) -> CGSize {
        guard isCollapsed else { return expandedContentSize }
        let visibleCount = min(max(sessionCount, 1), AgentSessionStore.maximumEntries)
        return CGSize(width: compactCellSize.width, height: compactCellSize.height * CGFloat(visibleCount))
    }

    static func statusControlFrame(at index: Int, sessionCount: Int, isCollapsed: Bool) -> CGRect {
        let visibleCount = min(max(sessionCount, 0), AgentSessionStore.maximumEntries)
        guard (0..<visibleCount).contains(index) else { return .zero }

        if isCollapsed {
            return CGRect(
                x: 0,
                y: CGFloat(visibleCount - index - 1) * compactCellSize.height,
                width: compactCellSize.width,
                height: compactCellSize.height
            )
        }

        return CGRect(
            x: railFrame.minX + 3,
            y: railFrame.maxY - 14 - CGFloat(index) * statusCellStep,
            width: statusCellSize.width,
            height: statusCellSize.height
        )
    }

    static var toggleControlFrame: CGRect {
        CGRect(x: 224, y: 75, width: 18, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isCollapsed {
            drawCollapsedRail()
        } else {
            drawExpandedBubble()
        }
    }

    private func drawExpandedBubble() {
        drawPixelFrame(Self.cardFrame, fill: NSColor(white: 0.84, alpha: 1))

        let header = CGRect(
            x: Self.cardFrame.minX + 2,
            y: Self.cardFrame.maxY - Self.headerHeight,
            width: Self.cardFrame.width - 4,
            height: Self.headerHeight - 2
        )
        NSColor(white: 0.72, alpha: 1).setFill()
        NSBezierPath(rect: header).fill()
        NSColor.black.setFill()
        NSBezierPath(rect: CGRect(x: Self.cardFrame.minX + 2, y: header.minY - 2, width: Self.cardFrame.width - 4, height: 2)).fill()

        drawPixelText(providerLabel, at: CGPoint(x: 8, y: 87), scale: 1)
        drawPixelButton(in: Self.toggleControlFrame)
        drawPixelText("-", at: CGPoint(x: 230, y: 85), scale: 1)

        drawPixelText(sessionLabel, at: CGPoint(x: 10, y: 60), scale: 1)
        drawPixelText(statusLabel.replacingOccurrences(of: "…", with: "..."), at: CGPoint(x: 10, y: 42), scale: 2)

        drawPixelFrame(Self.railFrame, fill: NSColor(white: 0.67, alpha: 1))
        for index in 0..<visibleCount {
            drawStatusLight(
                in: Self.statusControlFrame(at: index, sessionCount: sessionCount, isCollapsed: false),
                tone: tone(at: index),
                selected: index == selectedIndex
            )
        }
    }

    private func drawCollapsedRail() {
        for index in 0..<visibleCount {
            drawStatusLight(
                in: Self.statusControlFrame(at: index, sessionCount: sessionCount, isCollapsed: true),
                tone: tone(at: index),
                selected: index == selectedIndex
            )
        }
    }

    private var visibleCount: Int {
        min(max(sessionCount, 0), AgentSessionStore.maximumEntries)
    }

    private func tone(at index: Int) -> AgentStatusTone {
        indicatorTones.indices.contains(index) ? indicatorTones[index] : .yellow
    }

    private func drawPixelFrame(_ rect: CGRect, fill: NSColor) {
        NSColor.black.setFill()
        NSBezierPath(rect: rect).fill()
        fill.setFill()
        NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2)).fill()
    }

    private func drawPixelButton(in rect: CGRect) {
        NSColor.black.setFill()
        NSBezierPath(rect: rect).fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2)).fill()
    }

    private func drawStatusLight(in rect: CGRect, tone: AgentStatusTone, selected: Bool) {
        (selected ? NSColor.black : NSColor(white: 0.32, alpha: 1)).setFill()
        NSBezierPath(rect: rect).fill()
        color(for: tone).setFill()
        NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2)).fill()
    }

    private func color(for tone: AgentStatusTone) -> NSColor {
        switch tone {
        case .yellow: NSColor(calibratedRed: 0.96, green: 0.74, blue: 0.16, alpha: 1)
        case .cyan: NSColor(calibratedRed: 0.18, green: 0.68, blue: 0.86, alpha: 1)
        case .violet: NSColor(calibratedRed: 0.64, green: 0.32, blue: 0.84, alpha: 1)
        case .green: NSColor(calibratedRed: 0.22, green: 0.68, blue: 0.34, alpha: 1)
        case .red: NSColor(calibratedRed: 0.88, green: 0.22, blue: 0.22, alpha: 1)
        }
    }

    private func drawPixelText(_ text: String, at origin: CGPoint, scale: CGFloat, color: NSColor = .black) {
        var x = origin.x
        for character in text.uppercased() {
            drawPixelRows(PixelGlyphs.glyph(for: character), at: CGPoint(x: x, y: origin.y), scale: scale, color: color)
            x += 5 * scale + 2
        }
    }

    private func drawPixelRows(_ rows: [UInt8], at origin: CGPoint, scale: CGFloat, color: NSColor) {
        color.setFill()
        for (row, bits) in rows.enumerated() {
            for column in 0..<5 where (bits & (1 << (4 - column)) != 0) {
                NSBezierPath(rect: CGRect(
                    x: origin.x + CGFloat(column) * scale,
                    y: origin.y - CGFloat(row) * scale,
                    width: scale,
                    height: scale
                )).fill()
            }
        }
    }
}
