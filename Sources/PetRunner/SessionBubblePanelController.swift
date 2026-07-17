import AppKit
import PetRunnerCore

@MainActor
final class SessionBubblePanelController {
    private let background = StackedBubbleBackgroundView()
    private let collapseButton = NSButton(title: "", target: nil, action: nil)
    private let previousButton = NSButton(title: "", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private let expandButton = NSButton(title: "", target: nil, action: nil)
    private let metadataLabel = NSTextField(labelWithString: "")
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

        metadataLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        metadataLabel.textColor = .black
        metadataLabel.maximumNumberOfLines = 4
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.isSelectable = false
        contentView.addSubview(metadataLabel)

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
        let detailRows = detailRows(for: entry, visibleFields: visibleFields)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(petFrame) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? petFrame.insetBy(dx: -SessionBubbleLayout.width, dy: -200)
        let provisional = SessionBubbleLayout(
            sessionCount: entries.count,
            selectedIndex: selectedIndex,
            detailLineCount: detailRows.count,
            side: .above,
            isCollapsed: isCollapsed
        )
        let side = SessionBubbleLayout.preferredSide(petFrame: petFrame, visibleFrame: visible, contentSize: provisional.contentSize)
        let layout = SessionBubbleLayout(
            sessionCount: entries.count,
            selectedIndex: selectedIndex,
            detailLineCount: detailRows.count,
            side: side,
            isCollapsed: isCollapsed
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
        background.statusLabel = entry.displayText
        background.indicatorTones = entries.map(\.indicatorTone)
        background.detailLineCount = detailRows.count
        background.thoughtSide = side
        background.isCollapsed = isCollapsed
        background.canSelectPrevious = selectedIndex > 0
        background.canSelectNext = selectedIndex < entries.count - 1

        metadataLabel.frame = layout.metadataFrame
        metadataLabel.stringValue = detailRows.joined(separator: "\n")
        metadataLabel.isHidden = isCollapsed || detailRows.isEmpty

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
        return "Thought bubble. \(entry.provider.displayLabel)\(model), \(entry.detailText), \(entry.displayText), session \(selectedIndex + 1) of \(entryCount)."
    }

    private func detailRows(for entry: AgentSessionSnapshot, visibleFields: [MonitorBubbleField]) -> [String] {
        visibleFields.compactMap { field in
            switch field {
            case .model: entry.model.map { "MODEL  \($0.value)" }
            case .job: entry.activity.map { "JOB    \($0.value)" }
            case .sessionName: entry.sessionName.map { "SESSION \($0.value)" }
            case .cost: entry.estimatedCost.map { "SESSION EST. \($0.displayText)" }
            }
        }
    }
}
