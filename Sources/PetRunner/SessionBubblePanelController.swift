import AppKit
import PetRunnerCore

@MainActor
final class SessionBubblePanelController {
    private let background = StackedBubbleBackgroundView()
    private let collapseButton = NSButton(title: "", target: nil, action: nil)
    private let previousButton = NSButton(title: "", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private let expandButton = NSButton(title: "", target: nil, action: nil)
    private let modelLabel = NSTextField(labelWithString: "")
    private let jobLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let contentView = NSView()
    private let panel: NSPanel

    var onSelectPrevious: (() -> Void)?
    var onSelectNext: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onExpand: (() -> Void)?

    init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: SessionBubbleLayout.expandedContentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView.frame = panel.contentView!.bounds
        background.frame = contentView.bounds
        contentView.addSubview(background)

        modelLabel.font = .systemFont(ofSize: 12, weight: .bold)
        modelLabel.textColor = .black
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.isSelectable = false
        contentView.addSubview(modelLabel)

        jobLabel.font = .systemFont(ofSize: 10, weight: .medium)
        jobLabel.textColor = .black
        jobLabel.maximumNumberOfLines = 2
        jobLabel.lineBreakMode = .byTruncatingTail
        jobLabel.isSelectable = false
        contentView.addSubview(jobLabel)

        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        detailLabel.textColor = .black
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.isSelectable = false
        contentView.addSubview(detailLabel)

        configure(collapseButton, action: #selector(collapse))
        collapseButton.toolTip = "Minimize session monitor"
        collapseButton.setAccessibilityLabel("Minimize session monitor")
        contentView.addSubview(collapseButton)

        configure(previousButton, action: #selector(selectPrevious))
        previousButton.toolTip = "Show newer session"
        previousButton.setAccessibilityLabel("Show newer session")
        contentView.addSubview(previousButton)

        configure(nextButton, action: #selector(selectNext))
        nextButton.toolTip = "Show older session"
        nextButton.setAccessibilityLabel("Show older session")
        contentView.addSubview(nextButton)

        configure(expandButton, action: #selector(expand))
        expandButton.toolTip = "Expand session monitor"
        expandButton.setAccessibilityLabel("Expand session monitor")
        contentView.addSubview(expandButton)

        panel.contentView = contentView
    }

    func update(
        entries: [AgentSessionSnapshot],
        selectedIndex: Int,
        petFrame: CGRect,
        visibleFields: [MonitorBubbleField],
        isCollapsed: Bool = false
    ) {
        guard entries.indices.contains(selectedIndex) else { hide(); return }
        let entry = entries[selectedIndex]
        let content = SessionBubbleContent(entry: entry, visibleFields: visibleFields)
        let jobLineCount = wrappedJobLineCount(for: content.primaryText)
        let bodyLineCount = (content.modelTitle == nil ? 0 : 1) + jobLineCount + content.detailRows.count
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(petFrame) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? petFrame.insetBy(dx: -SessionBubbleLayout.width, dy: -200)
        let provisional = SessionBubbleLayout(
            sessionCount: entries.count,
            selectedIndex: selectedIndex,
            detailLineCount: bodyLineCount,
            side: .above,
            isCollapsed: isCollapsed
        )
        let side = SessionBubbleLayout.preferredSide(petFrame: petFrame, visibleFrame: visible, contentSize: provisional.contentSize)
        let unanchoredLayout = SessionBubbleLayout(
            sessionCount: entries.count,
            selectedIndex: selectedIndex,
            detailLineCount: bodyLineCount,
            side: side,
            isCollapsed: isCollapsed
        )
        let tailAnchorX = petFrame.midX - unanchoredLayout.origin(petFrame: petFrame, visibleFrame: visible).x
        let layout = SessionBubbleLayout(
            sessionCount: entries.count,
            selectedIndex: selectedIndex,
            detailLineCount: bodyLineCount,
            side: side,
            isCollapsed: isCollapsed,
            tailAnchorX: tailAnchorX
        )
        let contentSize = layout.contentSize
        panel.setContentSize(contentSize)
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        background.frame = contentView.bounds

        background.sessionCount = entries.count
        background.selectedIndex = selectedIndex
        background.providerLabel = entry.provider.displayLabel
        background.headerColor = entry.provider.headerColor
        background.sessionPosition = "\(selectedIndex + 1)/\(entries.count)"
        background.indicatorTones = entries.map(\.indicatorTone)
        background.detailLineCount = bodyLineCount
        background.thoughtSide = side
        background.isCollapsed = isCollapsed
        background.canSelectPrevious = selectedIndex > 0
        background.canSelectNext = selectedIndex < entries.count - 1

        layoutText(content, jobLineCount: jobLineCount, in: layout.metadataFrame, isCollapsed: isCollapsed)

        collapseButton.frame = layout.collapseControlFrame
        collapseButton.isHidden = isCollapsed
        previousButton.frame = layout.previousControlFrame
        previousButton.isHidden = isCollapsed
        previousButton.isEnabled = selectedIndex > 0
        nextButton.frame = layout.nextControlFrame
        nextButton.isHidden = isCollapsed
        nextButton.isEnabled = selectedIndex < entries.count - 1
        expandButton.frame = layout.expandControlFrame
        expandButton.isHidden = !isCollapsed
        expandButton.setAccessibilityLabel("Expand session monitor with \(entries.count) active sessions")
        background.setAccessibilityLabel(accessibilityLabel(for: entry, selectedIndex: selectedIndex, entryCount: entries.count, isCollapsed: isCollapsed))

        panel.setFrameOrigin(layout.origin(petFrame: petFrame, visibleFrame: visible))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    @objc private func selectPrevious() { onSelectPrevious?() }
    @objc private func selectNext() { onSelectNext?() }
    @objc private func collapse() { onCollapse?() }
    @objc private func expand() { onExpand?() }

    private func configure(_ button: NSButton, action: Selector) {
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.target = self
        button.action = action
    }

    private func accessibilityLabel(
        for entry: AgentSessionSnapshot,
        selectedIndex: Int,
        entryCount: Int,
        isCollapsed: Bool
    ) -> String {
        if isCollapsed {
            return "Collapsed session monitor. \(entryCount) active sessions. Expand to browse sessions."
        }
        let model = entry.model.map { ", model \($0.value)" } ?? ""
        return "Speech bubble. \(entry.provider.displayLabel)\(model), \(entry.detailText), \(entry.displayText), session \(selectedIndex + 1) of \(entryCount)."
    }

    private func wrappedJobLineCount(for text: String) -> Int {
        let font = jobLabel.font ?? .systemFont(ofSize: 10, weight: .medium)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: SessionBubbleLayout.width - 76, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return min(2, max(1, Int(ceil(bounds.height / lineHeight(for: font)))))
    }

    private func layoutText(_ content: SessionBubbleContent, jobLineCount: Int, in frame: CGRect, isCollapsed: Bool) {
        modelLabel.stringValue = content.modelTitle ?? ""
        jobLabel.stringValue = content.primaryText
        detailLabel.stringValue = content.detailRows.joined(separator: "\n")

        var nextY = frame.maxY
        if content.modelTitle != nil {
            let height = modelLabel.font.map(lineHeight(for:)) ?? 15
            nextY -= height
            modelLabel.frame = CGRect(x: frame.minX, y: nextY, width: frame.width, height: height)
        }
        let jobHeight = (jobLabel.font.map(lineHeight(for:)) ?? 12) * CGFloat(jobLineCount)
        nextY -= jobHeight
        jobLabel.frame = CGRect(x: frame.minX, y: nextY, width: frame.width, height: jobHeight)
        let detailHeight = (detailLabel.font.map(lineHeight(for:)) ?? 12) * CGFloat(content.detailRows.count)
        nextY -= detailHeight
        detailLabel.frame = CGRect(x: frame.minX, y: nextY, width: frame.width, height: detailHeight)

        modelLabel.isHidden = isCollapsed || content.modelTitle == nil
        jobLabel.isHidden = isCollapsed
        detailLabel.isHidden = isCollapsed || content.detailRows.isEmpty
    }

    private func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}
