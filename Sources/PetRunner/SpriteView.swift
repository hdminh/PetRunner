import AppKit
import PetRunnerCore

@MainActor
protocol SpriteViewDelegate: AnyObject {
    func spriteViewDidClick(_ view: SpriteView)
    func spriteViewDidHover(_ view: SpriteView)
    func spriteViewDidEndHover(_ view: SpriteView)
    func spriteView(_ view: SpriteView, dragDidBeginAt pointer: CGPoint)
    func spriteView(_ view: SpriteView, dragDidMoveTo pointer: CGPoint)
    func spriteView(_ view: SpriteView, dragDidEndWith velocity: CGVector)
    func spriteView(_ view: SpriteView, resizeDidBeginAt pointer: CGPoint)
    func spriteView(_ view: SpriteView, resizeDidMoveTo pointer: CGPoint)
    func spriteViewDidEndResize(_ view: SpriteView)
}

@MainActor
final class SpriteView: NSView {
    weak var delegate: SpriteViewDelegate?
    var contextMenuProvider: (() -> NSMenu?)?

    private var image: NSImage?
    private var trackingAreaReference: NSTrackingArea?
    private var mouseDownPoint: CGPoint?
    private var dragStarted = false
    private var resizing = false
    private var samples: [(time: TimeInterval, point: CGPoint)] = []
    private var showsResizeHandle = false

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ frame: CGImage?) {
        image = frame.map { NSImage(cgImage: $0, size: bounds.size) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        image?.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        guard showsResizeHandle || resizing else { return }
        let handleRect = resizeHandleRect.insetBy(dx: 3, dy: 3)
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        for offset in stride(from: CGFloat(3), through: 11, by: 4) {
            path.move(to: CGPoint(x: handleRect.maxX - offset, y: handleRect.minY))
            path.line(to: CGPoint(x: handleRect.maxX, y: handleRect.minY + offset))
        }
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseMoved(with event: NSEvent) {
        let shouldShow = resizeHandleRect.contains(convert(event.locationInWindow, from: nil))
        if shouldShow != showsResizeHandle {
            showsResizeHandle = shouldShow
            needsDisplay = true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        delegate?.spriteViewDidHover(self)
    }

    override func mouseExited(with event: NSEvent) {
        showsResizeHandle = false
        needsDisplay = true
        delegate?.spriteViewDidEndHover(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    override func mouseDown(with event: NSEvent) {
        let pointer = NSEvent.mouseLocation
        mouseDownPoint = pointer
        dragStarted = false
        samples = [(event.timestamp, pointer)]
        resizing = resizeHandleRect.contains(convert(event.locationInWindow, from: nil))
        if resizing {
            delegate?.spriteView(self, resizeDidBeginAt: pointer)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pointer = NSEvent.mouseLocation
        if resizing {
            delegate?.spriteView(self, resizeDidMoveTo: pointer)
            return
        }
        guard let mouseDownPoint else { return }
        if !dragStarted, hypot(pointer.x - mouseDownPoint.x, pointer.y - mouseDownPoint.y) >= 4 {
            dragStarted = true
            delegate?.spriteView(self, dragDidBeginAt: mouseDownPoint)
        }
        guard dragStarted else { return }
        samples.append((event.timestamp, pointer))
        samples.removeAll { event.timestamp - $0.time > 0.12 }
        delegate?.spriteView(self, dragDidMoveTo: pointer)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            samples.removeAll()
            dragStarted = false
            resizing = false
            needsDisplay = true
        }
        if resizing {
            delegate?.spriteViewDidEndResize(self)
            return
        }
        guard dragStarted else {
            delegate?.spriteViewDidClick(self)
            return
        }
        let end = NSEvent.mouseLocation
        let first = samples.first ?? (event.timestamp, end)
        let elapsed = max(event.timestamp - first.time, 0.001)
        let velocity = CGVector(
            dx: (end.x - first.point.x) / elapsed,
            dy: (end.y - first.point.y) / elapsed
        )
        delegate?.spriteView(self, dragDidEndWith: velocity)
    }

    private var resizeHandleRect: CGRect {
        CGRect(x: bounds.maxX - 20, y: bounds.minY, width: 20, height: 20)
    }
}
