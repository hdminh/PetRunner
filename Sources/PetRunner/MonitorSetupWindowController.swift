import AppKit
import PetRunnerCore

@MainActor
final class MonitorSetupWindowController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let enableButton = NSButton(title: "Enable", target: nil, action: nil)
    private var detections: [ProviderDetection] = []
    private var providerButtons: [NSButton] = []
    private var fieldButtons: [(MonitorBubbleField, NSButton)] = []
    private var completion: ((AgentProvider, [MonitorBubbleField]) -> Void)?
    var onDismiss: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 390),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Enable Agent Monitor"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    func present(
        detections: [ProviderDetection],
        selectedProvider: AgentProvider? = nil,
        bubbleFields: [MonitorBubbleField] = MonitorBubbleField.allCases,
        completion: @escaping (AgentProvider, [MonitorBubbleField]) -> Void
    ) {
        self.detections = detections
        self.completion = completion

        let content = NSView(frame: panel.contentView!.bounds)
        let explanation = NSTextField(wrappingLabelWithString: "Choose one provider for local monitor hooks. Provider and status are always shown; choose the fields to save for the Phase 2 bubble.")
        explanation.frame = CGRect(x: 20, y: 308, width: 320, height: 58)
        content.addSubview(explanation)

        let stack = NSStackView(frame: CGRect(x: 20, y: 216, width: 320, height: 82))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        providerButtons = detections.map { detection in
            let title = "\(detection.provider.displayLabel)\(detection.isDetected ? " (detected)" : "")"
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(selectionChanged))
            button.state = detection.provider == selectedProvider ? .on : .off
            stack.addArrangedSubview(button)
            return button
        }
        content.addSubview(stack)

        let fieldTitle = NSTextField(labelWithString: "Save optional fields")
        fieldTitle.frame = CGRect(x: 20, y: 184, width: 200, height: 20)
        content.addSubview(fieldTitle)
        let fields = NSStackView(frame: CGRect(x: 20, y: 82, width: 320, height: 96))
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 4
        fieldButtons = MonitorBubbleField.allCases.map { field in
            let button = NSButton(checkboxWithTitle: field.displayLabel, target: nil, action: nil)
            button.state = bubbleFields.contains(field) ? .on : .off
            fields.addArrangedSubview(button)
            return (field, button)
        }
        content.addSubview(fields)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = CGRect(x: 174, y: 20, width: 78, height: 28)
        enableButton.frame = CGRect(x: 262, y: 20, width: 78, height: 28)
        enableButton.target = self
        enableButton.action = #selector(enable)
        enableButton.keyEquivalent = "\r"
        enableButton.isEnabled = providerButtons.contains { $0.state == .on }
        content.addSubview(cancel)
        content.addSubview(enableButton)
        panel.contentView = content

        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        completion = nil
        onDismiss?()
    }

    @objc private func selectionChanged() {
        guard let selected = providerButtons.firstIndex(where: { $0.state == .on }) else {
            enableButton.isEnabled = false
            return
        }
        for index in providerButtons.indices where index != selected {
            providerButtons[index].state = .off
        }
        enableButton.isEnabled = true
    }

    @objc private func cancel() { panel.close() }

    @objc private func enable() {
        guard let provider = zip(detections, providerButtons).first(where: { $0.1.state == .on })?.0.provider else { return }
        let fields = fieldButtons.compactMap { $0.1.state == .on ? $0.0 : nil }
        let handler = completion
        completion = nil
        panel.close()
        handler?(provider, fields)
    }
}
