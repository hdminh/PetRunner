import Foundation

public enum ThoughtBubbleSide: String, Sendable {
    case above
    case below
}

public struct SessionBubbleLayout: Sendable {
    public static let width: CGFloat = 292
    public static let expandedContentSize = CGSize(width: width, height: 92)
    public static let maximumVisibleIndicators = 5

    public let sessionCount: Int
    public let selectedIndex: Int
    public let detailLineCount: Int
    public let side: ThoughtBubbleSide
    public let isCollapsed: Bool

    public init(
        sessionCount: Int,
        selectedIndex: Int = 0,
        detailLineCount: Int = 0,
        side: ThoughtBubbleSide = .above,
        isCollapsed: Bool
    ) {
        self.sessionCount = max(sessionCount, 0)
        self.selectedIndex = min(max(selectedIndex, 0), max(sessionCount - 1, 0))
        self.detailLineCount = min(max(detailLineCount, 0), MonitorBubbleField.allCases.count)
        self.side = side
        self.isCollapsed = isCollapsed
    }

    public var indicatorIndices: [Int] {
        guard sessionCount > 0 else { return [] }
        let count = min(sessionCount, Self.maximumVisibleIndicators)
        let start = min(max(selectedIndex - count / 2, 0), sessionCount - count)
        return Array(start..<(start + count))
    }

    public var bubbleHeight: CGFloat { 72 + CGFloat(detailLineCount * 16) }

    public var contentSize: CGSize {
        if isCollapsed { return CGSize(width: 24, height: 18 + CGFloat(indicatorIndices.count * 14)) }
        return CGSize(width: Self.width, height: bubbleHeight + 20)
    }

    public var contentBounds: CGRect { CGRect(origin: .zero, size: contentSize) }

    public var bubbleFrame: CGRect {
        let y: CGFloat = side == .above ? 20 : 0
        return CGRect(x: 14, y: y, width: Self.width - 14, height: bubbleHeight)
    }

    public var headerFrame: CGRect { CGRect(x: bubbleFrame.minX + 2, y: bubbleFrame.maxY - 22, width: bubbleFrame.width - 4, height: 20) }
    public var metadataFrame: CGRect { CGRect(x: bubbleFrame.minX + 12, y: bubbleFrame.minY + 24, width: bubbleFrame.width - 62, height: bubbleFrame.height - 50) }
    public var previousControlFrame: CGRect { CGRect(x: bubbleFrame.maxX - 42, y: bubbleFrame.minY + 8, width: 14, height: 14) }
    public var nextControlFrame: CGRect { CGRect(x: bubbleFrame.maxX - 24, y: bubbleFrame.minY + 8, width: 14, height: 14) }
    public var collapseControlFrame: CGRect { CGRect(x: bubbleFrame.maxX - 22, y: bubbleFrame.maxY - 20, width: 16, height: 16) }
    public var expandControlFrame: CGRect { CGRect(x: 2, y: contentSize.height - 18, width: 20, height: 18) }

    public func dotFrames() -> [CGRect] {
        let centerX = bubbleFrame.minX + 18
        switch side {
        case .above:
            return [
                CGRect(x: centerX, y: 3, width: 3, height: 3),
                CGRect(x: centerX + 4, y: 8, width: 5, height: 5),
                CGRect(x: centerX + 10, y: 14, width: 7, height: 7),
            ]
        case .below:
            return [
                CGRect(x: centerX + 10, y: bubbleFrame.maxY - 1, width: 7, height: 7),
                CGRect(x: centerX + 4, y: bubbleFrame.maxY + 8, width: 5, height: 5),
                CGRect(x: centerX, y: bubbleFrame.maxY + 16, width: 3, height: 3),
            ]
        }
    }

    public func indicatorFrame(at index: Int) -> CGRect {
        guard indicatorIndices.indices.contains(index) else { return .zero }
        if isCollapsed {
            return CGRect(x: 4, y: contentSize.height - 32 - CGFloat(index * 14), width: 16, height: 12)
        }
        return CGRect(x: bubbleFrame.maxX - 22, y: bubbleFrame.maxY - 46 - CGFloat(index * 9), width: 14, height: 6)
    }

    public static func preferredSide(petFrame: CGRect, visibleFrame: CGRect, contentSize: CGSize) -> ThoughtBubbleSide {
        let aboveFits = petFrame.maxY + 6 + contentSize.height <= visibleFrame.maxY
        if aboveFits || visibleFrame.maxY - petFrame.maxY >= petFrame.minY - visibleFrame.minY { return .above }
        return .below
    }

    public func origin(petFrame: CGRect, visibleFrame: CGRect) -> CGPoint {
        let preferredX = petFrame.midX - contentSize.width / 2
        let x = min(max(preferredX, visibleFrame.minX), visibleFrame.maxX - contentSize.width)
        let preferredY = side == .above ? petFrame.maxY + 6 : petFrame.minY - contentSize.height - 6
        let y = min(max(preferredY, visibleFrame.minY), visibleFrame.maxY - contentSize.height)
        return CGPoint(x: x, y: y)
    }
}
