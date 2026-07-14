@testable import PetRunnerCore
import Foundation
import Testing

struct SessionBubbleLayoutTests {
    @Test(arguments: 1...AgentSessionStore.maximumEntries) func expandedFramesStayInsideContent(count: Int) {
        let layout = SessionBubbleLayout(sessionCount: count, isCollapsed: false)

        #expect(layout.contentBounds.contains(layout.cardFrame))
        #expect(layout.contentBounds.contains(layout.railFrame))
        #expect(layout.contentBounds.contains(layout.previousControlFrame))
        #expect(layout.contentBounds.contains(layout.nextControlFrame))
        #expect(layout.contentBounds.contains(layout.collapseControlFrame))
        for index in 0..<count {
            #expect(layout.contentBounds.contains(layout.indicatorFrame(at: index)))
        }
    }

    @Test(arguments: 1...AgentSessionStore.maximumEntries) func compactFramesStayInsideContent(count: Int) {
        let layout = SessionBubbleLayout(sessionCount: count, isCollapsed: true)

        #expect(layout.contentSize == CGSize(width: 24, height: 18 + CGFloat(count * 14)))
        #expect(layout.contentBounds.contains(layout.expandControlFrame))
        for index in 0..<count {
            #expect(layout.contentBounds.contains(layout.indicatorFrame(at: index)))
        }
    }

    @Test func selectedIndicatorIsAVisualStateOnly() {
        let layout = SessionBubbleLayout(sessionCount: 5, isCollapsed: false)

        #expect(layout.indicatorFrame(at: 0).size == CGSize(width: 28, height: 8))
        #expect(layout.indicatorFrame(at: 4).minY == 31)
        #expect(layout.previousControlFrame.size == CGSize(width: 36, height: 22))
        #expect(layout.nextControlFrame.size == CGSize(width: 36, height: 22))
    }
}
