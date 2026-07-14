import CoreGraphics
import Foundation

public struct AtlasAddress: Hashable, Equatable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

public enum AnimationState: String, CaseIterable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review

    public var row: Int {
        switch self {
        case .idle: 0
        case .runningRight: 1
        case .runningLeft: 2
        case .waving: 3
        case .jumping: 4
        case .failed: 5
        case .waiting: 6
        case .running: 7
        case .review: 8
        }
    }

    public var frameDurations: [TimeInterval] {
        switch self {
        case .idle: [0.28, 0.11, 0.11, 0.14, 0.14, 0.32]
        case .runningRight, .runningLeft: Array(repeating: 0.12, count: 7) + [0.22]
        case .waving: Array(repeating: 0.14, count: 3) + [0.28]
        case .jumping: Array(repeating: 0.14, count: 4) + [0.28]
        case .failed: Array(repeating: 0.14, count: 7) + [0.24]
        case .waiting: Array(repeating: 0.15, count: 5) + [0.26]
        case .running: Array(repeating: 0.12, count: 5) + [0.22]
        case .review: Array(repeating: 0.15, count: 5) + [0.28]
        }
    }

    public var isOneShot: Bool { self == .jumping }
}

public struct AnimationPlayback {
    public private(set) var state: AnimationState
    public private(set) var frameIndex: Int
    public private(set) var elapsedInFrame: TimeInterval

    public init(state: AnimationState = .idle) {
        self.state = state
        frameIndex = 0
        elapsedInFrame = 0
    }

    public mutating func start(_ newState: AnimationState) {
        state = newState
        frameIndex = 0
        elapsedInFrame = 0
    }

    public mutating func advance(by deltaTime: TimeInterval) {
        guard deltaTime > 0 else { return }
        elapsedInFrame += deltaTime

        while elapsedInFrame + 1e-12 >= state.frameDurations[frameIndex] {
            elapsedInFrame -= state.frameDurations[frameIndex]
            frameIndex += 1
            if frameIndex == state.frameDurations.count {
                if state.isOneShot {
                    start(.idle)
                    return
                }
                frameIndex = 0
            }
        }
    }

    public var atlasAddress: AtlasAddress {
        AtlasAddress(row: state.row, column: frameIndex)
    }
}

public enum LookDirection {
    public static func frameIndex(vector: CGVector, deadzone: CGFloat = 24) -> Int? {
        guard hypot(vector.dx, vector.dy) >= deadzone else { return nil }
        var angle = atan2(vector.dx, vector.dy)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle / (.pi / 8)).rounded()) % 16
    }

    public static func atlasAddress(for frameIndex: Int) -> AtlasAddress? {
        guard (0..<16).contains(frameIndex) else { return nil }
        return frameIndex < 8
            ? AtlasAddress(row: 9, column: frameIndex)
            : AtlasAddress(row: 10, column: frameIndex - 8)
    }
}
