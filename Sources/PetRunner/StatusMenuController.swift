import AppKit
import ImageIO
import PetRunnerCore

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    var onSelectPet: ((String) -> Void)?
    var onSelectSize: ((CGFloat) -> Void)?
    var onReload: (() -> Void)?
    var onToggleMonitor: (() -> Void)?
    var onRepairMonitor: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var pets: [PetDescriptor] = []
    private var failures: [PetFailure] = []
    private var selectedID: String?
    private var selectedWidth: CGFloat = 112
    private var monitorEnabled = false
    private var petSubmenu: NSMenu?
    private var previewView: PetPreviewMenuView?
    private var thumbnailCache: [ThumbnailKey: NSImage] = [:]

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        {
            icon.size = CGSize(width: 18, height: 18)
            statusItem.button?.image = icon
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: "pawprint.fill",
                accessibilityDescription: "PetRunner"
            )
        }
        statusItem.button?.toolTip = "PetRunner"
        statusItem.menu = menu
        rebuildMenu()
    }

    func update(
        pets: [PetDescriptor],
        failures: [PetFailure],
        selectedID: String?,
        width: CGFloat,
        monitorEnabled: Bool = false
    ) {
        self.pets = pets
        self.failures = failures
        self.selectedID = selectedID
        selectedWidth = width
        self.monitorEnabled = monitorEnabled
        let activeKeys = Set(pets.map(thumbnailKey(for:)))
        thumbnailCache = thumbnailCache.filter { activeKeys.contains($0.key) }
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let heading = NSMenuItem(title: "PetRunner", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        let changePetItem = NSMenuItem(title: "Change Pet", action: nil, keyEquivalent: "")
        changePetItem.submenu = makePetSubmenu()
        menu.addItem(changePetItem)

        let sizeMenu = NSMenu(title: "Size")
        for (title, width) in [
            ("Small", CGFloat(80)),
            ("Medium", CGFloat(112)),
            ("Large", CGFloat(160)),
            ("XL", CGFloat(224)),
        ] {
            let item = NSMenuItem(title: "\(title) — \(Int(width)) px", action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: Double(width))
            item.state = abs(selectedWidth - width) < 0.5 ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let reload = NSMenuItem(title: "Reload Pets", action: #selector(reloadPets), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

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
        let monitorMenu = NSMenu(title: "Agent Monitor")
        let monitor = NSMenuItem(title: "Enable Agent Monitor", action: #selector(toggleMonitor), keyEquivalent: "")
        monitor.target = self
        monitor.state = monitorEnabled ? .on : .off
        monitorMenu.addItem(monitor)
        if monitorEnabled {
            monitorMenu.addItem(.separator())
            let repair = NSMenuItem(title: "Repair Hook Configuration…", action: #selector(repairMonitor), keyEquivalent: "")
            repair.target = self
            monitorMenu.addItem(repair)
        }
        let monitorItem = NSMenuItem(title: "Agent Monitor", action: nil, keyEquivalent: "")
        monitorItem.submenu = monitorMenu
        menu.addItem(monitorItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit PetRunner", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func makePetSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Change Pet")
        submenu.delegate = self
        petSubmenu = submenu

        guard !pets.isEmpty else {
            previewView = nil
            let empty = NSMenuItem(title: "No valid pets found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return submenu
        }

        let initialPet = pets.first(where: { $0.id == selectedID }) ?? pets[0]
        let preview = PetPreviewMenuView(frame: CGRect(x: 0, y: 0, width: 260, height: 88))
        preview.update(pet: initialPet, image: thumbnail(for: initialPet))
        previewView = preview
        let previewItem = NSMenuItem()
        previewItem.view = preview
        previewItem.isEnabled = false
        submenu.addItem(previewItem)
        submenu.addItem(.separator())

        for pet in pets {
            let item = NSMenuItem(title: pet.displayName, action: #selector(selectPet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pet.id
            item.state = pet.id == selectedID ? .on : .off
            item.toolTip = pet.description
            if let image = thumbnail(for: pet)?.copy() as? NSImage {
                image.size = CGSize(width: 24, height: 26)
                item.image = image
            }
            submenu.addItem(item)
        }
        return submenu
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard
            menu === petSubmenu,
            let id = item?.representedObject as? String,
            let pet = pets.first(where: { $0.id == id })
        else { return }
        previewView?.update(pet: pet, image: thumbnail(for: pet))
    }

    private func thumbnail(for pet: PetDescriptor) -> NSImage? {
        let key = thumbnailKey(for: pet)
        if let cached = thumbnailCache[key] { return cached }

        let thumbnail: NSImage? = autoreleasepool {
            guard
                let source = CGImageSourceCreateWithURL(pet.spritesheetURL as CFURL, nil),
                let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let idleFrame = atlas.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 208)),
                let context = CGContext(
                    data: nil,
                    width: 144,
                    height: 156,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }

            context.clear(CGRect(x: 0, y: 0, width: 144, height: 156))
            context.interpolationQuality = .high
            context.draw(idleFrame, in: CGRect(x: 0, y: 0, width: 144, height: 156))
            guard let rasterized = context.makeImage() else { return nil }
            return NSImage(cgImage: rasterized, size: CGSize(width: 72, height: 78))
        }
        if let thumbnail { thumbnailCache[key] = thumbnail }
        return thumbnail
    }

    private func thumbnailKey(for pet: PetDescriptor) -> ThumbnailKey {
        let modificationDate = try? pet.spritesheetURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return ThumbnailKey(path: pet.spritesheetURL.path, modificationDate: modificationDate)
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
    @objc private func toggleMonitor() { onToggleMonitor?() }
    @objc private func repairMonitor() { onRepairMonitor?() }
    @objc private func quitApp() { onQuit?() }
}

private struct ThumbnailKey: Hashable {
    let path: String
    let modificationDate: Date?
}

@MainActor
private final class PetPreviewMenuView: NSView {
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.frame = CGRect(x: 10, y: 7, width: 68, height: 74)
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.unregisterDraggedTypes()
        addSubview(imageView)

        nameLabel.frame = CGRect(x: 88, y: 49, width: 162, height: 20)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        descriptionLabel.frame = CGRect(x: 88, y: 13, width: 162, height: 34)
        descriptionLabel.font = .systemFont(ofSize: 10)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.lineBreakMode = .byTruncatingTail
        addSubview(descriptionLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(pet: PetDescriptor, image: NSImage?) {
        imageView.image = image
        nameLabel.stringValue = pet.displayName
        descriptionLabel.stringValue = pet.description ?? "Codex-compatible pet"
        setAccessibilityLabel("Preview of \(pet.displayName)")
    }
}
