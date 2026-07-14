import AppKit
import PetRunnerCore

@MainActor
final class StatusMenuController: NSObject {
    var onSelectPet: ((String) -> Void)?
    var onSelectSize: ((CGFloat) -> Void)?
    var onReload: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var pets: [PetDescriptor] = []
    private var failures: [PetFailure] = []
    private var selectedID: String?
    private var selectedWidth: CGFloat = 112

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "PetRunner")
        statusItem.button?.toolTip = "PetRunner"
        statusItem.menu = menu
        rebuildMenu()
    }

    func update(
        pets: [PetDescriptor],
        failures: [PetFailure],
        selectedID: String?,
        width: CGFloat
    ) {
        self.pets = pets
        self.failures = failures
        self.selectedID = selectedID
        selectedWidth = width
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let heading = NSMenuItem(title: "PetRunner", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        if pets.isEmpty {
            let empty = NSMenuItem(title: "No valid pets found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for pet in pets {
                let item = NSMenuItem(title: pet.displayName, action: #selector(selectPet(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pet.id
                item.state = pet.id == selectedID ? .on : .off
                item.toolTip = pet.description
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let sizeMenu = NSMenu(title: "Size")
        for (title, width) in [("Small", CGFloat(80)), ("Medium", CGFloat(112)), ("Large", CGFloat(160))] {
            let item = NSMenuItem(title: "\(title) — \(Int(width)) px", action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: Double(width))
            item.state = abs(selectedWidth - width) < 0.5 ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        if !failures.isEmpty {
            let errorMenu = NSMenu(title: "Unavailable Pets")
            for failure in failures {
                let item = NSMenuItem(title: failure.id, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.toolTip = failure.message
                errorMenu.addItem(item)
            }
            let errorItem = NSMenuItem(title: "Unavailable Pets (\(failures.count))", action: nil, keyEquivalent: "")
            errorItem.submenu = errorMenu
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())
        let reload = NSMenuItem(title: "Reload Pets", action: #selector(reloadPets), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        let quit = NSMenuItem(title: "Quit PetRunner", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func selectPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectPet?(id)
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        onSelectSize?(CGFloat(number.doubleValue))
    }

    @objc private func reloadPets() { onReload?() }
    @objc private func quitApp() { onQuit?() }
}
