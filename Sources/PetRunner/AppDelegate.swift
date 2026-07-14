import AppKit
import OSLog
import PetRunnerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "vn.hodinhminh.petrunner", category: "app")
    private let preferences = PetRunnerPreferences()
    private let overlay = OverlayPanelController()
    private var statusMenu: StatusMenuController?
    private var petsDirectory: URL!
    private var pets: [PetDescriptor] = []
    private var failures: [PetFailure] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        petsDirectory = resolvePetsDirectory()

        let menu = StatusMenuController()
        menu.onSelectPet = { [weak self] id in self?.selectPet(id: id) }
        menu.onSelectSize = { [weak self] width in self?.selectSize(width) }
        menu.onReload = { [weak self] in self?.reloadPets() }
        menu.onQuit = { NSApp.terminate(nil) }
        statusMenu = menu

        overlay.onPositionChanged = { [weak self] origin in self?.preferences.origin = origin }
        overlay.onSizeChanged = { [weak self] width in
            self?.preferences.petWidth = width
            self?.refreshMenu()
        }
        reloadPets()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.stop()
    }

    private func reloadPets() {
        let result = PetLibrary().scan(at: petsDirectory)
        pets = result.valid
        failures = result.invalid

        guard !pets.isEmpty else {
            overlay.hide()
            preferences.selectedPetID = nil
            refreshMenu()
            logger.error("No valid pets found in \(self.petsDirectory.path, privacy: .public)")
            return
        }

        let preferred = pets.first { $0.id == preferences.selectedPetID }
        let ordered = preferred.map { preferredPet in
            [preferredPet] + pets.filter { $0.id != preferredPet.id }
        } ?? pets
        var loadedPet: PetDescriptor?
        for pet in ordered {
            do {
                try overlay.show(pet: pet, width: preferences.petWidth, savedOrigin: preferences.origin)
                loadedPet = pet
                break
            } catch {
                failures.append(PetFailure(id: pet.id, message: error.localizedDescription))
                logger.error("Failed to render pet \(pet.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if let loadedPet {
            preferences.selectedPetID = loadedPet.id
        } else {
            overlay.hide()
            preferences.selectedPetID = nil
        }
        refreshMenu()
    }

    private func selectPet(id: String) {
        guard let pet = pets.first(where: { $0.id == id }) else { return }
        do {
            try overlay.show(pet: pet, width: preferences.petWidth, savedOrigin: preferences.origin)
            preferences.selectedPetID = pet.id
        } catch {
            failures.removeAll { $0.id == pet.id }
            failures.append(PetFailure(id: pet.id, message: error.localizedDescription))
            logger.error("Failed to select pet \(pet.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        refreshMenu()
    }

    private func selectSize(_ width: CGFloat) {
        preferences.petWidth = width
        overlay.setWidth(preferences.petWidth)
        refreshMenu()
    }

    private func refreshMenu() {
        statusMenu?.update(
            pets: pets,
            failures: failures,
            selectedID: preferences.selectedPetID,
            width: preferences.petWidth
        )
    }

    private func resolvePetsDirectory() -> URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--pets-dir"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath, isDirectory: true)
        }
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !codexHome.isEmpty {
            return URL(fileURLWithPath: NSString(string: codexHome).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("pets", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
    }
}
