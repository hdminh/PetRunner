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

public struct IdleAction: Equatable, Sendable {
    public static let standard = IdleAction(columns: Array(0..<6))

    public let columns: [Int]

    public init(columns: [Int]) {
        let validColumns = columns.filter { AnimationState.idle.frameDurations.indices.contains($0) }
        self.columns = validColumns.isEmpty ? [0] : validColumns
    }
}

public struct AnimationPlayback {
    private enum IdlePhase {
        case waiting
        case playing
    }

    public private(set) var state: AnimationState
    public private(set) var frameIndex: Int
    public private(set) var elapsedInFrame: TimeInterval

    private let idleActions: [IdleAction]
    private let idleDelayProvider: () -> TimeInterval
    private let idleActionIndexProvider: (Int) -> Int
    private var idlePhase: IdlePhase
    private var idleWaitRemaining: TimeInterval
    private var idleActionColumns: [Int]
    private var idleActionPosition: Int

    public init(
        state: AnimationState = .idle,
        idleActions: [IdleAction] = [.standard],
        idleDelayProvider: @escaping () -> TimeInterval = { Double.random(in: 5...10) },
        idleActionIndexProvider: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }
    ) {
        self.state = state
        self.idleActions = idleActions.isEmpty ? [.standard] : idleActions
        self.idleDelayProvider = idleDelayProvider
        self.idleActionIndexProvider = idleActionIndexProvider
        frameIndex = 0
        elapsedInFrame = 0
        idlePhase = .waiting
        idleWaitRemaining = 0
        idleActionColumns = []
        idleActionPosition = 0
        if state == .idle {
            scheduleNextIdleAction()
        }
    }

    public mutating func start(_ newState: AnimationState) {
        state = newState
        frameIndex = 0
        elapsedInFrame = 0
        if newState == .idle {
            idlePhase = .waiting
            idleActionColumns = []
            idleActionPosition = 0
            scheduleNextIdleAction()
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
                if state.isOneShot {
                    start(.idle)
                    return
                }
                frameIndex = 0
            }
        }
    }

    private mutating func advanceIdle(by deltaTime: TimeInterval) {
        var remaining = deltaTime

        while remaining > 1e-12 {
            switch idlePhase {
            case .waiting:
                if remaining + 1e-12 < idleWaitRemaining {
                    idleWaitRemaining -= remaining
                    return
                }
                remaining = max(0, remaining - idleWaitRemaining)
                beginIdleAction()

            case .playing:
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
                    idlePhase = .waiting
                    idleActionColumns = []
                    idleActionPosition = 0
                    scheduleNextIdleAction()
                } else {
                    frameIndex = idleActionColumns[idleActionPosition]
                }
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
        idlePhase = .playing
        idleWaitRemaining = 0
    }

    private mutating func scheduleNextIdleAction() {
        let requestedDelay = idleDelayProvider()
        idleWaitRemaining = requestedDelay.isFinite ? min(max(requestedDelay, 5), 10) : 5
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
