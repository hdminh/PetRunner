import Foundation
import Testing
@testable import PetRunnerCore

struct QuotaBarLayoutTests {
    @Test func preferredHeightDropsToggleStripWhenExpanded() {
        #expect(QuotaBarLayout.preferredHeight(forCount: 0) == 0)
        #expect(QuotaBarLayout.preferredHeight(forCount: 1, collapsed: false) == QuotaBarLayout.barsHeight(forCount: 1))
        #expect(QuotaBarLayout.preferredHeight(forCount: 2, collapsed: false) == QuotaBarLayout.barsHeight(forCount: 2))
        #expect(QuotaBarLayout.preferredHeight(forCount: 1, collapsed: true) == QuotaBarLayout.collapsedHeight)
        #expect(QuotaBarLayout.preferredHeight(forCount: 3, collapsed: true) == QuotaBarLayout.collapsedHeight)
    }

    @Test func expandedToggleSitsLeftOfHeartColumn() {
        let unit = QuotaBarLayout.pixelUnit(scale: 2)
        let frame = QuotaBarLayout.toggleFrame(
            containerWidth: 112,
            segmentCount: 1,
            collapsed: false,
            scale: 2
        )
        let heartX = QuotaBarLayout.heartLeadingX()
        #expect(frame.width == QuotaBarLayout.controlSize)
        #expect(frame.height == QuotaBarLayout.controlSize)
        #expect(frame.minX == QuotaBarLayout.sideInset)
        #expect(frame.maxX <= heartX)
        #expect(heartX < QuotaBarLayout.trackLeadingX(unit: unit))
    }

    @Test func collapsedToggleLeadsHeartsInOneRow() {
        let frame = QuotaBarLayout.toggleFrame(
            containerWidth: 112,
            segmentCount: 2,
            collapsed: true,
            scale: 2
        )
        let item = QuotaBarLayout.controlSize
        let total = 3 * item + 2 * QuotaBarLayout.collapsedItemGap
        let startX = max(QuotaBarLayout.sideInset, (112 - total) / 2)
        #expect(frame.origin.x == startX)
        #expect(frame.origin.y == (QuotaBarLayout.collapsedHeight - item) / 2)
        #expect(frame.size == CGSize(width: item, height: item))
    }

    @Test func heartFilledRowCountMapsRemainingPercent() {
        #expect(QuotaBarLayout.heartFilledRowCount(remainingPercent: 0) == 0)
        #expect(QuotaBarLayout.heartFilledRowCount(remainingPercent: 100) == 6)
        #expect(QuotaBarLayout.heartFilledRowCount(remainingPercent: 50) == 3)
        #expect(QuotaBarLayout.heartFilledRowCount(remainingPercent: -10) == 0)
        #expect(QuotaBarLayout.heartFilledRowCount(remainingPercent: 150) == 6)
    }
}
