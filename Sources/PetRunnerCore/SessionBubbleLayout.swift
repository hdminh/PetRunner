import Foundation

public enum ThoughtBubbleSide: String, Sendable {
    case above
    case below
}

public struct SessionBubbleContent: Equatable, Sendable {
    public let modelTitle: String?
    public let primaryText: String
    public let detailRows: [String]

    public init(entry: AgentSessionSnapshot, visibleFields: [MonitorBubbleField]) {
        modelTitle = visibleFields.contains(.model) ? entry.model?.value.uppercased() : nil
        primaryText = visibleFields.contains(.job) ? entry.activity?.value ?? entry.displayText : entry.displayText
        detailRows = [
            visibleFields.contains(.sessionName) ? entry.sessionName?.value : nil,
            visibleFields.contains(.cost) ? entry.estimatedCost?.displayText : nil,
        ].compactMap { $0 }
    }
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
    public let tailAnchorX: CGFloat?

    public init(
        sessionCount: Int,
        selectedIndex: Int = 0,
        detailLineCount: Int = 0,
        side: ThoughtBubbleSide = .above,
        isCollapsed: Bool,
        tailAnchorX: CGFloat? = nil
    ) {
        self.sessionCount = max(sessionCount, 0)
        self.selectedIndex = min(max(selectedIndex, 0), max(sessionCount - 1, 0))
        self.detailLineCount = min(max(detailLineCount, 0), MonitorBubbleField.allCases.count + 1)
        self.side = side
        self.isCollapsed = isCollapsed
        self.tailAnchorX = tailAnchorX
    }

    public var indicatorIndices: [Int] {
        guard sessionCount > 0 else { return [] }
        let count = min(sessionCount, Self.maximumVisibleIndicators)
        let start = min(max(selectedIndex - count / 2, 0), sessionCount - count)
        return Array(start..<(start + count))
    }

    public var bubbleHeight: CGFloat { 46 + CGFloat(detailLineCount * 16) }

    public var contentSize: CGSize {
        if isCollapsed { return CGSize(width: 24, height: 18 + CGFloat(indicatorIndices.count * 14)) }
        return CGSize(width: Self.width, height: bubbleHeight + 18)
    }

    public var contentBounds: CGRect { CGRect(origin: .zero, size: contentSize) }

    public var bubbleFrame: CGRect {
        let y: CGFloat = side == .above ? 18 : 0
        return CGRect(x: 14, y: y, width: Self.width - 14, height: bubbleHeight)
    }

    public var headerFrame: CGRect { CGRect(x: bubbleFrame.minX + 2, y: bubbleFrame.maxY - 22, width: bubbleFrame.width - 4, height: 20) }
    public var metadataFrame: CGRect { CGRect(x: bubbleFrame.minX + 12, y: bubbleFrame.minY + 10, width: bubbleFrame.width - 62, height: bubbleFrame.height - 36) }
    public var sessionPositionFrame: CGRect {
        let text = "\(selectedIndex + 1)/\(max(sessionCount, 1))"
        let width = CGFloat(text.count * 7 - 2)
        return CGRect(x: bubbleFrame.maxX - 6 - width, y: headerFrame.minY + 8, width: width, height: 7)
    }
    public var previousControlFrame: CGRect { CGRect(x: nextControlFrame.minX - 18, y: headerFrame.midY - 8, width: 16, height: 16) }
    public var nextControlFrame: CGRect { CGRect(x: sessionPositionFrame.minX - 20, y: headerFrame.midY - 8, width: 16, height: 16) }
    public var collapseControlFrame: CGRect { CGRect(x: bubbleFrame.minX + 6, y: bubbleFrame.maxY - 20, width: 16, height: 16) }
    public var expandControlFrame: CGRect { CGRect(x: 2, y: contentSize.height - 18, width: 20, height: 18) }

    public func speechTailFrames() -> [CGRect] {
        let centerX = speechTailCenterX
        switch side {
        case .above:
            return [
                CGRect(x: centerX - 10, y: bubbleFrame.minY - 2, width: 20, height: 4),
                CGRect(x: centerX - 10, y: bubbleFrame.minY - 6, width: 17, height: 4),
                CGRect(x: centerX - 10, y: bubbleFrame.minY - 10, width: 14, height: 4),
                CGRect(x: centerX - 10, y: bubbleFrame.minY - 14, width: 11, height: 4),
                CGRect(x: centerX - 10, y: bubbleFrame.minY - 18, width: 8, height: 4),
            ]
        case .below:
            return [
                CGRect(x: centerX - 10, y: bubbleFrame.maxY - 2, width: 20, height: 4),
                CGRect(x: centerX - 10, y: bubbleFrame.maxY + 2, width: 17, height: 4),
                CGRect(x: centerX - 10, y: bubbleFrame.maxY + 6, width: 14, height: 4),
                CGRect(x: centerX - 10, y: bubbleFrame.maxY + 10, width: 11, height: 4),
                CGRect(x: centerX - 10, y: bubbleFrame.maxY + 14, width: 8, height: 4),
            ]
        }
    }

    public func speechTailInteriorFrames() -> [CGRect] {
        let centerX = speechTailCenterX
        switch side {
        case .above:
            return [
                CGRect(x: centerX - 8, y: bubbleFrame.minY - 2, width: 16, height: 10),
                CGRect(x: centerX - 8, y: bubbleFrame.minY - 6, width: 13, height: 4),
                CGRect(x: centerX - 8, y: bubbleFrame.minY - 10, width: 10, height: 4),
                CGRect(x: centerX - 8, y: bubbleFrame.minY - 14, width: 7, height: 4),
                CGRect(x: centerX - 8, y: bubbleFrame.minY - 16, width: 4, height: 2),
            ]
        case .below:
            return [
                CGRect(x: centerX - 8, y: bubbleFrame.maxY - 8, width: 16, height: 10),
                CGRect(x: centerX - 8, y: bubbleFrame.maxY + 2, width: 13, height: 4),
                CGRect(x: centerX - 8, y: bubbleFrame.maxY + 6, width: 10, height: 4),
                CGRect(x: centerX - 8, y: bubbleFrame.maxY + 10, width: 7, height: 4),
                CGRect(x: centerX - 8, y: bubbleFrame.maxY + 14, width: 4, height: 2),
            ]
        }
    }

    private var speechTailCenterX: CGFloat {
        min(max(tailAnchorX ?? bubbleFrame.midX, bubbleFrame.minX + 10), bubbleFrame.maxX - 10)
    }

    public func indicatorFrame(at index: Int) -> CGRect {
        guard indicatorIndices.indices.contains(index) else { return .zero }
        if isCollapsed {
            return CGRect(x: 4, y: contentSize.height - 32 - CGFloat(index * 14), width: 16, height: 12)
        }
        return CGRect(
            x: sessionPositionFrame.maxX - 14,
            y: headerFrame.minY - 8 - CGFloat(index * 9),
            width: 14,
            height: 6
        )
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
