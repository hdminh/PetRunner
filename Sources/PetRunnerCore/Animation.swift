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
        // Codex pets use a deliberately unhurried idle pass. Keep the six
        // standard frames, but play each at one third of the former speed.
        case .idle: [0.84, 0.33, 0.33, 0.42, 0.42, 0.96]
        case .runningRight, .runningLeft: Array(repeating: 0.12, count: 7) + [0.22]
        case .waving: Array(repeating: 0.14, count: 3) + [0.28]
        case .jumping: Array(repeating: 0.14, count: 4) + [0.28]
        case .failed: Array(repeating: 0.14, count: 7) + [0.24]
        case .waiting: Array(repeating: 0.15, count: 5) + [0.26]
        case .running: Array(repeating: 0.12, count: 5) + [0.22]
        case .review: Array(repeating: 0.15, count: 5) + [0.28]
        }
    }

    public var cyclesBeforeReturningToIdle: Int? {
        self == .jumping ? 3 : nil
    }
}

public struct IdleAction: Equatable, Sendable {
    public static let standard = IdleAction(columns: Array(0..<6))

    public let columns: [Int]

    public init(columns: [Int]) {
        let validColumns = columns.filter { AnimationState.idle.frameDurations.indices.contains($0) }
        self.columns = validColumns.isEmpty ? [0] : validColumns
    }
}

public struct AnimationPlayback {
    public private(set) var state: AnimationState
    public private(set) var frameIndex: Int
    public private(set) var elapsedInFrame: TimeInterval

    private let idleActions: [IdleAction]
    private let idleActionIndexProvider: (Int) -> Int
    private var idleActionColumns: [Int]
    private var idleActionPosition: Int
    private var idlePauseRemaining: TimeInterval
    private var completedStateCycles: Int

    public init(
        state: AnimationState = .idle,
        idleActions: [IdleAction] = [.standard],
        idleActionIndexProvider: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }
    ) {
        self.state = state
        self.idleActions = idleActions.isEmpty ? [.standard] : idleActions
        self.idleActionIndexProvider = idleActionIndexProvider
        frameIndex = 0
        elapsedInFrame = 0
        idleActionColumns = []
        idleActionPosition = 0
        idlePauseRemaining = 0
        completedStateCycles = 0
        if state == .idle {
            beginIdleAction()
        }
    }

    public mutating func start(_ newState: AnimationState) {
        state = newState
        frameIndex = 0
        elapsedInFrame = 0
        idlePauseRemaining = 0
        completedStateCycles = 0
        if newState == .idle {
            beginIdleAction()
        }
    }

    public mutating func advance(by deltaTime: TimeInterval) {
        guard deltaTime > 0 else { return }
        if state == .idle {
            advanceIdle(by: deltaTime)
            return
        }

        elapsedInFrame += deltaTime

        while elapsedInFrame + 1e-12 >= state.frameDurations[frameIndex] {
            elapsedInFrame -= state.frameDurations[frameIndex]
            frameIndex += 1
            if frameIndex == state.frameDurations.count {
                if let cyclesBeforeReturningToIdle = state.cyclesBeforeReturningToIdle {
                    completedStateCycles += 1
                    if completedStateCycles == cyclesBeforeReturningToIdle {
                        start(.idle)
                        return
                    }
                }
                frameIndex = 0
            }
        }
    }

    private mutating func advanceIdle(by deltaTime: TimeInterval) {
        var remaining = deltaTime

        while remaining > 1e-12 {
            if idlePauseRemaining > 0 {
                if remaining + 1e-12 < idlePauseRemaining {
                    idlePauseRemaining -= remaining
                    return
                }
                remaining = max(0, remaining - idlePauseRemaining)
                idlePauseRemaining = 0
                beginIdleAction()
                continue
            }

            let frameDuration = AnimationState.idle.frameDurations[frameIndex]
            let timeToBoundary = frameDuration - elapsedInFrame
            if remaining + 1e-12 < timeToBoundary {
                elapsedInFrame += remaining
                return
            }

            remaining = max(0, remaining - timeToBoundary)
            elapsedInFrame = 0
            idleActionPosition += 1
            if idleActionPosition == idleActionColumns.count {
                frameIndex = 0
                idlePauseRemaining = 1
            } else {
                frameIndex = idleActionColumns[idleActionPosition]
            }
        }
    }

    private mutating func beginIdleAction() {
        let count = idleActions.count
        let requestedIndex = idleActionIndexProvider(count)
        let index = ((requestedIndex % count) + count) % count
        idleActionColumns = idleActions[index].columns
        idleActionPosition = 0
        frameIndex = idleActionColumns[0]
        elapsedInFrame = 0
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
