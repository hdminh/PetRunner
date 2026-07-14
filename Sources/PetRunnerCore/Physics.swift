import CoreGraphics
import Foundation
import CPetRunnerBridge

/// Native coordinate adapters around Rust-owned motion calculations.
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

    public func step(_ motion: inout MotionState, size: CGSize, bounds: CGRect, deltaTime: TimeInterval) {
        var coreMotion = PetrunnerMotionState(
            x: motion.origin.x,
            y: motion.origin.y,
            velocity_x: motion.velocity.dx,
            velocity_y: motion.velocity.dy
        )
        var result = PetrunnerPhysicsResult(horizontal_bounce: false, vertical_bounce: false)
        let status = RustBridge.shared.physicsStep(
            &coreMotion,
            PetrunnerSize(width: size.width, height: size.height),
            PetrunnerRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
            velocityRetentionPerSecond,
            restitution,
            stopSpeed,
            maximumDeltaTime,
            deltaTime,
            &result
        )
        precondition(status == RustBridge.ok, RustBridgeError.operationFailed(status).localizedDescription)
        motion.origin = CGPoint(x: coreMotion.x, y: coreMotion.y)
        motion.velocity = CGVector(dx: coreMotion.velocity_x, dy: coreMotion.velocity_y)
    }

    public static func clampedOrigin(_ origin: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
        var result = PetrunnerMotionState(x: 0, y: 0, velocity_x: 0, velocity_y: 0)
        let status = RustBridge.shared.physicsClamp(
            origin.x,
            origin.y,
            PetrunnerSize(width: size.width, height: size.height),
            PetrunnerRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
            &result
        )
        precondition(status == RustBridge.ok, RustBridgeError.operationFailed(status).localizedDescription)
        return CGPoint(x: result.x, y: result.y)
    }
}
