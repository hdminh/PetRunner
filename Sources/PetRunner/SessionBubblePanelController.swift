import AppKit
import PetRunnerCore

@MainActor
final class SessionBubblePanelController {
    private let background = StackedBubbleBackgroundView()
    private let collapseButton = NSButton(title: "", target: nil, action: nil)
    private let previousButton = NSButton(title: "", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private let expandButton = NSButton(title: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
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

        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .black
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.isSelectable = false
        contentView.addSubview(titleLabel)

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
        isCollapsed: Bool = false
    ) {
        guard entries.indices.contains(selectedIndex) else { hide(); return }
        let entry = entries[selectedIndex]
        let layout = SessionBubbleLayout(sessionCount: entries.count, isCollapsed: isCollapsed)
        let contentSize = layout.contentSize
        panel.setContentSize(contentSize)
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        background.frame = contentView.bounds

        background.sessionCount = entries.count
        background.selectedIndex = selectedIndex
        background.providerLabel = entry.provider.displayLabel
        background.sessionPosition = "\(selectedIndex + 1)/\(entries.count)"
        background.statusLabel = entry.displayText
        background.indicatorTones = entries.map(\.indicatorTone)
        background.isCollapsed = isCollapsed
        background.canSelectPrevious = selectedIndex > 0
        background.canSelectNext = selectedIndex < entries.count - 1

        titleLabel.frame = layout.titleFrame
        titleLabel.stringValue = entry.detailText
        titleLabel.isHidden = isCollapsed

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

        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(petFrame) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? petFrame.insetBy(dx: -contentSize.width, dy: -contentSize.height)
        let right = petFrame.maxX + 10
        let left = petFrame.minX - contentSize.width - 10
        let preferredX = visible.maxX - right >= contentSize.width ? right : left
        let x = min(max(preferredX, visible.minX), visible.maxX - contentSize.width)
        let y = min(max(petFrame.maxY - contentSize.height, visible.minY), visible.maxY - contentSize.height)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
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
        return "Expanded session monitor. \(entry.provider.displayLabel), \(entry.detailText), \(entry.displayText), session \(selectedIndex + 1) of \(entryCount)."
    }
}
