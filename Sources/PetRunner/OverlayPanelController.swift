import AppKit
import OSLog
import PetRunnerCore

@MainActor
final class OverlayPanelController: NSObject, SpriteViewDelegate {
    var onPositionChanged: ((CGPoint) -> Void)?
    var onSizeChanged: ((CGFloat) -> Void)?

    private let logger = Logger(subsystem: "vn.hodinhminh.petrunner", category: "overlay")
    private let panel: NSPanel
    private let spriteView: SpriteView
    private let physics = PhysicsEngine(maximumDeltaTime: 0.05)
    private var atlas: SpriteAtlas?
    private var pet: PetDescriptor?
    private var playback = AnimationPlayback()
    private var timer: Timer?
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var motion: MotionState?
    private var dragStartPointer: CGPoint?
    private var dragStartOrigin: CGPoint?
    private var previousDragPointer: CGPoint?
    private var resizeStartPointer: CGPoint?
    private var resizeStartWidth: CGFloat?
    private var interactionActive = false
    private var lastPointerLocation: CGPoint?
    private var lastPointerMovedAt = 0.0

    override init() {
        spriteView = SpriteView(frame: CGRect(x: 0, y: 0, width: 112, height: 121.33))
        panel = NSPanel(
            contentRect: spriteView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        spriteView.delegate = self
        panel.contentView = spriteView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "PetRunner Pet"

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show(pet: PetDescriptor, width: CGFloat, savedOrigin: CGPoint?) throws {
        let newAtlas = try SpriteAtlas(contentsOf: pet.spritesheetURL, version: pet.version)
        atlas = newAtlas
        self.pet = pet
        playback.start(.idle)
        motion = nil
        lastPointerLocation = NSEvent.mouseLocation
        lastPointerMovedAt = 0
        resize(to: width, anchorTopLeft: false)

        let initial = savedOrigin ?? defaultOrigin(for: panel.frame.size)
        panel.setFrameOrigin(clampedOrigin(initial))
        renderCurrentFrame()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        atlas = nil
        pet = nil
        motion = nil
        lastPointerLocation = nil
        lastPointerMovedAt = 0
    }

    func setWidth(_ width: CGFloat) {
        resize(to: width, anchorTopLeft: true)
        onSizeChanged?(panel.frame.width)
        onPositionChanged?(panel.frame.origin)
    }

    func clampToAvailableScreens() {
        let origin = clampedOrigin(panel.frame.origin)
        panel.setFrameOrigin(origin)
        onPositionChanged?(origin)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        panel.orderOut(nil)
    }

    func spriteViewDidClick(_ view: SpriteView) {
        motion = nil
        playback.start(.jumping)
        renderCurrentFrame()
    }

    func spriteView(_ view: SpriteView, dragDidBeginAt pointer: CGPoint) {
        motion = nil
        interactionActive = true
        dragStartPointer = pointer
        dragStartOrigin = panel.frame.origin
        previousDragPointer = pointer
    }

    func spriteView(_ view: SpriteView, dragDidMoveTo pointer: CGPoint) {
        guard let dragStartPointer, let dragStartOrigin else { return }
        let horizontalDelta = pointer.x - (previousDragPointer?.x ?? dragStartPointer.x)
        updateMovementAnimation(horizontalMotion: horizontalDelta)
        previousDragPointer = pointer
        let candidate = CGPoint(
            x: dragStartOrigin.x + pointer.x - dragStartPointer.x,
            y: dragStartOrigin.y + pointer.y - dragStartPointer.y
        )
        panel.setFrameOrigin(clampedOrigin(candidate))
        renderCurrentFrame()
    }

    func spriteView(_ view: SpriteView, dragDidEndWith velocity: CGVector) {
        interactionActive = false
        dragStartPointer = nil
        dragStartOrigin = nil
        previousDragPointer = nil
        onPositionChanged?(panel.frame.origin)
        if hypot(velocity.dx, velocity.dy) >= 120 {
            motion = MotionState(origin: panel.frame.origin, velocity: velocity)
            updateMovementAnimation(horizontalMotion: velocity.dx, useRightWhenVertical: true)
        } else {
            playback.start(.idle)
        }
        renderCurrentFrame()
    }

    func spriteView(_ view: SpriteView, resizeDidBeginAt pointer: CGPoint) {
        motion = nil
        playback.start(.idle)
        interactionActive = true
        resizeStartPointer = pointer
        resizeStartWidth = panel.frame.width
    }

    func spriteView(_ view: SpriteView, resizeDidMoveTo pointer: CGPoint) {
        guard let resizeStartPointer, let resizeStartWidth else { return }
        resize(to: resizeStartWidth + pointer.x - resizeStartPointer.x, anchorTopLeft: true)
    }

    func spriteViewDidEndResize(_ view: SpriteView) {
        interactionActive = false
        resizeStartPointer = nil
        resizeStartWidth = nil
        onSizeChanged?(panel.frame.width)
        onPositionChanged?(panel.frame.origin)
    }

    @objc private func screenConfigurationChanged() {
        clampToAvailableScreens()
    }

    private func tick() {
        guard atlas != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = max(0, min(now - previousTick, 0.05))
        previousTick = now

        playback.advance(by: delta)
        updatePointerMotion(at: now)
        if var currentMotion = motion {
            let bounds = bestScreen(for: panel.frame)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
            physics.step(&currentMotion, size: panel.frame.size, bounds: bounds, deltaTime: delta)
            panel.setFrameOrigin(currentMotion.origin)
            if currentMotion.velocity == .zero {
                motion = nil
                playback.start(.idle)
                onPositionChanged?(panel.frame.origin)
            } else {
                motion = currentMotion
                updateMovementAnimation(horizontalMotion: currentMotion.velocity.dx, useRightWhenVertical: true)
            }
        }
        renderCurrentFrame()
    }

    private func updateMovementAnimation(
        horizontalMotion: CGFloat,
        useRightWhenVertical: Bool = false
    ) {
        let movementState: AnimationState
        if abs(horizontalMotion) >= 0.5 {
            movementState = horizontalMotion < 0 ? .runningLeft : .runningRight
        } else {
            guard useRightWhenVertical, playback.state != .runningLeft, playback.state != .runningRight else {
                return
            }
            movementState = .runningRight
        }
        if playback.state != movementState {
            playback.start(movementState)
        }
    }

    private func renderCurrentFrame() {
        guard let atlas, let pet else { return }
        var address = playback.atlasAddress
        if pet.version == .v2,
           playback.state == .idle,
           !interactionActive,
           motion == nil,
           ProcessInfo.processInfo.systemUptime - lastPointerMovedAt <= 0.75 {
            let pointer = NSEvent.mouseLocation
            let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            let vector = CGVector(dx: pointer.x - center.x, dy: pointer.y - center.y)
            if let index = LookDirection.frameIndex(vector: vector),
               let lookAddress = LookDirection.atlasAddress(for: index) {
                address = lookAddress
            }
        }
        spriteView.display(atlas.frame(at: address))
    }

    private func updatePointerMotion(at now: TimeInterval) {
        let location = NSEvent.mouseLocation
        defer { lastPointerLocation = location }
        guard let lastPointerLocation, hypot(location.x - lastPointerLocation.x, location.y - lastPointerLocation.y) >= 1 else {
            return
        }
        lastPointerMovedAt = now
    }

    private func resize(to requestedWidth: CGFloat, anchorTopLeft: Bool) {
        let width = min(max(requestedWidth, 80), 224)
        let size = CGSize(width: width, height: width * SpriteAtlas.cellSize.height / SpriteAtlas.cellSize.width)
        let oldFrame = panel.frame
        var origin = oldFrame.origin
        if anchorTopLeft {
            origin.y = oldFrame.maxY - size.height
        }
        let frame = CGRect(origin: origin, size: size)
        panel.setFrame(frame, display: true)
        spriteView.frame = CGRect(origin: .zero, size: size)
        panel.setFrameOrigin(clampedOrigin(panel.frame.origin))
    }

    private func defaultOrigin(for size: CGSize) -> CGPoint {
        guard let frame = NSScreen.main?.visibleFrame else { return CGPoint(x: 40, y: 40) }
        return CGPoint(x: frame.maxX - size.width - 32, y: frame.minY + 32)
    }

    private func clampedOrigin(_ origin: CGPoint) -> CGPoint {
        let proposed = CGRect(origin: origin, size: panel.frame.size)
        let screen = bestScreen(for: proposed) ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return origin }
        return PhysicsEngine.clampedOrigin(origin, size: panel.frame.size, bounds: bounds)
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        guard !NSScreen.screens.isEmpty else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let containing = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }
        return NSScreen.screens.min {
            squaredDistance(center, to: $0.visibleFrame) < squaredDistance(center, to: $1.visibleFrame)
        }
    }

    private func squaredDistance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
