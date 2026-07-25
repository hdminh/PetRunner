import AppKit
import PetRunnerCore

/// Pixel-style HP bars drawn under the pet (heart + capsule track + remaining fill).
@MainActor
final class PetQuotaBarView: NSView {
    private var segments: [QuotaBarSegment] = []
    private var isCollapsed = false

    static let barHeight = QuotaBarLayout.barHeight
    static let barSpacing = QuotaBarLayout.barSpacing
    static let sideInset = QuotaBarLayout.sideInset
    static let controlSize = QuotaBarLayout.controlSize
    static let collapsedHeight = QuotaBarLayout.collapsedHeight

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Bars ignore mouse so drag/resize stay on the sprite; the toggle button handles hits.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setSegments(_ segments: [QuotaBarSegment]) {
        self.segments = segments
        needsDisplay = true
    }

    func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        needsDisplay = true
    }

    static func barsHeight(forCount count: Int) -> CGFloat {
        QuotaBarLayout.barsHeight(forCount: count)
    }

    static func preferredHeight(forCount count: Int, collapsed: Bool = false) -> CGFloat {
        QuotaBarLayout.preferredHeight(forCount: count, collapsed: collapsed)
    }

    static func toggleFrame(
        containerWidth: CGFloat,
        segmentCount: Int,
        collapsed: Bool,
        scale: CGFloat
    ) -> CGRect {
        QuotaBarLayout.toggleFrame(
            containerWidth: containerWidth,
            segmentCount: segmentCount,
            collapsed: collapsed,
            scale: scale
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !segments.isEmpty else { return }

        let previousAntialias = NSGraphicsContext.current?.shouldAntialias
        let previousInterpolation = NSGraphicsContext.current?.imageInterpolation
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.imageInterpolation = .none
        defer {
            if let previousAntialias {
                NSGraphicsContext.current?.shouldAntialias = previousAntialias
            }
            if let previousInterpolation {
                NSGraphicsContext.current?.imageInterpolation = previousInterpolation
            }
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let unit = QuotaBarLayout.pixelUnit(scale: scale)

        if isCollapsed {
            drawCollapsedHearts(unit: unit)
            return
        }

        var y = bounds.minY + 2
        for segment in segments.reversed() {
            drawBar(segment: segment, originY: y, unit: unit)
            y += Self.barHeight + Self.barSpacing
        }
    }

    private func drawCollapsedHearts(unit: CGFloat) {
        let item = QuotaBarLayout.controlSize
        let gap = QuotaBarLayout.collapsedItemGap
        let total = CGFloat(segments.count + 1) * item + CGFloat(segments.count) * gap
        // Skip the leading expand-control slot (drawn by QuotaBarCollapseButton).
        var x = max(Self.sideInset, (bounds.width - total) / 2) + item + gap
        let y = (Self.collapsedHeight - item) / 2
        for segment in segments {
            let heartSize = CGSize(width: unit * 7, height: unit * 6)
            let heartOrigin = CGPoint(
                x: x + (item - heartSize.width) / 2,
                y: y + (item - heartSize.height) / 2
            )
            drawHeart(at: heartOrigin, unit: unit, remainingPercent: segment.remainingPercent)
            x += item + gap
        }
    }

    private func drawBar(segment: QuotaBarSegment, originY: CGFloat, unit: CGFloat) {
        let heartSize = CGSize(width: unit * 7, height: unit * 6)
        let heartOrigin = CGPoint(
            x: QuotaBarLayout.heartLeadingX(),
            y: originY + (Self.barHeight - heartSize.height) / 2
        )
        // Expanded hearts stay full; the track encodes remaining %.
        drawHeart(at: heartOrigin, unit: unit, remainingPercent: 100)

        // Track starts after the control + heart column.
        let trackX = QuotaBarLayout.trackLeadingX(unit: unit)
        let innerW = max(8, Int(floor((bounds.width - trackX - Self.sideInset) / unit)))
        let innerH = 4
        let trackHeight = CGFloat(innerH) * unit
        let trackY = originY + (Self.barHeight - trackHeight) / 2
        let outerOrigin = CGPoint(x: trackX - unit, y: trackY - unit)
        let outerW = innerW + 2
        let outerH = innerH + 2

        // 8-bit black outline (stepped capsule), then white track interior.
        fillPixelCapsule(
            origin: outerOrigin,
            widthUnits: outerW,
            heightUnits: outerH,
            unit: unit,
            color: .black
        )
        fillPixelCapsule(
            origin: CGPoint(x: trackX, y: trackY),
            widthUnits: innerW,
            heightUnits: innerH,
            unit: unit,
            color: .white
        )

        let remaining = max(0, min(1, segment.remainingPercent / 100))
        let fillUnits = Int((remaining * Double(innerW)).rounded(.down))
        if fillUnits > 0 {
            let palette = fillPalette(forRemaining: segment.remainingPercent)
            drawPixelFill(
                origin: CGPoint(x: trackX, y: trackY),
                fillUnits: fillUnits,
                heightUnits: innerH,
                fullWidthUnits: innerW,
                unit: unit,
                palette: palette
            )
        }
    }

    private struct FillPalette {
        let light: NSColor
        let dark: NSColor
        let shadow: NSColor
    }

    private func fillPalette(forRemaining remaining: Double) -> FillPalette {
        // High → green; mid → yellow; low-mid → orange; critical → red.
        if remaining > 60 {
            return FillPalette(
                light: NSColor(calibratedRed: 0.38, green: 0.92, blue: 0.32, alpha: 1),
                dark: NSColor(calibratedRed: 0.16, green: 0.62, blue: 0.22, alpha: 1),
                shadow: NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.14, alpha: 1)
            )
        }
        if remaining > 40 {
            return FillPalette(
                light: NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.18, alpha: 1),
                dark: NSColor(calibratedRed: 0.86, green: 0.52, blue: 0.10, alpha: 1),
                shadow: NSColor(calibratedRed: 0.72, green: 0.38, blue: 0.06, alpha: 1)
            )
        }
        if remaining > 20 {
            return FillPalette(
                light: NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.16, alpha: 1),
                dark: NSColor(calibratedRed: 0.82, green: 0.28, blue: 0.10, alpha: 1),
                shadow: NSColor(calibratedRed: 0.62, green: 0.16, blue: 0.06, alpha: 1)
            )
        }
        return FillPalette(
            light: NSColor(calibratedRed: 0.95, green: 0.28, blue: 0.28, alpha: 1),
            dark: NSColor(calibratedRed: 0.68, green: 0.12, blue: 0.16, alpha: 1),
            shadow: NSColor(calibratedRed: 0.48, green: 0.06, blue: 0.10, alpha: 1)
        )
    }

    /// Fills a stepped pixel capsule (rounded ends via discrete circle test).
    private func fillPixelCapsule(
        origin: CGPoint,
        widthUnits: Int,
        heightUnits: Int,
        unit: CGFloat,
        color: NSColor
    ) {
        guard widthUnits > 0, heightUnits > 0 else { return }
        color.setFill()
        for py in 0..<heightUnits {
            for px in 0..<widthUnits where isInsidePixelCapsule(px: px, py: py, width: widthUnits, height: heightUnits) {
                pixelRect(origin: origin, px: px, py: py, unit: unit).fill()
            }
        }
    }

    /// Dual-tone fill + 1px top inner shadow, clipped to the capsule silhouette.
    private func drawPixelFill(
        origin: CGPoint,
        fillUnits: Int,
        heightUnits: Int,
        fullWidthUnits: Int,
        unit: CGFloat,
        palette: FillPalette
    ) {
        let mid = heightUnits / 2
        for py in 0..<heightUnits {
            // AppKit y-up: py 0 = bottom. Top interior row is the inner shadow.
            let color: NSColor
            if py == heightUnits - 1 {
                color = palette.shadow
            } else if py >= mid {
                color = palette.light
            } else {
                color = palette.dark
            }
            color.setFill()
            for px in 0..<fillUnits where isInsidePixelCapsule(px: px, py: py, width: fullWidthUnits, height: heightUnits) {
                pixelRect(origin: origin, px: px, py: py, unit: unit).fill()
            }
        }
    }

    /// Discrete capsule: flat middle, stepped semicircle caps (no antialias).
    private func isInsidePixelCapsule(px: Int, py: Int, width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, px >= 0, py >= 0, px < width, py < height else { return false }
        let radius = max(1, height / 2)
        if px >= radius && px < width - radius {
            return true
        }
        let centerY = Double(height - 1) / 2
        let centerX = px < radius
            ? Double(radius) - 0.5
            : Double(width - radius) - 0.5
        let dx = Double(px) - centerX
        let dy = Double(py) - centerY
        return dx * dx + dy * dy <= Double(radius) * Double(radius)
    }

    private func pixelRect(origin: CGPoint, px: Int, py: Int, unit: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + CGFloat(px) * unit,
            y: origin.y + CGFloat(py) * unit,
            width: unit,
            height: unit
        )
    }

    private func drawHeart(at origin: CGPoint, unit: CGFloat, remainingPercent: Double) {
        let outline = NSColor.black
        let fill = NSColor(calibratedRed: 0.92, green: 0.18, blue: 0.22, alpha: 1)
        let shade = NSColor(calibratedRed: 0.68, green: 0.08, blue: 0.14, alpha: 1)
        let highlight = NSColor.white

        // Classic 7×6 pixel heart silhouette (row 0 = bottom in AppKit y-up).
        let cells: Set<[Int]> = [
            [3, 0],
            [2, 1], [3, 1], [4, 1],
            [1, 2], [2, 2], [3, 2], [4, 2], [5, 2],
            [0, 3], [1, 3], [2, 3], [3, 3], [4, 3], [5, 3], [6, 3],
            [0, 4], [1, 4], [2, 4], [4, 4], [5, 4], [6, 4],
            [1, 5], [2, 5], [4, 5], [5, 5],
        ]
        // Darker red along bottom-right for depth.
        let shaded: Set<[Int]> = [
            [4, 1], [5, 2], [5, 3], [6, 3], [6, 4], [4, 2], [3, 0], [3, 1],
        ]

        let filledRows = QuotaBarLayout.heartFilledRowCount(remainingPercent: remainingPercent)
        let filledCells = Set(cells.filter { $0[1] < filledRows })

        // 1px black border from neighbors of the full silhouette (hollow upper stays outlined).
        var border = Set<[Int]>()
        for cell in cells {
            let cx = cell[0], cy = cell[1]
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)] {
                let n = [cx + dx, cy + dy]
                if !cells.contains(n) {
                    border.insert(n)
                }
            }
        }

        outline.setFill()
        for cell in border {
            pixelRect(origin: origin, px: cell[0], py: cell[1], unit: unit).fill()
        }
        for cell in filledCells {
            let color = shaded.contains(cell) ? shade : fill
            color.setFill()
            pixelRect(origin: origin, px: cell[0], py: cell[1], unit: unit).fill()
        }
        // White glint upper-left — only when those cells are filled.
        highlight.setFill()
        for glint in [[1, 4], [1, 5]] where filledCells.contains(glint) {
            pixelRect(origin: origin, px: glint[0], py: glint[1], unit: unit).fill()
        }
    }
}

/// Circular pixel control that collapses / expands the under-feet quota bars.
@MainActor
final class QuotaBarCollapseButton: NSButton {
    var isCollapsed = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        title = ""
        image = nil
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: QuotaBarLayout.controlSize, height: QuotaBarLayout.controlSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let previousAntialias = NSGraphicsContext.current?.shouldAntialias
        NSGraphicsContext.current?.shouldAntialias = false
        defer {
            if let previousAntialias {
                NSGraphicsContext.current?.shouldAntialias = previousAntialias
            }
        }

        drawCircularChrome(in: bounds)

        // AppKit y-up: pointing down = collapse when expanded; up = expand when collapsed.
        let pointingUp = isCollapsed
        let unit: CGFloat = 1.5
        let cols = 5
        let rows = 3
        let width = CGFloat(cols) * unit
        let height = CGFloat(rows) * unit
        let origin = CGPoint(x: bounds.midX - width / 2, y: bounds.midY - height / 2)

        let cells: [[Int]]
        if pointingUp {
            cells = [
                [2, 2],
                [1, 1], [2, 1], [3, 1],
                [0, 0], [1, 0], [2, 0], [3, 0], [4, 0],
            ]
        } else {
            cells = [
                [0, 2], [1, 2], [2, 2], [3, 2], [4, 2],
                [1, 1], [2, 1], [3, 1],
                [2, 0],
            ]
        }

        NSColor.black.setFill()
        for cell in cells {
            CGRect(
                x: origin.x + CGFloat(cell[0]) * unit,
                y: origin.y + CGFloat(cell[1]) * unit,
                width: unit,
                height: unit
            ).fill()
        }
    }

    private func drawCircularChrome(in rect: CGRect) {
        let unit: CGFloat = 1
        let size = Int(floor(min(rect.width, rect.height) / unit))
        guard size > 2 else { return }
        let origin = CGPoint(x: rect.midX - CGFloat(size) * unit / 2, y: rect.midY - CGFloat(size) * unit / 2)
        let radius = Double(size - 1) / 2
        let center = Double(size - 1) / 2

        NSColor.black.setFill()
        for py in 0..<size {
            for px in 0..<size {
                let dx = Double(px) - center
                let dy = Double(py) - center
                if dx * dx + dy * dy <= radius * radius {
                    CGRect(
                        x: origin.x + CGFloat(px) * unit,
                        y: origin.y + CGFloat(py) * unit,
                        width: unit,
                        height: unit
                    ).fill()
                }
            }
        }

        let inset = 2
        let inner = size - inset * 2
        guard inner > 0 else { return }
        let innerOrigin = CGPoint(x: origin.x + CGFloat(inset) * unit, y: origin.y + CGFloat(inset) * unit)
        let innerRadius = Double(inner - 1) / 2
        let innerCenter = Double(inner - 1) / 2
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        for py in 0..<inner {
            for px in 0..<inner {
                let dx = Double(px) - innerCenter
                let dy = Double(py) - innerCenter
                if dx * dx + dy * dy <= innerRadius * innerRadius {
                    CGRect(
                        x: innerOrigin.x + CGFloat(px) * unit,
                        y: innerOrigin.y + CGFloat(py) * unit,
                        width: unit,
                        height: unit
                    ).fill()
                }
            }
        }
    }
}
