import AppKit
import PetRunnerCore

@MainActor
final class MonitorSetupWindowController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let enableButton = NSButton(title: "Enable", target: nil, action: nil)
    private var detections: [ProviderDetection] = []
    private var buttons: [NSButton] = []
    private var completion: (([AgentProvider]) -> Void)?
    var onDismiss: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 250),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Enable Agent Monitor"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    func present(detections: [ProviderDetection], completion: @escaping ([AgentProvider]) -> Void) {
        self.detections = detections
        self.completion = completion

        let content = NSView(frame: panel.contentView!.bounds)
        let explanation = NSTextField(wrappingLabelWithString: "Select providers to install local monitor hooks. PetRunner keeps a shortened first prompt as the session name only while it runs; Cursor may replace it with its local title. Nothing is selected by default.")
        explanation.frame = CGRect(x: 20, y: 166, width: 320, height: 60)
        content.addSubview(explanation)

        let stack = NSStackView(frame: CGRect(x: 20, y: 65, width: 320, height: 92))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        buttons = detections.map { detection in
            let title = "\(detection.provider.displayLabel)\(detection.isDetected ? " (detected)" : "")"
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(selectionChanged))
            button.state = .off
            stack.addArrangedSubview(button)
            return button
        }
        content.addSubview(stack)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = CGRect(x: 174, y: 20, width: 78, height: 28)
        enableButton.frame = CGRect(x: 262, y: 20, width: 78, height: 28)
        enableButton.target = self
        enableButton.action = #selector(enable)
        enableButton.keyEquivalent = "\r"
        enableButton.isEnabled = false
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
        enableButton.isEnabled = buttons.contains { $0.state == .on }
    }

    @objc private func cancel() { panel.close() }

    @objc private func enable() {
        let providers = zip(detections, buttons).compactMap { $0.1.state == .on ? $0.0.provider : nil }
        guard !providers.isEmpty else { return }
        let handler = completion
        completion = nil
        handler?(providers)
        panel.close()
    }
}
