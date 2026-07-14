import Foundation

public struct SessionBubbleLayout: Sendable {
    public static let expandedContentSize = CGSize(width: 264, height: 112)

    public let sessionCount: Int
    public let isCollapsed: Bool

    public init(sessionCount: Int, isCollapsed: Bool) {
        self.sessionCount = min(max(sessionCount, 0), AgentSessionStore.maximumEntries)
        self.isCollapsed = isCollapsed
    }

    public var contentSize: CGSize {
        if !isCollapsed { return Self.expandedContentSize }
        return CGSize(width: 24, height: 18 + CGFloat(sessionCount * 14))
    }

    public var contentBounds: CGRect {
        CGRect(origin: .zero, size: contentSize)
    }

    public var cardFrame: CGRect { CGRect(x: 0, y: 0, width: 222, height: 112) }
    public var railFrame: CGRect { CGRect(x: 220, y: 0, width: 44, height: 112) }
    public var headerFrame: CGRect { CGRect(x: 2, y: 90, width: 218, height: 20) }
    public var titleFrame: CGRect { CGRect(x: 10, y: 42, width: 200, height: 40) }
    public var collapseControlFrame: CGRect { CGRect(x: 194, y: 91, width: 22, height: 18) }
    public var previousControlFrame: CGRect { CGRect(x: 224, y: 86, width: 36, height: 22) }
    public var nextControlFrame: CGRect { CGRect(x: 224, y: 4, width: 36, height: 22) }
    public var expandControlFrame: CGRect {
        CGRect(x: 2, y: contentSize.height - 18, width: 20, height: 18)
    }

    public func indicatorFrame(at index: Int) -> CGRect {
        guard (0..<sessionCount).contains(index) else { return .zero }
        if isCollapsed {
            return CGRect(x: 4, y: contentSize.height - 32 - CGFloat(index * 14), width: 16, height: 12)
        }
        return CGRect(x: 228, y: 75 - CGFloat(index * 11), width: 28, height: 8)
    }
}
