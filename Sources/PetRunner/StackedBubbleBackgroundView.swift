import AppKit
import PetRunnerCore

@MainActor
final class StackedBubbleBackgroundView: NSView {
    var sessionCount = 0 { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var providerLabel = "" { didSet { needsDisplay = true } }
    var sessionPosition = "" { didSet { needsDisplay = true } }
    var statusLabel = "" { didSet { needsDisplay = true } }
    var indicatorTones: [AgentStatusTone] = [] { didSet { needsDisplay = true } }
    var isCollapsed = false { didSet { needsDisplay = true } }
    var canSelectPrevious = false { didSet { needsDisplay = true } }
    var canSelectNext = false { didSet { needsDisplay = true } }

    private var layout: SessionBubbleLayout {
        SessionBubbleLayout(sessionCount: sessionCount, isCollapsed: isCollapsed)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isCollapsed {
            drawCollapsedRail()
        } else {
            drawExpandedBubble()
        }
    }

    private func drawExpandedBubble() {
        let layout = layout
        drawPixelFrame(layout.cardFrame, fill: NSColor(white: 0.84, alpha: 1))

        NSColor(white: 0.72, alpha: 1).setFill()
        NSBezierPath(rect: layout.headerFrame).fill()
        NSColor.black.setFill()
        NSBezierPath(rect: CGRect(x: 2, y: layout.headerFrame.minY - 2, width: layout.headerFrame.width, height: 2)).fill()

        drawPixelText(providerLabel, at: CGPoint(x: 8, y: 103), scale: 1)
        drawPixelText(sessionPosition, at: CGPoint(x: 164, y: 103), scale: 1)
        drawPixelButton(in: layout.collapseControlFrame, enabled: true)
        drawPixelText("-", at: CGPoint(x: 201, y: 102), scale: 1)

        drawPixelText(statusLabel.replacingOccurrences(of: "…", with: "..."), at: CGPoint(x: 10, y: 28), scale: 1)

        drawPixelFrame(layout.railFrame, fill: NSColor(white: 0.67, alpha: 1))
        drawPixelButton(in: layout.previousControlFrame, enabled: canSelectPrevious)
        drawChevron(in: layout.previousControlFrame, pointingUp: true, enabled: canSelectPrevious)
        drawPixelButton(in: layout.nextControlFrame, enabled: canSelectNext)
        drawChevron(in: layout.nextControlFrame, pointingUp: false, enabled: canSelectNext)
        drawIndicators(using: layout)
    }

    private func drawCollapsedRail() {
        let layout = layout
        drawPixelButton(in: layout.expandControlFrame, enabled: true)
        drawExpandArrows(in: layout.expandControlFrame)
        drawIndicators(using: layout)
    }

    private func drawExpandArrows(in rect: CGRect) {
        let inset: CGFloat = 4
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let upperRight = CGPoint(x: rect.maxX - inset, y: rect.maxY - inset)
        let lowerLeft = CGPoint(x: rect.minX + inset, y: rect.minY + inset)

        let arrows = NSBezierPath()
        arrows.lineWidth = 2
        arrows.lineCapStyle = .square
        arrows.move(to: center)
        arrows.line(to: upperRight)
        arrows.line(to: CGPoint(x: upperRight.x - 4, y: upperRight.y))
        arrows.move(to: upperRight)
        arrows.line(to: CGPoint(x: upperRight.x, y: upperRight.y - 4))
        arrows.move(to: center)
        arrows.line(to: lowerLeft)
        arrows.line(to: CGPoint(x: lowerLeft.x + 4, y: lowerLeft.y))
        arrows.move(to: lowerLeft)
        arrows.line(to: CGPoint(x: lowerLeft.x, y: lowerLeft.y + 4))
        NSColor.black.setStroke()
        arrows.stroke()
    }

    private func drawIndicators(using layout: SessionBubbleLayout) {
        for index in 0..<sessionCount {
            drawStatusLight(
                in: layout.indicatorFrame(at: index),
                tone: tone(at: index),
                selected: index == selectedIndex
            )
        }
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

    private func drawPixelButton(in rect: CGRect, enabled: Bool) {
        (enabled ? NSColor.black : NSColor(white: 0.38, alpha: 1)).setFill()
        NSBezierPath(rect: rect).fill()
        (enabled ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.65, alpha: 1)).setFill()
        NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2)).fill()
    }

    private func drawChevron(in rect: CGRect, pointingUp: Bool, enabled: Bool) {
        let color = enabled ? NSColor.black : NSColor(white: 0.42, alpha: 1)
        let centerX = rect.midX
        let centerY = rect.midY
        let rows: [(CGFloat, CGFloat)] = pointingUp
            ? [(0, 0), (1, 2), (2, 3)]
            : [(0, 3), (1, 2), (2, 0)]
        color.setFill()
        for (row, inset) in rows {
            NSBezierPath(rect: CGRect(x: centerX - 4 + inset, y: centerY - 3 + row * 3, width: 8 - inset * 2, height: 2)).fill()
        }
    }

    private func drawStatusLight(in rect: CGRect, tone: AgentStatusTone, selected: Bool) {
        (selected ? NSColor.black : NSColor(white: 0.32, alpha: 1)).setFill()
        NSBezierPath(rect: rect).fill()
        color(for: tone).setFill()
        NSBezierPath(rect: rect.insetBy(dx: selected ? 2 : 1, dy: selected ? 2 : 1)).fill()
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
