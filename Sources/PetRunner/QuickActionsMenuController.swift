import AppKit
import PetRunnerCore

@MainActor
final class QuickActionsMenuController: NSObject {
    struct State {
        let pets: [PetDescriptor]
        let selectedPetID: String?
        let monitorEnabled: Bool
        let autonomyEnabled: Bool
        let todayUsage: String
        let monthUsage: String
    }

    var state: () -> State?
    var onOpenDashboard: (() -> Void)?
    var onRefreshUsage: (() -> Void)?
    var onSelectPet: ((String) -> Void)?
    var onImportPet: (() -> Void)?
    var onToggleAutonomy: (() -> Void)?
    var onToggleMonitor: (() -> Void)?
    var onQuit: (() -> Void)?

    init(state: @escaping () -> State?) { self.state = state }

    func makeMenu() -> NSMenu? {
        guard let state = state() else { return nil }
        let menu = NSMenu(title: "PetRunner")
        menu.addItem(item("Open Dashboard", action: #selector(openDashboard)))
        let today = NSMenuItem(title: "Today: \(state.todayUsage)", action: nil, keyEquivalent: "")
        today.isEnabled = false
        menu.addItem(today)
        let month = NSMenuItem(title: "This month: \(state.monthUsage)", action: nil, keyEquivalent: "")
        month.isEnabled = false
        menu.addItem(month)
        menu.addItem(item("Refresh Usage", action: #selector(refreshUsage)))
        menu.addItem(.separator())

        let pets = NSMenu(title: "Change Pet")
        for pet in state.pets {
            let entry = item(pet.displayName, action: #selector(selectPet(_:)))
            entry.representedObject = pet.id
            entry.state = pet.id == state.selectedPetID ? .on : .off
            pets.addItem(entry)
        }
        let change = NSMenuItem(title: "Change Pet", action: nil, keyEquivalent: "")
        change.submenu = pets
        menu.addItem(change)
        menu.addItem(item("Import Pet…", action: #selector(importPet)))
        menu.addItem(.separator())
        let autonomy = item("Autonomous Pet", action: #selector(toggleAutonomy))
        autonomy.state = state.autonomyEnabled ? .on : .off
        menu.addItem(autonomy)
        let monitor = item("Agent Monitor", action: #selector(toggleMonitor))
        monitor.state = state.monitorEnabled ? .on : .off
        menu.addItem(monitor)
        menu.addItem(.separator())
        menu.addItem(item("Quit PetRunner", action: #selector(quit)))
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openDashboard() { onOpenDashboard?() }
    @objc private func refreshUsage() { onRefreshUsage?() }
    @objc private func selectPet(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { onSelectPet?(id) } }
    @objc private func importPet() { onImportPet?() }
    @objc private func toggleAutonomy() { onToggleAutonomy?() }
    @objc private func toggleMonitor() { onToggleMonitor?() }
    @objc private func quit() { onQuit?() }
}
