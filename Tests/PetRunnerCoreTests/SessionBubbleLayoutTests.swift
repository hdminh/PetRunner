@testable import PetRunnerCore
import Foundation
import Testing

struct SessionBubbleLayoutTests {
    @Test(arguments: [1, 5, 6, 20]) func expandedFramesStayInsideContent(count: Int) {
        let layout = SessionBubbleLayout(sessionCount: count, selectedIndex: count / 2, detailLineCount: 4, side: .above, isCollapsed: false)

        #expect(layout.contentBounds.contains(layout.bubbleFrame))
        #expect(layout.speechTailFrames().allSatisfy(layout.contentBounds.contains))
        #expect(layout.contentBounds.contains(layout.previousControlFrame))
        #expect(layout.contentBounds.contains(layout.nextControlFrame))
        #expect(layout.contentBounds.contains(layout.collapseControlFrame))
        #expect(layout.contentBounds.contains(layout.resetControlFrame))
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
        #expect(layout.previousControlFrame.size == CGSize(width: 16, height: 16))
        #expect(layout.nextControlFrame.size == CGSize(width: 16, height: 16))
    }

    @Test func collapseControlSitsAtTheStartOfTheHeader() {
        let layout = SessionBubbleLayout(sessionCount: 1, isCollapsed: false)

        #expect(layout.collapseControlFrame.minX == layout.bubbleFrame.minX + 6)
        #expect(layout.collapseControlFrame.midY == layout.headerFrame.midY)
    }

    @Test func resetControlSitsBesideMinimizeInTheHeader() {
        let layout = SessionBubbleLayout(sessionCount: 1, isCollapsed: false)

        #expect(layout.resetControlFrame.minX == layout.collapseControlFrame.maxX + 2)
        #expect(layout.resetControlFrame.midY == layout.headerFrame.midY)
        #expect(layout.resetControlFrame.size == CGSize(width: 16, height: 16))
    }

    @Test func expandedSessionRailStartsJustBelowTheHeader() {
        let layout = SessionBubbleLayout(sessionCount: 5, detailLineCount: 2, isCollapsed: false)
        let rail = layout.indicatorIndices.indices.map(layout.indicatorFrame(at:))

        #expect(rail.first?.maxY == layout.headerFrame.minY - 2)
        #expect(rail.allSatisfy { $0.maxX == layout.sessionPositionFrame.maxX })
    }

    @Test func navigationControlsShareTheHeaderWithTheSessionPosition() {
        let layout = SessionBubbleLayout(sessionCount: 12, selectedIndex: 8, isCollapsed: false)

        #expect(layout.previousControlFrame.midY == layout.headerFrame.midY)
        #expect(layout.nextControlFrame.midY == layout.headerFrame.midY)
        #expect(layout.previousControlFrame.maxX < layout.nextControlFrame.minX)
        #expect(layout.nextControlFrame.maxX < layout.sessionPositionFrame.minX)
        #expect(layout.sessionPositionFrame.maxX == layout.bubbleFrame.maxX - 6)
    }

    @Test func bubbleContentUsesModelAsTitleAndJobAsPrimaryText() {
        let entry = AgentSessionSnapshot(
            key: AgentSessionKey(provider: .codex, sessionID: "session"),
            status: .working,
            model: AgentSessionModel.sanitized("gpt-5.2-codex"),
            activity: AgentActivity.sanitized("Updating the monitor bubble"),
            sessionName: AgentSessionName.sanitized("Monitor redesign"),
            estimatedCost: AgentSessionEstimatedCost(usd: Decimal(string: "0.25")!)
        )
        let content = SessionBubbleContent(entry: entry, visibleFields: MonitorBubbleField.allCases)

        #expect(content.modelTitle == "GPT-5.2-CODEX")
        #expect(content.primaryText == "Updating the monitor bubble")
        #expect(content.detailRows == ["Monitor redesign", "$0.25"])
    }

    @Test func bubbleContentFallsBackToStatusWhenJobIsHidden() {
        let entry = AgentSessionSnapshot(key: AgentSessionKey(provider: .codex, sessionID: "session"), status: .needsApproval)
        let content = SessionBubbleContent(entry: entry, visibleFields: [.model])

        #expect(content.primaryText == entry.displayText)
    }

    @Test func placesSpeechBubbleAboveWhenThereIsRoomAndBelowOtherwise() {
        let pet = CGRect(x: 100, y: 100, width: 80, height: 80)
        let above = SessionBubbleLayout(sessionCount: 1, detailLineCount: 2, side: .above, isCollapsed: false)
        #expect(SessionBubbleLayout.preferredSide(petFrame: pet, visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 500), contentSize: above.contentSize) == .above)
        #expect(SessionBubbleLayout.preferredSide(petFrame: pet, visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 200), contentSize: above.contentSize) == .below)

        let tailAbove = above.speechTailFrames()
        #expect(tailAbove.allSatisfy(above.contentBounds.contains))
        #expect(tailAbove.map(\.minY).min() == above.contentBounds.minY)
        #expect(tailAbove.map(\.minY).min()! < above.bubbleFrame.minY)
        #expect(tailAbove.map(\.maxY).max()! >= above.bubbleFrame.minY)

        let below = SessionBubbleLayout(sessionCount: 1, detailLineCount: 2, side: .below, isCollapsed: false)
        let tailBelow = below.speechTailFrames()
        #expect(tailBelow.allSatisfy(below.contentBounds.contains))
        #expect(tailBelow.map(\.maxY).max() == below.contentBounds.maxY)
        #expect(tailBelow.map(\.maxY).max()! > below.bubbleFrame.maxY)
        #expect(tailBelow.map(\.minY).min()! <= below.bubbleFrame.maxY)
    }

    @Test func speechTailTracksPetAndStaysWithinBubbleWidth() {
        let anchored = SessionBubbleLayout(sessionCount: 1, side: .above, isCollapsed: false, tailAnchorX: 74)
        #expect(anchored.speechTailFrames().first?.midX == 74)

        let constrained = SessionBubbleLayout(sessionCount: 1, side: .below, isCollapsed: false, tailAnchorX: -20)
        #expect(constrained.speechTailFrames().first?.minX == constrained.bubbleFrame.minX)
    }

    @Test func speechTailKeepsItsLeftEdgeStraightWhileSteppingInFromTheRight() {
        let layout = SessionBubbleLayout(sessionCount: 1, side: .above, isCollapsed: false)
        let tail = layout.speechTailFrames()

        #expect(tail.map(\.minX) == Array(repeating: tail[0].minX, count: 5))
        #expect(tail.map(\.width) == [20, 17, 14, 11, 8])
        let interior = layout.speechTailInteriorFrames()
        #expect(interior.map(\.minX) == Array(repeating: interior[0].minX, count: 5))
        #expect(interior.map(\.width) == [16, 13, 10, 7, 4])
    }

    @Test func speechTailFaceCoversTheInsetShadowAtItsJoin() {
        let above = SessionBubbleLayout(sessionCount: 1, side: .above, isCollapsed: false)
        let aboveFace = above.bubbleFrame.insetBy(dx: 2, dy: 2)
        #expect(above.speechTailInteriorFrames()[0].maxY >= aboveFace.minY + 5)

        let below = SessionBubbleLayout(sessionCount: 1, side: .below, isCollapsed: false)
        let belowFace = below.bubbleFrame.insetBy(dx: 2, dy: 2)
        #expect(below.speechTailInteriorFrames()[0].minY <= belowFace.maxY - 5)
    }
}
