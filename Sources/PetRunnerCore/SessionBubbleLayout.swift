import Foundation

public enum ThoughtBubbleSide: String, Sendable {
    case above
    case below
}

public struct SessionBubbleContent: Equatable, Sendable {
    public let modelTitle: String?
    public let primaryText: String
    public let detailRows: [String]
    public let isSubagent: Bool

    public init(entry: AgentSessionSnapshot, visibleFields: [MonitorBubbleField]) {
        let isSubagent: Bool
        if case .subagent = entry.key.scope {
            isSubagent = true
        } else {
            isSubagent = false
        }
        self.isSubagent = isSubagent
        modelTitle = visibleFields.contains(.model) ? entry.model?.value.uppercased() : nil
        primaryText = visibleFields.contains(.job) ? entry.activity?.value ?? entry.displayText : entry.displayText
        var rows: [String] = []
        if isSubagent {
                    if let type = entry.agentType?.value, !type.isEmpty {
                        rows.append("SUB · \(type)")
                    } else {
                        rows.append("SUBAGENT")
                    }
        }
        if visibleFields.contains(.sessionName), let name = entry.sessionName?.value {
            rows.append(name)
        }
        if visibleFields.contains(.cost), let cost = entry.estimatedCost?.displayText {
            rows.append(cost)
        }
        detailRows = rows
    }
}

public struct SessionBubbleLayout: Sendable {
    public static let baseWidth: CGFloat = 292
    public static let width: CGFloat = baseWidth
    public static let expandedContentSize = CGSize(width: width, height: 92)
    public static let maximumVisibleIndicators = 5

    public let sessionCount: Int
    public let selectedIndex: Int
    public let detailLineCount: Int
    public let side: ThoughtBubbleSide
    public let isCollapsed: Bool
    public let tailAnchorX: CGFloat?
    public let scale: CGFloat

    public init(
        sessionCount: Int,
        selectedIndex: Int = 0,
        detailLineCount: Int = 0,
        side: ThoughtBubbleSide = .above,
        isCollapsed: Bool,
        tailAnchorX: CGFloat? = nil,
        scale: CGFloat = 1
    ) {
        self.sessionCount = max(sessionCount, 0)
        self.selectedIndex = min(max(selectedIndex, 0), max(sessionCount - 1, 0))
        self.detailLineCount = min(max(detailLineCount, 0), MonitorBubbleField.allCases.count + 2)
        self.side = side
        self.isCollapsed = isCollapsed
        self.tailAnchorX = tailAnchorX
        self.scale = max(0.5, min(scale, 2))
    }

    public var panelWidth: CGFloat { Self.baseWidth * scale }

    public var indicatorIndices: [Int] {
        guard sessionCount > 0 else { return [] }
        let count = min(sessionCount, Self.maximumVisibleIndicators)
        let start = min(max(selectedIndex - count / 2, 0), sessionCount - count)
        return Array(start..<(start + count))
    }

    public var bubbleHeight: CGFloat { (46 + CGFloat(detailLineCount * 16)) * scale }

    public var contentSize: CGSize {
        if isCollapsed { return CGSize(width: 24 * scale, height: (18 + CGFloat(indicatorIndices.count * 14)) * scale) }
        return CGSize(width: panelWidth, height: bubbleHeight + 18 * scale)
    }

    public var contentBounds: CGRect { CGRect(origin: .zero, size: contentSize) }

    public var bubbleFrame: CGRect {
        let y: CGFloat = side == .above ? 18 * scale : 0
        return CGRect(x: 14 * scale, y: y, width: panelWidth - 14 * scale, height: bubbleHeight)
    }

    public var headerFrame: CGRect { CGRect(x: bubbleFrame.minX + 2 * scale, y: bubbleFrame.maxY - 22 * scale, width: bubbleFrame.width - 4 * scale, height: 20 * scale) }
    public var metadataFrame: CGRect { CGRect(x: bubbleFrame.minX + 12 * scale, y: bubbleFrame.minY + 10 * scale, width: bubbleFrame.width - 62 * scale, height: bubbleFrame.height - 36 * scale) }
    public var sessionPositionFrame: CGRect {
        let text = "\(selectedIndex + 1)/\(max(sessionCount, 1))"
        let width = CGFloat(text.count * 7 - 2) * scale
        return CGRect(x: bubbleFrame.maxX - (6 * scale) - width, y: headerFrame.minY + 8 * scale, width: width, height: 7 * scale)
    }
    public var previousControlFrame: CGRect { CGRect(x: nextControlFrame.minX - 18 * scale, y: headerFrame.midY - 8 * scale, width: 16 * scale, height: 16 * scale) }
    public var nextControlFrame: CGRect { CGRect(x: sessionPositionFrame.minX - 20 * scale, y: headerFrame.midY - 8 * scale, width: 16 * scale, height: 16 * scale) }
    public var collapseControlFrame: CGRect { CGRect(x: bubbleFrame.minX + 6 * scale, y: bubbleFrame.maxY - 20 * scale, width: 16 * scale, height: 16 * scale) }
    /// Pixel reset / clear control immediately after minimize in the expanded header.
    public var resetControlFrame: CGRect { CGRect(x: collapseControlFrame.maxX + 2 * scale, y: bubbleFrame.maxY - 20 * scale, width: 16 * scale, height: 16 * scale) }
    public var expandControlFrame: CGRect { CGRect(x: 2 * scale, y: contentSize.height - 18 * scale, width: 20 * scale, height: 18 * scale) }

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
