import Foundation

/// Geometry for the under-pet quota HP bar and its circular collapse control.
public enum QuotaBarLayout: Sendable {
    public static let barHeight: CGFloat = 12
    public static let barSpacing: CGFloat = 3
    public static let sideInset: CGFloat = 4
    /// Circular collapse / expand control to the left of the heart.
    public static let controlSize: CGFloat = 18
    public static let controlGap: CGFloat = 2
    /// Collapsed row: expand control + fill-level hearts in one horizontal strip.
    public static let collapsedHeight: CGFloat = 22
    public static let collapsedItemGap: CGFloat = 4
    /// Pixel rows in the classic 7×6 heart (bottom → top).
    public static let heartRowCount = 6

    public static func barsHeight(forCount count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * barHeight + CGFloat(count - 1) * barSpacing + 4
    }

    public static func preferredHeight(forCount count: Int, collapsed: Bool = false) -> CGFloat {
        guard count > 0 else { return 0 }
        if collapsed { return collapsedHeight }
        return barsHeight(forCount: count)
    }

    public static func pixelUnit(scale: CGFloat) -> CGFloat {
        max(1, floor(2 * max(scale, 1)) / max(scale, 1))
    }

    /// Leading x of the heart column (after the circular control).
    public static func heartLeadingX() -> CGFloat {
        sideInset + controlSize + controlGap
    }

    /// How many bottom-up heart rows are filled for a remaining-percent level (0…6).
    public static func heartFilledRowCount(remainingPercent: Double) -> Int {
        let clamped = max(0, min(100, remainingPercent))
        if clamped <= 0 { return 0 }
        if clamped >= 100 { return heartRowCount }
        return Int((clamped / 100.0 * Double(heartRowCount)).rounded(.toNearestOrAwayFromZero))
    }

    /// Frame for the circular toggle, in the quota footer’s local coordinates.
    public static func toggleFrame(
        containerWidth: CGFloat,
        segmentCount: Int,
        collapsed: Bool,
        scale: CGFloat
    ) -> CGRect {
        if collapsed {
            let item = controlSize
            let heartCount = max(segmentCount, 0)
            let total = CGFloat(heartCount + 1) * item + CGFloat(heartCount) * collapsedItemGap
            let startX = max(sideInset, (containerWidth - total) / 2)
            let y = (collapsedHeight - controlSize) / 2
            // Expand control leads the collapsed row (left of hearts).
            return CGRect(x: startX, y: y, width: controlSize, height: controlSize)
        }

        // Sit outside left of the bottom-most heart (feet side of the stack).
        let y = 2 + (barHeight - controlSize) / 2
        return CGRect(x: sideInset, y: y, width: controlSize, height: controlSize)
    }

    /// Leading x where the HP track starts (after control + heart column).
    public static func trackLeadingX(unit: CGFloat) -> CGFloat {
        let heartWidth = unit * 7
        return heartLeadingX() + heartWidth + controlGap
    }
}
