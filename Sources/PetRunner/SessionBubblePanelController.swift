import AppKit
import PetRunnerCore

@MainActor
final class SessionBubblePanelController {
    private let background = StackedBubbleBackgroundView()
    private let toggleCollapsed = NSButton(title: "", target: nil, action: nil)
    private let statusButtons = (0..<AgentSessionStore.maximumEntries).map { _ in
        NSButton(title: "", target: nil, action: nil)
    }
    private let contentView = NSView()
    private let panel: NSPanel
    private var isCollapsed = false

    /// The second argument is true when choosing a compact status cell should reopen the bubble.
    var onSelectSession: ((Int, Bool) -> Void)?
    var onToggleCollapsed: (() -> Void)?

    init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: StackedBubbleBackgroundView.expandedContentSize),
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

        configure(toggleCollapsed)
        toggleCollapsed.toolTip = "Minimize session status"
        toggleCollapsed.setAccessibilityLabel("Minimize session status")
        toggleCollapsed.action = #selector(togglePresentation)
        contentView.addSubview(toggleCollapsed)

        for (index, button) in statusButtons.enumerated() {
            configure(button)
            button.tag = index
            button.action = #selector(selectSession)
            contentView.addSubview(button)
        }

        panel.contentView = contentView
    }

    func update(
        entries: [AgentSessionSnapshot],
        selectedIndex: Int,
        petFrame: CGRect,
        isCollapsed: Bool = false
    ) {
        guard entries.indices.contains(selectedIndex) else { hide(); return }
        self.isCollapsed = isCollapsed
        let entry = entries[selectedIndex]
        let contentSize = StackedBubbleBackgroundView.contentSize(isCollapsed: isCollapsed, sessionCount: entries.count)
        panel.setContentSize(contentSize)
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        background.frame = contentView.bounds

        let sessionLabels = AgentSessionLabel.labels(for: entries.map(\.key))
        let selectedSessionLabel = sessionLabels[entry.key] ?? "SESSION"
        background.sessionCount = entries.count
        background.selectedIndex = selectedIndex
        background.providerLabel = entry.provider.displayLabel
        background.sessionLabel = selectedSessionLabel
        background.statusLabel = entry.displayText
        background.indicatorTones = entries.map(\.indicatorTone)
        background.isCollapsed = isCollapsed

        toggleCollapsed.frame = StackedBubbleBackgroundView.toggleControlFrame
        toggleCollapsed.isHidden = isCollapsed
        updateStatusButtons(entries: entries, sessionLabels: sessionLabels, isCollapsed: isCollapsed)
        background.setAccessibilityLabel(accessibilityLabel(
            for: entry,
            sessionLabel: selectedSessionLabel,
            selectedIndex: selectedIndex,
            entryCount: entries.count,
            isCollapsed: isCollapsed
        ))

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

    @objc private func selectSession(_ sender: NSButton) {
        onSelectSession?(sender.tag, isCollapsed)
    }

    @objc private func togglePresentation() { onToggleCollapsed?() }

    private func configure(_ button: NSButton) {
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.target = self
    }

    private func updateStatusButtons(
        entries: [AgentSessionSnapshot],
        sessionLabels: [AgentSessionKey: String],
        isCollapsed: Bool
    ) {
        for (index, button) in statusButtons.enumerated() {
            let isVisible = entries.indices.contains(index)
            button.isHidden = !isVisible
            guard isVisible else { continue }

            let entry = entries[index]
            let sessionLabel = sessionLabels[entry.key] ?? "SESSION"
            button.frame = StackedBubbleBackgroundView.statusControlFrame(
                at: index,
                sessionCount: entries.count,
                isCollapsed: isCollapsed
            )
            let action = isCollapsed ? "Open" : "Show"
            let label = "\(action) \(entry.provider.displayLabel) \(sessionLabel), \(entry.displayText)"
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
    }

    private func accessibilityLabel(
        for entry: AgentSessionSnapshot,
        sessionLabel: String,
        selectedIndex: Int,
        entryCount: Int,
        isCollapsed: Bool
    ) -> String {
        if isCollapsed {
            return "Collapsed session status list. \(entryCount) active sessions. Select a status cell to open that session."
        }
        return "Expanded session bubble. \(entry.provider.displayLabel), \(sessionLabel), \(entry.displayText), session \(selectedIndex + 1) of \(entryCount). Select a status cell to show another active session."
    }
}
