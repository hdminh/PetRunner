import AppKit
import OSLog
import PetRunnerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "vn.hodinhminh.petrunner", category: "app")
    private let preferences = PetRunnerPreferences()
    private let overlay = OverlayPanelController()
    private let monitorBridge = AgentMonitorBridge()
    private var monitorStore = AgentSessionStore()
    private var terminalSessionExpiry: [AgentSessionKey: DispatchWorkItem] = [:]
    private let sessionBubble = SessionBubblePanelController()
    private var monitorSetup: MonitorSetupWindowController?
    private var statusMenu: StatusMenuController?
    private var petsDirectory: URL!
    private var pets: [PetDescriptor] = []
    private var failures: [PetFailure] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        petsDirectory = resolvePetsDirectory()
        preferences.migrateLegacyMonitorProviderIfNeeded()

        let menu = StatusMenuController()
        menu.onSelectPet = { [weak self] id in self?.selectPet(id: id) }
        menu.onSelectSize = { [weak self] width in self?.selectSize(width) }
        menu.onReload = { [weak self] in self?.reloadPets() }
        menu.onToggleMonitor = { [weak self] in self?.toggleMonitor() }
        menu.onConfigureMonitor = { [weak self] in self?.presentMonitorSetup() }
        menu.onRepairMonitor = { [weak self] in self?.repairMonitorHooks() }
        menu.onQuit = { NSApp.terminate(nil) }
        statusMenu = menu

        overlay.onPositionChanged = { [weak self] origin in self?.preferences.origin = origin }
        overlay.onSizeChanged = { [weak self] width in
            self?.preferences.petWidth = width
            self?.refreshMenu()
        }
        sessionBubble.onSelectPrevious = { [weak self] in self?.selectPreviousSession() }
        sessionBubble.onSelectNext = { [weak self] in self?.selectNextSession() }
        sessionBubble.onCollapse = { [weak self] in self?.setMonitorBubbleCollapsed(true) }
        sessionBubble.onExpand = { [weak self] in self?.setMonitorBubbleCollapsed(false) }
        overlay.onFrameChanged = { [weak self] _ in self?.refreshMonitorPresentation() }
        reloadPets()
        if preferences.monitorEnabled, preferences.monitorProvider != nil {
            do {
                try startMonitorBridge()
                restoreRecoveredMonitorSessions()
            } catch {
                logger.error("Failed to start monitor bridge: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            AgentMonitorBridge.removeDescriptor()
            AgentMonitorBridge.removeRecoveryJournal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelTerminalExpiry()
        overlay.stop()
        monitorBridge.stop()
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
            width: preferences.petWidth,
            monitorEnabled: preferences.monitorEnabled
        )
    }

    private func toggleMonitor() {
        if preferences.monitorEnabled {
            do {
                try ProviderHookInstaller().removeAll()
                preferences.monitorEnabled = false
                preferences.monitorProvider = nil
                cancelTerminalExpiry()
                monitorStore.removeAll()
                monitorBridge.stop()
                AgentMonitorBridge.removeRecoveryJournal()
                sessionBubble.hide()
                overlay.setMonitorAnimation(nil)
            } catch {
                logger.error("Failed to remove monitor hooks: \(error.localizedDescription, privacy: .public)")
                showMonitorError("PetRunner could not remove all of its monitor hooks. Your monitoring setup is still enabled; repair the provider config and try again.")
            }
            refreshMenu()
            return
        }
        presentMonitorSetup()
    }

    private func presentMonitorSetup() {
        let detections = ProviderDetector.detect(existingPaths: Set([".claude", ".codex", ".cursor"].filter {
            FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path)
        }))
        let setup = MonitorSetupWindowController()
        monitorSetup = setup
        setup.onDismiss = { [weak self] in self?.monitorSetup = nil }
        setup.present(
            detections: detections,
            selectedProvider: preferences.monitorProvider,
            bubbleFields: preferences.monitorBubbleFields
        ) { [weak self] provider, bubbleFields in
            guard let self, let executable = Bundle.main.executableURL?.path else { return }
            do {
                try self.startMonitorBridge()
                do {
                    try ProviderHookInstaller().replace(with: provider, executablePath: executable)
                } catch {
                    self.monitorBridge.stop()
                    throw error
                }
                self.preferences.monitorProvider = provider
                self.preferences.monitorBubbleFields = bubbleFields
                self.preferences.monitorEnabled = true
                self.refreshMenu()
            } catch {
                self.logger.error("Failed to install monitor hooks: \(error.localizedDescription, privacy: .public)")
                self.showMonitorError("PetRunner did not enable monitoring. \(error.localizedDescription)")
            }
        }
    }

    private func repairMonitorHooks() {
        guard preferences.monitorEnabled,
              let provider = preferences.monitorProvider,
              let executable = Bundle.main.executableURL?.path
        else { return }
        do {
            try startMonitorBridge()
            try ProviderHookInstaller().replace(with: provider, executablePath: executable)
        } catch {
            logger.error("Failed to repair monitor hooks: \(error.localizedDescription, privacy: .public)")
            showMonitorError("PetRunner could not repair its monitor hooks. \(error.localizedDescription)")
        }
    }

    private func startMonitorBridge() throws {
        monitorBridge.onEvent = { [weak self] event in
            guard let self, MonitorEventFilter(selectedProvider: self.preferences.monitorProvider).accepts(event) else { return }
            self.terminalSessionExpiry.removeValue(forKey: event.key)?.cancel()
            let changed = self.monitorStore.upsert(event)
            if event.status == .finished || event.status == .failed {
                self.expireTerminalSession(event.key)
            }
            if changed { self.refreshMonitorPresentation() }
        }
        try monitorBridge.start()
    }

    private func restoreRecoveredMonitorSessions() {
        let journal = AgentMonitorRecoveryJournal(url: AgentMonitorBridge.recoveryJournalURL)
        guard let events = try? journal.recoveredEvents(), !events.isEmpty else { return }
        for event in events where event.provider == preferences.monitorProvider {
            _ = monitorStore.upsert(event)
        }
        _ = monitorStore.select(at: 0)
        refreshMonitorPresentation()
    }

    private func selectPreviousSession() {
        monitorStore.selectPrevious()
        refreshMonitorPresentation()
    }

    private func selectNextSession() {
        monitorStore.selectNext()
        refreshMonitorPresentation()
    }

    private func setMonitorBubbleCollapsed(_ isCollapsed: Bool) {
        preferences.monitorBubbleCollapsed = isCollapsed
        refreshMonitorPresentation()
    }

    private func refreshMonitorPresentation() {
        guard let selected = monitorStore.selected else { sessionBubble.hide(); overlay.setMonitorAnimation(nil); return }
        overlay.setMonitorAnimation(selected.animation)
        sessionBubble.update(
            entries: monitorStore.entries,
            selectedIndex: monitorStore.selectedIndex,
            petFrame: overlay.frame,
            visibleFields: preferences.monitorBubbleFields,
            isCollapsed: preferences.monitorBubbleCollapsed
        )
    }

    private func expireTerminalSession(_ key: AgentSessionKey) {
        let expiry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.terminalSessionExpiry.removeValue(forKey: key)
            if self.monitorStore.remove(key) {
                self.refreshMonitorPresentation()
            }
        }
        terminalSessionExpiry[key] = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentSessionExpiryPolicy.gracePeriod(for: key), execute: expiry)
    }

    private func cancelTerminalExpiry() {
        terminalSessionExpiry.values.forEach { $0.cancel() }
        terminalSessionExpiry.removeAll()
    }

    private func showMonitorError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Agent Monitor"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
