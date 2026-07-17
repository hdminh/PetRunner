@testable import PetRunnerCore
import Foundation
import Testing

struct SessionBubbleLayoutTests {
    @Test(arguments: [1, 5, 6, 20]) func expandedFramesStayInsideContent(count: Int) {
        let layout = SessionBubbleLayout(sessionCount: count, selectedIndex: count / 2, detailLineCount: 4, side: .above, isCollapsed: false)

        #expect(layout.contentBounds.contains(layout.bubbleFrame))
        #expect(layout.dotFrames().allSatisfy(layout.contentBounds.contains))
        #expect(layout.contentBounds.contains(layout.previousControlFrame))
        #expect(layout.contentBounds.contains(layout.nextControlFrame))
        #expect(layout.contentBounds.contains(layout.collapseControlFrame))
        for index in layout.indicatorIndices.indices {
            #expect(layout.contentBounds.contains(layout.indicatorFrame(at: index)))
        }
    }

    @Test(arguments: [1, 5, 6, 20]) func compactFramesStayInsideContent(count: Int) {
        let layout = SessionBubbleLayout(sessionCount: count, selectedIndex: count / 2, isCollapsed: true)

        #expect(layout.contentSize == CGSize(width: 24, height: 18 + CGFloat(min(count, SessionBubbleLayout.maximumVisibleIndicators) * 14)))
        #expect(layout.contentBounds.contains(layout.expandControlFrame))
        for index in layout.indicatorIndices.indices {
            #expect(layout.contentBounds.contains(layout.indicatorFrame(at: index)))
        }
    }

    @Test func selectedIndicatorIsAVisualStateOnly() {
        let layout = SessionBubbleLayout(sessionCount: 12, selectedIndex: 8, detailLineCount: 2, isCollapsed: false)

        #expect(layout.indicatorFrame(at: 0).size == CGSize(width: 14, height: 6))
        #expect(layout.indicatorIndices == [6, 7, 8, 9, 10])
        #expect(layout.previousControlFrame.size == CGSize(width: 14, height: 14))
        #expect(layout.nextControlFrame.size == CGSize(width: 14, height: 14))
    }

    @Test func placesThoughtBubbleAboveWhenThereIsRoomAndBelowOtherwise() {
        let pet = CGRect(x: 100, y: 100, width: 80, height: 80)
        let above = SessionBubbleLayout(sessionCount: 1, detailLineCount: 2, side: .above, isCollapsed: false)
        #expect(SessionBubbleLayout.preferredSide(petFrame: pet, visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 500), contentSize: above.contentSize) == .above)
        #expect(SessionBubbleLayout.preferredSide(petFrame: pet, visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 200), contentSize: above.contentSize) == .below)

        let below = SessionBubbleLayout(sessionCount: 1, detailLineCount: 2, side: .below, isCollapsed: false)
        #expect(below.dotFrames().map(\.minY).max()! > below.bubbleFrame.maxY)
    }
}
