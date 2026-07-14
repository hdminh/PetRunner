import CoreGraphics
import Foundation
import CPetRunnerBridge

/// Native-facing DTOs. Playback and direction math live in the Rust core.
public struct AtlasAddress: Hashable, Equatable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

public enum AnimationState: Int32, CaseIterable {
    case idle = 0
    case runningRight = 1
    case runningLeft = 2
    case waving = 3
    case jumping = 4
    case failed = 5
    case waiting = 6
    case running = 7
    case review = 8

    public var row: Int { Int(rawValue) }

    public var frameDurations: [TimeInterval] {
        let count = Int(RustBridge.shared.animationFrameCount(rawValue))
        guard count > 0 else { return [] }
        return (0..<count).compactMap { index in
            let duration = RustBridge.shared.animationFrameDuration(rawValue, Int32(index))
            return duration >= 0 ? duration : nil
        }
    }

    public var cyclesBeforeReturningToIdle: Int? {
        let cycles = RustBridge.shared.animationCyclesBeforeIdle(rawValue)
        return cycles > 0 ? Int(cycles) : nil
    }
}

/// Retained for source compatibility with existing native UI callers. The Rust runtime selects
/// the standard idle sequence; custom sequence injection was test-only legacy behavior.
public struct IdleAction: Equatable, Sendable {
    public static let standard = IdleAction(columns: Array(0..<6))
    public let columns: [Int]
    public init(columns: [Int]) { self.columns = columns }
}

public final class AnimationPlayback {
    private var handle: UnsafeMutableRawPointer?

    public init(
        state: AnimationState = .idle,
        idleActions _: [IdleAction] = [.standard],
        idleActionIndexProvider _: @escaping (Int) -> Int = { _ in 0 }
    ) {
        var newHandle: UnsafeMutableRawPointer?
        let result = RustBridge.shared.animationCreate(state.rawValue, &newHandle)
        guard result == RustBridge.ok, let newHandle else {
            fatalError(RustBridgeError.operationFailed(result).localizedDescription)
        }
        handle = newHandle
    }

    deinit { RustBridge.shared.animationDestroy(handle) }

    public var state: AnimationState { AnimationState(rawValue: snapshot.state) ?? .idle }
    public var frameIndex: Int { Int(snapshot.frame_index) }
    public var elapsedInFrame: TimeInterval { snapshot.elapsed_in_frame }
    public var atlasAddress: AtlasAddress { AtlasAddress(row: Int(snapshot.row), column: Int(snapshot.column)) }

    public func start(_ state: AnimationState) {
        let result = RustBridge.shared.animationStart(handle, state.rawValue)
        precondition(result == RustBridge.ok, RustBridgeError.operationFailed(result).localizedDescription)
    }

    public func advance(by deltaTime: TimeInterval) {
        let result = RustBridge.shared.animationAdvance(handle, deltaTime)
        precondition(result == RustBridge.ok, RustBridgeError.operationFailed(result).localizedDescription)
    }

    private var snapshot: PetrunnerAnimationSnapshot {
        var value = PetrunnerAnimationSnapshot(state: 0, frame_index: 0, elapsed_in_frame: 0, row: 0, column: 0)
        let result = RustBridge.shared.animationSnapshot(handle, &value)
        precondition(result == RustBridge.ok, RustBridgeError.operationFailed(result).localizedDescription)
        return value
    }
}

public enum LookDirection {
    public static func frameIndex(vector: CGVector, deadzone: CGFloat = 24) -> Int? {
        guard hypot(vector.dx, vector.dy) >= deadzone else { return nil }
        // The bridge exposes an atlas address because hosts only consume the V2 direction frame.
        guard let address = atlasAddress(forVector: vector, deadzone: deadzone) else { return nil }
        return address.row == 9 ? address.column : address.column + 8
    }

    public static func atlasAddress(for frameIndex: Int) -> AtlasAddress? {
        guard (0..<16).contains(frameIndex) else { return nil }
        return frameIndex < 8 ? AtlasAddress(row: 9, column: frameIndex) : AtlasAddress(row: 10, column: frameIndex - 8)
    }

    public static func atlasAddress(forVector vector: CGVector, deadzone: CGFloat = 24) -> AtlasAddress? {
        var address = PetrunnerAtlasAddress(row: 0, column: 0)
        guard RustBridge.shared.lookDirection(vector.dx, vector.dy, deadzone, &address) else { return nil }
        return AtlasAddress(row: Int(address.row), column: Int(address.column))
    }
}
