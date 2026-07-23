import AppKit
import OSLog
import PetRunnerCore

@MainActor
final class OverlayPanelController: NSObject, SpriteViewDelegate {
    var onPositionChanged: ((CGPoint) -> Void)?
    var onSizeChanged: ((CGFloat) -> Void)?
    var onFrameChanged: ((CGRect) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)? {
        didSet { spriteView.contextMenuProvider = contextMenuProvider }
    }

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
    private var lastPointerMovementTime: TimeInterval = -.infinity
    private var monitorAnimation: AnimationState?
    private var autonomy = AutonomyPolicy()
    private var autonomyEnabled = true
    private var autonomousWalk: AutonomousWalk?
    private var autonomousAnimationActive = false

    private let physicalPointerLookDuration: TimeInterval = 0.6

    var frame: CGRect { panel.frame }

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
        cancelAutonomy()
        lastPointerLocation = nil
        lastPointerMovementTime = -.infinity
        resize(to: width, anchorTopLeft: false)

        let initial = savedOrigin ?? defaultOrigin(for: panel.frame.size)
        panel.setFrameOrigin(clampedOrigin(initial))
        renderCurrentFrame()
        panel.orderFrontRegardless()
        onFrameChanged?(panel.frame)
    }

    func hide() {
        panel.orderOut(nil)
        atlas = nil
        pet = nil
        motion = nil
        cancelAutonomy()
    }

    func setWidth(_ width: CGFloat) {
        cancelAutonomy()
        resize(to: width, anchorTopLeft: true)
        onSizeChanged?(panel.frame.width)
        onPositionChanged?(panel.frame.origin)
        onFrameChanged?(panel.frame)
    }

    func setMonitorAnimation(_ state: AnimationState?) {
        guard monitorAnimation != state else { return }
        cancelAutonomy()
        monitorAnimation = state
        playback.start(state ?? (motion == nil ? .idle : playback.state))
        renderCurrentFrame()
    }

    func setAutonomyEnabled(_ enabled: Bool) {
        autonomyEnabled = enabled
        cancelAutonomy()
        renderCurrentFrame()
    }

    func setAutonomyConfiguration(_ configuration: AutonomyConfiguration) {
        autonomy.update(configuration: configuration)
        cancelAutonomy()
        renderCurrentFrame()
    }

    func resetPositionToDefault() {
        // Stop in-flight throw/walk so the next tick cannot yank the pet off the
        // newly chosen origin (which looked like a "disappear" on multi-monitor setups).
        motion = nil
        cancelAutonomy()
        interactionActive = false
        dragStartPointer = nil
        dragStartOrigin = nil
        previousDragPointer = nil

        let size = panel.frame.size
        let origin = clampedOrigin(defaultOrigin(for: size), preferring: NSScreen.main)
        panel.setFrameOrigin(origin)
        if atlas != nil {
            panel.orderFrontRegardless()
        }
        if monitorAnimation == nil {
            playback.start(.idle)
        }
        onPositionChanged?(origin)
        onFrameChanged?(panel.frame)
        renderCurrentFrame()
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
        cancelAutonomy()
        guard monitorAnimation == nil else { return }
        playback.start(.jumping)
        renderCurrentFrame()
    }

    func spriteViewDidHover(_ view: SpriteView) {
        cancelAutonomy()
        guard monitorAnimation == nil else { return }
        guard !interactionActive, motion == nil, playback.state == .idle else { return }
        guard let action = autonomy.startAction() else { return }
        performAutonomousAction(action)
        renderCurrentFrame()
    }

    func spriteViewDidEndHover(_ view: SpriteView) {
        cancelAutonomy()
        guard monitorAnimation == nil else { return }
        guard !interactionActive, motion == nil, playback.state == .jumping else { return }
        playback.start(.idle)
        renderCurrentFrame()
    }

    func spriteView(_ view: SpriteView, dragDidBeginAt pointer: CGPoint) {
        motion = nil
        cancelAutonomy()
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
        onFrameChanged?(panel.frame)
        renderCurrentFrame()
    }

    func spriteView(_ view: SpriteView, dragDidEndWith velocity: CGVector) {
        cancelAutonomy()
        interactionActive = false
        dragStartPointer = nil
        dragStartOrigin = nil
        previousDragPointer = nil
        onPositionChanged?(panel.frame.origin)
        if hypot(velocity.dx, velocity.dy) >= 120 {
            motion = MotionState(origin: panel.frame.origin, velocity: velocity)
            updateMovementAnimation(horizontalMotion: velocity.dx, useRightWhenVertical: true)
        } else {
            playback.start(monitorAnimation ?? .idle)
        }
        renderCurrentFrame()
    }

    func spriteView(_ view: SpriteView, resizeDidBeginAt pointer: CGPoint) {
        motion = nil
        cancelAutonomy()
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
        onFrameChanged?(panel.frame)
    }

    @objc private func screenConfigurationChanged() {
        cancelAutonomy()
        clampToAvailableScreens()
    }

    private func tick() {
        guard atlas != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = max(0, min(now - previousTick, 0.05))
        previousTick = now

        playback.advance(by: delta)
        if var currentMotion = motion {
            let bounds = bestScreen(for: panel.frame)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
            physics.step(&currentMotion, size: panel.frame.size, bounds: bounds, deltaTime: delta)
            panel.setFrameOrigin(currentMotion.origin)
            onFrameChanged?(panel.frame)
            if currentMotion.velocity == .zero {
                motion = nil
                playback.start(monitorAnimation ?? .idle)
                onPositionChanged?(panel.frame.origin)
                onFrameChanged?(panel.frame)
            } else {
                motion = currentMotion
                updateMovementAnimation(horizontalMotion: currentMotion.velocity.dx, useRightWhenVertical: true)
            }
        }
        advanceAutonomy(now: now, delta: delta)
        renderCurrentFrame()
    }

    private func advanceAutonomy(now: TimeInterval, delta: TimeInterval) {
        if var walk = autonomousWalk {
            walk.elapsed = min(walk.duration, walk.elapsed + delta)
            let progress = walk.duration == 0 ? 1 : walk.elapsed / walk.duration
            panel.setFrameOrigin(clampedOrigin(CGPoint(
                x: walk.origin.x + (walk.targetX - walk.origin.x) * progress,
                y: walk.origin.y
            )))
            onFrameChanged?(panel.frame)
            if walk.elapsed >= walk.duration {
                autonomousWalk = nil
                autonomy.finish()
                playback.start(.idle)
                onPositionChanged?(panel.frame.origin)
                onFrameChanged?(panel.frame)
            } else {
                autonomousWalk = walk
            }
            return
        }
        if autonomousAnimationActive, playback.state == .idle {
            autonomousAnimationActive = false
            autonomy.finish()
        }
        guard isAutonomyEligible,
              let action = autonomy.tick(now: now, isEligible: true)
        else { return }
        performAutonomousAction(action)
    }

    private func performAutonomousAction(_ action: AutonomousAction) {
        switch action {
        case let .walk(duration): startAutonomousWalk(duration: duration)
        case .wave:
            autonomousAnimationActive = true
            playback.start(.waving)
        case .jump:
            autonomousAnimationActive = true
            playback.start(.jumping)
        case .cry:
            autonomousAnimationActive = true
            playback.start(.failed)
        }
    }

    private var isAutonomyEligible: Bool {
        panel.isVisible && autonomyEnabled && monitorAnimation == nil && !interactionActive && motion == nil && autonomousWalk == nil && !autonomousAnimationActive && playback.state == .idle
    }

    private func startAutonomousWalk(duration: TimeInterval) {
        let bounds = bestScreen(for: panel.frame)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let leftSpace = panel.frame.minX - bounds.minX
        let rightSpace = bounds.maxX - panel.frame.maxX
        let direction: CGFloat = rightSpace >= leftSpace ? 1 : -1
        let available = max(0, direction > 0 ? rightSpace : leftSpace)
        let distance = min(available, max(panel.frame.width * 0.75, 96 * duration))
        guard distance >= 8 else {
            autonomy.finish()
            return
        }
        autonomousWalk = AutonomousWalk(origin: panel.frame.origin, targetX: panel.frame.origin.x + direction * distance, duration: duration)
        playback.start(direction < 0 ? .runningLeft : .runningRight)
    }

    private func cancelAutonomy() {
        let hadAutonomousAction = autonomy.isPerforming || autonomousWalk != nil || autonomousAnimationActive
        autonomy.cancel()
        autonomousWalk = nil
        autonomousAnimationActive = false
        if hadAutonomousAction, monitorAnimation == nil {
            playback.start(.idle)
        }
    }

    private func updateMovementAnimation(
        horizontalMotion: CGFloat,
        useRightWhenVertical: Bool = false
    ) {
        guard monitorAnimation == nil else { return }
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
        let address = recentPointerLookAddress(for: pet) ?? playback.atlasAddress
        spriteView.display(atlas.frame(at: address))
    }

    private func recentPointerLookAddress(for pet: PetDescriptor) -> AtlasAddress? {
        guard pet.version == .v2,
              playback.state == .idle,
              !interactionActive,
              motion == nil
        else { return nil }

        let pointer = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        if pointer != lastPointerLocation {
            lastPointerLocation = pointer
            lastPointerMovementTime = now
        }
        guard now - lastPointerMovementTime <= physicalPointerLookDuration else { return nil }

        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let vector = CGVector(dx: pointer.x - center.x, dy: pointer.y - center.y)
        guard let index = LookDirection.frameIndex(vector: vector) else { return nil }
        return LookDirection.atlasAddress(for: index)
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
        // Primary display (menu-bar screen). Use visibleFrame so menu bar / dock are respected.
        let bounds = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        return PhysicsEngine.centeredOrigin(size: size, bounds: bounds)
    }

    private func clampedOrigin(_ origin: CGPoint, preferring preferredScreen: NSScreen? = nil) -> CGPoint {
        let proposed = CGRect(origin: origin, size: panel.frame.size)
        let screen = preferredScreen ?? bestScreen(for: proposed) ?? NSScreen.main
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

private struct AutonomousWalk {
    let origin: CGPoint
    let targetX: CGFloat
    let duration: TimeInterval
    var elapsed: TimeInterval = 0
}
