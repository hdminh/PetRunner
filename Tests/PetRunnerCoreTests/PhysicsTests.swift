import CoreGraphics
import Testing
@testable import PetRunnerCore

struct PhysicsTests {
    @Test func clampKeepsPetInsideVisibleFrame() {
        let bounds = CGRect(x: 100, y: 50, width: 800, height: 600)
        let result = PhysicsEngine.clampedOrigin(
            CGPoint(x: -20, y: 900),
            size: CGSize(width: 112, height: 121),
            bounds: bounds
        )
        #expect(result == CGPoint(x: 100, y: 529))
    }

    @Test func centeredOriginUsesVisibleFrameMidpoint() {
        let bounds = CGRect(x: 100, y: 50, width: 800, height: 600)
        let size = CGSize(width: 112, height: 121)
        let result = PhysicsEngine.centeredOrigin(size: size, bounds: bounds)
        #expect(abs(result.x - (bounds.midX - size.width / 2)) < 0.001)
        #expect(abs(result.y - (bounds.midY - size.height / 2)) < 0.001)
    }

    @Test func centeredOriginClampsWhenPetLargerThanBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 50, height: 40)
        let result = PhysicsEngine.centeredOrigin(size: CGSize(width: 112, height: 121), bounds: bounds)
        #expect(result == CGPoint(x: 10, y: 20))
    }

    @Test func stepBouncesAtRightEdgeWithConfiguredRestitution() {
        let engine = PhysicsEngine(velocityRetentionPerSecond: 1, restitution: 0.72, stopSpeed: 0)
        var motion = MotionState(origin: CGPoint(x: 385, y: 100), velocity: CGVector(dx: 200, dy: 0))
        engine.step(
            &motion,
            size: CGSize(width: 100, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            deltaTime: 0.1
        )
        #expect(abs(motion.origin.x - 400) < 0.001)
        #expect(abs(motion.velocity.dx + 144) < 0.001)
    }

    @Test func stepAppliesDampingAndStopsSmallVelocity() {
        let engine = PhysicsEngine(velocityRetentionPerSecond: 0.25, restitution: 0.72, stopSpeed: 8)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var fast = MotionState(origin: .zero, velocity: CGVector(dx: 100, dy: 0))
        engine.step(&fast, size: CGSize(width: 100, height: 100), bounds: bounds, deltaTime: 0.5)
        #expect(abs(fast.velocity.dx - 50) < 0.001)

        var slow = MotionState(origin: .zero, velocity: CGVector(dx: 7, dy: 0))
        engine.step(&slow, size: CGSize(width: 100, height: 100), bounds: bounds, deltaTime: 0.1)
        #expect(slow.velocity == .zero)
    }

    @Test func stepClampsLongFrameDelta() {
        let engine = PhysicsEngine(
            velocityRetentionPerSecond: 1,
            restitution: 0.72,
            stopSpeed: 0,
            maximumDeltaTime: 0.05
        )
        var motion = MotionState(origin: CGPoint(x: 100, y: 100), velocity: CGVector(dx: 100, dy: 0))
        engine.step(
            &motion,
            size: CGSize(width: 100, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            deltaTime: 2
        )
        #expect(abs(motion.origin.x - 105) < 0.001)
    }
}
