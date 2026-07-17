import AppKit
import PetRunnerCore

@MainActor
final class StackedBubbleBackgroundView: NSView {
    var sessionCount = 0 { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var providerLabel = "" { didSet { needsDisplay = true } }
    var headerColor = ProviderHeaderColor(red: 0.72, green: 0.72, blue: 0.72) { didSet { needsDisplay = true } }
    var sessionPosition = "" { didSet { needsDisplay = true } }
    var indicatorTones: [AgentStatusTone] = [] { didSet { needsDisplay = true } }
    var detailLineCount = 0 { didSet { needsDisplay = true } }
    var thoughtSide: ThoughtBubbleSide = .above { didSet { needsDisplay = true } }
    var isCollapsed = false { didSet { needsDisplay = true } }
    var canSelectPrevious = false { didSet { needsDisplay = true } }
    var canSelectNext = false { didSet { needsDisplay = true } }

    private var layout: SessionBubbleLayout {
        SessionBubbleLayout(
            sessionCount: sessionCount,
            selectedIndex: selectedIndex,
            detailLineCount: detailLineCount,
            side: thoughtSide,
            isCollapsed: isCollapsed
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        if isCollapsed {
            drawCollapsedRail()
        } else {
            drawThoughtBubble()
        }
    }

    private func drawThoughtBubble() {
        let layout = layout
        let bubble = layout.bubbleFrame
        drawPixelSpeechBubble(
            bubble,
            tailFrames: layout.speechTailFrames(),
            tailInteriorFrames: layout.speechTailInteriorFrames(),
            fill: .white
        )

        drawMinimizeBar(in: layout.collapseControlFrame)
        drawPixelText(providerLabel, at: CGPoint(x: layout.collapseControlFrame.maxX + 6, y: bubble.maxY - 8), scale: 1)
        drawPixelText(sessionPosition, at: CGPoint(x: layout.sessionPositionFrame.minX, y: layout.sessionPositionFrame.maxY - 1), scale: 1)

        drawNavigationButton(in: layout.previousControlFrame, pointingUp: true, enabled: canSelectPrevious)
        drawNavigationButton(in: layout.nextControlFrame, pointingUp: false, enabled: canSelectNext)
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
        for (railIndex, sessionIndex) in layout.indicatorIndices.enumerated() {
            drawStatusLight(
                in: layout.indicatorFrame(at: railIndex),
                tone: tone(at: sessionIndex),
                selected: sessionIndex == selectedIndex
            )
        }
    }

    private func tone(at index: Int) -> AgentStatusTone {
        indicatorTones.indices.contains(index) ? indicatorTones[index] : .yellow
    }

    private func drawPixelSpeechBubble(
        _ rect: CGRect,
        tailFrames: [CGRect],
        tailInteriorFrames: [CGRect],
        fill: NSColor
    ) {
        let shadowOffset = CGSize(width: 4, height: -4)
        NSColor(calibratedRed: 0.35, green: 0.21, blue: 0.13, alpha: 1).setFill()
        pixelRoundedPath(in: rect.offsetBy(dx: shadowOffset.width, dy: shadowOffset.height)).fill()
        for tail in tailFrames {
            NSBezierPath(rect: tail.offsetBy(dx: shadowOffset.width, dy: shadowOffset.height)).fill()
        }

        NSColor.black.setFill()
        pixelRoundedPath(in: rect).fill()
        fill.setFill()
        pixelRoundedPath(in: rect.insetBy(dx: 2, dy: 2)).fill()

        NSColor.black.setFill()
        for tail in tailFrames {
            NSBezierPath(rect: tail).fill()
        }
        fill.setFill()
        for tail in tailInteriorFrames {
            NSBezierPath(rect: tail).fill()
        }
    }

    private func pixelRoundedPath(in rect: CGRect) -> NSBezierPath {
        let corner: CGFloat = 6
        let step: CGFloat = 2
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - corner, y: rect.minY + step))
        path.line(to: CGPoint(x: rect.maxX - step, y: rect.minY + step))
        path.line(to: CGPoint(x: rect.maxX - step, y: rect.minY + corner))
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY + corner))
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
        path.line(to: CGPoint(x: rect.maxX - step, y: rect.maxY - corner))
        path.line(to: CGPoint(x: rect.maxX - step, y: rect.maxY - step))
        path.line(to: CGPoint(x: rect.maxX - corner, y: rect.maxY - step))
        path.line(to: CGPoint(x: rect.maxX - corner, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX + corner, y: rect.maxY - step))
        path.line(to: CGPoint(x: rect.minX + step, y: rect.maxY - step))
        path.line(to: CGPoint(x: rect.minX + step, y: rect.maxY - corner))
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY - corner))
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + corner))
        path.line(to: CGPoint(x: rect.minX + step, y: rect.minY + corner))
        path.line(to: CGPoint(x: rect.minX + step, y: rect.minY + step))
        path.line(to: CGPoint(x: rect.minX + corner, y: rect.minY + step))
        path.close()
        return path
    }

    private func drawPixelButton(in rect: CGRect, enabled: Bool) {
        (enabled ? NSColor.black : NSColor(white: 0.38, alpha: 1)).setFill()
        NSBezierPath(rect: rect).fill()
        (enabled ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.65, alpha: 1)).setFill()
        NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2)).fill()
    }

    private func drawMinimizeBar(in rect: CGRect) {
        let bar = CGRect(x: rect.minX + 2, y: rect.midY - 1.5, width: rect.width - 4, height: 3)
        NSColor.black.setFill()
        NSBezierPath(rect: bar).fill()
    }

    private func drawNavigationButton(in rect: CGRect, pointingUp: Bool, enabled: Bool) {
        (enabled ? NSColor.black : NSColor(white: 0.38, alpha: 1)).setFill()
        NSBezierPath(rect: rect).fill()
        (enabled ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.65, alpha: 1)).setFill()
        NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2)).fill()

        let triangle = NSBezierPath()
        if pointingUp {
            triangle.move(to: CGPoint(x: rect.midX, y: rect.maxY - 4))
            triangle.line(to: CGPoint(x: rect.minX + 4, y: rect.minY + 4))
            triangle.line(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4))
        } else {
            triangle.move(to: CGPoint(x: rect.midX, y: rect.minY + 4))
            triangle.line(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 4))
            triangle.line(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 4))
        }
        triangle.close()
        (enabled ? NSColor.black : NSColor(white: 0.42, alpha: 1)).setFill()
        triangle.fill()
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

    private func color(for headerColor: ProviderHeaderColor) -> NSColor {
        NSColor(
            calibratedRed: headerColor.red,
            green: headerColor.green,
            blue: headerColor.blue,
            alpha: 1
        )
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
