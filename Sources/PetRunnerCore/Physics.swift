import CoreGraphics
import Foundation

public struct MotionState: Equatable {
    public var origin: CGPoint
    public var velocity: CGVector

    public init(origin: CGPoint, velocity: CGVector) {
        self.origin = origin
        self.velocity = velocity
    }
}

public struct PhysicsEngine {
    public let velocityRetentionPerSecond: CGFloat
    public let restitution: CGFloat
    public let stopSpeed: CGFloat
    public let maximumDeltaTime: TimeInterval

    public init(
        velocityRetentionPerSecond: CGFloat = 0.18,
        restitution: CGFloat = 0.72,
        stopSpeed: CGFloat = 8,
        maximumDeltaTime: TimeInterval = 1
    ) {
        self.velocityRetentionPerSecond = velocityRetentionPerSecond
        self.restitution = restitution
        self.stopSpeed = stopSpeed
        self.maximumDeltaTime = maximumDeltaTime
    }

    public func step(
        _ motion: inout MotionState,
        size: CGSize,
        bounds: CGRect,
        deltaTime: TimeInterval
    ) {
        let dt = CGFloat(max(0, min(deltaTime, maximumDeltaTime)))
        guard dt > 0 else { return }

        motion.origin.x += motion.velocity.dx * dt
        motion.origin.y += motion.velocity.dy * dt

        let maxX = max(bounds.minX, bounds.maxX - size.width)
        let maxY = max(bounds.minY, bounds.maxY - size.height)
        if motion.origin.x < bounds.minX {
            motion.origin.x = bounds.minX
            motion.velocity.dx = abs(motion.velocity.dx) * restitution
        } else if motion.origin.x > maxX {
            motion.origin.x = maxX
            motion.velocity.dx = -abs(motion.velocity.dx) * restitution
        }
        if motion.origin.y < bounds.minY {
            motion.origin.y = bounds.minY
            motion.velocity.dy = abs(motion.velocity.dy) * restitution
        } else if motion.origin.y > maxY {
            motion.origin.y = maxY
            motion.velocity.dy = -abs(motion.velocity.dy) * restitution
        }

        let retention = pow(velocityRetentionPerSecond, dt)
        motion.velocity.dx *= retention
        motion.velocity.dy *= retention
        if hypot(motion.velocity.dx, motion.velocity.dy) < stopSpeed {
            motion.velocity = .zero
        }
    }

    public static func clampedOrigin(_ origin: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
            y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        )
    }

    /// Centers `size` within `bounds`, then clamps so the full frame stays on-screen.
    public static func centeredOrigin(size: CGSize, bounds: CGRect) -> CGPoint {
        clampedOrigin(
            CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            size: size,
            bounds: bounds
        )
    }
}
