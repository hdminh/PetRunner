import AppKit
import CoreGraphics
import Foundation
import PetRunnerCore

struct DashboardPetState {
    let pets: [PetDescriptor]
    let selectedPetID: String?
    let width: CGFloat
    let autonomyEnabled: Bool
    let autonomyConfiguration: AutonomyConfiguration
}

@MainActor
final class DashboardWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let historyStore: () -> AgentSessionHistoryStore?
    private let historyError: () -> String?
    private let petState: () -> DashboardPetState?
    private let onSelectPet: (String) -> Void
    private let onSetWidth: (CGFloat) -> Void
    private let onResetPosition: () -> Void
    private let onSetAutonomyEnabled: (Bool) -> Void
    private let onSetAutonomyConfiguration: (AutonomyConfiguration) -> Void

    private let providerPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let rangePopup = NSPopUpButton()
    private let searchField = NSSearchField()
    private let totalLabel = NSTextField(labelWithString: "Estimated total: No estimates")
    private let sessionTable = NSTableView()
    private let detailView = NSTextView()
    private let petPopup = NSPopUpButton()
    private let sizeControl = NSSegmentedControl(labels: ["Small", "Medium", "Large", "XL"], trackingMode: .selectOne, target: nil, action: nil)
    private let autonomyToggle = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let minimumPopup = NSPopUpButton()
    private let maximumPopup = NSPopUpButton()
    private var actionToggles: [AutonomousActionKind: NSButton] = [:]
    private var summaries: [AgentSessionHistorySummary] = []
    private var allSummaries: [AgentSessionHistorySummary] = []

    init(
        historyStore: @escaping () -> AgentSessionHistoryStore?,
        historyError: @escaping () -> String?,
        petState: @escaping () -> DashboardPetState?,
        onSelectPet: @escaping (String) -> Void,
        onSetWidth: @escaping (CGFloat) -> Void,
        onResetPosition: @escaping () -> Void,
        onSetAutonomyEnabled: @escaping (Bool) -> Void,
        onSetAutonomyConfiguration: @escaping (AutonomyConfiguration) -> Void
    ) {
        self.historyStore = historyStore
        self.historyError = historyError
        self.petState = petState
        self.onSelectPet = onSelectPet
        self.onSetWidth = onSetWidth
        self.onResetPosition = onResetPosition
        self.onSetAutonomyEnabled = onSetAutonomyEnabled
        self.onSetAutonomyConfiguration = onSetAutonomyConfiguration

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PetRunner Dashboard"
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureWindow()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        refreshHistory()
        refreshPetControls()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshHistory() {
        guard let store = historyStore() else {
            summaries = []
            sessionTable.reloadData()
            detailView.string = historyError() ?? "Session history is unavailable."
            totalLabel.stringValue = "Estimated total: No estimates"
            return
        }
        do {
            allSummaries = try store.summaries()
            populateModelPopup()
            let query = AgentSessionHistoryQuery(
                provider: selectedProvider,
                model: selectedModel,
                searchText: searchField.stringValue,
                startDate: selectedRange.startDate
            )
            summaries = try store.summaries(matching: query)
            sessionTable.reloadData()
            totalLabel.stringValue = "Estimated total: \(estimatedTotalText())"
            if summaries.isEmpty {
                detailView.string = "No sessions in this range. Live monitor events will appear here."
            } else {
                sessionTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                showDetails(for: summaries[0])
            }
        } catch {
            summaries = []
            sessionTable.reloadData()
            detailView.string = error.localizedDescription
            totalLabel.stringValue = "Estimated total: No estimates"
        }
    }

    func refreshPetControls() {
        guard let state = petState() else { return }
        let currentID = petPopup.selectedItem?.representedObject as? String
        petPopup.removeAllItems()
        for pet in state.pets {
            petPopup.addItem(withTitle: pet.displayName)
            petPopup.lastItem?.representedObject = pet.id
        }
        if let selectedID = state.selectedPetID,
           let index = petPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedID }) {
            petPopup.selectItem(at: index)
        } else if let currentID,
                  let index = petPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == currentID }) {
            petPopup.selectItem(at: index)
        }
        sizeControl.selectedSegment = [80, 112, 160, 224].firstIndex { abs(state.width - CGFloat($0)) < 0.5 } ?? 1
        autonomyToggle.state = state.autonomyEnabled ? .on : .off
        minimumPopup.selectItem(withTitle: "\(Int(state.autonomyConfiguration.minimumWait)) seconds")
        maximumPopup.selectItem(withTitle: "\(Int(state.autonomyConfiguration.maximumWait)) seconds")
        for (action, toggle) in actionToggles {
            toggle.state = state.autonomyConfiguration.enabledActions.contains(action) ? .on : .off
        }
    }

    @objc private func refreshHistoryFromControl() { refreshHistory() }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all session history?"
        alert.informativeText = "This removes the local 90-day history. Monitoring remains enabled."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let store = historyStore() else { return }
        do {
            try store.clear()
            refreshHistory()
        } catch {
            detailView.string = error.localizedDescription
        }
    }

    @objc private func selectPet() {
        guard let id = petPopup.selectedItem?.representedObject as? String else { return }
        onSelectPet(id)
    }

    @objc private func selectSize() {
        let sizes: [CGFloat] = [80, 112, 160, 224]
        guard sizes.indices.contains(sizeControl.selectedSegment) else { return }
        onSetWidth(sizes[sizeControl.selectedSegment])
    }

    @objc private func resetPosition() { onResetPosition() }

    @objc private func toggleAutonomy() {
        onSetAutonomyEnabled(autonomyToggle.state == .on)
    }

    @objc private func updateAutonomyConfiguration() {
        let minimum = TimeInterval(selectedSeconds(from: minimumPopup))
        let maximum = TimeInterval(selectedSeconds(from: maximumPopup))
        if minimum > maximum {
            maximumPopup.selectItem(withTitle: "\(Int(minimum)) seconds")
        }
        let enabled = Set(actionToggles.compactMap { action, toggle in toggle.state == .on ? action : nil })
        guard !enabled.isEmpty else {
            actionToggles[.walk]?.state = .on
            return
        }
        guard let configuration = AutonomyConfiguration(
            minimumWait: minimum,
            maximumWait: max(minimum, TimeInterval(selectedSeconds(from: maximumPopup))),
            enabledActions: enabled
        ) else { return }
        onSetAutonomyConfiguration(configuration)
    }

    private func configureWindow() {
        let tabs = NSTabView(frame: window?.contentView?.bounds ?? .zero)
        tabs.autoresizingMask = [.width, .height]
        tabs.addTabViewItem(NSTabViewItem(identifier: "sessions"))
        tabs.tabViewItems[0].label = "Sessions"
        tabs.tabViewItems[0].view = sessionView()
        tabs.addTabViewItem(NSTabViewItem(identifier: "pet"))
        tabs.tabViewItems[1].label = "Pet"
        tabs.tabViewItems[1].view = petView()
        window?.contentView = tabs
    }

    private func sessionView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 590))
        providerPopup.frame = NSRect(x: 18, y: 545, width: 130, height: 26)
        providerPopup.addItems(withTitles: ["All providers"] + AgentProvider.allCases.map(\.displayLabel))
        modelPopup.frame = NSRect(x: 158, y: 545, width: 145, height: 26)
        rangePopup.frame = NSRect(x: 313, y: 545, width: 125, height: 26)
        rangePopup.addItems(withTitles: HistoryRange.allCases.map(\.label))
        rangePopup.selectItem(withTitle: HistoryRange.days30.label)
        searchField.frame = NSRect(x: 448, y: 545, width: 240, height: 26)
        searchField.placeholderString = "Search session or job"
        searchField.sendsSearchStringImmediately = true
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshHistoryFromControl))
        refresh.frame = NSRect(x: 698, y: 545, width: 80, height: 26)
        let clear = NSButton(title: "Clear History…", target: self, action: #selector(clearHistory))
        clear.frame = NSRect(x: 786, y: 545, width: 100, height: 26)
        totalLabel.frame = NSRect(x: 18, y: 514, width: 350, height: 20)
        for control in [providerPopup, modelPopup, rangePopup, searchField] {
            control.target = self
            control.action = #selector(refreshHistoryFromControl)
            view.addSubview(control)
        }
        view.addSubview(refresh)
        view.addSubview(clear)
        view.addSubview(totalLabel)

        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        tableColumn.width = 350
        sessionTable.addTableColumn(tableColumn)
        sessionTable.headerView = nil
        sessionTable.rowHeight = 62
        sessionTable.delegate = self
        sessionTable.dataSource = self
        let tableScroll = NSScrollView(frame: NSRect(x: 18, y: 18, width: 355, height: 485))
        tableScroll.autoresizingMask = [.height]
        sessionTable.frame = tableScroll.bounds
        tableScroll.documentView = sessionTable
        tableScroll.hasVerticalScroller = true
        view.addSubview(tableScroll)

        detailView.isEditable = false
        detailView.isSelectable = true
        detailView.font = .systemFont(ofSize: 13)
        detailView.textContainerInset = NSSize(width: 12, height: 12)
        let detailScroll = NSScrollView(frame: NSRect(x: 386, y: 18, width: 496, height: 485))
        detailScroll.autoresizingMask = [.width, .height]
        detailScroll.documentView = detailView
        detailScroll.hasVerticalScroller = true
        view.addSubview(detailScroll)
        return view
    }

    private func petView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 590))
        addLabel("Pet", at: NSRect(x: 24, y: 530, width: 90, height: 24), to: view)
        petPopup.frame = NSRect(x: 130, y: 528, width: 250, height: 26)
        petPopup.target = self
        petPopup.action = #selector(selectPet)
        view.addSubview(petPopup)

        addLabel("Size", at: NSRect(x: 24, y: 480, width: 90, height: 24), to: view)
        sizeControl.frame = NSRect(x: 130, y: 476, width: 330, height: 28)
        sizeControl.target = self
        sizeControl.action = #selector(selectSize)
        view.addSubview(sizeControl)
        let reset = NSButton(title: "Reset Position", target: self, action: #selector(resetPosition))
        reset.frame = NSRect(x: 475, y: 476, width: 120, height: 28)
        view.addSubview(reset)

        addLabel("Autonomous Pet", at: NSRect(x: 24, y: 410, width: 150, height: 24), to: view)
        autonomyToggle.frame = NSRect(x: 130, y: 406, width: 120, height: 26)
        autonomyToggle.target = self
        autonomyToggle.action = #selector(toggleAutonomy)
        view.addSubview(autonomyToggle)
        addLabel("Minimum wait", at: NSRect(x: 24, y: 362, width: 100, height: 24), to: view)
        addLabel("Maximum wait", at: NSRect(x: 24, y: 324, width: 100, height: 24), to: view)
        for popup in [minimumPopup, maximumPopup] {
            popup.addItems(withTitles: (5...30).map { "\($0) seconds" })
            popup.target = self
            popup.action = #selector(updateAutonomyConfiguration)
        }
        minimumPopup.frame = NSRect(x: 130, y: 360, width: 130, height: 26)
        maximumPopup.frame = NSRect(x: 130, y: 322, width: 130, height: 26)
        view.addSubview(minimumPopup)
        view.addSubview(maximumPopup)

        var y = 270
        for action in AutonomousActionKind.allCases {
            let toggle = NSButton(checkboxWithTitle: action.displayLabel, target: self, action: #selector(updateAutonomyConfiguration))
            toggle.frame = NSRect(x: 130, y: y, width: 130, height: 24)
            actionToggles[action] = toggle
            view.addSubview(toggle)
            y -= 32
        }
        return view
    }

    private func addLabel(_ text: String, at frame: NSRect, to view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        view.addSubview(label)
    }

    private var selectedProvider: AgentProvider? {
        providerPopup.indexOfSelectedItem == 0 ? nil : AgentProvider(rawValue: providerPopup.titleOfSelectedItem?.lowercased() ?? "")
    }

    private var selectedModel: AgentSessionModel? {
        modelPopup.indexOfSelectedItem <= 0 ? nil : AgentSessionModel.sanitized(modelPopup.titleOfSelectedItem ?? "")
    }

    private var selectedRange: HistoryRange {
        HistoryRange.allCases.first { $0.label == rangePopup.titleOfSelectedItem } ?? .days30
    }

    private func populateModelPopup() {
        let selected = modelPopup.titleOfSelectedItem
        modelPopup.removeAllItems()
        modelPopup.addItem(withTitle: "All models")
        modelPopup.addItems(withTitles: Array(Set(allSummaries.compactMap { $0.model?.value })).sorted())
        if let selected, modelPopup.itemTitles.contains(selected) { modelPopup.selectItem(withTitle: selected) }
    }

    private func estimatedTotalText() -> String {
        let values = summaries.compactMap(\.estimatedCost?.usd)
        guard !values.isEmpty else { return "No estimates" }
        return AgentSessionEstimatedCost(usd: values.reduce(Decimal.zero, +))?.displayText ?? "No estimates"
    }

    private func selectedSeconds(from popup: NSPopUpButton) -> Int {
        Int(popup.titleOfSelectedItem?.split(separator: " ").first ?? "10") ?? 10
    }

    private func showDetails(for summary: AgentSessionHistorySummary) {
        guard let store = historyStore() else { return }
        do {
            let timeline = try store.timeline(for: summary.id)
            let header = "\(summary.sessionName?.value ?? "Unnamed session")\n\(summary.provider.displayLabel) · \(summary.model?.value ?? "Unknown model")\n\(summary.estimatedCost?.displayText ?? "No estimate")"
            let entries = timeline.map { entry in
                "\n\(entry.occurredAt.formatted())\n\(entry.status.displayText)\n\(entry.activity?.value ?? entry.status.detailText)"
            }.joined(separator: "\n")
            detailView.string = header + "\n\nTimeline\n" + entries
        } catch {
            detailView.string = error.localizedDescription
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { summaries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard summaries.indices.contains(row) else { return nil }
        let summary = summaries[row]
        let cell = NSTableCellView()
        let text = NSTextField(wrappingLabelWithString: "\(summary.sessionName?.value ?? "Unnamed session")\n\(summary.provider.displayLabel) · \(summary.model?.value ?? "Unknown model")\n\(summary.activity?.value ?? summary.status.displayText) · \(summary.estimatedCost?.displayText ?? "No estimate")")
        text.frame = NSRect(x: 8, y: 5, width: 334, height: 54)
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sessionTable.selectedRow
        guard summaries.indices.contains(row) else { return }
        showDetails(for: summaries[row])
    }
}

private enum HistoryRange: CaseIterable {
    case days7
    case days30
    case days90
    case all

    var label: String {
        switch self {
        case .days7: "7 days"
        case .days30: "30 days"
        case .days90: "90 days"
        case .all: "All retained"
        }
    }

    var startDate: Date? {
        switch self {
        case .days7: Date().addingTimeInterval(-7 * 24 * 60 * 60)
        case .days30: Date().addingTimeInterval(-30 * 24 * 60 * 60)
        case .days90: Date().addingTimeInterval(-90 * 24 * 60 * 60)
        case .all: nil
        }
    }
}
