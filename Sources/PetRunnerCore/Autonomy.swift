import Foundation

public enum AutonomousActionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case walk
    case wave
    case jump
    case cry

    public var displayLabel: String {
        switch self {
        case .walk: "Walk"
        case .wave: "Wave"
        case .jump: "Jump"
        case .cry: "Cry"
        }
    }

    fileprivate var weight: Double {
        switch self {
        case .walk: 0.40
        case .wave: 0.25
        case .jump: 0.25
        case .cry: 0.10
        }
    }
}

public enum AutonomousAction: Equatable, Sendable {
    case walk(duration: TimeInterval)
    case wave
    case jump
    case cry

    public var kind: AutonomousActionKind {
        switch self {
        case .walk: .walk
        case .wave: .wave
        case .jump: .jump
        case .cry: .cry
        }
    }
}

public struct AutonomyConfiguration: Codable, Equatable, Sendable {
    public static let minimumAllowedWait: TimeInterval = 5
    public static let maximumAllowedWait: TimeInterval = 30
    public static let `default` = AutonomyConfiguration(
        minimumWait: 10,
        maximumWait: 20,
        enabledActions: Set(AutonomousActionKind.allCases)
    )!

    public let minimumWait: TimeInterval
    public let maximumWait: TimeInterval
    public let enabledActions: Set<AutonomousActionKind>

    public init?(
        minimumWait: TimeInterval,
        maximumWait: TimeInterval,
        enabledActions: Set<AutonomousActionKind>
    ) {
        guard minimumWait >= Self.minimumAllowedWait,
              maximumWait <= Self.maximumAllowedWait,
              minimumWait <= maximumWait,
              !enabledActions.isEmpty
        else { return nil }
        self.minimumWait = minimumWait
        self.maximumWait = maximumWait
        self.enabledActions = enabledActions
    }
}

public struct AutonomyPolicy {
    public static let minimumWait: TimeInterval = 10
    public static let maximumWait: TimeInterval = 20
    public static let minimumWalkDuration: TimeInterval = 1
    public static let maximumWalkDuration: TimeInterval = 2

    private let randomUnit: () -> Double
    private var configuration: AutonomyConfiguration
    private var deadline: TimeInterval?
    private(set) public var isPerforming = false

    public init(
        configuration: AutonomyConfiguration = .default,
        randomUnit: @escaping () -> Double = { Double.random(in: 0...1) }
    ) {
        self.configuration = configuration
        self.randomUnit = randomUnit
    }

    public mutating func update(configuration: AutonomyConfiguration) {
        self.configuration = configuration
        cancel()
    }

    public mutating func tick(now: TimeInterval, isEligible: Bool) -> AutonomousAction? {
        guard isEligible else {
            cancel()
            return nil
        }
        guard !isPerforming else { return nil }
        if deadline == nil {
            deadline = now + sampled(in: configuration.minimumWait...configuration.maximumWait)
            return nil
        }
        guard let deadline, now >= deadline else { return nil }
        self.deadline = nil
        return startAction()
    }

    public mutating func startAction() -> AutonomousAction? {
        guard !isPerforming else { return nil }
        isPerforming = true
        switch nextActionKind() {
        case .walk: return .walk(duration: sampled(in: Self.minimumWalkDuration...Self.maximumWalkDuration))
        case .wave: return .wave
        case .jump: return .jump
        case .cry: return .cry
        }
    }

    public mutating func finish() { isPerforming = false }

    public mutating func cancel() {
        deadline = nil
        isPerforming = false
    }

    private func sampled(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        range.lowerBound + (range.upperBound - range.lowerBound) * clampedUnit()
    }

    private func nextActionKind() -> AutonomousActionKind {
        let enabled = AutonomousActionKind.allCases.filter { configuration.enabledActions.contains($0) }
        let totalWeight = enabled.reduce(0) { $0 + $1.weight }
        var threshold = clampedUnit() * totalWeight
        for action in enabled {
            threshold -= action.weight
            if threshold < 0 { return action }
        }
        return enabled.last ?? .walk
    }

    private func clampedUnit() -> Double { min(max(randomUnit(), 0), 1) }
}
