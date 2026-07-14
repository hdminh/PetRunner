import Foundation

public struct ProviderDetection: Equatable, Sendable {
    public let provider: AgentProvider
    public let isDetected: Bool

    public init(provider: AgentProvider, isDetected: Bool) {
        self.provider = provider
        self.isDetected = isDetected
    }
}

public enum ProviderDetector {
    public static func detect(existingPaths: Set<String>) -> [ProviderDetection] {
        AgentProvider.allCases.map { provider in
            let hints: [String] = switch provider {
            case .claude: [".claude", ".claude/settings.json"]
            case .codex: [".codex", ".codex/hooks.json"]
            case .cursor: [".cursor", ".cursor/hooks.json"]
            }
            return ProviderDetection(provider: provider, isDetected: hints.contains { existingPaths.contains($0) })
        }
    }
}
