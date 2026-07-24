import Foundation

/// Official provider usage / status links shown on the Providers dashboard.
public struct ProviderOfficialLinks: Equatable, Sendable {
    public let usageURL: URL
    public let statusURL: URL

    public init(usageURL: URL, statusURL: URL) {
        self.usageURL = usageURL
        self.statusURL = statusURL
    }
}

public extension UsageProvider {
    var officialLinks: ProviderOfficialLinks {
        switch self {
        case .claude:
            return ProviderOfficialLinks(
                usageURL: URL(string: "https://claude.ai/settings/usage")!,
                statusURL: URL(string: "https://status.anthropic.com/")!
            )
        case .codex:
            return ProviderOfficialLinks(
                usageURL: URL(string: "https://chatgpt.com/#settings")!,
                statusURL: URL(string: "https://status.openai.com/")!
            )
        case .cursor:
            return ProviderOfficialLinks(
                usageURL: URL(string: "https://cursor.com/dashboard?tab=usage")!,
                statusURL: URL(string: "https://status.cursor.com/")!
            )
        }
    }
}
